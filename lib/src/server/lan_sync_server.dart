import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../config.dart';
import '../crypto/lan_sync_crypto.dart';
import '../database/lan_sync_database.dart';
import '../identity/app_identity.dart';

/// Shelf HTTP server exposing the LAN-sync API.
///
/// Endpoints
/// ─────────
/// POST /handshake     — X25519 key exchange + HMAC mutual app verification
/// POST /sync/push     — push encrypted CRDT SyncLog batch
/// GET  /sync/pull     — pull encrypted CRDT SyncLog batch
/// POST /items/push    — transfer encrypted item batch (requires approval)
class LanSyncServer {
  LanSyncServer._({
    required LanSyncDatabase db,
    required LanSyncConfig config,
    required String localDeviceId,
  })  : _db = db,
        _config = config,
        _localDeviceId = localDeviceId;

  final LanSyncDatabase _db;
  LanSyncConfig _config;
  final String _localDeviceId;

  /// Called when a peer pushes item data:
  /// (deviceId, deviceName, dataJson, authenticatedScopeId).
  Future<void> Function(String, String, String, String)? onItemsReceived;

  HttpServer? _httpServer;
  int? _port;
  bool _acceptingRequests = false;
  int _serverGeneration = 0;

  int? get port => _port;
  bool get isRunning => _httpServer != null;

  static LanSyncServer? _instance;

  static LanSyncServer create({
    required LanSyncDatabase db,
    required LanSyncConfig config,
    required String localDeviceId,
  }) {
    _instance =
        LanSyncServer._(db: db, config: config, localDeviceId: localDeviceId);
    return _instance!;
  }

  void updateConfig(LanSyncConfig config) => _config = config;

  Future<void> start({int port = 7437}) async {
    if (_httpServer != null) return;

    final router = Router()
      ..post('/handshake', _handleHandshake)
      ..post('/sync/push', _withAuth(_handlePush))
      ..get('/sync/pull', _withAuth(_handlePull))
      ..post('/items/push', _withAuth(_handleItemPush));

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_corsMiddleware())
        .addHandler(router.call);

