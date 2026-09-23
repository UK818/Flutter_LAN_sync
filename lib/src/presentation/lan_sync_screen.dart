import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../database/lan_sync_database.dart';
import '../discovery/mdns_discovery.dart';
import '../service/lan_sync_service.dart';
import 'incoming_transfer_sheet.dart';
import 'ls_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Screen root
// ─────────────────────────────────────────────────────────────────────────────

/// Full LAN sync management screen with Devices, Manage, and History tabs.
///
/// Pass [items] to offer the caller's data for selective transfer.
///
/// ```dart
/// LanSyncScreen(
///   items: patients.map((p) => LanSyncItem(
///     id: p.id, displayName: p.fullName, data: p.toJson(),
///   )).toList(),
/// )
/// ```
class LanSyncScreen extends StatefulWidget {
  final List<LanSyncItem> items;
  final String itemLabel;

  const LanSyncScreen({
    super.key,
    this.items = const [],
    this.itemLabel = 'Item',
  });

  @override
  State<LanSyncScreen> createState() => _LanSyncScreenState();
}

class _LanSyncScreenState extends State<LanSyncScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final LanSyncService _svc;
  StreamSubscription<SyncStatus>? _statusSub;
  StreamSubscription<LanPendingTransfer>? _incomingTransferSub;
  SyncStatus _status = const SyncStatus();
  int _pendingTransferCount = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _svc = LanSyncService.instance;
    _status = _svc.currentStatus;
    _statusSub = _svc.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _incomingTransferSub =
        _svc.incomingTransferStream.listen((_) => _refreshPendingCount());
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _loadPendingTransfers());
  }

  Future<void> _refreshPendingCount() async {
    try {
      final pending = await _svc.getPendingTransfers();
      if (mounted) setState(() => _pendingTransferCount = pending.length);
    } catch (_) {}
  }

  Future<void> _loadPendingTransfers() async {
    final pending = await _svc.getPendingTransfers();
    if (mounted) setState(() => _pendingTransferCount = pending.length);
    for (final transfer in pending) {
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        backgroundColor: Colors.transparent,
        builder: (_) => IncomingTransferSheet(
          transfer: transfer,
          svc: _svc,
          onResolved: _refreshPendingCount,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 350));
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _incomingTransferSub?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LsColors.background,
      appBar: AppBar(
        backgroundColor: LsColors.white,
        foregroundColor: LsColors.text,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('LAN Device Sync',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: LsColors.text)),
            Text('Offline peer-to-peer sync',
                style: TextStyle(fontSize: 10, color: LsColors.subText)),
          ],
        ),
        actions: [
          if (_status.serverRunning) _LiveDot(),
          IconButton(
            icon: Icon(Icons.help_outline_rounded, size: 22),
            tooltip: 'How to connect',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) =>
                  _ConnectionGuideSheet(itemLabel: widget.itemLabel),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: LsColors.primary,
          unselectedLabelColor: LsColors.subText,
          indicatorColor: LsColors.primary,
          indicatorWeight: 2.5,
          dividerColor: LsColors.border,
          labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          tabs: const [
            Tab(
                icon: Icon(Icons.wifi_tethering_rounded, size: 18),
                text: 'Devices'),
            Tab(icon: Icon(Icons.devices_rounded, size: 18), text: 'Manage'),
            Tab(
                icon: Icon(Icons.swap_horiz_rounded, size: 18),
                text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _DevicesTab(
              status: _status,
              svc: _svc,
              items: widget.items,
              itemLabel: widget.itemLabel,
              pendingTransferCount: _pendingTransferCount),
          _ManageTab(svc: _svc),
          _HistoryTab(svc: _svc, itemLabel: widget.itemLabel),
        ],
      ),
    );
  }
}

// ─── Live dot ─────────────────────────────────────────────────────────────────

