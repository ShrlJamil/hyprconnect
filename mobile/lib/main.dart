//! HyprConnect mobile. The root is a KDE Connect style shell: a
//! navigation drawer (see app_drawer.dart) switches between paired
//! devices, each shown as a device page; pairing a new device,
//! settings and about live behind the drawer too.

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'l10n/l10n.dart';
import 'src/ui/app_drawer.dart';
import 'src/ui/app_state.dart';
import 'src/ui/device_page.dart';

void main() {
  runApp(const HyprConnectApp());
}

class HyprConnectApp extends StatelessWidget {
  const HyprConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyprConnect',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final AppState _appState;
  String? _selectedDeviceId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appState = AppState();
    _appState.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appState.onResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appState.dispose();
    super.dispose();
  }

  bool _isPaired(DeviceListEntry entry) {
    final conn = _appState.connectionFor(entry.deviceId);
    return entry.trusted || (conn?.isPaired ?? false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final paired = _appState.entries
            .where(_isPaired)
            .where(
              (entry) =>
                  entry.online ||
                  (_appState.connectionFor(entry.deviceId)?.isConnected ??
                      false),
            )
            .toList();
        DeviceListEntry? selected;
        for (final entry in paired) {
          if (entry.deviceId == _selectedDeviceId) {
            selected = entry;
            break;
          }
        }
        selected ??= paired.isNotEmpty ? paired.first : null;
        final drawer = AppDrawer(
          appState: _appState,
          selectedDeviceId: selected?.deviceId,
          onSelectDevice: (id) => setState(() => _selectedDeviceId = id),
        );
        if (selected == null) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('HyprConnect'),
              leading: Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: context.l10n.devices,
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
            ),
            drawer: drawer,
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.devices, size: 56),
                    SizedBox(height: 12),
                    Text(
                      context.l10n.noPairedDeviceTitle,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.noPairedDeviceBody,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return DevicePage(
          key: ValueKey(selected.deviceId),
          appState: _appState,
          entry: selected,
          isRoot: true,
          drawer: drawer,
        );
      },
    );
  }
}
