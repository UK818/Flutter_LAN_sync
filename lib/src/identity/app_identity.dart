import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Mutual app-identity verification for the LAN sync handshake.
///
/// During handshake each side computes HMAC-SHA256(appSecret, peerDeviceId)
/// and sends the hex digest as `appToken`. The receiver recomputes and
/// compares — a mismatch means the peer is not a genuine instance of the app.
class AppIdentity {
  AppIdentity._();

  static String? _cachedPackageName;

  /// Returns the running app's package / bundle identifier (cached).
  static Future<String> getPackageName() async {
    if (_cachedPackageName != null) return _cachedPackageName!;
    final info = await PackageInfo.fromPlatform();
    _cachedPackageName = info.packageName;
    return _cachedPackageName!;
  }

  /// Returns `HMAC-SHA256(appSecret, deviceId)` as a lowercase hex string.
  static String computeHmac(String appSecret, String deviceId) {
    final key = utf8.encode(appSecret);
    final msg = utf8.encode(deviceId);
    return Hmac(sha256, key).convert(msg).toString();
  }

  /// Returns true when [hmac] matches the expected token for [deviceId].
  static bool verifyHmac(String appSecret, String deviceId, String hmac) =>
      computeHmac(appSecret, deviceId) == hmac;
}
