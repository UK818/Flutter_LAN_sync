import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../crdt/crdt_merger.dart';
import '../crypto/lan_sync_crypto.dart';
import '../database/lan_sync_database.dart';
import '../discovery/mdns_discovery.dart';
import '../identity/app_identity.dart';
import '../server/lan_sync_server.dart';
import '../presentation/ls_theme.dart';

/// Orchestrates the full LAN sync lifecycle.
///
/// Use [LanSync.initialize] rather than constructing this directly.
class LanSyncService {
  LanSyncService._({required LanSyncDatabase db, required LanSyncConfig config})
      : _db = db,
        _config = config;

  static LanSyncService? _instance;
  static bool get isInitialized => _instance != null;
  static LanSyncService get instance {
    assert(_instance != null, 'Call LanSync.initialize() first');
    return _instance!;
  }

  static final _onInitCtrl = StreamController<LanSyncService>.broadcast();
  static Stream<LanSyncService> get onInitialized => _onInitCtrl.stream;

  /// Invalidates the authenticated LAN realm and stops all network activity.
  /// A later call to [init] with a fresh signed-in configuration is required
  /// before the service can be started again.
  static Future<void> clearSession() async {
    final service = _instance;
    if (service == null) return;
    service._sessionActive = false;
    service._runGeneration++;
    await service.stop();
  }

  static Future<LanSyncService> init({
    required LanSyncDatabase db,
    required LanSyncConfig config,
  }) async {
    LsColors.setTheme(config.theme);
    if (_instance == null) {
      _instance = LanSyncService._(db: db, config: config);
      await _instance!._setUp();
    } else {
      await _instance!.updateConfig(config);
    }
    if (!_onInitCtrl.isClosed) _onInitCtrl.add(_instance!);
    return _instance!;
  }

  final LanSyncDatabase _db;
  LanSyncConfig _config;
  late final String _deviceId;
  late final LanSyncServer _server;
  late final MdnsAdvertiser _advertiser;

  bool _running = false;
  bool _sessionActive = true;
  bool _syncCycleRunning = false;
  int _runGeneration = 0;
  StreamSubscription<void>? _syncTimer;

  static const _storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _deviceIdKey = 'lan_sync_device_id';

  // ── Status stream ─────────────────────────────────────────────────────────────
  final _statusCtrl = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _statusCtrl.stream;
  SyncStatus _status = const SyncStatus();
  SyncStatus get currentStatus => _status;

  // ── Transfer stream ───────────────────────────────────────────────────────────
  final _transferCtrl = StreamController<LanPendingTransfer>.broadcast();
  Stream<LanPendingTransfer> get incomingTransferStream => _transferCtrl.stream;

  // ── Transfer history stream ───────────────────────────────────────────────────
  final _historyCtrl = StreamController<List<LanTransferLog>>.broadcast();
  Stream<List<LanTransferLog>> get transferHistoryStream => _historyCtrl.stream;

  String get deviceId => _deviceId;
  String get deviceName => _config.deviceName;
  String get scopeId => _config.scopeId;
  bool get hasActiveSession => _sessionActive;
  bool get allowsUnscopedPeers => !_config.requireScopedPeers;

  // ─── Setup ──────────────────────────────────────────────────────────────────

  Future<void> _setUp() async {
    _config.validatePeerScope();
    _deviceId = await _getOrCreateDeviceId();

    _server = LanSyncServer.create(
      db: _db,
      config: _config,
      localDeviceId: _deviceId,
    );
    _server.onItemsReceived = _handleIncomingItems;
    _advertiser = MdnsAdvertiser(
      deviceId: _deviceId,
      port: 7437,
      scopeId: _config.scopeId,
    );
  }

  Future<String> _getOrCreateDeviceId() async {
    final stored = await _storage.read(key: _deviceIdKey);
    if (stored != null) return stored;
    final id = const Uuid().v4();
    await _storage.write(key: _deviceIdKey, value: id);
    return id;
  }

