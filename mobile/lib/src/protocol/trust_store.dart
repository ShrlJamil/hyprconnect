//! Trusted devices: devices the user paired with. Their certificates
//! are stored so reconnections are authenticated and automatic.
//! Same JSON shape as the daemon's trusted.json, so both sides of the
//! pair can be inspected with the same tools.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

String hexEncode(Uint8List data) {
  return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List? hexDecode(String s) {
  if (s.length % 2 != 0) return null;
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}

class TrustedDevice {
  final String deviceId;
  final String name;
  final String deviceType;

  /// Peer certificate, hex encoded DER.
  final String certHex;

  const TrustedDevice({
    required this.deviceId,
    required this.name,
    required this.deviceType,
    required this.certHex,
  });

  factory TrustedDevice.fromJson(Map<String, dynamic> json) {
    return TrustedDevice(
      deviceId: json['deviceId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      deviceType: json['deviceType'] as String? ?? '',
      certHex: json['certHex'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'name': name,
      'deviceType': deviceType,
      'certHex': certHex,
    };
  }
}

class TrustStore {
  final Directory dir;
  final Map<String, TrustedDevice> _devices;

  TrustStore._(this.dir, this._devices);

  static Future<TrustStore> load(Directory dir) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}/trusted.json');
    final devices = <String, TrustedDevice>{};
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final item in list) {
          final device = TrustedDevice.fromJson(
            (item as Map).cast<String, dynamic>(),
          );
          if (device.deviceId.isNotEmpty) {
            devices[device.deviceId] = device;
          }
        }
      } catch (_) {
        // A corrupt trust file is treated as empty; pairing again
        // re-creates the entries.
      }
    }
    return TrustStore._(dir, devices);
  }

  List<TrustedDevice> get devices => _devices.values.toList();

  bool isTrusted(String deviceId) => _devices.containsKey(deviceId);

  bool certMatches(String deviceId, Uint8List certDer) {
    final stored = _devices[deviceId];
    if (stored == null) return false;
    final decoded = hexDecode(stored.certHex);
    if (decoded == null || decoded.length != certDer.length) return false;
    for (var i = 0; i < decoded.length; i++) {
      if (decoded[i] != certDer[i]) return false;
    }
    return true;
  }

  Uint8List? storedCert(String deviceId) {
    final stored = _devices[deviceId];
    if (stored == null) return null;
    return hexDecode(stored.certHex);
  }

  Future<void> add(TrustedDevice device) async {
    _devices[device.deviceId] = device;
    await _save();
  }

  Future<void> remove(String deviceId) async {
    _devices.remove(deviceId);
    await _save();
  }

  Future<void> _save() async {
    final file = File('${dir.path}/trusted.json');
    final tmp = File('${dir.path}/trusted.json.tmp');
    final list = _devices.values.map((d) => d.toJson()).toList();
    await tmp.writeAsString(jsonEncode(list));
    await tmp.rename(file.path);
  }
}
