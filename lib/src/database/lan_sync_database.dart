import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// ─── Plain-Dart model classes ─────────────────────────────────────────────────

class LanDevice {
  final String id;
  final String name;
  final String publicKey;
  final bool approved;
  final int lastSeen;
  final String? lastIp;
  final int? lastPort;
  final int totalSyncs;
  final bool appVerified;
  final String? packageName;
  final String scopeId;
  final int protocolVersion;

  const LanDevice({
    required this.id,
    required this.name,
    required this.publicKey,
    required this.approved,
    required this.lastSeen,
    this.lastIp,
    this.lastPort,
    required this.totalSyncs,
    required this.appVerified,
    this.packageName,
    this.scopeId = '',
    this.protocolVersion = 1,
  });

  factory LanDevice.fromMap(Map<String, dynamic> m) => LanDevice(
        id: m['id'] as String,
        name: m['name'] as String,
        publicKey: m['public_key'] as String,
        approved: (m['approved'] as int) == 1,
        lastSeen: m['last_seen'] as int? ?? 0,
        lastIp: m['last_ip'] as String?,
        lastPort: m['last_port'] as int?,
        totalSyncs: m['total_syncs'] as int? ?? 0,
        appVerified: (m['app_verified'] as int? ?? 0) == 1,
        packageName: m['package_name'] as String?,
        scopeId: m['scope_id'] as String? ?? '',
        protocolVersion: m['protocol_version'] as int? ?? 0,
      );
}

class LanSyncLog {
  final String id;
  final String deviceId;
  final String entityType;
  final String entityId;
  final String fieldName;
  final String? oldValue;
  final String? newValue;
  final int hlcTimestamp;
  final int vectorClock;
  final bool synced;
  final String syncedToDevices;
  final String scopeId;

  const LanSyncLog({
    required this.id,
    required this.deviceId,
    required this.entityType,
    required this.entityId,
    required this.fieldName,
    this.oldValue,
    this.newValue,
    required this.hlcTimestamp,
    required this.vectorClock,
    required this.synced,
    required this.syncedToDevices,
    required this.scopeId,
  });

  factory LanSyncLog.fromMap(Map<String, dynamic> m) => LanSyncLog(
        id: m['id'] as String,
        deviceId: m['device_id'] as String,
        entityType: m['entity_type'] as String,
        entityId: m['entity_id'] as String,
        fieldName: m['field_name'] as String,
        oldValue: m['old_value'] as String?,
        newValue: m['new_value'] as String?,
        hlcTimestamp: m['hlc_timestamp'] as int,
        vectorClock: m['vector_clock'] as int? ?? 0,
        synced: (m['synced'] as int? ?? 0) == 1,
        syncedToDevices: m['synced_to_devices'] as String? ?? '[]',
        scopeId: m['scope_id'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'entityType': entityType,
        'entityId': entityId,
        'fieldName': fieldName,
        'oldValue': oldValue,
        'newValue': newValue,
        'hlcTimestamp': hlcTimestamp,
        'vectorClock': vectorClock,
        'synced': synced,
        'syncedToDevices': syncedToDevices,
        'scopeId': scopeId,
      };
}

class LanPendingTransfer {
  final String id;
  final String fromDeviceId;
  final String fromDeviceName;
  final int transferredAt;
  final int itemCount;
  final String dataJson;
  final String status;
  final String scopeId;

  const LanPendingTransfer({
    required this.id,
    required this.fromDeviceId,
    required this.fromDeviceName,
    required this.transferredAt,
    required this.itemCount,
    required this.dataJson,
    required this.status,
    this.scopeId = '',
  });

  factory LanPendingTransfer.fromMap(Map<String, dynamic> m) =>
      LanPendingTransfer(
        id: m['id'] as String,
        fromDeviceId: m['from_device_id'] as String,
        fromDeviceName: m['from_device_name'] as String,
        transferredAt: m['transferred_at'] as int,
        itemCount: m['item_count'] as int,
        dataJson: m['data_json'] as String,
        status: m['status'] as String? ?? 'pending',
        scopeId: m['scope_id'] as String? ?? '',
      );
}

class LanTransferLog {
  final String id;
  final String deviceId;
  final String deviceName;
  final int itemCount;
  final String direction;
  final int completedAt;
  final String? itemNamesJson;
  final String scopeId;

  const LanTransferLog({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.itemCount,
    required this.direction,
    required this.completedAt,
    this.itemNamesJson,
    this.scopeId = '',
  });

