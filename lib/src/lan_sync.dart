import 'config.dart';
import 'database/lan_sync_database.dart';
import 'service/lan_sync_service.dart';

/// Entry point for the flutter_lan_sync package.
///
/// Call [initialize] once at app startup before [runApp].
class LanSync {
  LanSync._();

  /// Initialises the database and service with the given [config].
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  static Future<LanSyncService> initialize(LanSyncConfig config) async {
    final db = await LanSyncDatabase.open();
    return LanSyncService.init(db: db, config: config);
  }
}