    _httpServer = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    _port = port;
    _serverGeneration++;
    _acceptingRequests = true;
  }

  Future<void> stop() async {
    _acceptingRequests = false;
    _serverGeneration++;
    await _httpServer?.close(force: true);
    _httpServer = null;
    _port = null;
  }

  // ── Middleware ───────────────────────────────────────────────────────────────

  Handler _withAuth(Handler handler) {
    return (Request req) async {
      final config = _config;
      final expectedScopeId = config.scopeId;
      final requestGeneration = _serverGeneration;
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }
      try {
        config.validatePeerScope();
      } catch (_) {
        return Response(403, body: 'LAN sync session is not scoped');
      }
      final deviceId = req.headers['x-device-id'];
      if (deviceId == null || deviceId.isEmpty) {
        return Response(401, body: 'Missing X-Device-Id header');
      }
      final device = await _db.getDevice(deviceId);
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }
      if (device == null) return Response(403, body: 'Unknown device');
      if (!device.approved) return Response(403, body: 'Device not approved');
      if (!device.appVerified ||
          device.scopeId != expectedScopeId ||
          device.protocolVersion != lanSyncProtocolVersion ||
          LanSyncConfig.normalizeScopePart(device.packageName ?? '') !=
              LanSyncConfig.normalizeScopePart(config.packageName) ||
          req.headers['x-lan-scope'] != expectedScopeId) {
        return Response(403, body: 'Device is not authorized for this scope');
      }

      final remoteIp =
          (req.context['shelf.io.connection_info'] as HttpConnectionInfo?)
                  ?.remoteAddress
                  .address ??
              '';
      unawaited(_db.updateLastSeen(deviceId, remoteIp, device.lastPort ?? 0));
      return handler(
        req.change(
          context: {
            'lan_sync_scope_id': expectedScopeId,
            'lan_sync_server_generation': requestGeneration,
          },
        ),
      );
    };
  }

  bool _isRequestActive(String expectedScopeId, int generation) =>
      _acceptingRequests &&
      _serverGeneration == generation &&
      _config.scopeId == expectedScopeId;

  String _requestScope(Request req) =>
      req.context['lan_sync_scope_id'] as String;

  int _requestGeneration(Request req) =>
      req.context['lan_sync_server_generation'] as int;

  Middleware _corsMiddleware() {
    return (Handler inner) {
      return (Request req) async {
        final response = await inner(req);
        return response.change(headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers':
              'X-Device-Id, X-Lan-Scope, Content-Type',
        });
      };
    };
  }

  // ── Handlers ─────────────────────────────────────────────────────────────────

  /// POST /handshake
  ///
  /// Request:  { deviceId, publicKey, name, packageName, appToken, facilityId, instanceType }
  /// Response: { deviceId, publicKey, appToken }
  Future<Response> _handleHandshake(Request req) async {
    final config = _config;
    final expectedScopeId = config.scopeId;
    final requestGeneration = _serverGeneration;
    if (!_isRequestActive(expectedScopeId, requestGeneration)) {
      return Response(503, body: 'LAN sync server is stopping');
    }
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final peerId = body['deviceId'] as String? ?? '';
      final peerPub = body['publicKey'] as String? ?? '';
      final peerName = body['name'] as String? ?? 'Unknown';
      final peerPackage = body['packageName'] as String? ?? '';
      final appToken = body['appToken'] as String? ?? '';
      final peerFacilityId = body['facilityId'] as String? ?? '';
      final peerInstanceType = body['instanceType'] as String? ?? '';
      final peerScopeId = body['scopeId'] as String? ?? '';
      final peerProtocolVersion = body['protocolVersion'] as int? ?? 0;

      if (peerId.isEmpty || peerPub.isEmpty || peerId == _localDeviceId) {
        return Response(400, body: 'Missing deviceId or publicKey');
      }

      try {
        config.validatePeerScope();
      } catch (_) {
        return Response.forbidden(
          jsonEncode({
            'error': 'local_scope_missing',
            'message': 'Sign in to a facility and app instance before syncing.',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      // 1. Package name check
      if (LanSyncConfig.normalizeScopePart(peerPackage) !=
          LanSyncConfig.normalizeScopePart(config.packageName)) {
        return Response.forbidden(
          jsonEncode({
            'error': 'app_not_verified',
            'message': 'Package name mismatch.',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      // 2. HMAC verification
      if (!AppIdentity.verifyHmac(config.appSecret, peerId, appToken)) {
        return Response.forbidden(
          jsonEncode({
            'error': 'app_not_verified',
            'message': 'App token verification failed.',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      // 3. Fail closed when the peer is unsigned, legacy, or belongs to a
      // different facility/app instance.
      if (!config.acceptsPeerScope(
        peerFacilityId: peerFacilityId,
        peerInstanceType: peerInstanceType,
        peerScopeId: peerScopeId,
        peerProtocolVersion: peerProtocolVersion,
      )) {
        return Response.forbidden(
          jsonEncode({
            'error': 'scope_mismatch',
            'message':
                'Devices must use the same app instance and facility to sync.',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      // 4. Upsert device
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }
      await _db.upsertDevice(
        id: peerId,
        name: peerName,
        publicKey: peerPub,
        scopeId: expectedScopeId,
        protocolVersion: lanSyncProtocolVersion,
      );
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }
      await _db.markAppVerified(peerId, peerPackage);

      // 5. Respond with our public key + our HMAC
      final localPub = await LanSyncCrypto.getPublicKeyBase64();
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }
      final serverToken = AppIdentity.computeHmac(
        config.appSecret,
        _localDeviceId,
      );

      return Response.ok(
        jsonEncode({
          'deviceId': _localDeviceId,
          'deviceName': config.deviceName,
          'publicKey': localPub,
          'appToken': serverToken,
          'packageName': config.packageName,
          'facilityId': config.facilityId,
          'instanceType': config.instanceType,
          'scopeId': expectedScopeId,
          'protocolVersion': lanSyncProtocolVersion,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response(500, body: 'Handshake error: $e');
    }
  }

  /// POST /sync/push — receive encrypted CRDT logs from peer.
  Future<Response> _handlePush(Request req) async {
    final peerId = req.headers['x-device-id']!;
    final expectedScopeId = _requestScope(req);
    final requestGeneration = _requestGeneration(req);
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final ciphertext = body['data'] as String? ?? '';
      final peer = await _db.getDevice(peerId);
      if (peer == null) return Response(403, body: 'Unknown device');

      final sharedKey = await LanSyncCrypto.deriveSharedKey(peer.publicKey);
      final plain =
          await LanSyncCrypto.decrypt(base64Url.decode(ciphertext), sharedKey);
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }

      final logs =
          (jsonDecode(utf8.decode(plain)) as List).cast<Map<String, dynamic>>();

      final lanLogs = logs
          .map((j) => LanSyncLog(
                id: j['id'] as String,
                deviceId: j['deviceId'] as String,
                entityType: j['entityType'] as String,
                entityId: j['entityId'] as String,
                fieldName: j['fieldName'] as String,
                oldValue: j['oldValue'] as String?,
                newValue: j['newValue'] as String?,
                hlcTimestamp: j['hlcTimestamp'] as int,
                vectorClock: j['vectorClock'] as int? ?? 0,
                synced: true,
                syncedToDevices: '[]',
                // Never trust a peer-supplied realm. The authenticated HTTP
                // scope determines where received CRDT records are stored.
                scopeId: expectedScopeId,
              ))
          .toList();

      final ids = logs.map((l) => l['id'] as String).toList();
      await _db.insertAndMarkLogsSynced(
        lanLogs,
        ids: ids,
        scopeId: expectedScopeId,
      );

      return Response.ok(
        jsonEncode({'accepted': ids.length}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response(500, body: 'Push error: $e');
    }
  }

  /// GET /sync/pull?since={hlcTimestamp} — send our logs to peer.
  Future<Response> _handlePull(Request req) async {
    final peerId = req.headers['x-device-id']!;
    final expectedScopeId = _requestScope(req);
    final requestGeneration = _requestGeneration(req);
    try {
      final sinceParam = req.url.queryParameters['since'] ?? '0';
      final since = int.tryParse(sinceParam) ?? 0;
      final logs = await _db.getLogsSince(
        since,
        scopeId: expectedScopeId,
      );
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }

      final peer = await _db.getDevice(peerId);
      if (peer == null) return Response(403, body: 'Unknown device');

      final sharedKey = await LanSyncCrypto.deriveSharedKey(peer.publicKey);
      final payload = logs.map((l) => l.toJson()).toList();
      final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      final cipher = await LanSyncCrypto.encrypt(plain, sharedKey);
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }

      return Response.ok(
        jsonEncode({'data': base64Url.encode(cipher)}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response(500, body: 'Pull error: $e');
    }
  }

  /// POST /items/push — receive an encrypted batch of items from peer.
  Future<Response> _handleItemPush(Request req) async {
    final peerId = req.headers['x-device-id']!;
    final expectedScopeId = _requestScope(req);
    final requestGeneration = _requestGeneration(req);
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final ciphertext = body['data'] as String? ?? '';

      final peer = await _db.getDevice(peerId);
      if (peer == null) return Response(403, body: 'Unknown device');

      final sharedKey = await LanSyncCrypto.deriveSharedKey(peer.publicKey);
      final plain =
          await LanSyncCrypto.decrypt(base64Url.decode(ciphertext), sharedKey);
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }

      final dataJson = utf8.decode(plain);
      final count = (jsonDecode(dataJson) as List).length;

      await onItemsReceived?.call(
        peerId,
        peer.name,
        dataJson,
        expectedScopeId,
      );
      if (!_isRequestActive(expectedScopeId, requestGeneration)) {
        return Response(503, body: 'LAN sync server is stopping');
      }

      return Response.ok(
        jsonEncode({'accepted': count}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response(500, body: 'Item push error: $e');
    }
  }
}
