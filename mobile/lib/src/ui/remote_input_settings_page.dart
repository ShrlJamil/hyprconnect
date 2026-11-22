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

import '../../l10n/app_localizations.dart';
import '../../l10n/l10n.dart';
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
          appBar: AppBar(title: Text(context.l10n.remoteInputSettingsTitle)),
          body: ListView(
            children: [
              dropdownRow<TapAction>(
                context.l10n.setTapActionOne,
                prefs.tapOne,
                TapAction.values,
                (v) => tapActionLabel(context.l10n, v),
                (v) => update((p) => p.tapOne = v),
              ),
              dropdownRow<TapAction>(
                context.l10n.setTapActionTwo,
                prefs.tapTwo,
                TapAction.values,
                (v) => tapActionLabel(context.l10n, v),
                (v) => update((p) => p.tapTwo = v),
              ),
              dropdownRow<TapAction>(
                context.l10n.setTapActionThree,
                prefs.tapThree,
                TapAction.values,
                (v) => tapActionLabel(context.l10n, v),
                (v) => update((p) => p.tapThree = v),
              ),
              dropdownRow<SensitivityPreset>(
                context.l10n.setTouchpadSensitivity,
                prefs.sensitivity,
                SensitivityPreset.values,
                (v) => sensitivityLabel(context.l10n, v),
                (v) => update((p) => p.sensitivity = v),
              ),
              dropdownRow<AccelerationPreset>(
                context.l10n.setPointerAcceleration,
                prefs.acceleration,
                AccelerationPreset.values,
                (v) => accelerationLabel(context.l10n, v),
                (v) => update((p) => p.acceleration = v),
              ),
              SwitchListTile(
                title: Text(context.l10n.reverseScrollDirection),
                value: prefs.reverseScroll,
                onChanged: (v) => update((p) => p.reverseScroll = v),
              ),
              sliderRow(
                context.l10n.scrollSensitivity,
                prefs.scrollSensitivity,
                (v) => update((p) => p.scrollSensitivity = v),
              ),
              SwitchListTile(
                title: Text(context.l10n.enableGyroMouse),
                value: prefs.gyroEnabled,
                onChanged: (v) => update((p) => p.gyroEnabled = v),
              ),
              sliderRow(
                context.l10n.gyroSensitivity,
                prefs.gyroSensitivity,
                (v) => update((p) => p.gyroSensitivity = v),
              ),
              SwitchListTile(
                title: Text(context.l10n.showMouseButtons),
                value: prefs.showMouseButtons,
                onChanged: (v) => update((p) => p.showMouseButtons = v),
              ),
              SwitchListTile(
                title: Text(context.l10n.dragAndDropBehavior),
                subtitle: Text(context.l10n.doubleTapToDrag),
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

/// Localized labels for the remote-input enums; the enums keep
/// English source labels, the settings page resolves through here.
String tapActionLabel(AppLocalizations l, TapAction action) => switch (action) {
  TapAction.left => l.tapLeft,
  TapAction.right => l.tapRight,
  TapAction.middle => l.tapMiddle,
  TapAction.none => l.tapNone,
};

String sensitivityLabel(AppLocalizations l, SensitivityPreset preset) =>
    switch (preset) {
      SensitivityPreset.slow => l.sensSlow,
      SensitivityPreset.standard => l.sensDefault,
      SensitivityPreset.fast => l.sensFast,
    };

String accelerationLabel(AppLocalizations l, AccelerationPreset preset) =>
    switch (preset) {
      AccelerationPreset.off => l.accelOff,
      AccelerationPreset.low => l.accelLow,
      AccelerationPreset.medium => l.accelMedium,
      AccelerationPreset.high => l.accelHigh,
    };