class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat(reverse: true);
    _anim = Tween(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(right: 4),
      child: FadeTransition(
        opacity: _anim,
        child: Container(
          width: 8,
          height: 8,
          margin: EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: LsColors.success,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: LsColors.success.withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 1)
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Connection guide sheet ───────────────────────────────────────────────────

class _ConnectionGuideSheet extends StatelessWidget {
  final String itemLabel;
  const _ConnectionGuideSheet({required this.itemLabel});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.94,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: LsColors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          controller: ctrl,
          padding: EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                      color: LsColors.border,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              SizedBox(height: 18),
              Text('Quick-Start Guide',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      color: LsColors.text)),
              SizedBox(height: 4),
              Text('Get two devices syncing in under two minutes.',
                  style: TextStyle(
                      fontSize: 12, color: LsColors.subText, height: 1.4)),
              SizedBox(height: 20),
              _step(
                  1,
                  Icons.router_rounded,
                  LsColors.info,
                  'Same Wi-Fi, mobile data OFF',
                  'Both devices must be on the same Wi-Fi network.'),
              _step(
                  2,
                  Icons.play_circle_outline_rounded,
                  LsColors.primary,
                  'Start server on both devices',
                  'Tap "Start Server" on the Devices tab of each device.'),
              _step(
                  3,
                  Icons.handshake_rounded,
                  LsColors.purple,
                  'Connect (first time only)',
                  'Tap "Connect" next to the other device for a one-time key exchange.'),
              _step(
                  4,
                  Icons.verified_user_rounded,
                  LsColors.warning,
                  'Approve on the other device',
                  'On the other device → Manage tab → tap Approve.'),
              _step(
                  5,
                  Icons.sync_rounded,
                  LsColors.success,
                  'Send ${itemLabel}s',
                  'Tap "Sync" on an approved device to choose which ${itemLabel.toLowerCase()}s to send.',
                  isLast: true),
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: LsColors.info.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: LsColors.info.withValues(alpha: 0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline_rounded,
                        color: LsColors.info, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'All data is encrypted with AES-256-GCM. Keys are derived per device-pair via X25519 ECDH — never sent in plaintext.',
                        style: TextStyle(
                            fontSize: 11, color: LsColors.subText, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(int n, IconData icon, Color color, String title, String body,
      {bool isLast = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 32,
          child: Column(children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text('$n',
                  style: TextStyle(
                      color: LsColors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13)),
            ),
            if (!isLast)
              Container(width: 2, height: 44, color: LsColors.border),
          ]),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 6),
                Row(children: [
                  Icon(icon, size: 13, color: color),
                  SizedBox(width: 5),
                  Expanded(
                    child: Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: LsColors.text)),
                  ),
                ]),
                SizedBox(height: 4),
                Text(body,
                    style: TextStyle(
                        fontSize: 12, color: LsColors.subText, height: 1.45)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Live peer entry ──────────────────────────────────────────────────────────

class _LiveEntry {
  final LanPeer peer;
  final DateTime lastSeen;
  const _LiveEntry({required this.peer, required this.lastSeen});
}

// ─── Devices Tab ──────────────────────────────────────────────────────────────

class _DevicesTab extends StatefulWidget {
  final SyncStatus status;
  final LanSyncService svc;
  final List<LanSyncItem> items;
  final String itemLabel;
  final int pendingTransferCount;

  const _DevicesTab({
    required this.status,
    required this.svc,
    required this.items,
    required this.itemLabel,
    required this.pendingTransferCount,
  });

  @override
  State<_DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<_DevicesTab> {
  final Map<String, _LiveEntry> _live = {};
  StreamSubscription<LanPeer>? _watchSub;
  List<LanDevice> _knownDevices = [];
  Timer? _pruneTimer;
  bool _toggling = false;
  bool _syncingAll = false;
  final Map<String, bool> _handshaking = {};
  final Map<String, bool> _syncing = {};

  @override
  void initState() {
    super.initState();
    _loadKnownDevices();
    _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) => _prune());
    if (widget.status.serverRunning) _startWatch();
  }

  Future<void> _loadKnownDevices() async {
    try {
      final devices = await widget.svc.getAllDevices();
      if (mounted) setState(() => _knownDevices = devices);
    } catch (_) {
      // The live mDNS list remains usable even if the approval store is
      // temporarily unavailable; the next handshake reloads it.
    }
  }

  @override
  void didUpdateWidget(_DevicesTab old) {
    super.didUpdateWidget(old);
    if (!old.status.serverRunning && widget.status.serverRunning) {
      _startWatch();
    } else if (old.status.serverRunning && !widget.status.serverRunning) {
      _watchSub?.cancel();
      _watchSub = null;
      if (mounted) setState(() => _live.clear());
    }
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    _pruneTimer?.cancel();
    super.dispose();
  }

  void _startWatch() {
    _watchSub?.cancel();
    _watchSub = MdnsDiscovery.watch(
      localDeviceId: widget.svc.deviceId,
      localScopeId: widget.svc.scopeId,
      allowUnscoped: widget.svc.allowsUnscopedPeers,
    ).listen((peer) {
      if (mounted) {
        if (peer.isClosing) {
          if (_live.remove(peer.deviceId) != null) setState(() {});
          return;
        }

        final previous = _live[peer.deviceId];
        _live[peer.deviceId] = _LiveEntry(peer: peer, lastSeen: DateTime.now());
        // Beacons arrive every two seconds. Keep the heartbeat for expiry,
        // but rebuild only when the visible connected-device set changes.
        if (previous == null ||
            previous.peer.host != peer.host ||
            previous.peer.port != peer.port) {
          setState(() {});
        }
      }
    });
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 8));
    bool changed = false;
    _live.removeWhere((_, e) {
      if (e.lastSeen.isBefore(cutoff)) {
        changed = true;
        return true;
      }
      return false;
    });
    if (changed && mounted) setState(() {});
  }

  Future<void> _toggleServer() async {
    setState(() => _toggling = true);
    try {
      widget.status.serverRunning
          ? await widget.svc.stop()
          : await widget.svc.start();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not change LAN server status: $error'),
            backgroundColor: LsColors.danger,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _pushItems(LanPeer peer, List<LanSyncItem> items) async {
    if (_syncing[peer.deviceId] == true) return;
    setState(() => _syncing[peer.deviceId] = true);
    try {
      await widget.svc.pushItems(peer, items);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${items.length} ${widget.itemLabel.toLowerCase()}${items.length == 1 ? "" : "s"} sent — the other device will be asked to approve.'),
          backgroundColor: LsColors.success,
          duration: const Duration(seconds: 3),
        ));
      }
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Transfer timed out — the other device may have disconnected.'),
          backgroundColor: LsColors.danger,
          duration: Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Transfer failed: $e'),
          backgroundColor: LsColors.danger,
          duration: const Duration(seconds: 4),
        ));
      }
    } finally {
      if (mounted) setState(() => _syncing.remove(peer.deviceId));
    }
  }

  Future<void> _syncAll() async {
    if (widget.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'No ${widget.itemLabel.toLowerCase()}s loaded. Pass items to LanSyncScreen to enable sync.'),
        backgroundColor: LsColors.warning,
        duration: const Duration(seconds: 4),
      ));
      return;
    }
    setState(() => _syncingAll = true);
    try {
      final knownMap = {for (final d in _knownDevices) d.id: d};
      for (final entry in List.of(_live.values)) {
        final device = knownMap[entry.peer.deviceId];
        if (device == null || !device.approved) continue;
        await _pushItems(entry.peer, widget.items);
      }
    } finally {
      if (mounted) setState(() => _syncingAll = false);
    }
  }

  Future<void> _handshake(LanPeer peer) async {
    setState(() => _handshaking[peer.deviceId] = true);
    try {
      await widget.svc.handshakeWithPeer(peer);
      await _loadKnownDevices();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Connected — go to the other device\'s Manage tab and tap Approve'),
          backgroundColor: LsColors.success,
          duration: Duration(seconds: 5),
        ));
      }
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Connection timed out. Check the other device has started its server.'),
          backgroundColor: LsColors.danger,
          duration: Duration(seconds: 5),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Connection failed: $e'),
          backgroundColor: LsColors.danger,
          duration: const Duration(seconds: 5),
        ));
      }
    } finally {
      if (mounted) setState(() => _handshaking.remove(peer.deviceId));
    }
  }

  void _showItemPicker(LanPeer peer, String peerName) {
    if (widget.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'No ${widget.itemLabel.toLowerCase()}s loaded. Pass items to LanSyncScreen.'),
        backgroundColor: LsColors.warning,
        duration: const Duration(seconds: 4),
      ));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ItemPickerSheet(
        items: widget.items,
        peerName: peerName,
        itemLabel: widget.itemLabel,
        onSyncAll: () {
          Navigator.pop(context);
          _pushItems(peer, widget.items);
        },
        onSyncSelected: (ids) {
          Navigator.pop(context);
          final selected =
              widget.items.where((i) => ids.contains(i.id)).toList();
          _pushItems(peer, selected);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.status.serverRunning;
    final syncing = widget.status.syncing || _syncingAll;
    final knownMap = {for (final d in _knownDevices) d.id: d};
    final onlineEntries = _live.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        _ServerCard(
          status: widget.status,
          svc: widget.svc,
          toggling: _toggling,
          syncing: syncing,
          onToggle: _toggleServer,
          onSyncAll: _syncAll,
        ),
        if (widget.status.lastError != null) ...[
          SizedBox(height: 10),
          _ErrorBanner(widget.status.lastError!),
        ],
        SizedBox(height: 20),
        _SectionLabel(
          icon: Icons.wifi_find_rounded,
          label: 'Connected Devices',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.pendingTransferCount > 0)
                _CountBadge(
                  count: widget.pendingTransferCount,
                  color: LsColors.warning,
                ),
              if (running) ...[
                if (widget.pendingTransferCount > 0) SizedBox(width: 8),
                _WatchingPill(),
              ],
            ],
          ),
        ),
        SizedBox(height: 8),
        if (!running)
          _HintCard(
            icon: Icons.play_circle_outline_rounded,
            text:
                'Start the server to see connected devices available for transfer.',
            color: LsColors.info,
          )
        else if (onlineEntries.isEmpty)
          _WaitingState()
        else
          ...onlineEntries.map((e) {
            final known = knownMap[e.peer.deviceId];
            return _LiveDeviceCard(
              entry: e,
              knownDevice: known,
              isHandshaking: _handshaking[e.peer.deviceId] == true,
              isSyncing: _syncing[e.peer.deviceId] == true,
              onConnect: () => _handshake(e.peer),
              onSync: () => _showItemPicker(
                e.peer,
                known?.name.isNotEmpty == true ? known!.name : 'Peer Device',
              ),
            );
          }),
        if (widget.items.isNotEmpty && running && onlineEntries.isNotEmpty) ...[
          SizedBox(height: 16),
          _HintCard(
            icon: Icons.folder_open_rounded,
            text:
                '${widget.items.length} ${widget.itemLabel.toLowerCase()}${widget.items.length == 1 ? "" : "s"} available for selective sync. Tap "Sync" on an online device to choose.',
            color: LsColors.info,
          ),
        ],
      ],
    );
  }
}

