import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';

Future<InternetAddress?> _wifiInterfaceAddress() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      if (name.startsWith('wlan') || name.startsWith('en')) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr;
          }
        }
      }
    }
  } catch (_) {}
  return null;
}

/// A discovered LAN-sync peer.
class LanPeer {
  final String deviceId;
  final String host;
  final int port;
  final String scopeId;
  final int protocolVersion;

  const LanPeer({
    required this.deviceId,
    required this.host,
    required this.port,
    this.scopeId = '',
    this.protocolVersion = 1,
  });

  bool matchesScope(
    String expectedScopeId, {
    bool allowUnscoped = false,
  }) =>
      protocolVersion == lanSyncProtocolVersion &&
      scopeId == expectedScopeId &&
      (scopeId.isNotEmpty || allowUnscoped);

  bool get isClosing => port == 0;

  @override
  String toString() => 'LanPeer($deviceId @ $host:$port)';
}

const int _beaconPort = 7438;
const Duration _beaconInterval = Duration(seconds: 2);
const Duration _scanDuration = Duration(seconds: 5);

/// Broadcasts a UDP discovery beacon so peers can find this device.
class MdnsAdvertiser {
  final String deviceId;
  final int port;
  String scopeId;

  RawDatagramSocket? _socket;
  Timer? _timer;

  MdnsAdvertiser({
    required this.deviceId,
    required this.port,
    required this.scopeId,
  });

  Future<void> start() async {
    if (_socket != null) return;
    final wifiAddr = await _wifiInterfaceAddress() ?? InternetAddress.anyIPv4;
    _socket = await RawDatagramSocket.bind(wifiAddr, 0,
        reuseAddress: false, reusePort: false);
    _socket!.broadcastEnabled = true;
    _sendBeacon();
    _timer = Timer.periodic(_beaconInterval, (_) => _sendBeacon());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _sendBeacon(closing: true);
    _socket?.close();
    _socket = null;
  }

  void _sendBeacon({bool closing = false}) {
    final sock = _socket;
    if (sock == null) return;
    final payload = utf8.encode(jsonEncode({
      'deviceId': deviceId,
      'port': closing ? 0 : port,
      'scopeId': scopeId,
      'protocolVersion': lanSyncProtocolVersion,
    }));
    try {
      sock.send(payload, InternetAddress('255.255.255.255'), _beaconPort);
    } catch (_) {}
  }
}

/// Listens for [MdnsAdvertiser] beacons and returns discovered peers.
class MdnsDiscovery {
  MdnsDiscovery._();

  /// Deterministic parser seam for verifying discovery isolation without
  /// binding a real UDP socket in tests.
  @visibleForTesting
  static LanPeer? parseBeaconForTesting({
    required List<int> data,
    required String sourceIp,
    required String localDeviceId,
    required String localScopeId,
    bool allowUnscoped = false,
  }) =>
      _parseBeacon(
        data: data,
        sourceIp: sourceIp,
        localDeviceId: localDeviceId,
        localScopeId: localScopeId,
        allowUnscoped: allowUnscoped,
      );

  static Future<List<LanPeer>> scan({
    required String localDeviceId,
    required String localScopeId,
    bool allowUnscoped = false,
  }) async {
    final peers = <LanPeer>[];
    final seen = <String>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, _beaconPort,
          reuseAddress: true, reusePort: false);
      final done = Completer<void>();
      Timer(_scanDuration, () {
        if (!done.isCompleted) done.complete();
      });
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final peer = _parseBeacon(
          data: datagram.data,
          sourceIp: datagram.address.address,
          localDeviceId: localDeviceId,
          localScopeId: localScopeId,
          allowUnscoped: allowUnscoped,
        );
        if (peer == null) return;
        if (peer.isClosing) {
          peers.removeWhere((item) => item.deviceId == peer.deviceId);
          seen.remove(peer.deviceId);
        } else if (seen.add(peer.deviceId)) {
          peers.add(peer);
        }
      });
      await done.future;
    } catch (_) {
      return [];
    } finally {
      socket?.close();
    }
    return peers;
  }

  static Stream<LanPeer> watch({
    required String localDeviceId,
    required String localScopeId,
    bool allowUnscoped = false,
    Duration duration = const Duration(hours: 1),
  }) async* {
    final ctrl = StreamController<LanPeer>();
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, _beaconPort,
          reuseAddress: true, reusePort: false);
      Timer(duration, ctrl.close);
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final peer = _parseBeacon(
          data: datagram.data,
          sourceIp: datagram.address.address,
          localDeviceId: localDeviceId,
          localScopeId: localScopeId,
          allowUnscoped: allowUnscoped,
        );
        if (peer != null) ctrl.add(peer);
      }, onDone: ctrl.close, onError: (_) => ctrl.close());
      yield* ctrl.stream;
    } catch (_) {
    } finally {
      socket?.close();
    }
  }

  static LanPeer? _parseBeacon({
    required List<int> data,
    required String sourceIp,
    required String localDeviceId,
    required String localScopeId,
    required bool allowUnscoped,
  }) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final id = json['deviceId'] as String? ?? '';
      final port = json['port'] as int? ?? 0;
      final scopeId = json['scopeId'] as String? ?? '';
      final protocolVersion = json['protocolVersion'] as int? ?? 0;
      if (id.isEmpty || port < 0 || id == localDeviceId) return null;
      if (protocolVersion != lanSyncProtocolVersion ||
          (!allowUnscoped && localScopeId.isEmpty) ||
          scopeId != localScopeId) {
        return null;
      }
      return LanPeer(
        deviceId: id,
        host: sourceIp,
        port: port,
        scopeId: scopeId,
        protocolVersion: protocolVersion,
      );
    } catch (_) {
      return null;
    }
  }
}
