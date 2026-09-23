import 'package:flutter_lan_sync/src/database/lan_sync_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database rawDb;
  late LanSyncDatabase db;

  setUp(() async {
    rawDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await rawDb.execute('''
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
    await rawDb.execute('''
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
    await rawDb.execute('''
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
    db = LanSyncDatabase.forTesting(rawDb);
  });

  tearDown(() => rawDb.close());

  test('push insert and acknowledgement roll back together', () async {
    await rawDb.execute('''
      CREATE TRIGGER reject_sync_update
      BEFORE UPDATE ON sync_logs
      BEGIN
        SELECT RAISE(ABORT, 'forced update failure');
      END
    ''');
    final log = _log('log-1');

    await expectLater(
      db.insertAndMarkLogsSynced(
        [log],
        ids: [log.id],
        scopeId: 'scope-a',
      ),
      throwsA(anything),
    );

    expect(await rawDb.query('sync_logs'), isEmpty);
  });

  test('transfer insert and read return one persisted row', () async {
    final transfer = await db.insertTransferAndGet(
      id: 'transfer-1',
      fromDeviceId: 'device-1',
      fromDeviceName: 'Clinic tablet',
      transferredAt: 100,
      itemCount: 2,
      dataJson: '[{},{}]',
      scopeId: 'scope-a',
    );

    expect(transfer.id, 'transfer-1');
    expect(transfer.itemCount, 2);
    expect(await rawDb.query('pending_transfers'), hasLength(1));
  });

  test('approval and history insert roll back together', () async {
    await db.insertTransferAndGet(
      id: 'transfer-1',
      fromDeviceId: 'device-1',
      fromDeviceName: 'Clinic tablet',
      transferredAt: 100,
      itemCount: 1,
      dataJson: '[{}]',
      scopeId: 'scope-a',
    );
    await rawDb.insert('transfer_logs', {
      'id': 'duplicate-log',
      'device_id': 'device-1',
      'device_name': 'Clinic tablet',
      'item_count': 1,
      'direction': 'incoming',
      'completed_at': 100,
      'scope_id': 'scope-a',
    });

    await expectLater(
      db.approveTransferAndInsertLog(
        transferId: 'transfer-1',
        id: 'duplicate-log',
        deviceId: 'device-1',
        deviceName: 'Clinic tablet',
        itemCount: 1,
        direction: 'incoming',
        completedAt: 101,
        scopeId: 'scope-a',
      ),
      throwsA(anything),
    );

    final transfer = (await rawDb.query('pending_transfers')).single;
    expect(transfer['status'], 'pending');
    expect(transfer['resolved_at'], isNull);
    expect(await rawDb.query('transfer_logs'), hasLength(1));
  });
}

LanSyncLog _log(String id) => LanSyncLog(
      id: id,
      deviceId: 'device-1',
      entityType: 'patient',
      entityId: 'patient-1',
      fieldName: 'firstName',
      newValue: 'Ada',
      hlcTimestamp: 1,
      vectorClock: 1,
      synced: false,
      syncedToDevices: '[]',
      scopeId: 'scope-a',
    );