// ─── Server card ──────────────────────────────────────────────────────────────

class _ServerCard extends StatelessWidget {
  final SyncStatus status;
  final LanSyncService svc;
  final bool toggling;
  final bool syncing;
  final VoidCallback onToggle;
  final VoidCallback onSyncAll;

  const _ServerCard({
    required this.status,
    required this.svc,
    required this.toggling,
    required this.syncing,
    required this.onToggle,
    required this.onSyncAll,
  });

  @override
  Widget build(BuildContext context) {
    final running = status.serverRunning;
    final df = DateFormat('MMM d, h:mm a');

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: LsColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: running
                ? LsColors.success.withValues(alpha: 0.35)
                : LsColors.border),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              _PulseIndicator(active: running),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      running ? 'Server Running' : 'Server Stopped',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: running ? LsColors.success : LsColors.subText),
                    ),
                    Text(
                      running
                          ? 'Broadcasting on port ${status.port} · Discoverable'
                          : 'Start the server to become discoverable',
                      style: TextStyle(fontSize: 11, color: LsColors.hint),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: svc.deviceId));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Device ID copied'),
                      duration: Duration(seconds: 1)));
                },
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: LsColors.background,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: LsColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        svc.deviceId.substring(0, 8),
                        style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: LsColors.subText),
                      ),
                      SizedBox(width: 4),
                      Icon(Icons.copy_rounded, size: 11, color: LsColors.hint),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (status.lastSyncAt != null) ...[
            Divider(height: 16, color: LsColors.border),
            Row(children: [
              Icon(Icons.check_circle_outline_rounded,
                  size: 13, color: LsColors.success),
              SizedBox(width: 6),
              Text(
                'Last sync: ${df.format(status.lastSyncAt!)} · ${status.peersSynced} peer${status.peersSynced == 1 ? "" : "s"}',
                style: TextStyle(fontSize: 11, color: LsColors.subText),
              ),
            ]),
          ],
          Divider(height: 16, color: LsColors.border),
          Row(children: [
            Expanded(
              flex: 3,
              child: _Btn(
                label: toggling
                    ? (running ? 'Stopping…' : 'Starting…')
                    : (running ? 'Stop Server' : 'Start Server'),
                icon: toggling
                    ? null
                    : (running ? Icons.stop_rounded : Icons.play_arrow_rounded),
                loading: toggling,
                color: running ? LsColors.danger : LsColors.primary,
                onPressed: toggling ? null : onToggle,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: _Btn(
                label: syncing ? 'Syncing…' : 'Sync All',
                icon: Icons.sync_rounded,
                loading: syncing,
                color: LsColors.info,
                outlined: true,
                onPressed: (syncing || !running) ? null : onSyncAll,
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ─── Live / Offline device cards ──────────────────────────────────────────────

class _LiveDeviceCard extends StatelessWidget {
  final _LiveEntry entry;
  final LanDevice? knownDevice;
  final bool isHandshaking;
  final bool isSyncing;
  final VoidCallback onConnect;
  final VoidCallback onSync;

  const _LiveDeviceCard({
    required this.entry,
    required this.knownDevice,
    required this.isHandshaking,
    required this.isSyncing,
    required this.onConnect,
    required this.onSync,
  });

  @override
  Widget build(BuildContext context) {
    final peer = entry.peer;
    final approved = knownDevice?.approved ?? false;
    final pending = knownDevice != null && !approved;
    final unknown = knownDevice == null;
    final accentColor = approved
        ? LsColors.success
        : pending
            ? LsColors.warning
            : LsColors.primary;

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: LsColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2))
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.phone_android_rounded,
                    color: accentColor, size: 22),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          knownDevice?.name.isNotEmpty == true
                              ? knownDevice!.name
                              : 'Peer Device',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: LsColors.text),
                        ),
                      ),
                      _OnlineBadge(),
                    ]),
                    SizedBox(height: 2),
                    Text('${peer.host}:${peer.port}',
                        style:
                            TextStyle(fontSize: 11, color: LsColors.subText)),
                    Text('ID: ${peer.deviceId.substring(0, 8)}…',
                        style: TextStyle(fontSize: 10, color: LsColors.hint)),
                  ],
                ),
              ),
            ]),
            SizedBox(height: 12),
            if (unknown)
              _ConnectRow(loading: isHandshaking, onConnect: onConnect)
            else if (pending)
              _PendingRow()
            else
              _SyncRow(loading: isSyncing, onSync: onSync),
          ],
        ),
      ),
    );
  }
}

