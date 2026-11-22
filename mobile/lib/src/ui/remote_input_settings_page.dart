//! Settings for the remote input plugin, one device at a time,
//! following the stock app's "Pengaturan Masukan jarak jauh" page:
//! per-finger-count tap actions, touchpad sensitivity, pointer
//! acceleration, scroll direction and sensitivity, the gyro mouse,
//! the on-screen mouse buttons, and the double-tap drag behaviour.
//!
//! The stock page also carries a "share keystrokes from other apps"
//! section (Android share intents with a custom mime type); this app
//! has no such share target, so that section is not reproduced.

import 'package:flutter/material.dart';

import '../settings/remote_input_prefs.dart';
import 'app_state.dart';

class RemoteInputSettingsPage extends StatelessWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const RemoteInputSettingsPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final prefs = appState.remoteInputPrefsFor(entry.deviceId);

        Future<void> update(void Function(RemoteInputPrefs) change) async {
          final next = prefs.copy();
          change(next);
          await appState.updateRemoteInputPrefs(entry.deviceId, next);
        }

        Widget dropdownRow<T extends Enum>(
          String title,
          T value,
          List<T> values,
          String Function(T) label,
          ValueChanged<T> onChanged,
        ) {
          return ListTile(
            title: Text(title),
            subtitle: Text(label(value)),
            trailing: DropdownButton<T>(
              value: value,
              underline: const SizedBox.shrink(),
              items: [
                for (final option in values)
                  DropdownMenuItem(value: option, child: Text(label(option))),
              ],
              onChanged: (option) {
                if (option != null) onChanged(option);
              },
            ),
          );
        }

        Widget sliderRow(
          String title,
          double value,
          ValueChanged<double> onChanged,
        ) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(title: Text(title)),
              Slider(value: value, onChanged: (v) => onChanged(v)),
            ],
          );
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Pengaturan Masukan jarak jauh')),
          body: ListView(
            children: [
              dropdownRow<TapAction>(
                'Setel aksi ketuk satu jari',
                prefs.tapOne,
                TapAction.values,
                (v) => v.label,
                (v) => update((p) => p.tapOne = v),
              ),
              dropdownRow<TapAction>(
                'Setel aksi ketuk dua jari',
                prefs.tapTwo,
                TapAction.values,
                (v) => v.label,
                (v) => update((p) => p.tapTwo = v),
              ),
              dropdownRow<TapAction>(
                'Setel aksi ketuk tiga jari',
                prefs.tapThree,
                TapAction.values,
                (v) => v.label,
                (v) => update((p) => p.tapThree = v),
              ),
              dropdownRow<SensitivityPreset>(
                'Setel kepekaan touchpad',
                prefs.sensitivity,
                SensitivityPreset.values,
                (v) => v.label,
                (v) => update((p) => p.sensitivity = v),
              ),
              dropdownRow<AccelerationPreset>(
                'Setel akselerasi pointer',
                prefs.acceleration,
                AccelerationPreset.values,
                (v) => v.label,
                (v) => update((p) => p.acceleration = v),
              ),
              SwitchListTile(
                title: const Text('Arah Menggulir Terbalik'),
                value: prefs.reverseScroll,
                onChanged: (v) => update((p) => p.reverseScroll = v),
              ),
              sliderRow(
                'Scroll sensitivity',
                prefs.scrollSensitivity,
                (v) => update((p) => p.scrollSensitivity = v),
              ),
              SwitchListTile(
                title: const Text('Aktifkan tetikus giroskop'),
                value: prefs.gyroEnabled,
                onChanged: (v) => update((p) => p.gyroEnabled = v),
              ),
              sliderRow(
                'Gyroscope sensitivity',
                prefs.gyroSensitivity,
                (v) => update((p) => p.gyroSensitivity = v),
              ),
              SwitchListTile(
                title: const Text('Tampilkan tombol tetikus'),
                value: prefs.showMouseButtons,
                onChanged: (v) => update((p) => p.showMouseButtons = v),
              ),
              SwitchListTile(
                title: const Text('Drag and drop behavior'),
                subtitle: const Text('Ketuk dua kali untuk drag'),
                value: prefs.doubleTapDrag,
                onChanged: (v) => update((p) => p.doubleTapDrag = v),
              ),
            ],
          ),
        );
      },
    );
  }
}
