/// flutter_lan_sync — offline peer-to-peer data sync over Wi-Fi.
///
/// Quick start:
/// ```dart
/// // 1. Initialise once at startup (before runApp)
/// await LanSync.initialize(
///   LanSyncConfig(
///     appSecret: 'my-app-secret',
///     packageName: 'com.example.myapp',
///     deviceName: 'Dr Smith',
///     facilityId: 'facility-123',
///     instanceType: 'production',
///     requireScopedPeers: true,
///     onReceive: (items) async {
///       await db.saveAll(items.map(MyModel.fromJson).toList());
///     },
///   ),
/// );
///
/// // 2. Wrap your MaterialApp for global incoming-transfer alerts
/// LanTransferListener(navigatorKey: navigatorKey, child: MyApp())
///
/// // 3. Open the sync screen with the items you want to offer
/// LanSyncScreen(
///   items: records.map((r) => LanSyncItem(
///     id: r.id,
///     displayName: r.fullName,
///     data: r.toJson(),
///   )).toList(),
/// )
/// ```
library flutter_lan_sync;

export 'src/config.dart';
export 'src/lan_sync.dart';
export 'src/database/lan_sync_database.dart'
    show LanPendingTransfer, LanTransferLog, LanDevice;
export 'src/discovery/mdns_discovery.dart' show LanPeer, MdnsDiscovery;
export 'src/service/lan_sync_service.dart' show LanSyncService, SyncStatus;
export 'src/presentation/lan_sync_screen.dart';
export 'src/presentation/lan_transfer_listener.dart';
export 'src/presentation/incoming_transfer_sheet.dart';
export 'src/presentation/ls_theme.dart' show LanSyncTheme;