class _OnlineBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: LsColors.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LsColors.success.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: LsColors.success,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: LsColors.success.withValues(alpha: 0.5), blurRadius: 4)
            ],
          ),
        ),
        SizedBox(width: 4),
        Text('Online',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: LsColors.success)),
      ]),
    );
  }
}

class _ConnectRow extends StatelessWidget {
  final bool loading;
  final VoidCallback onConnect;
  const _ConnectRow({required this.loading, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(Icons.info_outline_rounded, size: 13, color: LsColors.subText),
      SizedBox(width: 6),
      Expanded(
        child: Text('First time? Tap Connect to pair.',
            style: TextStyle(fontSize: 11, color: LsColors.subText)),
      ),
      SizedBox(width: 8),
      _Btn(
          label: 'Connect',
          color: LsColors.primary,
          loading: loading,
          onPressed: loading ? null : onConnect,
          compact: true),
    ]);
  }
}

class _PendingRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: LsColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.hourglass_top_rounded, size: 14, color: LsColors.warning),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Awaiting approval — go to the other device\'s Manage tab and tap Approve.',
            style: TextStyle(fontSize: 11, color: LsColors.text),
          ),
        ),
      ]),
    );
  }
}

class _SyncRow extends StatelessWidget {
  final bool loading;
  final VoidCallback onSync;
  const _SyncRow({required this.loading, required this.onSync});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(Icons.autorenew_rounded, size: 13, color: LsColors.success),
      SizedBox(width: 6),
      Expanded(
        child: Text('Approved · tap Sync to send items',
            style: TextStyle(
                fontSize: 11,
                color: LsColors.success,
                fontWeight: FontWeight.w600)),
      ),
      SizedBox(width: 8),
      _Btn(
          label: 'Sync',
          icon: Icons.sync_rounded,
          color: LsColors.info,
          loading: loading,
          onPressed: loading ? null : onSync,
          compact: true),
    ]);
  }
}