  factory LanTransferLog.fromMap(Map<String, dynamic> m) => LanTransferLog(
        id: m['id'] as String,
        deviceId: m['device_id'] as String,
        deviceName: m['device_name'] as String,
        itemCount: m['item_count'] as int,
        direction: m['direction'] as String,
        completedAt: m['completed_at'] as int,
        itemNamesJson: m['item_names_json'] as String?,
        scopeId: m['scope_id'] as String? ?? '',
      );
}

// ─── Database ─────────────────────────────────────────────────────────────────

class LanSyncDatabase {
  LanSyncDatabase._(this._db);

  /// Creates a wrapper around an isolated database for transaction tests.
  LanSyncDatabase.forTesting(this._db);

  final Database _db;
  static LanSyncDatabase? _instance;

  static Future<LanSyncDatabase> open() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'flutter_lan_sync.db');
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    _instance = LanSyncDatabase._(db);
    return _instance!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE devices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        public_key TEXT NOT NULL DEFAULT '',
        approved INTEGER NOT NULL DEFAULT 0,
        last_seen INTEGER NOT NULL DEFAULT 0,
        last_ip TEXT,
        last_port INTEGER,
        total_syncs INTEGER NOT NULL DEFAULT 0,
        app_verified INTEGER NOT NULL DEFAULT 0,
        package_name TEXT,
        scope_id TEXT NOT NULL DEFAULT '',
        protocol_version INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_logs (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        field_name TEXT NOT NULL,
        old_value TEXT,
        new_value TEXT,
        hlc_timestamp INTEGER NOT NULL,
        vector_clock INTEGER NOT NULL DEFAULT 0,
        synced INTEGER NOT NULL DEFAULT 0,
        synced_to_devices TEXT NOT NULL DEFAULT '[]',
        scope_id TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_transfers (
        id TEXT PRIMARY KEY,
        from_device_id TEXT NOT NULL,
        from_device_name TEXT NOT NULL,
        transferred_at INTEGER NOT NULL,
        item_count INTEGER NOT NULL,
        data_json TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        resolved_at INTEGER,
        scope_id TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE transfer_logs (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        device_name TEXT NOT NULL,
        item_count INTEGER NOT NULL,
        direction TEXT NOT NULL,
        completed_at INTEGER NOT NULL,
        item_names_json TEXT,
        scope_id TEXT NOT NULL DEFAULT ''
      )
    ''');
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE devices ADD COLUMN scope_id TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        'ALTER TABLE devices ADD COLUMN protocol_version INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE pending_transfers ADD COLUMN scope_id TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        "ALTER TABLE transfer_logs ADD COLUMN scope_id TEXT NOT NULL DEFAULT ''",
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        "ALTER TABLE sync_logs ADD COLUMN scope_id TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  // ── Devices ──────────────────────────────────────────────────────────────────

  Future<LanDevice?> getDevice(String id) async {
    final rows = await _db.query('devices', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return LanDevice.fromMap(rows.first);
  }

  Future<List<LanDevice>> getAllDevices({required String scopeId}) async {
    final rows = await _db.query(
      'devices',
      where: 'scope_id = ?',
      whereArgs: [scopeId],
      orderBy: 'last_seen DESC',
    );
    return rows.map(LanDevice.fromMap).toList();
  }

  Stream<List<LanDevice>> watchAllDevices({required String scopeId}) async* {
    while (true) {
      final rows = await _db.query(
        'devices',
        where: 'scope_id = ?',
        whereArgs: [scopeId],
        orderBy: 'last_seen DESC',
      );
      yield rows.map(LanDevice.fromMap).toList();
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> upsertDevice({
    required String id,
    required String name,
    required String publicKey,
    required String scopeId,
    required int protocolVersion,
  }) async {
    final existing = await getDevice(id);
    final sameVerifiedIdentity = existing != null &&
        existing.publicKey == publicKey &&
        existing.scopeId == scopeId &&
        existing.protocolVersion == protocolVersion;
    final values = <String, Object?>{
      'id': id,
      'name': name,
      'public_key': publicKey,
      'scope_id': scopeId,
      'protocol_version': protocolVersion,
      // Every handshake must verify the app again. Approval is retained only
      // when the peer key and authenticated realm are unchanged.
      'approved': sameVerifiedIdentity && existing.approved ? 1 : 0,
      'app_verified': 0,
      'package_name': null,
    };
    if (existing == null) {
      await _db.insert('devices', values);
    } else {
      await _db.update(
        'devices',
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<void> markAppVerified(String id, String packageName) async {
    await _db.update(
      'devices',
      {'app_verified': 1, 'package_name': packageName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateLastSeen(String id, String ip, int port) async {
    await _db.update(
      'devices',
      {
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'last_ip': ip,
        'last_port': port,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> approveDevice(String id) async {
    await _db.update('devices', {'approved': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> revokeDevice(String id) async {
    await _db.update('devices', {'approved': 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> incrementSyncCount(String id) async {
    await _db.rawUpdate(
        'UPDATE devices SET total_syncs = total_syncs + 1 WHERE id = ?', [id]);
  }

  Future<bool> isAppVerified(String id) async {
    final rows = await _db.query('devices',
        columns: ['app_verified'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return false;
    return (rows.first['app_verified'] as int? ?? 0) == 1;
  }

  // ── Sync logs ─────────────────────────────────────────────────────────────────

  Future<void> insertLog(LanSyncLog log) async {
    await _db.insert(
      'sync_logs',
      {
        'id': log.id,
        'device_id': log.deviceId,
        'entity_type': log.entityType,
        'entity_id': log.entityId,
        'field_name': log.fieldName,
        'old_value': log.oldValue,
        'new_value': log.newValue,
        'hlc_timestamp': log.hlcTimestamp,
        'vector_clock': log.vectorClock,
        'synced': log.synced ? 1 : 0,
        'synced_to_devices': log.syncedToDevices,
        'scope_id': log.scopeId,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> insertLogs(List<LanSyncLog> logs) async {
    await _insertLogs(_db, logs);
  }

  Future<void> _insertLogs(
    DatabaseExecutor executor,
    List<LanSyncLog> logs,
  ) async {
    final batch = executor.batch();
    for (final log in logs) {
      batch.insert(
        'sync_logs',
        {
          'id': log.id,
          'device_id': log.deviceId,
          'entity_type': log.entityType,
          'entity_id': log.entityId,
          'field_name': log.fieldName,
          'old_value': log.oldValue,
          'new_value': log.newValue,
          'hlc_timestamp': log.hlcTimestamp,
          'vector_clock': log.vectorClock,
          'synced': log.synced ? 1 : 0,
          'synced_to_devices': log.syncedToDevices,
          'scope_id': log.scopeId,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<LanSyncLog>> getUnsyncedLogs({required String scopeId}) async {
    final rows = await _db.query(
      'sync_logs',
      where: 'synced = 0 AND scope_id = ?',
      whereArgs: [scopeId],
      orderBy: 'hlc_timestamp ASC',
    );
    return rows.map(LanSyncLog.fromMap).toList();
  }

  Future<List<LanSyncLog>> getLogsForEntity(
    String entityId, {
    required String scopeId,
  }) async {
    final rows = await _db.query(
      'sync_logs',
      where: 'entity_id = ? AND scope_id = ?',
      whereArgs: [entityId, scopeId],
      orderBy: 'hlc_timestamp ASC',
    );
    return rows.map(LanSyncLog.fromMap).toList();
  }

  Future<List<LanSyncLog>> getLogsSince(
    int hlcTimestamp, {
    required String scopeId,
  }) async {
    final rows = await _db.query(
      'sync_logs',
      where: 'hlc_timestamp > ? AND scope_id = ?',
      whereArgs: [hlcTimestamp, scopeId],
      orderBy: 'hlc_timestamp ASC',
    );
    return rows.map(LanSyncLog.fromMap).toList();
  }

  Future<void> markLogsSynced(
    List<String> ids,
    String deviceId, {
    required String scopeId,
  }) async {
    if (ids.isEmpty) return;
    await _markLogsSynced(
      _db,
      ids,
      scopeId: scopeId,
    );
  }

  Future<void> _markLogsSynced(
    DatabaseExecutor executor,
    List<String> ids, {
    required String scopeId,
  }) async {
    if (ids.isEmpty) return;
    final placeholders = ids.map((_) => '?').join(',');
    await executor.rawUpdate(
      'UPDATE sync_logs SET synced = 1 '
      'WHERE scope_id = ? AND id IN ($placeholders)',
      [scopeId, ...ids],
    );
  }

  Future<void> insertAndMarkLogsSynced(
    List<LanSyncLog> logs, {
    required List<String> ids,
    required String scopeId,
  }) async {
    await _db.transaction((txn) async {
      await _insertLogs(txn, logs);
      await _markLogsSynced(txn, ids, scopeId: scopeId);
    });
  }

  // ── Pending transfers ─────────────────────────────────────────────────────────

  Future<void> insertTransfer({
    required String id,
    required String fromDeviceId,
    required String fromDeviceName,
    required int transferredAt,
    required int itemCount,
    required String dataJson,
    required String scopeId,
  }) async {
    await _db.insert('pending_transfers', {
      'id': id,
      'from_device_id': fromDeviceId,
      'from_device_name': fromDeviceName,
      'transferred_at': transferredAt,
      'item_count': itemCount,
      'data_json': dataJson,
      'status': 'pending',
      'scope_id': scopeId,
    });
  }

  Future<LanPendingTransfer> insertTransferAndGet({
    required String id,
    required String fromDeviceId,
    required String fromDeviceName,
    required int transferredAt,
    required int itemCount,
    required String dataJson,
    required String scopeId,
  }) async {
    return _db.transaction((txn) async {
      await txn.insert('pending_transfers', {
        'id': id,
        'from_device_id': fromDeviceId,
        'from_device_name': fromDeviceName,
        'transferred_at': transferredAt,
        'item_count': itemCount,
        'data_json': dataJson,
        'status': 'pending',
        'scope_id': scopeId,
      });
      final rows = await txn.query(
        'pending_transfers',
        where: 'id = ? AND scope_id = ?',
        whereArgs: [id, scopeId],
        limit: 1,
      );
      return LanPendingTransfer.fromMap(rows.single);
    });
  }

  Future<LanPendingTransfer?> getTransfer(
    String id, {
    required String scopeId,
  }) async {
    final rows = await _db.query(
      'pending_transfers',
      where: 'id = ? AND scope_id = ?',
      whereArgs: [id, scopeId],
    );
    if (rows.isEmpty) return null;
    return LanPendingTransfer.fromMap(rows.first);
  }

  Future<List<LanPendingTransfer>> getPendingTransfers({
    required String scopeId,
  }) async {
    final rows = await _db.query('pending_transfers',
        where: 'status = ? AND scope_id = ?',
        whereArgs: ['pending', scopeId],
        orderBy: 'transferred_at DESC');
    return rows.map(LanPendingTransfer.fromMap).toList();
  }

  Future<void> updateTransferStatus(
    String id,
    String status, {
    required String scopeId,
  }) async {
    await _db.update(
      'pending_transfers',
      {'status': status, 'resolved_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ? AND scope_id = ?',
      whereArgs: [id, scopeId],
    );
  }

  // ── Transfer logs ─────────────────────────────────────────────────────────────

  Future<void> insertTransferLog({
    required String id,
    required String deviceId,
    required String deviceName,
    required int itemCount,
    required String direction,
    required int completedAt,
    String? itemNamesJson,
    required String scopeId,
  }) async {
    await _db.insert('transfer_logs', {
      'id': id,
      'device_id': deviceId,
      'device_name': deviceName,
      'item_count': itemCount,
      'direction': direction,
      'completed_at': completedAt,
      'item_names_json': itemNamesJson,
      'scope_id': scopeId,
    });
  }

  Future<void> approveTransferAndInsertLog({
    required String transferId,
    required String id,
    required String deviceId,
    required String deviceName,
    required int itemCount,
    required String direction,
    required int completedAt,
    String? itemNamesJson,
    required String scopeId,
  }) async {
    await _db.transaction((txn) async {
      await txn.update(
        'pending_transfers',
        {
          'status': 'approved',
          'resolved_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ? AND scope_id = ?',
        whereArgs: [transferId, scopeId],
      );
      await txn.insert('transfer_logs', {
        'id': id,
        'device_id': deviceId,
        'device_name': deviceName,
        'item_count': itemCount,
        'direction': direction,
        'completed_at': completedAt,
        'item_names_json': itemNamesJson,
        'scope_id': scopeId,
      });
    });
  }

  Future<List<LanTransferLog>> getTransferLogs({
    required String scopeId,
    int limit = 50,
  }) async {
    final rows = await _db.query('transfer_logs',
        where: 'scope_id = ?',
        whereArgs: [scopeId],
        orderBy: 'completed_at DESC',
        limit: limit);
    return rows.map(LanTransferLog.fromMap).toList();
  }

  Future<List<LanTransferLog>> getTransferLogsForDevice(
    String deviceId, {
    required String scopeId,
    int limit = 50,
  }) async {
    final rows = await _db.query('transfer_logs',
        where: 'device_id = ? AND scope_id = ?',
        whereArgs: [deviceId, scopeId],
        orderBy: 'completed_at DESC',
        limit: limit);
    return rows.map(LanTransferLog.fromMap).toList();
  }
}
