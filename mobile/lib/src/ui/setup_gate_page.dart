//! First-run setup gate: on a fresh install the app cannot be
//! used until the two background-survival switches are on. The
//! battery exemption is checked automatically (the system can
//! answer that); the vendor Autostart switch on Xiaomi / HyperOS
//! cannot be read by apps, so the user opens its page from here
//! and then confirms it is on. Completing the gate is remembered
//! in AppPrefs, and an install that already has paired devices
//! never sees it (see AppState.setupGateRequired).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../platform/native_bridge.dart';
import 'app_state.dart';

class SetupGatePage extends StatefulWidget {
  final AppState appState;

  const SetupGatePage({super.key, required this.appState});

  @override
  State<SetupGatePage> createState() => _SetupGatePageState();
}

class _SetupGatePageState extends State<SetupGatePage>
    with WidgetsBindingObserver {
  bool? _batteryOk;
  bool _autostartOpened = false;
  bool _autostartConfirmed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBattery();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkBattery();
  }

  Future<void> _checkBattery() async {
    final ok = await NativeBridge.isIgnoringBatteryOptimizations();
    if (mounted) setState(() => _batteryOk = ok);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final batteryOk = _batteryOk ?? false;
    final canContinue = batteryOk && _autostartConfirmed;
    return Scaffold(
      appBar: AppBar(title: Text(l.setupTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.setupIntro),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.battery_saver, size: 36),
            title: Text(l.batteryOptimization),
            subtitle: Text(
              batteryOk ? l.batteryUnrestricted : l.batteryRestricted,
            ),
            trailing: batteryOk
                ? const Icon(Icons.check_circle, color: Colors.green)
                : TextButton(
                    onPressed: () async {
                      await NativeBridge.openBatteryOptimizationSettings();
                      await Future<void>.delayed(
                        const Duration(seconds: 1),
                      );
                      await _checkBattery();
                    },
                    child: Text(l.batteryAllow),
                  ),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.rocket_launch, size: 36),
            title: Text(l.autostart),
            subtitle: Text(l.autostartBody),
            trailing: _autostartConfirmed
                ? const Icon(Icons.check_circle, color: Colors.green)
                : TextButton(
                    onPressed: () async {
                      final opened =
                          await NativeBridge.openAutostartSettings();
                      if (opened && mounted) {
                        setState(() => _autostartOpened = true);
                      }
                    },
                    child: Text(l.autostartOpen),
                  ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _autostartConfirmed,
            onChanged: _autostartOpened
                ? (value) =>
                      setState(() => _autostartConfirmed = value ?? false)
                : null,
            title: Text(l.autostartConfirm),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: canContinue
                ? () => widget.appState.completeSetup()
                : null,
            child: Text(l.setupContinue),
          ),
        ],
      ),
    );
  }
}