// ─── Item Picker Sheet ────────────────────────────────────────────────────────

class _ItemPickerSheet extends StatefulWidget {
  final List<LanSyncItem> items;
  final String peerName;
  final String itemLabel;
  final VoidCallback onSyncAll;
  final void Function(List<String> ids) onSyncSelected;

  const _ItemPickerSheet({
    required this.items,
    required this.peerName,
    required this.itemLabel,
    required this.onSyncAll,
    required this.onSyncSelected,
  });

  @override
  State<_ItemPickerSheet> createState() => _ItemPickerSheetState();
}

class _ItemPickerSheetState extends State<_ItemPickerSheet> {
  final Set<String> _selected = {};
  String _search = '';

  List<LanSyncItem> get _filtered {
    if (_search.isEmpty) return widget.items;
    final q = _search.toLowerCase();
    return widget.items
        .where((i) => i.displayName.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final allSelected =
        filtered.isNotEmpty && filtered.every((i) => _selected.contains(i.id));
    final label = widget.itemLabel;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: LsColors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.only(top: 12, bottom: 8),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                      color: LsColors.border,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Select ${label}s',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              color: LsColors.text)),
                      Text('Syncing to: ${widget.peerName}',
                          style:
                              TextStyle(fontSize: 11, color: LsColors.subText)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: widget.onSyncAll,
                  style: TextButton.styleFrom(
                      foregroundColor: LsColors.primary,
                      textStyle:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  child: Text('Sync All'),
                ),
              ]),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  hintText: 'Search…',
                  hintStyle: TextStyle(fontSize: 12, color: LsColors.hint),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: LsColors.hint),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: LsColors.border)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: LsColors.border)),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  filled: true,
                  fillColor: LsColors.background,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Checkbox(
                  value: allSelected,
                  tristate: true,
                  onChanged: (v) => setState(() {
                    v == true
                        ? _selected.addAll(filtered.map((i) => i.id))
                        : _selected.removeAll(filtered.map((i) => i.id));
                  }),
                  activeColor: LsColors.primary,
                ),
                Text(
                    allSelected
                        ? 'Deselect all'
                        : 'Select all (${filtered.length})',
                    style: TextStyle(
                        fontSize: 12,
                        color: LsColors.text,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_selected.isNotEmpty)
                  Text('${_selected.length} selected',
                      style: TextStyle(
                          fontSize: 11,
                          color: LsColors.primary,
                          fontWeight: FontWeight.w700)),
              ]),
            ),
            Divider(height: 1, color: LsColors.border),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text('No ${label.toLowerCase()}s found',
                          style: TextStyle(fontSize: 13, color: LsColors.hint)))
                  : ListView.builder(
                      controller: ctrl,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final item = filtered[i];
                        final sel = _selected.contains(item.id);
                        final initials = item.displayName
                            .trim()
                            .split(' ')
                            .where((w) => w.isNotEmpty)
                            .map((w) => w[0].toUpperCase())
                            .take(2)
                            .join();
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                LsColors.primary.withValues(alpha: 0.1),
                            child: Text(
                              initials.isEmpty ? '?' : initials,
                              style: TextStyle(
                                  color: LsColors.primary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13),
                            ),
                          ),
                          title: Text(item.displayName,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: LsColors.text)),
                          trailing: Checkbox(
                            value: sel,
                            onChanged: (_) => setState(() => sel
                                ? _selected.remove(item.id)
                                : _selected.add(item.id)),
                            activeColor: LsColors.primary,
                          ),
                          onTap: () => setState(() => sel
                              ? _selected.remove(item.id)
                              : _selected.add(item.id)),
                        );
                      },
                    ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _selected.isEmpty
                          ? LsColors.border
                          : LsColors.primary,
                      padding: EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: Icon(Icons.sync_rounded, size: 18),
                    label: Text(
                      _selected.isEmpty
                          ? 'Select ${label.toLowerCase()}s to sync'
                          : 'Sync ${_selected.length} $label${_selected.length == 1 ? "" : "s"}',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                    onPressed: _selected.isEmpty
                        ? null
                        : () => widget.onSyncSelected(_selected.toList()),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Manage Tab ───────────────────────────────────────────────────────────────

class _ManageTab extends StatefulWidget {
  final LanSyncService svc;
  const _ManageTab({required this.svc});

  @override
  State<_ManageTab> createState() => _ManageTabState();
}

class _ManageTabState extends State<_ManageTab> {
  List<LanDevice> _devices = [];
  List<LanPendingTransfer> _pendingTransfers = [];
  StreamSubscription<List<LanDevice>>? _sub;
  StreamSubscription<LanPendingTransfer>? _incomingTransferSub;

  @override
  void initState() {
    super.initState();
    _sub = widget.svc.watchAllDevices().listen((d) {
      if (mounted) setState(() => _devices = d);
    });
    _incomingTransferSub = widget.svc.incomingTransferStream.listen((_) {
      _loadPendingTransfers();
    });
    _loadPendingTransfers();
  }

  Future<void> _loadPendingTransfers() async {
    try {
      final transfers = await widget.svc.getPendingTransfers();
      if (mounted) setState(() => _pendingTransfers = transfers);
    } catch (_) {}
  }

  Future<void> _reviewTransfer(LanPendingTransfer transfer) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: Colors.transparent,
      builder: (_) => IncomingTransferSheet(
        transfer: transfer,
        svc: widget.svc,
        onResolved: _loadPendingTransfers,
      ),
    );
    _loadPendingTransfers();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _incomingTransferSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _devices.where((d) => !d.approved).toList();
    final approved = _devices.where((d) => d.approved).toList();

    return ListView(
      padding: EdgeInsets.all(16),
      children: [
        _HintCard(
          icon: Icons.info_outline_rounded,
          text:
              'Devices appear here after the other device taps "Connect". Approve to allow sync, Revoke to block.',
          color: LsColors.info,
        ),
        if (_pendingTransfers.isNotEmpty) ...[
          SizedBox(height: 16),
          _SectionLabel(
            icon: Icons.download_rounded,
            label: 'Incoming Transfers',
            trailing: _CountBadge(
              count: _pendingTransfers.length,
              color: LsColors.warning,
            ),
          ),
          SizedBox(height: 8),
          ..._pendingTransfers.map(
            (transfer) => _PendingTransferCard(
              transfer: transfer,
              onReview: () => _reviewTransfer(transfer),
            ),
          ),
        ],
        if (pending.isNotEmpty) ...[
          SizedBox(height: 16),
          _SectionLabel(
            icon: Icons.pending_actions_rounded,
            label: 'Awaiting Approval',
            trailing:
                _CountBadge(count: pending.length, color: LsColors.warning),
          ),
          SizedBox(height: 8),
          ...pending.map((d) => _DeviceManageCard(device: d, svc: widget.svc)),
        ],
        if (approved.isNotEmpty) ...[
          SizedBox(height: 16),
          _SectionLabel(
            icon: Icons.check_circle_rounded,
            label: 'Approved Devices',
            trailing:
                _CountBadge(count: approved.length, color: LsColors.success),
          ),
          SizedBox(height: 8),
          ...approved.map((d) => _DeviceManageCard(device: d, svc: widget.svc)),
        ],
        if (_devices.isEmpty && _pendingTransfers.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Column(children: [
              Icon(Icons.devices_rounded, size: 56, color: LsColors.border),
              SizedBox(height: 12),
              Text('No paired devices yet',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: LsColors.subText)),
              SizedBox(height: 6),
              Text(
                'Start the server on both devices,\nthen tap "Connect" on the Devices tab.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: LsColors.hint, height: 1.5),
              ),
            ]),
          ),
      ],
    );
  }
}

