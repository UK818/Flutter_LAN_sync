import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import 'presentation/ls_theme.dart';

/// Current wire/storage compatibility version for scoped LAN peers.
const int lanSyncProtocolVersion = 2;

/// A single item to transfer over LAN sync.
///
/// ```dart
/// LanSyncItem(
///   id: patient.id,
///   displayName: patient.fullName,
///   data: patient.toJson(),
/// )
/// ```
class LanSyncItem {
  /// Stable identifier used to match this item across peers.
  final String id;

  /// Human-readable label shown in transfer-selection interfaces.
  final String displayName;

  /// JSON-serializable payload transferred to the receiving peer.
  final Map<String, dynamic> data;

  /// Optional host-defined category for heterogeneous item collections.
  final String? dataType;

  /// Creates an item that can be offered to a LAN peer.
  const LanSyncItem({
    required this.id,
    required this.displayName,
    required this.data,
    this.dataType,
  });
}

/// Configuration passed to [LanSync.initialize].
///
/// All callbacks are optional except [onReceive].
class LanSyncConfig {
  /// Shared secret embedded in all genuine builds of your app.
  /// Both sides must have the same value — mismatches reject the handshake.
  final String appSecret;

  /// Your app's Android package name / iOS bundle identifier.
  /// Used to prevent cross-app connections during handshake.
  final String packageName;

  /// Human-readable name for this device (e.g. logged-in user's name).
  final String deviceName;

  /// Optional host-controlled theme for the package widgets.
  final LanSyncTheme? theme;

  /// Optional: restricts sync to devices in the same facility.
  final String facilityId;

  /// Optional: restricts sync to devices using the same instance type.
  final String instanceType;

  /// When true, LAN sync fails closed unless both [facilityId] and
  /// [instanceType] are present and match on both devices.
  final bool requireScopedPeers;

  /// Called when the user approves an incoming transfer.
  /// Receives the raw [data] maps from each [LanSyncItem] sent by the peer.
  final Future<void> Function(List<Map<String, dynamic>> items) onReceive;

  /// Optional fail-fast validation before an incoming transfer is persisted
  /// or shown for approval. Throw to reject malformed or out-of-realm data.
  final Future<void> Function(List<Map<String, dynamic>> items)?
      validateIncoming;

  /// Optional: called after a transfer is approved so you can show a
  /// local notification. Receives the item count and the sender's device name.
  final void Function(int count, String fromDevice)? onTransferNotification;

  /// Optional: called for audit-log events (e.g. "items_sent", "items_received").
  final void Function(String action, String description)? onActivity;

  /// Required for [LanTransferListener] to display the approval sheet over
  /// any screen. Pass the same key used by your [MaterialApp].
  final GlobalKey<NavigatorState>? navigatorKey;

  const LanSyncConfig({
    required this.appSecret,
    required this.packageName,
    required this.deviceName,
    required this.onReceive,
    this.theme,
    this.facilityId = '',
    this.instanceType = '',
    this.requireScopedPeers = false,
    this.validateIncoming,
    this.onTransferNotification,
    this.onActivity,
    this.navigatorKey,
  });

  /// Normalizes a scope component before comparison or signing.
  static String normalizeScopePart(String value) => value.trim().toLowerCase();

  /// Normalized facility identifier used for peer-scope checks.
  String get normalizedFacilityId => normalizeScopePart(facilityId);

  /// Normalized instance type used for peer-scope checks.
  String get normalizedInstanceType => normalizeScopePart(instanceType);

  /// Whether both values required for scoped peer matching are available.
  bool get hasCompletePeerScope =>
      normalizedFacilityId.isNotEmpty && normalizedInstanceType.isNotEmpty;

  /// Opaque HMAC scope advertised on the LAN instead of exposing facility IDs.
  String get scopeId {
    if (!hasCompletePeerScope) return '';
    final key = utf8.encode(appSecret);
    final value = [
      'lan-sync-v$lanSyncProtocolVersion',
      normalizeScopePart(packageName),
      normalizedFacilityId,
      normalizedInstanceType,
    ].join('|');
    return Hmac(sha256, key).convert(utf8.encode(value)).toString();
  }

  /// Throws when strict peer scoping is enabled without complete scope data.
  void validatePeerScope() {
    if (requireScopedPeers && !hasCompletePeerScope) {
      throw StateError(
        'LAN sync requires a signed-in app instance and facility.',
      );
    }
  }

  /// Returns whether a peer's signed scope matches this configuration.
  bool acceptsPeerScope({
    required String peerFacilityId,
    required String peerInstanceType,
    required String peerScopeId,
    required int peerProtocolVersion,
  }) {
    if (peerProtocolVersion != lanSyncProtocolVersion) return false;
    if (!hasCompletePeerScope) {
      return !requireScopedPeers && peerScopeId.isEmpty;
    }
    return normalizeScopePart(peerFacilityId) == normalizedFacilityId &&
        normalizeScopePart(peerInstanceType) == normalizedInstanceType &&
        peerScopeId == scopeId;
  }
}
