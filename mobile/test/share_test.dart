//! M2 protocol tests: share.request packet shape, filename
//! sanitizing, unique receive paths, clipboard length guard, and a
//! full payload round-trip between two real DeviceConnections
//! (A serves a file, B downloads it over the payload TLS channel).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

Future<(DeviceConnection, DeviceConnection, TcpListener)> _pair(
  Directory dirA,
  Directory dirB,
) async {
  final idA = await LocalIdentity.loadOrCreate(dirA, deviceName: 'Phone A');
  final idB = await LocalIdentity.loadOrCreate(dirB, deviceName: 'Phone B');
  final trustA = await TrustStore.load(dirA);
  final trustB = await TrustStore.load(dirB);
  final listener = TcpListener();
  final listenPort = await listener.start();
  final connB = DeviceConnection(
    identity: idB,
    trust: trustB,
    tcpPort: listenPort,
  );
  final acceptDone = listener.connections.first.then((raw) async {
    await connB.acceptIncoming(raw);
  });
  final connA = DeviceConnection(
    identity: idA,
    trust: trustA,
    tcpPort: listenPort,
  );
  await connA.connectOutgoing(
    address: InternetAddress.loopbackIPv4,
    tcpPort: listenPort,
    deviceId: idB.deviceId,
    name: idB.deviceName,
    deviceType: 'phone',
    peerCertDer: idB.certDer,
  );
  await acceptDone.timeout(const Duration(seconds: 10));
  expect(connA.isConnected, isTrue);
  expect(connB.isConnected, isTrue);
  return (connA, connB, listener);
}

void main() {
  test('share.request packet carries filename, size and port', () {
    final packet = Packet(
      id: 42,
      type: 'kdeconnect.share.request',
      body: {'filename': 'foto.png'},
      payloadSize: 1234,
      payloadTransferInfo: {'port': 1740},
    );
    final decoded = Packet.fromJson(packet.toJson());
    expect(decoded.type, 'kdeconnect.share.request');
    expect(decoded.body['filename'], 'foto.png');
    expect(decoded.payloadSize, 1234);
    expect(decoded.payloadTransferInfo?['port'], 1740);
    expect(packet.toLine().endsWith('\n'), isTrue);
  });

  test('sanitizeSharedFilename never lets a name escape the dir', () {
    expect(sanitizeSharedFilename('../evil.txt'), 'evil.txt');
    expect(sanitizeSharedFilename('a/b/c.png'), 'c.png');
    expect(sanitizeSharedFilename('..\\..\\win.txt'), 'win.txt');
    expect(sanitizeSharedFilename(''), 'shared-file');
    expect(sanitizeSharedFilename('..'), 'shared-file');
    expect(sanitizeSharedFilename(null), 'shared-file');
    expect(sanitizeSharedFilename('normal.pdf'), 'normal.pdf');
  });

  test('uniqueFilePath deduplicates like the daemon', () async {
    final dir = await Directory.systemTemp.createTemp('hyprconnect-m2-');
    try {
      expect(
        uniqueFilePath(dir, 'a.txt'),
        '${dir.path}/a.txt',
      );
      await File('${dir.path}/a.txt').writeAsString('x');
      expect(
        uniqueFilePath(dir, 'a.txt'),
        '${dir.path}/a (1).txt',
      );
      await File('${dir.path}/a (1).txt').writeAsString('x');
      expect(
        uniqueFilePath(dir, 'a.txt'),
        '${dir.path}/a (2).txt',
      );
      expect(
        uniqueFilePath(dir, '../evil.txt'),
        '${dir.path}/evil.txt',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('sendClipboard refuses content over the daemon limit', () async {
    final dir = await Directory.systemTemp.createTemp('hyprconnect-m2-');
    try {
      final identity = await LocalIdentity.loadOrCreate(
        dir,
        deviceName: 'Phone A',
      );
      final trust = await TrustStore.load(dir);
      final conn = DeviceConnection(
        identity: identity,
        trust: trust,
        tcpPort: 1714,
      );
      await expectLater(
        conn.sendClipboard('x' * (maxClipboardChars + 1)),
        throwsArgumentError,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('payload round-trip: A serves a file, B downloads it',
      () async {
    final dirA = await Directory.systemTemp.createTemp('hyprconnect-m2-a-');
    final dirB = await Directory.systemTemp.createTemp('hyprconnect-m2-b-');
    DeviceConnection? connA;
    DeviceConnection? connB;
    TcpListener? listener;
    try {
      final pair = await _pair(dirA, dirB);
      connA = pair.$1;
      connB = pair.$2;
      listener = pair.$3;

      // Clipboard push A -> B arrives as a packet.
      final clipSeen = connB.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.clipboard' &&
            p.body['content'] == 'halo papan klip',
      );
      await connA.sendClipboard('halo papan klip');
      await clipSeen.timeout(const Duration(seconds: 10));

      // File push A -> B over the payload channel. The offered name
      // tries a traversal; B must save it as a plain base name.
      final payload = Uint8List.fromList(
        List<int>.generate(100000, (i) => i % 251),
      );
      final receiveDir = Directory('${dirB.path}/receive');
      final sendFuture = connA.sendFile(
        filename: '../evil.txt',
        size: payload.length,
        bytes: Stream<List<int>>.value(payload),
      );
      final packet = await connB.packets
          .firstWhere((p) => p.type == 'kdeconnect.share.request')
          .timeout(const Duration(seconds: 10));
      expect(packet.payloadSize, payload.length);
      expect(packet.payloadTransferInfo?['port'], isNotNull);
      final received = await connB
          .receiveFile(packet, receiveDir)
          .timeout(const Duration(seconds: 10));
      await sendFuture.timeout(const Duration(seconds: 10));
      expect(received.filename, 'evil.txt');
      expect(received.size, payload.length);
      expect(received.path, startsWith(receiveDir.path));
      expect(await File(received.path).readAsBytes(), payload);

      // The reverse direction works too: B serves, A downloads.
      final back = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sendBack = connB.sendFile(
        filename: 'balik.bin',
        size: back.length,
        bytes: Stream<List<int>>.value(back),
      );
      final packetBack = await connA.packets
          .firstWhere((p) => p.type == 'kdeconnect.share.request')
          .timeout(const Duration(seconds: 10));
      final receivedBack = await connA
          .receiveFile(packetBack, Directory('${dirA.path}/receive'))
          .timeout(const Duration(seconds: 10));
      await sendBack.timeout(const Duration(seconds: 10));
      expect(receivedBack.filename, 'balik.bin');
      expect(
        await File(receivedBack.path).readAsBytes(),
        back,
      );
    } finally {
      await connA?.close();
      await connB?.close();
      await listener?.stop();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
