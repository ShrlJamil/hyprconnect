//! Navigation drawer, mirroring KDE Connect Android: a header with
//! this device, the paired devices under "Peranti", then pair-new-
//! device, settings and about. The pill highlight follows the active
//! destination: it sits on the selected device, or on pair, settings
//! or about while one of those pages is showing. All four top-level
//! pages carry this drawer behind a hamburger button, and switching
//! between them replaces the current page instead of stacking, so
//! the back stack stays flat like in KDE Connect.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'about_page.dart';
import 'app_state.dart';
import 'fade_page_route.dart';
import 'pair_new_page.dart';
import 'settings_page.dart';

/// Which top-level destination a drawer instance belongs to; the
/// pill highlight is drawn on the matching entry.
enum DrawerActive { device, pair, settings, about }

class AppDrawer extends StatelessWidget {
  final AppState appState;
  final String? selectedDeviceId;
  final DrawerActive active;
  final ValueChanged<String> onSelectDevice;

  /// Navigation overrides for drawers hosted by a sub page (pair,
  /// settings, about): the host page is popped before the chosen
  /// destination opens, so destinations never stack on each other.
  final VoidCallback? onOpenPair;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenAbout;

  const AppDrawer({
    super.key,
    required this.appState,
    required this.selectedDeviceId,
    required this.active,
    required this.onSelectDevice,
    this.onOpenPair,
    this.onOpenSettings,
    this.onOpenAbout,
  });

  bool _isPaired(DeviceListEntry entry) {
    final conn = appState.connectionFor(entry.deviceId);
    return entry.trusted || (conn?.isPaired ?? false);
  }

  /// A drawer for a sub page pushed from this one: acting on it
  /// first pops the sub page, then behaves exactly like this drawer.
  AppDrawer _subDrawer(BuildContext pageContext, DrawerActive active) {
    return AppDrawer(
      appState: appState,
      selectedDeviceId: selectedDeviceId,
      active: active,
      onSelectDevice: (id) {
        Navigator.of(pageContext).pop();
        onSelectDevice(id);
      },
      onOpenPair: () {
        final navigator = Navigator.of(pageContext);
        navigator.pop();
        _pushPair(navigator);
      },
      onOpenSettings: () {
        final navigator = Navigator.of(pageContext);
        navigator.pop();
        _pushSettings(navigator);
      },
      onOpenAbout: () {
        final navigator = Navigator.of(pageContext);
        navigator.pop();
        _pushAbout(navigator);
      },
    );
  }

  void _pushPair(NavigatorState navigator) {
    navigator.push(
      FadePageRoute<void>(
        builder: (pageContext) => PairNewPage(
          appState: appState,
          drawer: _subDrawer(pageContext, DrawerActive.pair),
          onSelectDevice: (deviceId) {
            navigator.pop();
            onSelectDevice(deviceId);
          },
        ),
      ),
    );
  }

  void _pushSettings(NavigatorState navigator) {
    navigator.push(
      FadePageRoute<void>(
        builder: (pageContext) => SettingsPage(
          appState: appState,
          drawer: _subDrawer(pageContext, DrawerActive.settings),
        ),
      ),
    );
  }

  void _pushAbout(NavigatorState navigator) {
    navigator.push(
      FadePageRoute<void>(
        builder: (pageContext) =>
            AboutPage(drawer: _subDrawer(pageContext, DrawerActive.about)),
      ),
    );
  }

  /// One of the destination entries (pair, settings, about), with
  /// the same pill treatment as the device rows: [isActive] draws
  /// the highlight, and tapping the active destination only closes
  /// the drawer.
  Widget _destinationTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool isActive,
    required VoidCallback? override,
    required void Function(NavigatorState navigator) pushDefault,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: isActive ? colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: ListTile(
          leading: Icon(icon),
          title: Text(title),
          selected: isActive,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          onTap: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            if (isActive) return;
            if (override != null) {
              override();
            } else {
              pushDefault(navigator);
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = appState.identity;
    final pairedDevices = appState.entries
        .where(_isPaired)
        .where(
          (entry) =>
              entry.online ||
              (appState.connectionFor(entry.deviceId)?.isConnected ?? false),
        )
        .toList();
    final colorScheme = Theme.of(context).colorScheme;
    // The device rows carry the pill only while a device page is
    // the active destination; on pair, settings and about the pill
    // belongs to that page's own entry instead.
    final pillDeviceId = active == DrawerActive.device
        ? selectedDeviceId
        : null;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.smartphone, size: 40, color: colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          identity?.deviceName ?? 'HyprConnect',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          context.l10n.thisDevice,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                context.l10n.devices,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final entry in pairedDevices)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Material(
                  color: entry.deviceId == pillDeviceId
                      ? colorScheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                  child: ListTile(
                    leading: Icon(
                      entry.deviceType.contains('phone')
                          ? Icons.smartphone
                          : Icons.desktop_windows,
                    ),
                    title: Text(
                      entry.name.isEmpty ? entry.deviceId : entry.name,
                    ),
                    selected: entry.deviceId == pillDeviceId,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      onSelectDevice(entry.deviceId);
                    },
                  ),
                ),
              ),
            _destinationTile(
              context,
              icon: Icons.devices,
              title: context.l10n.allDevices,
              isActive: active == DrawerActive.pair,
              override: onOpenPair,
              pushDefault: _pushPair,
            ),
            const Divider(),
            _destinationTile(
              context,
              icon: Icons.settings,
              title: context.l10n.settings,
              isActive: active == DrawerActive.settings,
              override: onOpenSettings,
              pushDefault: _pushSettings,
            ),
            _destinationTile(
              context,
              icon: Icons.info,
              title: context.l10n.about,
              isActive: active == DrawerActive.about,
              override: onOpenAbout,
              pushDefault: _pushAbout,
            ),
          ],
        ),
      ),
    );
  }
}