class _PendingTransferCard extends StatelessWidget {
  final LanPendingTransfer transfer;
  final VoidCallback onReview;

  const _PendingTransferCard({
    required this.transfer,
    required this.onReview,
  });

  @override
  Widget build(BuildContext context) {
    final when = DateFormat('MMM d, h:mm a').format(
      DateTime.fromMillisecondsSinceEpoch(transfer.transferredAt),
    );
    final sender = transfer.fromDeviceName.isNotEmpty
        ? transfer.fromDeviceName
        : 'Peer device';

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LsColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: LsColors.warning.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: LsColors.warning.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.download_rounded,
              color: LsColors.warning,
              size: 20,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sender,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: LsColors.text,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '${transfer.itemCount} item${transfer.itemCount == 1 ? '' : 's'} · $when',
                  style: TextStyle(
                    fontSize: 11,
                    color: LsColors.subText,
                  ),
                ),
              ],
            ),
          ),
          _Btn(
            label: 'Review',
            icon: Icons.visibility_rounded,
            color: LsColors.warning,
            onPressed: onReview,
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _DeviceManageCard extends StatefulWidget {
  final LanDevice device;
  final LanSyncService svc;
  const _DeviceManageCard({required this.device, required this.svc});

  @override
  State<_DeviceManageCard> createState() => _DeviceManageCardState();
}

class _DeviceManageCardState extends State<_DeviceManageCard> {
  bool? _appVerified;

  @override
  void initState() {
    super.initState();
    widget.svc.isDeviceAppVerified(widget.device.id).then((v) {
      if (mounted) setState(() => _appVerified = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final df = DateFormat('MMM d, h:mm a');
    final approved = device.approved;
    final statusColor = approved ? LsColors.success : LsColors.warning;
    final lastSeen = device.lastSeen > 0
        ? df.format(DateTime.fromMillisecondsSinceEpoch(device.lastSeen))
        : 'Never';

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LsColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle),
              child: Icon(
                  approved
                      ? Icons.check_circle_rounded
                      : Icons.hourglass_top_rounded,
                  color: statusColor,
                  size: 20),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                          device.name.isNotEmpty
                              ? device.name
                              : 'Unknown Device',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: LsColors.text)),
                    ),
                    if (_appVerified == true)
                      Tooltip(
                        message: 'Verified genuine app',
                        child: Icon(Icons.verified_rounded,
                            size: 14, color: LsColors.info),
                      ),
                  ]),
                  SizedBox(height: 2),
                  Text(
                      'Last seen: $lastSeen · ${device.totalSyncs} sync${device.totalSyncs == 1 ? "" : "s"}',
                      style: TextStyle(fontSize: 11, color: LsColors.subText)),
                ],
              ),
            ),
            _StatusPill(approved: approved),
          ]),
          SizedBox(height: 12),
          Row(children: [
            if (!approved) ...[
              Expanded(
                child: Text(
                    'This device wants to sync. Approve to allow data exchange.',
                    style: TextStyle(
                        fontSize: 11, color: LsColors.subText, height: 1.4)),
              ),
              SizedBox(width: 10),
              _Btn(
                  label: 'Approve',
                  color: LsColors.success,
                  onPressed: () => widget.svc.approveDevice(device.id),
                  compact: true),
            ] else ...[
              Expanded(
                child: Text('Approved · ready to receive transfers.',
                    style: TextStyle(fontSize: 11, color: LsColors.subText)),
              ),
              SizedBox(width: 10),
              _Btn(
                  label: 'Revoke',
                  color: LsColors.danger,
                  outlined: true,
                  onPressed: () => _confirmRevoke(context),
                  compact: true),
            ],
          ]),
        ],
      ),
    );
  }

  void _confirmRevoke(BuildContext context) {
    final name =
        widget.device.name.isNotEmpty ? widget.device.name : 'This device';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Revoke access?'),
        content: Text('"$name" will no longer be able to sync.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: LsColors.danger),
            onPressed: () {
              Navigator.pop(context);
              widget.svc.revokeDevice(widget.device.id);
            },
            child: Text('Revoke'),
          ),
        ],
      ),
    );
  }
}

