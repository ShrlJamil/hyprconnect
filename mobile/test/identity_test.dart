import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/der.dart';
import 'package:hyprconnect_mobile/src/protocol/identity.dart';

void main() {
  test('generated identity has CN = deviceId and a usable SPKI', () {
    final identity = LocalIdentity.generate(
      deviceId: '0123456789abcdef0123456789abcdef',
      deviceName: 'Test Phone',
    );
    final info = LocalIdentity.certInfo(identity.certDer);
    expect(info.commonName, identity.deviceId);
    expect(info.spki.length, greaterThan(100));
    expect(info.spki, identity.spkiDer);
    expect(identity.certPem, contains('BEGIN CERTIFICATE'));
    expect(identity.keyPem, contains('BEGIN PRIVATE KEY'));
  });

  test('verification key matches the daemon formula (known vector)', () {
    // SPKI fiktif; nilai harapan dihitung independen dengan sha256sum:
    // SHA256(besar + kecil) -> 8 hex pertama, huruf besar.
    final a = Uint8List.fromList([0x30, 0x82, 0x01, 0x22, 0x01, 0x00]);
    final b = Uint8List.fromList([0x30, 0x82, 0x01, 0x22, 0x01, 0xff]);
    expect(LocalIdentity.verificationKey(a, b), '10E4D84D');
    // Simetris: urutan argumen tidak berpengaruh.
    expect(LocalIdentity.verificationKey(b, a), '10E4D84D');
  });

  test('DER helpers reject garbage', () {
    expect(
      () => extractSpki(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(
      () => extractCommonName(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  test('loadOrCreate persists the identity across loads', () async {
    final dir = await Directory.systemTemp.createTemp('hyprconnect-id-');
    try {
      final first = await LocalIdentity.loadOrCreate(
        dir,
        deviceName: 'Test Phone',
      );
      final second = await LocalIdentity.loadOrCreate(
        dir,
        deviceName: 'Test Phone',
      );
      expect(second.deviceId, first.deviceId);
      expect(second.certPem, first.certPem);
      expect(second.keyPem, first.keyPem);
      expect(File('${dir.path}/device.json').existsSync(), isTrue);
      expect(File('${dir.path}/cert.pem').existsSync(), isTrue);
      expect(File('${dir.path}/key.pem').existsSync(), isTrue);
      // Bukti independen: openssl membaca CN yang sama.
      final result = await Process.run('openssl', [
        'x509',
        '-in',
        '${dir.path}/cert.pem',
        '-noout',
        '-subject',
      ]);
      expect(result.stdout as String, contains(first.deviceId));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('validDeviceId follows the daemon rules', () {
    expect(LocalIdentity.validDeviceId('a' * 32), isTrue);
    expect(LocalIdentity.validDeviceId('a' * 38), isTrue);
    expect(LocalIdentity.validDeviceId('short'), isFalse);
    expect(LocalIdentity.validDeviceId('a' * 39), isFalse);
    expect(LocalIdentity.validDeviceId('a' * 31 + '!'), isFalse);
  });
}
