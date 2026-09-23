import 'dart:async';

import 'package:flutter/material.dart';

import '../database/lan_sync_database.dart';
import '../service/lan_sync_service.dart';
import 'incoming_transfer_sheet.dart';

/// Wrap your app tree with this widget to receive incoming transfer sheets
/// over any screen — not only when [LanSyncScreen] is open.
///
/// Requires a [navigatorKey] to show sheets via the root navigator.
/// Pass the same key used by your [MaterialApp].
///
/// ```dart
/// final navigatorKey = GlobalKey<NavigatorState>();
///
/// await LanSync.initialize(
///   LanSyncConfig(navigatorKey: navigatorKey, ...),
/// );
///
/// MaterialApp(
///   navigatorKey: navigatorKey,
///   home: LanTransferListener(
///     navigatorKey: navigatorKey,
///     child: MyHomePage(),
///   ),
/// );
/// ```
class LanTransferListener extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  const LanTransferListener({
    super.key,
    required this.child,
    this.navigatorKey,
  });

  @override
  State<LanTransferListener> createState() => _LanTransferListenerState();
}

class _LanTransferListenerState extends State<LanTransferListener> {
  StreamSubscription<LanSyncService>? _initSub;
  StreamSubscription<LanPendingTransfer>? _transferSub;

  @override
  void initState() {
    super.initState();
    if (LanSyncService.isInitialized) {
      _subscribeToTransfers(LanSyncService.instance);
    }
    _initSub = LanSyncService.onInitialized.listen(_subscribeToTransfers);
  }

  void _subscribeToTransfers(LanSyncService svc) {
    _transferSub?.cancel();
    _transferSub = svc.incomingTransferStream.listen(_onTransfer);
  }

  void _onTransfer(LanPendingTransfer transfer) {
    final navKey = widget.navigatorKey;
    final BuildContext? ctx =
        navKey?.currentContext ?? (mounted ? context : null);
    if (ctx == null) return;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: Colors.transparent,
      builder: (_) => IncomingTransferSheet(
        transfer: transfer,
        svc: LanSyncService.instance,
      ),
    );
  }

  @override
  void dispose() {
    _initSub?.cancel();
    _transferSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
