import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database/lan_sync_database.dart';
import '../service/lan_sync_service.dart';
import 'ls_theme.dart';

/// Bottom sheet shown when an incoming transfer arrives for approval.
///
/// Displays the sender's name, item count, individual item names, and
/// Accept / Decline actions. Used by [LanTransferListener] globally and
/// by [LanSyncScreen] for transfers that arrived while offline.
class IncomingTransferSheet extends StatefulWidget {
  final LanPendingTransfer transfer;
  final LanSyncService svc;
  final Future<void> Function()? onResolved;

  const IncomingTransferSheet({
    super.key,
    required this.transfer,
    required this.svc,
    this.onResolved,
  });

  @override
  State<IncomingTransferSheet> createState() => _IncomingTransferSheetState();
}

class _IncomingTransferSheetState extends State<IncomingTransferSheet> {
  bool _busy = false;

  static final _df = DateFormat('MMM d, h:mm a');

  static List<String> _parseNames(String dataJson) {
    try {
      final list = jsonDecode(dataJson) as List;
      return list
          .map((item) {
            final m = item as Map<String, dynamic>;
            // Support items that embed a 'displayName' key or common name fields.
            if (m.containsKey('displayName')) return m['displayName'] as String;
            final first =
                m['first_name'] as String? ?? m['firstName'] as String? ?? '';
            final last =
                m['last_name'] as String? ?? m['lastName'] as String? ?? '';
            final full = '$first $last'.trim();
            if (full.isNotEmpty) return full;
            final name = m['name'] as String? ?? '';
            return name;
          })
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await widget.svc.approveTransfer(widget.transfer.id);
      await widget.onResolved?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to accept transfer: $e'),
          backgroundColor: LsColors.danger,
        ));
      }
    }
  }

  Future<void> _decline() async {
    setState(() => _busy = true);
    await widget.svc.rejectTransfer(widget.transfer.id);
    await widget.onResolved?.call();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.transfer;
    final names = _parseNames(t.dataJson);
    final when =
        _df.format(DateTime.fromMillisecondsSinceEpoch(t.transferredAt));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.9,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: LsColors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: LsColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),

            // Header
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: LsColors.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.download_rounded,
                        color: LsColors.primary, size: 22),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Incoming Transfer',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: LsColors.text,
                          ),
                        ),
                        Text(
                          'From: ${t.fromDeviceName.isNotEmpty ? t.fromDeviceName : "a peer device"}',
                          style:
                              TextStyle(fontSize: 12, color: LsColors.subText),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: 16),

            // Summary card
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: LsColors.background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: LsColors.border),
                ),
                child: Row(
                  children: [
                    _stat(Icons.folder_rounded, '${t.itemCount}',
                        '${t.itemCount == 1 ? "Item" : "Items"}'),
                    _divider(),
                    _stat(Icons.access_time_rounded, when, 'Received'),
                  ],
                ),
              ),
            ),

            SizedBox(height: 12),

            // Item list
            if (names.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Row(children: [
                  Icon(Icons.list_rounded, size: 14, color: LsColors.subText),
                  SizedBox(width: 6),
                  Text(
                    '${names.length} item${names.length == 1 ? "" : "s"}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: LsColors.subText),
                  ),
                ]),
              ),
              SizedBox(height: 6),
              Expanded(
                child: ListView.builder(
                  controller: ctrl,
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  itemCount: names.length,
                  itemBuilder: (_, i) {
                    final initials = names[i]
                        .trim()
                        .split(' ')
                        .where((w) => w.isNotEmpty)
                        .map((w) => w[0])
                        .take(2)
                        .join()
                        .toUpperCase();
                    return Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor:
                              LsColors.primary.withValues(alpha: 0.1),
                          child: Text(
                            initials.isEmpty ? '?' : initials,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: LsColors.primary),
                          ),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(names[i],
                              style: TextStyle(
                                  fontSize: 13, color: LsColors.text)),
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ] else
              const Spacer(),

            // Actions
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: LsColors.danger,
                        side: BorderSide(
                            color: LsColors.danger.withValues(alpha: 0.5)),
                        padding: EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _busy ? null : _decline,
                      child: const Text('Decline',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            _busy ? LsColors.border : LsColors.success,
                        padding: EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: _busy
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: LsColors.white))
                          : Icon(Icons.check_rounded, size: 18),
                      label: Text(
                        _busy
                            ? 'Saving…'
                            : 'Accept ${t.itemCount} Item${t.itemCount == 1 ? "" : "s"}',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onPressed: _busy ? null : _accept,
                    ),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(IconData icon, String value, String label) {
    return Expanded(
      child: Column(children: [
        Icon(icon, size: 18, color: LsColors.primary),
        SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: LsColors.text)),
        Text(label, style: TextStyle(fontSize: 10, color: LsColors.subText)),
      ]),
    );
  }

  Widget _divider() => Container(
      height: 36,
      width: 1,
      color: LsColors.border,
      margin: EdgeInsets.symmetric(horizontal: 8));
}
