//! Per-device preferences for the remote input (mousepad) plugin,
//! modelled on the stock KDE Connect app's settings page: what each
//! finger-count tap does, touchpad sensitivity and pointer
//! acceleration presets, scroll direction and sensitivity, the gyro
//! mouse, whether the on-screen mouse buttons show, and whether a
//! double tap starts a drag.
//!
//! Storage: remote_input_prefs.json in the app documents directory,
//! {"<deviceId>": { ...fields... }}. Defaults match the stock app's
//! out-of-box behaviour (left/right/middle taps, default sensitivity,
//! medium acceleration, buttons shown, double-tap drag on, gyro off).

import 'dart:convert';
import 'dart:io';

/// What a tap with a given finger count sends.
enum TapAction {
  left('Klik kiri'),
  right('Klik kanan'),
  middle('Klik tengah'),
  none('Tidak ada');

  final String label;
  const TapAction(this.label);
}

/// Touchpad sensitivity presets (a plain multiplier on drag deltas).
enum SensitivityPreset {
  slow('Pelan', 0.6),
  standard('Bawaan', 1.0),
  fast('Cepat', 1.6);

  final String label;
  final double factor;
  const SensitivityPreset(this.label, this.factor);
}

/// Pointer acceleration presets (extra gain that grows with the
/// speed of the drag, so fast flicks travel further).
enum AccelerationPreset {
  off('Mati', 0.0),
  low('Rendah', 0.5),
  medium('Menengah', 1.0),
  high('Tinggi', 1.8);

  final String label;
  final double gain;
  const AccelerationPreset(this.label, this.gain);
}

class RemoteInputPrefs {
  TapAction tapOne;
  TapAction tapTwo;
  TapAction tapThree;
  SensitivityPreset sensitivity;
  AccelerationPreset acceleration;
  bool reverseScroll;

  /// 0..1 as shown by the settings slider.
  double scrollSensitivity;
  bool gyroEnabled;

  /// 0..1 as shown by the settings slider.
  double gyroSensitivity;
  bool showMouseButtons;
  bool doubleTapDrag;

  RemoteInputPrefs({
    this.tapOne = TapAction.left,
    this.tapTwo = TapAction.right,
    this.tapThree = TapAction.middle,
    this.sensitivity = SensitivityPreset.standard,
    this.acceleration = AccelerationPreset.medium,
    this.reverseScroll = false,
    this.scrollSensitivity = 0.9,
    this.gyroEnabled = false,
    this.gyroSensitivity = 0.85,
    this.showMouseButtons = true,
    this.doubleTapDrag = true,
  });

  /// Multiplier applied to two-finger scroll deltas.
  double get scrollFactor => 0.2 + 1.8 * scrollSensitivity;

  /// Gyro mouse gain: pixels per radian/second of rotation.
  double get gyroFactor => 20 + 100 * gyroSensitivity;

  Map<String, dynamic> toJson() => {
    'tapOne': tapOne.name,
    'tapTwo': tapTwo.name,
    'tapThree': tapThree.name,
    'sensitivity': sensitivity.name,
    'acceleration': acceleration.name,
    'reverseScroll': reverseScroll,
    'scrollSensitivity': scrollSensitivity,
    'gyroEnabled': gyroEnabled,
    'gyroSensitivity': gyroSensitivity,
    'showMouseButtons': showMouseButtons,
    'doubleTapDrag': doubleTapDrag,
  };

  static RemoteInputPrefs fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    double slider(Object? value, double fallback) {
      if (value is num) return value.toDouble().clamp(0.0, 1.0);
      return fallback;
    }

    final defaults = RemoteInputPrefs();
    return RemoteInputPrefs(
      tapOne: pick(TapAction.values, json['tapOne'], defaults.tapOne),
      tapTwo: pick(TapAction.values, json['tapTwo'], defaults.tapTwo),
      tapThree: pick(TapAction.values, json['tapThree'], defaults.tapThree),
      sensitivity: pick(
        SensitivityPreset.values,
        json['sensitivity'],
        defaults.sensitivity,
      ),
      acceleration: pick(
        AccelerationPreset.values,
        json['acceleration'],
        defaults.acceleration,
      ),
      reverseScroll: json['reverseScroll'] as bool? ?? defaults.reverseScroll,
      scrollSensitivity: slider(
        json['scrollSensitivity'],
        defaults.scrollSensitivity,
      ),
      gyroEnabled: json['gyroEnabled'] as bool? ?? defaults.gyroEnabled,
      gyroSensitivity: slider(
        json['gyroSensitivity'],
        defaults.gyroSensitivity,
      ),
      showMouseButtons:
          json['showMouseButtons'] as bool? ?? defaults.showMouseButtons,
      doubleTapDrag: json['doubleTapDrag'] as bool? ?? defaults.doubleTapDrag,
    );
  }

  RemoteInputPrefs copy() => RemoteInputPrefs.fromJson(toJson());
}

/// Loads and saves [RemoteInputPrefs] per device, mirroring
/// [PluginSettings]' storage habits (tmp file + rename).
class RemoteInputPrefsStore {
  final Directory? _dir;
  final Map<String, RemoteInputPrefs> _prefs;

  RemoteInputPrefsStore._(this._dir, this._prefs);

  static Future<RemoteInputPrefsStore> load(Directory dir) async {
    await dir.create(recursive: true);
    final prefs = <String, RemoteInputPrefs>{};
    final file = File('${dir.path}/remote_input_prefs.json');
    if (await file.exists()) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final entry in json.entries) {
          if (entry.value is Map<String, dynamic>) {
            prefs[entry.key] = RemoteInputPrefs.fromJson(
              entry.value as Map<String, dynamic>,
            );
          }
        }
      } catch (_) {
        // A corrupt prefs file is treated as empty; changing any
        // setting re-creates it.
      }
    }
    return RemoteInputPrefsStore._(dir, prefs);
  }

  /// In-memory store (no persistence), for tests and previews.
  factory RemoteInputPrefsStore.inMemory() => RemoteInputPrefsStore._(null, {});

  /// The prefs for [deviceId], defaults when never changed.
  RemoteInputPrefs forDevice(String deviceId) =>
      _prefs[deviceId] ?? RemoteInputPrefs();

  Future<void> save(String deviceId, RemoteInputPrefs prefs) async {
    _prefs[deviceId] = prefs;
    final dir = _dir;
    if (dir == null) return;
    final file = File('${dir.path}/remote_input_prefs.json');
    final tmp = File('${dir.path}/remote_input_prefs.json.tmp');
    final json = <String, dynamic>{
      for (final entry in _prefs.entries) entry.key: entry.value.toJson(),
    };
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename(file.path);
  }
}
