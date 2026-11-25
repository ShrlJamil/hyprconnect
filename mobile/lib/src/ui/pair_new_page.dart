//! One page for every known device, grouped by its relationship to
//! this phone: connected now, paired before but not connected, and
//! newly discovered. Connecting and pairing happen right on a
//! device's card, without opening its device page first. Tapping a
//! paired device that is connected or in range switches to it as
//! the home device, exactly like tapping its row in the drawer;
//! tapping any other card opens its device page as a sub page.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../protocol/protocol.dart';
import 'app_state.dart';
import 'device_page.dart';
import 'fade_page_route.dart';

class PairNewPage extends StatefulWidget {
  final AppState appState;

  /// The home navigation drawer, when pushed from it: the page then
  /// keeps the hamburger instead of a back arrow, like KDE Connect.
  final Widget? drawer;

  /// Switches the home page to a device, the way the drawer's
  /// device rows do. The host pops this page first, so the stack
  /// stays flat. Null when no home page hosts this page.
  final ValueChanged<String>? onSelectDevice;

  const PairNewPage({
    super.key,
    required this.appState,
    this.drawer,
    this.onSelectDevice,
  });

  @override
  State<PairNewPage> createState() => _PairNewPageState();
}

class _PairNewPageState extends State<PairNewPage> {
  /// Devices with a connect or pairing attempt in flight, so their
  /// card shows progress instead of a tappable button. A first
  /// pairing can wait up to 25 seconds for the desktop to connect
  /// back (see AppState.connectTo).
  final Set<String> _busy = {};

  AppState get appState => widget.appState;

