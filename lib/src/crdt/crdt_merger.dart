import 'dart:convert';

import '../database/lan_sync_database.dart';

// ─── Hybrid Logical Clock ─────────────────────────────────────────────────────

/// 64-bit packed HLC: upper 48 bits = wall-clock ms, lower 16 bits = counter.
class Hlc {
  Hlc._();

  static int _counter = 0;
  static int _lastMs = 0;

  static int now() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    if (ms > _lastMs) {
      _lastMs = ms;
      _counter = 0;
    } else {
      _counter++;
    }
    return (_lastMs << 16) | (_counter & 0xFFFF);
  }

  static int receive(int remoteHlc) {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final remoteMs = remoteHlc >> 16;
    final maxMs = ms > remoteMs ? ms : remoteMs;
    if (maxMs == _lastMs) {
      _counter++;
    } else if (maxMs > _lastMs) {
      _lastMs = maxMs;
      _counter = maxMs == remoteMs ? (remoteHlc & 0xFFFF) + 1 : 0;
    }
    return (_lastMs << 16) | (_counter & 0xFFFF);
  }

  static int compare(int a, int b) => a.compareTo(b);
}

// ─── CRDT Merger ─────────────────────────────────────────────────────────────

/// Append-only fields — always union-merged, never LWW.
const _appendOnlyFields = {
  'notes',
  'visitHistory',
  'labResults',
  'medications'
};

class SyncConflict {
  final String entityId;
  final String entityType;
  final String fieldName;
  final String? localValue;
  final String? remoteValue;
  final int localTimestamp;
  final int remoteTimestamp;
  final String localDeviceId;
  final String remoteDeviceId;

  const SyncConflict({
    required this.entityId,
    required this.entityType,
    required this.fieldName,
    this.localValue,
    this.remoteValue,
    required this.localTimestamp,
    required this.remoteTimestamp,
    required this.localDeviceId,
    required this.remoteDeviceId,
  });
}

class MergeResult {
  final List<LanSyncLog> winners;
  final List<SyncConflict> conflicts;
  const MergeResult({required this.winners, required this.conflicts});
}

class CrdtMerger {
  CrdtMerger._();

  static MergeResult merge({
    required String deviceId,
    required List<LanSyncLog> localLogs,
    required List<LanSyncLog> remoteLogs,
  }) {
    final Map<String, LanSyncLog> winners = {};
    final List<SyncConflict> conflicts = [];

    final Map<String, LanSyncLog> localByField = {};
    for (final log in localLogs) {
      final existing = localByField[log.fieldName];
      if (existing == null ||
          Hlc.compare(log.hlcTimestamp, existing.hlcTimestamp) > 0) {
        localByField[log.fieldName] = log;
      }
    }

    for (final remote in remoteLogs) {
      final field = remote.fieldName;

      if (_appendOnlyFields.contains(field)) {
        winners[field] = remote;
        continue;
      }

      final local = localByField[field];
      if (local == null) {
        winners[field] = remote;
        continue;
      }

      final cmp = Hlc.compare(remote.hlcTimestamp, local.hlcTimestamp);
      if (cmp > 0) {
        winners[field] = remote;
      } else if (cmp == 0) {
        if (remote.deviceId.compareTo(local.deviceId) > 0) {
          winners[field] = remote;
        } else if (remote.deviceId != local.deviceId) {
          conflicts.add(SyncConflict(
            entityId: local.entityId,
            entityType: local.entityType,
            fieldName: field,
            localValue: local.newValue,
            remoteValue: remote.newValue,
            localTimestamp: local.hlcTimestamp,
            remoteTimestamp: remote.hlcTimestamp,
            localDeviceId: deviceId,
            remoteDeviceId: remote.deviceId,
          ));
        }
      }
    }

    return MergeResult(winners: winners.values.toList(), conflicts: conflicts);
  }

  static String mergeJsonArrays(String localJson, String remoteJson) {
    final local = (jsonDecode(localJson) as List).cast<Map<String, dynamic>>();
    final remote =
        (jsonDecode(remoteJson) as List).cast<Map<String, dynamic>>();
    final seen = <String>{};
    final merged = <Map<String, dynamic>>[];
    for (final item in [...local, ...remote]) {
      final id = item['id'] as String? ?? jsonEncode(item);
      if (seen.add(id)) merged.add(item);
    }
    merged.sort((a, b) {
      final ta = a['hlcTimestamp'] as int? ?? 0;
      final tb = b['hlcTimestamp'] as int? ?? 0;
      return ta.compareTo(tb);
    });
    return jsonEncode(merged);
  }
}
