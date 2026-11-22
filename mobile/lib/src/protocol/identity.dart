//! Local device identity: a stable device id plus a self-signed RSA 2048
//! certificate whose common name is the device id (KDE Connect model).
//! Lives in app-private storage, never in the repo. Mirrors the daemon's
//! src/identity.rs, except the key is RSA 2048 (what stock KDE Connect
//! uses) instead of the daemon's ECDSA P-256; the protocol accepts either.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import 'der.dart';

class LocalIdentity {
  final String deviceId;
  final String deviceName;
  final String certPem;
  final String keyPem;
  final Uint8List certDer;
  final Uint8List spkiDer;

  const LocalIdentity({
    required this.deviceId,
    required this.deviceName,
    required this.certPem,
    required this.keyPem,
    required this.certDer,
    required this.spkiDer,
  });

  /// 32 hex chars, matches the protocol id pattern.
  static String generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool validDeviceId(String id) {
    if (id.length < 32 || id.length > 38) return false;
    return id.runes.every(
      (c) =>
          (c >= 0x30 && c <= 0x39) ||
          (c >= 0x41 && c <= 0x5a) ||
          (c >= 0x61 && c <= 0x7a) ||
          c == 0x5f ||
          c == 0x2d,
    );
  }

  /// Generate a fresh identity: RSA 2048 key, self-signed certificate
  /// with CN = deviceId and SAN = deviceId, valid 10 years.
  static LocalIdentity generate({
    required String deviceId,
    required String deviceName,
  }) {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': deviceId},
      privateKey,
      publicKey,
      san: [deviceId],
    );
    final certPem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3650,
      sans: [deviceId],
    );
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
    final certDer = Uint8List.fromList(
      CryptoUtils.getBytesFromPEMString(certPem),
    );
    return LocalIdentity(
      deviceId: deviceId,
      deviceName: deviceName,
      certPem: certPem,
      keyPem: keyPem,
      certDer: certDer,
      spkiDer: extractSpki(certDer),
    );
  }

  /// Load the stored identity from [dir], or create and store one.
  /// Files: device.json, cert.pem, key.pem.
  static Future<LocalIdentity> loadOrCreate(
    Directory dir, {
    required String deviceName,
  }) async {
    await dir.create(recursive: true);
    final idFile = File('${dir.path}/device.json');
    final certFile = File('${dir.path}/cert.pem');
    final keyFile = File('${dir.path}/key.pem');
    if (await idFile.exists() &&
        await certFile.exists() &&
        await keyFile.exists()) {
      final meta =
          jsonDecode(await idFile.readAsString()) as Map<String, dynamic>;
      final deviceId = meta['deviceId'] as String;
      final certPem = await certFile.readAsString();
      final keyPem = await keyFile.readAsString();
      final certDer = Uint8List.fromList(
        CryptoUtils.getBytesFromPEMString(certPem),
      );
      return LocalIdentity(
        deviceId: deviceId,
        deviceName: meta['deviceName'] as String? ?? deviceName,
        certPem: certPem,
        keyPem: keyPem,
        certDer: certDer,
        spkiDer: extractSpki(certDer),
      );
    }
    final identity = generate(
      deviceId: generateDeviceId(),
      deviceName: deviceName,
    );
    await idFile.writeAsString(
      jsonEncode({
        'deviceId': identity.deviceId,
        'deviceName': identity.deviceName,
      }),
    );
    await certFile.writeAsString(identity.certPem);
    await keyFile.writeAsString(identity.keyPem);
    return identity;
  }

  /// Extract (common name, SPKI DER) from a peer certificate DER.
  static ({String commonName, Uint8List spki}) certInfo(Uint8List certDer) {
    return (
      commonName: extractCommonName(certDer),
      spki: extractSpki(certDer),
    );
  }

  /// KDE Connect verification key: SHA-256 over both devices' public
  /// keys (SPKI DER), larger byte string first; first 8 hex chars,
  /// upper case. Matches the daemon's identity::verification_key and
  /// what the stock Android app displays.
  static String verificationKey(Uint8List localSpki, Uint8List peerSpki) {
    final (first, second) = _lexicographicCompare(localSpki, peerSpki) < 0
        ? (peerSpki, localSpki)
        : (localSpki, peerSpki);
    final digest = sha256.convert([...first, ...second]);
    return digest.toString().substring(0, 8).toUpperCase();
  }

  static int _lexicographicCompare(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