// ─── History Tab ──────────────────────────────────────────────────────────────

class _HistoryTab extends StatefulWidget {
  final LanSyncService svc;
  final String itemLabel;
  const _HistoryTab({required this.svc, required this.itemLabel});

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  List<LanTransferLog> _logs = [];
  StreamSubscription<List<LanTransferLog>>? _sub;
  bool _loading = true;

  static final _df = DateFormat('MMM d, h:mm a');

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.svc.transferHistoryStream.listen((l) {
      if (mounted) setState(() => _logs = l);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final logs = await widget.svc.getTransferHistory();
    if (mounted)
      setState(() {
        _logs = logs;
        _loading = false;
      });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(child: CircularProgressIndicator());
    }
    if (_logs.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.swap_horiz_rounded, size: 52, color: LsColors.border),
          SizedBox(height: 14),
          Text('No transfers yet',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: LsColors.subText)),
          SizedBox(height: 6),
          Text(
            'Sent and received ${widget.itemLabel.toLowerCase()} batches\nappear here after they complete.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: LsColors.hint, height: 1.5),
          ),
        ]),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.all(14),
      itemCount: _logs.length,
      itemBuilder: (_, i) {
        final log = _logs[i];
        final isOut = log.direction == 'outgoing';
        final color = isOut ? LsColors.primary : LsColors.success;
        final icon = isOut ? Icons.upload_rounded : Icons.download_rounded;
        final label = isOut ? 'Sent' : 'Received';
        final when =
            _df.format(DateTime.fromMillisecondsSinceEpoch(log.completedAt));

        // Parse names for expand
        List<String> names = [];
        if (log.itemNamesJson != null) {
          try {
            names = (jsonDecode(log.itemNamesJson!) as List).cast<String>();
          } catch (_) {}
        }

        return _HistoryCard(
            log: log,
            color: color,
            icon: icon,
            label: label,
            when: when,
            names: names,
            itemLabel: widget.itemLabel);
      },
    );
  }
}