  /// Toast-style notice, the same floating pill the device page uses.
  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// The device page's one-tap connect, in place: open the channel,
  /// then ask for pairing right away when the device is not paired
  /// yet. For an already paired device this simply reconnects.
  Future<void> _connect(DeviceListEntry entry) async {
    if (!_busy.add(entry.deviceId)) return;
    setState(() {});
    try {
      final outcome = await appState.connectTo(entry);
      if (!mounted) return;
      if (outcome == ConnectOutcome.failed) {
        _snack(context.l10n.connectFailed);
        return;
      }
      final conn = appState.connectionFor(entry.deviceId);
      if (conn != null &&
          !conn.isPaired &&
          conn.pairState == PairState.unpaired) {
        await appState.requestPair(entry.deviceId);
      }
    } finally {
      _busy.remove(entry.deviceId);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: widget.drawer,
      appBar: AppBar(
        leading: widget.drawer == null
            ? null
            : Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: context.l10n.devices,
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
        title: Text(context.l10n.allDevices),
      ),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          bool connectedPaired(DeviceListEntry entry) {
            final conn = appState.connectionFor(entry.deviceId);
            return entry.trusted &&
                (conn?.isPaired ?? false) &&
                (conn?.isConnected ?? false);
          }

          final entries = appState.entries;
          final connected = entries.where(connectedPaired).toList();
          final notConnected = entries
              .where((entry) => entry.trusted && !connectedPaired(entry))
              .toList();
          final available = entries
              .where((entry) => !entry.trusted && entry.online)
              .toList();
          final l = context.l10n;
          if (connected.isEmpty && notConnected.isEmpty && available.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  title: Text(l.noDeviceOnNetwork),
                  subtitle: Text(l.sameWifiHint),
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              if (connected.isNotEmpty) ...[
                _SectionHeader(label: l.sectionConnected),
                for (final entry in connected)
                  _DeviceRow(entry: entry, page: this),
              ],
              if (notConnected.isNotEmpty) ...[
                _SectionHeader(label: l.sectionNotConnected),
                for (final entry in notConnected)
                  _DeviceRow(entry: entry, page: this),
              ],
              if (available.isNotEmpty) ...[
                _SectionHeader(label: l.sectionAvailable),
                for (final entry in available)
                  _DeviceRow(entry: entry, page: this),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// A group label followed by a rule, the way the sections were
/// sketched: "Connected -------".
class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final DeviceListEntry entry;
  final _PairNewPageState page;

  const _DeviceRow({required this.entry, required this.page});

  AppState get appState => page.appState;

  @override
  Widget build(BuildContext context) {
    final conn = appState.connectionFor(entry.deviceId);
    final paired = conn?.isPaired ?? false;
    final connected = conn?.isConnected ?? false;
    final pendingIn = conn?.pairState == PairState.pendingIn;
    final pendingOut = conn?.pairState == PairState.pendingOut;
    final l = context.l10n;
    final status = paired && connected
        ? l.statusConnectedPaired
        : pendingIn
        ? l.statusPairRequestCheckKey
        : pendingOut
        ? l.waitingForDesktop
        : connected
        ? l.statusConnectedUnpaired
        : entry.trusted
        ? l.statusPaired
        : l.statusDiscovered;
    final key = (pendingIn || pendingOut) ? conn?.verificationKey : null;
    return Card(
      child: ListTile(
        leading: Icon(
          entry.deviceType.contains('phone')
              ? Icons.smartphone
              : Icons.desktop_windows,
          size: 32,
          color: entry.online || connected
              ? null
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        title: Text(entry.name.isEmpty ? entry.deviceId : entry.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_typeLabel(context, entry.deviceType)} - $status'),
            if (key != null) ...[
              const SizedBox(height: 2),
              Text(
                key,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
            ],
          ],
        ),
        trailing: _trailing(context, conn),
        onTap: () {
          // A paired device that is connected or in range behaves
          // exactly like its drawer row: it becomes the home device
          // instead of opening as a stacked sub page. Everything
          // else (new candidates, devices out of range) opens its
          // device page on top.
          final select = page.widget.onSelectDevice;
          final pairedDevice =
              entry.trusted || (conn?.isPaired ?? false);
          final reachable = entry.online || (conn?.isConnected ?? false);
          if (select != null && pairedDevice && reachable) {
            select(entry.deviceId);
            return;
          }
          Navigator.of(context).push(
            FadePageRoute<void>(
              builder: (context) =>
                  DevicePage(appState: appState, entry: entry),
            ),
          );
        },
      ),
    );
  }

  /// The protocol's raw device type as a proper label, so the card
  /// reads "Desktop - Connected, paired", not "desktop - ...".
  String _typeLabel(BuildContext context, String raw) {
    final l = context.l10n;
    final type = raw.toLowerCase();
    if (type.contains('phone')) return l.deviceTypePhone;
    if (type.contains('tablet')) return l.deviceTypeTablet;
    if (type.contains('laptop')) return l.deviceTypeLaptop;
    if (type.contains('desktop')) return l.deviceTypeDesktop;
    return raw.isEmpty ? raw : '${raw[0].toUpperCase()}${raw.substring(1)}';
  }

  Widget? _trailing(BuildContext context, DeviceConnection? conn) {
    final l = context.l10n;
    if (page._busy.contains(entry.deviceId)) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }
    if (conn != null && conn.pairState == PairState.pendingIn) {
      // Answer a pairing request without leaving this page. Accepting
      // sends pair=true back over the channel, like the device page.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: () => appState.requestPair(entry.deviceId),
            child: Text(l.accept),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => appState.rejectPair(entry.deviceId),
            child: Text(l.reject),
          ),
        ],
      );
    }
    if (conn != null && conn.pairState == PairState.pendingOut) {
      return TextButton(
        onPressed: () => appState.rejectPair(entry.deviceId),
        child: Text(l.cancelRequest),
      );
    }
    if (conn != null && conn.isConnected && conn.isPaired) return null;
    if (!entry.online) return null;
    if (entry.trusted) {
      return FilledButton.tonal(
        onPressed: () => page._connect(entry),
        child: Text(l.connect),
      );
    }
    return FilledButton(
      onPressed: () => page._connect(entry),
      child: Text(l.requestPairing),
    );
  }
}
