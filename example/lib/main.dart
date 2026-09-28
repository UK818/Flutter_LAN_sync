import 'package:flutter/material.dart';
import 'package:flutter_lan_sync/flutter_lan_sync.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LanSync.initialize(
    LanSyncConfig(
      // Use the same application secret on trusted peer installations.
      // Load production secrets from your secure application configuration.
      appSecret: 'replace-with-a-secure-application-secret',
      packageName: 'com.example.flutter_lan_sync_example',
      deviceName: 'Example device',
      facilityId: 'example-facility',
      instanceType: 'training',
      requireScopedPeers: true,
      navigatorKey: navigatorKey,
      onReceive: (items) async {
        // Validate and persist received maps in the host application's store.
        debugPrint('Received ${items.length} item(s)');
      },
    ),
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'LAN Sync Example',
      home: LanTransferListener(
        navigatorKey: navigatorKey,
        child: const ExampleHomePage(),
      ),
    );
  }
}

class ExampleHomePage extends StatelessWidget {
  const ExampleHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <LanSyncItem>[
      const LanSyncItem(
        id: 'record-1',
        displayName: 'Example record',
        dataType: 'record',
        data: <String, dynamic>{'id': 'record-1', 'status': 'ready'},
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('LAN Sync Example')),
      body: Center(
        child: FilledButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LanSyncScreen(
                  items: items,
                  itemLabel: 'Record',
                ),
              ),
            );
          },
          child: const Text('Open LAN sync'),
        ),
      ),
    );
  }
}