class _HistoryCard extends StatefulWidget {
  final LanTransferLog log;
  final Color color;
  final IconData icon;
  final String label;
  final String when;
  final List<String> names;
  final String itemLabel;

  const _HistoryCard({
    required this.log,
    required this.color,
    required this.icon,
    required this.label,
    required this.when,
    required this.names,
    required this.itemLabel,
  });

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final log = widget.log;
    final color = widget.color;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: LsColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap: widget.names.isNotEmpty
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      shape: BoxShape.circle),
                  child: Icon(widget.icon, color: color, size: 20),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            log.deviceName.isNotEmpty
                                ? log.deviceName
                                : 'Peer Device',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: LsColors.text),
                          ),
                        ),
                        Container(
                          padding:
                              EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border:
                                Border.all(color: color.withValues(alpha: 0.3)),
                          ),
                          child: Text(widget.label,
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: color)),
                        ),
                      ]),
                      SizedBox(height: 3),
                      Row(children: [
                        Icon(Icons.access_time_rounded,
                            size: 11, color: LsColors.hint),
                        SizedBox(width: 3),
                        Text(widget.when,
                            style: TextStyle(
                                fontSize: 11, color: LsColors.subText)),
                        SizedBox(width: 8),
                        Text(
                            '${log.itemCount} ${widget.itemLabel.toLowerCase()}${log.itemCount == 1 ? "" : "s"}',
                            style:
                                TextStyle(fontSize: 11, color: LsColors.hint)),
                        if (widget.names.isNotEmpty) ...[
                          const Spacer(),
                          Icon(
                              _expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: LsColors.hint),
                        ],
                      ]),
                    ],
                  ),
                ),
              ]),
            ),
          ),
          if (_expanded && widget.names.isNotEmpty) ...[
            Divider(height: 1, color: LsColors.border),
            Padding(
              padding: EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.names
                    .map((n) => Padding(
                          padding: EdgeInsets.only(bottom: 4),
                          child: Text('· $n',
                              style: TextStyle(
                                  fontSize: 12, color: LsColors.text)),
                        ))
                    .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Shared small widgets ─────────────────────────────────────────────────────

class _PulseIndicator extends StatelessWidget {
  final bool active;
  const _PulseIndicator({required this.active});

  @override
  Widget build(BuildContext context) {
    final color = active ? LsColors.success : Colors.grey.shade300;
    return Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: active
            ? [
                BoxShadow(
                    color: color.withValues(alpha: 0.5),
                    blurRadius: 6,
                    spreadRadius: 1)
              ]
            : [],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;

  const _SectionLabel({required this.icon, required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16, color: LsColors.primary),
      SizedBox(width: 6),
      Expanded(
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: LsColors.text))),
      if (trailing != null) trailing!,
    ]);
  }
}

class _WatchingPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: LsColors.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LsColors.success.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: LsColors.success),
        ),
        SizedBox(width: 5),
        Text('Live',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: LsColors.success)),
      ]),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  final Color color;
  const _CountBadge({required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text('$count',
          style: TextStyle(
              color: LsColors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11)),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool approved;
  const _StatusPill({required this.approved});

  @override
  Widget build(BuildContext context) {
    final color = approved ? LsColors.success : LsColors.warning;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(approved ? 'Approved' : 'Pending',
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _HintCard extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _HintCard(
      {required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 15, color: color),
        SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 11, color: LsColors.text, height: 1.45))),
      ]),
    );
  }
}

class _WaitingState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 28),
      child: Column(children: [
        Icon(Icons.wifi_find_rounded, size: 42, color: LsColors.border),
        SizedBox(height: 10),
        Text('Waiting for connected devices…',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: LsColors.subText)),
        SizedBox(height: 4),
        Text(
          'Make sure the other device has started\nits server and is on the same Wi-Fi.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: LsColors.hint, height: 1.5),
        ),
      ]),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LsColors.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: LsColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(Icons.error_outline_rounded, color: LsColors.danger, size: 16),
        SizedBox(width: 8),
        Expanded(
            child: Text(message,
                style: TextStyle(fontSize: 11, color: LsColors.text))),
      ]),
    );
  }
}

class _Btn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool loading;
  final bool outlined;
  final bool compact;
  final VoidCallback? onPressed;

  const _Btn({
    required this.label,
    required this.color,
    this.icon,
    this.loading = false,
    this.outlined = false,
    this.compact = false,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final padding = compact
        ? EdgeInsets.symmetric(horizontal: 14, vertical: 8)
        : EdgeInsets.symmetric(vertical: 13);
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(9));
    final child = loading
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: outlined ? color : LsColors.white))
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: outlined ? color : LsColors.white),
                SizedBox(width: 4),
              ],
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: outlined ? color : LsColors.white)),
            ],
          );

    if (outlined) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.6)),
          padding: padding,
          shape: shape,
        ),
        onPressed: onPressed,
        child: child,
      );
    }
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: onPressed == null ? LsColors.border : color,
        padding: padding,
        shape: shape,
      ),
      onPressed: onPressed,
      child: child,
    );
  }
}
