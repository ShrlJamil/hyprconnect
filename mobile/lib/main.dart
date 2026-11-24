//! HyprConnect mobile. The root is a KDE Connect style shell: a
//! navigation drawer (see app_drawer.dart) switches between paired
//! devices, each shown as a device page; pairing a new device,
//! settings and about live behind the drawer too. On a fresh
//! install a setup gate (see setup_gate_page.dart) comes first:
//! the app cannot be used until the background-survival switches
//! are on.

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/app_localizations.dart';
import 'l10n/l10n.dart';
import 'src/settings/app_prefs.dart';
import 'src/ui/app_drawer.dart';
import 'src/ui/app_state.dart';
import 'src/ui/device_page.dart';
import 'src/ui/setup_gate_page.dart';
import 'src/ui/update_dialog.dart';
import 'src/update/update_checker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appDir = await getApplicationDocumentsDirectory();
  final prefs = await AppPrefs.load(appDir);
  // The connection core starts here, not from a widget: the
  // engine can be started by the keep-alive service with no
  // activity attached (after the system killed the process), and
  // widget lifecycle callbacks wait for the first frame in that
  // case, while the listener must come up immediately. The
  // AppState lives for the engine's whole lifetime; the UI just
  // observes it.
  final appState = AppState(prefs: prefs);
  appState.initialize();
  runApp(HyprConnectApp(prefs: prefs, appState: appState));
}

class HyprConnectApp extends StatelessWidget {
  final AppPrefs prefs;
  final AppState appState;

  const HyprConnectApp({super.key, required this.prefs, required this.appState});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) {
        return MaterialApp(
          title: 'HyprConnect',
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: prefs.themeMode,
          home: HomePage(prefs: prefs, appState: appState),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  final AppPrefs prefs;
  final AppState appState;

  const HomePage({super.key, required this.prefs, required this.appState});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  AppState get _appState => widget.appState;
  String? _selectedDeviceId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeCheckForUpdates();
    });
  }

  bool _updateCheckStarted = false;

  /// The automatic update check: at most once a day, only past
  /// the setup gate, and silent when nothing is available.
  Future<void> _maybeCheckForUpdates() async {
    if (_updateCheckStarted) return;
    _updateCheckStarted = true;
    final prefs = _appState.prefs;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - prefs.lastUpdateCheckMillis < 86400000) return;
    await prefs.markUpdateChecked(now);
    if (_appState.setupGateRequired) return;
    final info = await UpdateChecker.checkForUpdate();
    if (info != null && mounted) {
      await showUpdateDialog(context, info);
    }
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
    // The AppState is not disposed here: it belongs to the
    // engine, which outlives this page (and the activity).
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
        if (_appState.setupGateRequired) {
          return SetupGatePage(appState: _appState);
        }
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