  // ─── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> start({int syncIntervalMinutes = 15}) async {
    _requireActiveSession();
    if (_running) return;
    _config.validatePeerScope();
    final expectedScopeId = _config.scopeId;
    _runGeneration++;
    _running = true;
    try {
      _server.updateConfig(_config);
      await _server.start(port: 7437);
      _requireActiveScope(expectedScopeId);
      await _advertiser.start();
      _requireActiveScope(expectedScopeId);
      unawaited(_syncCycle());
      _syncTimer = Stream.periodic(Duration(minutes: syncIntervalMinutes))
          .listen((_) => unawaited(_syncCycle()));
      _emit(_status.copyWith(serverRunning: true, port: 7437));
    } catch (error) {
      _running = false;
      _runGeneration++;
      try {
        await _syncTimer?.cancel();
      } catch (_) {}
      _syncTimer = null;
      try {
        await _advertiser.stop();
      } catch (_) {}
      try {
        await _server.stop();
      } catch (_) {}
      _emit(
        _status.copyWith(
          serverRunning: false,
          syncing: false,
          lastError: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<void> stop() async {
    _running = false;
    _runGeneration++;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> cleanUp(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await cleanUp(() async => _syncTimer?.cancel());
    _syncTimer = null;
    // Stop advertising first so peers immediately stop presenting this
    // authenticated realm, even if closing the HTTP server later fails.
    await cleanUp(_advertiser.stop);
    await cleanUp(_server.stop);
    _emit(_status.copyWith(serverRunning: false, syncing: false));
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  // ─── Sync cycle ─────────────────────────────────────────────────────────────

  Future<void> _syncCycle() async {
    if (!_running || !_sessionActive || _syncCycleRunning) return;
    _syncCycleRunning = true;
    try {
      await _performSyncCycle();
    } finally {
      _syncCycleRunning = false;
    }
  }

  Future<void> _performSyncCycle() async {
    final runGeneration = _runGeneration;
    final cycleScopeId = _config.scopeId;
    _emit(_status.copyWith(syncing: true, lastError: null));
    int successCount = 0;
    try {
      final peers = await MdnsDiscovery.scan(
        localDeviceId: _deviceId,
        localScopeId: cycleScopeId,
        allowUnscoped: !_config.requireScopedPeers,
      );
      if (!_isCurrentRun(runGeneration, cycleScopeId)) return;
      for (final peer in peers) {
        if (!_isCurrentRun(runGeneration, cycleScopeId)) return;
        final device = await _db.getDevice(peer.deviceId);
        if (device == null || !_isAuthorizedDevice(device)) continue;
        try {
          await _syncWithPeer(peer, device);
          await _db.incrementSyncCount(peer.deviceId);
          successCount++;
        } catch (_) {}
      }
    } catch (e) {
      if (!_isCurrentRun(runGeneration, cycleScopeId)) return;
      _emit(_status.copyWith(syncing: false, lastError: e.toString()));
      return;
    }
    if (!_isCurrentRun(runGeneration, cycleScopeId)) return;
    _emit(_status.copyWith(
      syncing: false,
      lastSyncAt: DateTime.now(),
      peersSynced: successCount,
    ));
  }

  Future<void> syncNow() => _syncCycle();

  Future<void> syncWithPeer(LanPeer peer) async {
    _requireActiveSession();
    _requireCompatiblePeer(peer);
    final device = await _db.getDevice(peer.deviceId);
    if (device == null || !_isAuthorizedDevice(device)) {
      throw Exception('Device not found or not approved');
    }
    await _syncWithPeer(peer, device);
    await _db.incrementSyncCount(peer.deviceId);
  }

  Future<void> _syncWithPeer(LanPeer peer, LanDevice device) async {
    _requireActiveSession();
    final expectedScopeId = _config.scopeId;
    final operationGeneration = _runGeneration;
    _requireCompatiblePeer(peer);
    if (!_isAuthorizedDevice(device)) {
      throw StateError('Device is not authorized for this LAN sync scope.');
    }
    final base = 'http://${peer.host}:${peer.port}';
    final sharedKey = await LanSyncCrypto.deriveSharedKey(device.publicKey);
    _requireActiveOperation(expectedScopeId, operationGeneration);

    // Push
    final unsyncedLogs = await _db.getUnsyncedLogs(scopeId: expectedScopeId);
    if (unsyncedLogs.isNotEmpty) {
      final payload = unsyncedLogs.map((l) => l.toJson()).toList();
      final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      final cipher = await LanSyncCrypto.encrypt(plain, sharedKey);
      _requireActiveOperation(expectedScopeId, operationGeneration);
      final pushResp = await http
          .post(
            Uri.parse('$base/sync/push'),
            headers: {
              'content-type': 'application/json',
              'x-device-id': _deviceId,
              'x-lan-scope': expectedScopeId,
            },
            body: jsonEncode({'data': base64Url.encode(cipher)}),
          )
          .timeout(const Duration(seconds: 30));
      if (pushResp.statusCode == 200) {
        _requireActiveOperation(expectedScopeId, operationGeneration);
        final ids = unsyncedLogs.map((l) => l.id).toList();
        await _db.markLogsSynced(
          ids,
          peer.deviceId,
          scopeId: expectedScopeId,
        );
      }
    }

    // Pull
    _requireActiveOperation(expectedScopeId, operationGeneration);
    final localLogs = await _db.getLogsSince(0, scopeId: expectedScopeId);
    final sinceHlc = localLogs.isEmpty ? 0 : localLogs.last.hlcTimestamp;
    final pullResp = await http.get(
      Uri.parse('$base/sync/pull?since=$sinceHlc'),
      headers: {
        'x-device-id': _deviceId,
        'x-lan-scope': expectedScopeId,
      },
    ).timeout(const Duration(seconds: 30));

    if (pullResp.statusCode != 200) return;
    _requireActiveOperation(expectedScopeId, operationGeneration);

    final pullBody = jsonDecode(pullResp.body) as Map<String, dynamic>;
    final cipherBytes = base64Url.decode(pullBody['data'] as String);
    final plainBytes = await LanSyncCrypto.decrypt(cipherBytes, sharedKey);
    final remoteLogs = (jsonDecode(utf8.decode(plainBytes)) as List)
        .cast<Map<String, dynamic>>();

    if (remoteLogs.isEmpty) return;

    // CRDT merge
    final byEntity = <String, List<Map<String, dynamic>>>{};
    for (final log in remoteLogs) {
      byEntity.putIfAbsent(log['entityId'] as String, () => []).add(log);
    }

    for (final entry in byEntity.entries) {
      final entityId = entry.key;
      final remoteEntityLogs = entry.value
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
                scopeId: expectedScopeId,
              ))
          .toList();

      _requireActiveOperation(expectedScopeId, operationGeneration);
      final localEntityLogs = await _db.getLogsForEntity(
        entityId,
        scopeId: expectedScopeId,
      );
      final result = CrdtMerger.merge(
        deviceId: _deviceId,
        localLogs: localEntityLogs,
        remoteLogs: remoteEntityLogs,
      );

      if (result.winners.isNotEmpty) {
        _requireActiveOperation(expectedScopeId, operationGeneration);
        await _db.insertLogs(result.winners);
      }
    }

    for (final log in remoteLogs) {
      Hlc.receive(log['hlcTimestamp'] as int);
    }
  }

  bool _isScopedVerifiedDevice(LanDevice device) =>
      device.appVerified &&
      device.scopeId == _config.scopeId &&
      device.protocolVersion == lanSyncProtocolVersion &&
      LanSyncConfig.normalizeScopePart(device.packageName ?? '') ==
          LanSyncConfig.normalizeScopePart(_config.packageName);

  bool _isAuthorizedDevice(LanDevice device) =>
      device.approved && _isScopedVerifiedDevice(device);

  void _requireCompatiblePeer(LanPeer peer) {
    _requireActiveSession();
    if (!peer.matchesScope(
      _config.scopeId,
      allowUnscoped: !_config.requireScopedPeers,
    )) {
      throw StateError(
        'This device is not signed in to the same app instance and facility.',
      );
    }
  }

  bool _isCurrentRun(int generation, String expectedScopeId) =>
      _running &&
      _sessionActive &&
      generation == _runGeneration &&
      expectedScopeId == _config.scopeId;

  void _requireActiveSession() {
    if (!_sessionActive) {
      throw StateError(
        'The LAN sync session ended. Sign in and reopen LAN Device Sync.',
      );
    }
    _config.validatePeerScope();
  }

  void _requireActiveScope(String expectedScopeId) {
    _requireActiveSession();
    if (_config.scopeId != expectedScopeId) {
      throw StateError('The LAN sync facility or app instance changed.');
    }
  }

  void _requireActiveOperation(String expectedScopeId, int generation) {
    _requireActiveScope(expectedScopeId);
    if (_runGeneration != generation) {
      throw StateError('The LAN sync network session changed.');
    }
  }

  // ─── Handshake (client-side) ─────────────────────────────────────────────────

  Future<void> handshakeWithPeer(LanPeer peer) async {
    _requireActiveSession();
    _requireCompatiblePeer(peer);
    final config = _config;
    final expectedScopeId = config.scopeId;
    final operationGeneration = _runGeneration;
    final localPub = await LanSyncCrypto.getPublicKeyBase64();
    _requireActiveOperation(expectedScopeId, operationGeneration);
    final packageName = config.packageName;
    final appToken = AppIdentity.computeHmac(config.appSecret, _deviceId);

    final resp = await http
        .post(
          Uri.parse('http://${peer.host}:${peer.port}/handshake'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'deviceId': _deviceId,
            'publicKey': localPub,
            'name': config.deviceName,
            'packageName': packageName,
            'appToken': appToken,
            'facilityId': config.facilityId,
            'instanceType': config.instanceType,
            'scopeId': expectedScopeId,
            'protocolVersion': lanSyncProtocolVersion,
          }),
        )
        .timeout(const Duration(seconds: 10));
    _requireActiveOperation(expectedScopeId, operationGeneration);

    if (resp.statusCode == 403) {
      String message = 'App verification rejected by remote device.';
      try {
        final err = jsonDecode(resp.body) as Map<String, dynamic>;
        message = err['message'] as String? ?? message;
      } catch (_) {}
      throw Exception(message);
    }
    if (resp.statusCode != 200) {
      throw Exception(
          'Handshake failed (HTTP ${resp.statusCode}): ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final peerPub = body['publicKey'] as String;
    final serverDeviceId = body['deviceId'] as String? ?? peer.deviceId;
    final serverToken = body['appToken'] as String? ?? '';
    final serverPackageName = body['packageName'] as String? ?? '';
    final serverFacilityId = body['facilityId'] as String? ?? '';
    final serverInstanceType = body['instanceType'] as String? ?? '';
    final serverScopeId = body['scopeId'] as String? ?? '';
    final serverProtocolVersion = body['protocolVersion'] as int? ?? 0;

    if (serverDeviceId != peer.deviceId) {
      throw Exception('The remote device identity changed during handshake.');
    }

    if (LanSyncConfig.normalizeScopePart(serverPackageName) !=
        LanSyncConfig.normalizeScopePart(config.packageName)) {
      throw Exception('The remote device is not running the same app.');
    }

    if (!config.acceptsPeerScope(
      peerFacilityId: serverFacilityId,
      peerInstanceType: serverInstanceType,
      peerScopeId: serverScopeId,
      peerProtocolVersion: serverProtocolVersion,
    )) {
      throw Exception(
        'The remote device is not signed in to the same app instance and facility.',
      );
    }

    if (!AppIdentity.verifyHmac(
        config.appSecret, serverDeviceId, serverToken)) {
      throw Exception('The remote device did not pass app verification.');
    }

    _requireActiveOperation(expectedScopeId, operationGeneration);
    await _db.upsertDevice(
      id: peer.deviceId,
      name: body['deviceName'] as String? ?? peer.deviceId,
      publicKey: peerPub,
      scopeId: expectedScopeId,
      protocolVersion: lanSyncProtocolVersion,
    );
    _requireActiveOperation(expectedScopeId, operationGeneration);
    await _db.markAppVerified(peer.deviceId, serverPackageName);
  }

  // ─── Incoming item transfer ──────────────────────────────────────────────────

  Future<void> _handleIncomingItems(
    String deviceId,
    String deviceName,
    String dataJson,
    String expectedScopeId,
  ) async {
    final operationGeneration = _runGeneration;
    final config = _config;
    _requireActiveOperation(expectedScopeId, operationGeneration);
    final rawItems =
        (jsonDecode(dataJson) as List).cast<Map<String, dynamic>>();
    await config.validateIncoming?.call(rawItems);
    _requireActiveOperation(expectedScopeId, operationGeneration);
    final count = rawItems.length;
    final id = const Uuid().v4();
    final transfer = await _db.insertTransferAndGet(
      id: id,
      fromDeviceId: deviceId,
      fromDeviceName: deviceName,
      transferredAt: DateTime.now().millisecondsSinceEpoch,
      itemCount: count,
      dataJson: dataJson,
      scopeId: expectedScopeId,
    );
    _requireActiveOperation(expectedScopeId, operationGeneration);
    if (!_transferCtrl.isClosed) {
      _transferCtrl.add(transfer);
    }
  }

  // ─── Item push (outgoing) ────────────────────────────────────────────────────

  Future<void> pushItems(LanPeer peer, List<LanSyncItem> items) async {
    _requireActiveSession();
    if (items.isEmpty) return;
    _requireCompatiblePeer(peer);
    final config = _config;
    final expectedScopeId = _config.scopeId;
    final operationGeneration = _runGeneration;
    final device = await _db.getDevice(peer.deviceId);
    if (device == null || !_isAuthorizedDevice(device)) {
      throw Exception('Device not approved');
    }

    final sharedKey = await LanSyncCrypto.deriveSharedKey(device.publicKey);
    final dataJson = jsonEncode(items.map((i) => i.data).toList());
    final plain = Uint8List.fromList(utf8.encode(dataJson));
    final cipher = await LanSyncCrypto.encrypt(plain, sharedKey);
    _requireActiveOperation(expectedScopeId, operationGeneration);

    final resp = await http
        .post(
          Uri.parse('http://${peer.host}:${peer.port}/items/push'),
          headers: {
            'content-type': 'application/json',
            'x-device-id': _deviceId,
            'x-lan-scope': expectedScopeId,
          },
          body: jsonEncode({'data': base64Url.encode(cipher)}),
        )
        .timeout(const Duration(seconds: 30));
    _requireActiveOperation(expectedScopeId, operationGeneration);

    if (resp.statusCode != 200) {
      throw Exception(
          'Item push failed (HTTP ${resp.statusCode}): ${resp.body}');
    }

    final outNames = jsonEncode(items.map((i) => i.displayName).toList());
    await _db.insertTransferLog(
      id: const Uuid().v4(),
      deviceId: peer.deviceId,
      deviceName: device.name,
      itemCount: items.length,
      direction: 'outgoing',
      completedAt: DateTime.now().millisecondsSinceEpoch,
      itemNamesJson: outNames,
      scopeId: expectedScopeId,
    );
    _requireActiveOperation(expectedScopeId, operationGeneration);
    unawaited(_notifyHistoryUpdated());

    final toName = device.name.isNotEmpty ? device.name : 'a peer device';
    config.onActivity?.call(
      'items_sent',
      'Sent ${items.length} item${items.length == 1 ? "" : "s"} to $toName via LAN sync',
    );
  }

  // ─── Approval ────────────────────────────────────────────────────────────────

  Future<void> approveTransfer(String transferId) async {
    _requireActiveSession();
    final config = _config;
    final expectedScopeId = config.scopeId;
    final operationGeneration = _runGeneration;
    final transfer = await _db.getTransfer(
      transferId,
      scopeId: expectedScopeId,
    );
    if (transfer == null) throw Exception('Transfer not found');

    final rawList =
        (jsonDecode(transfer.dataJson) as List).cast<Map<String, dynamic>>();

    try {
      await config.onReceive(rawList);
      _requireActiveOperation(expectedScopeId, operationGeneration);
    } catch (_) {
      // Invalid or no-longer-authorized payloads must not remain pending and
      // repeatedly prompt after the host app rejects them.
      await _db.updateTransferStatus(
        transferId,
        'rejected',
        scopeId: expectedScopeId,
      );
      rethrow;
    }

    await _db.approveTransferAndInsertLog(
      transferId: transferId,
      id: const Uuid().v4(),
      deviceId: transfer.fromDeviceId,
      deviceName: transfer.fromDeviceName,
      itemCount: transfer.itemCount,
      direction: 'incoming',
      completedAt: DateTime.now().millisecondsSinceEpoch,
      scopeId: expectedScopeId,
    );
    unawaited(_notifyHistoryUpdated());

    final fromName = transfer.fromDeviceName.isNotEmpty
        ? transfer.fromDeviceName
        : 'a peer device';
    config.onTransferNotification?.call(transfer.itemCount, fromName);
    config.onActivity?.call(
      'items_received',
      'Received ${transfer.itemCount} item${transfer.itemCount == 1 ? "" : "s"} from $fromName via LAN sync',
    );
  }

  Future<void> rejectTransfer(String transferId) {
    _requireActiveSession();
    return _db.updateTransferStatus(
      transferId,
      'rejected',
      scopeId: _config.scopeId,
    );
  }

  Future<void> _notifyHistoryUpdated() async {
    final logs = await _db.getTransferLogs(scopeId: _config.scopeId);
    if (!_historyCtrl.isClosed) _historyCtrl.add(logs);
  }

  // ─── Accessors ───────────────────────────────────────────────────────────────

  Future<List<LanPendingTransfer>> getPendingTransfers() =>
      _getPendingTransfersForActiveSession();

  Future<List<LanPendingTransfer>> _getPendingTransfersForActiveSession() {
    _requireActiveSession();
    return _db.getPendingTransfers(scopeId: _config.scopeId);
  }

  Future<List<LanTransferLog>> getTransferHistory({int limit = 50}) {
    _requireActiveSession();
    return _db.getTransferLogs(scopeId: _config.scopeId, limit: limit);
  }

  Future<List<LanTransferLog>> getTransferHistoryForDevice(
    String deviceId, {
    int limit = 50,
  }) {
    _requireActiveSession();
    return _db.getTransferLogsForDevice(
      deviceId,
      scopeId: _config.scopeId,
      limit: limit,
    );
  }

  Future<void> approveDevice(String deviceId) async {
    _requireActiveSession();
    final device = await _db.getDevice(deviceId);
    if (device == null || !_isScopedVerifiedDevice(device)) {
      throw StateError('Device is not verified for this LAN sync scope.');
    }
    await _db.approveDevice(deviceId);
  }

  Future<void> revokeDevice(String deviceId) async {
    _requireActiveSession();
    final device = await _db.getDevice(deviceId);
    if (device == null || device.scopeId != _config.scopeId) return;
    await _db.revokeDevice(deviceId);
  }

  Future<List<LanDevice>> getAllDevices() {
    _requireActiveSession();
    return _db.getAllDevices(scopeId: _config.scopeId);
  }

  Stream<List<LanDevice>> watchAllDevices() {
    _requireActiveSession();
    return _db.watchAllDevices(scopeId: _config.scopeId);
  }

  Future<bool> isDeviceAppVerified(String deviceId) async {
    _requireActiveSession();
    final device = await _db.getDevice(deviceId);
    return device != null && _isScopedVerifiedDevice(device);
  }

  void _emit(SyncStatus s) {
    _status = s;
    _statusCtrl.add(s);
  }

  /// Call this when the logged-in user changes so the config is refreshed.
  Future<void> updateConfig(LanSyncConfig config) async {
    config.validatePeerScope();
    final scopeChanged = config.scopeId != _config.scopeId;
    if (scopeChanged && _running) await stop();
    _config = config;
    _sessionActive = true;
    _server.updateConfig(config);
    _advertiser.scopeId = config.scopeId;
  }
}

// ─── Hardware device name helper ─────────────────────────────────────────────

Future<String> getLanSyncDeviceName() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) return (await info.androidInfo).model;
    if (Platform.isIOS) return (await info.iosInfo).name;
  } catch (_) {}
  return 'Peer Device';
}

// ─── Status model ─────────────────────────────────────────────────────────────

class SyncStatus {
  final bool serverRunning;
  final bool syncing;
  final int port;
  final DateTime? lastSyncAt;
  final int peersSynced;
  final String? lastError;

  const SyncStatus({
    this.serverRunning = false,
    this.syncing = false,
    this.port = 0,
    this.lastSyncAt,
    this.peersSynced = 0,
    this.lastError,
  });

  SyncStatus copyWith({
    bool? serverRunning,
    bool? syncing,
    int? port,
    DateTime? lastSyncAt,
    int? peersSynced,
    String? lastError,
  }) =>
      SyncStatus(
        serverRunning: serverRunning ?? this.serverRunning,
        syncing: syncing ?? this.syncing,
        port: port ?? this.port,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        peersSynced: peersSynced ?? this.peersSynced,
        lastError: lastError ?? this.lastError,
      );
}
