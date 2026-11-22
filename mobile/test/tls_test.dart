//! TLS both roles + pairing state machine, in-process, through the real
//! protocol classes: A opens the TCP connection (TLS server), B accepts
//! (TLS client). Proves the Dart TLS-server configuration the daemon
//! needs: the peer's self-signed certificate as the trusted anchor.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

Future<Directory> _tempDir(String prefix) {
  return Directory.systemTemp.createTemp(prefix);
}

void main() {
  test('opener is TLS server, acceptor is TLS client; pairing completes',
      () async {
    final dirA = await _tempDir('hyprconnect-tls-a-');
    final dirB = await _tempDir('hyprconnect-tls-b-');
    try {
      final idA = await LocalIdentity.loadOrCreate(
        dirA,
        deviceName: 'Phone A',
      );
      final idB = await LocalIdentity.loadOrCreate(
        dirB,
        deviceName: 'Phone B',
      );
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
      expect(connA.remoteDeviceId, idB.deviceId);
      expect(connB.remoteDeviceId, idA.deviceId);
      // Both sides saw the peer certificate and checked CN == deviceId.
      expect(connA.peerCertDer, isNotNull);
      expect(connB.peerCertDer, isNotNull);
      // The verification key agrees on both sides (symmetric formula).
      expect(connA.verificationKey, isNotNull);
      expect(connA.verificationKey, connB.verificationKey);

      // Pairing: A asks, B accepts, both end up paired and trusted.
      final bPackets = <Packet>[];
      final sub = connB.packets.listen(bPackets.add);
      await connA.requestPair();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(connB.pairState, PairState.pendingIn);
      await connB.requestPair();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(connA.isPaired, isTrue);
      expect(connB.isPaired, isTrue);
      expect(trustA.isTrusted(idB.deviceId), isTrue);
      expect(trustB.isTrusted(idA.deviceId), isTrue);
      expect(trustA.certMatches(idB.deviceId, idB.certDer), isTrue);

      // A ping crosses the encrypted channel.
      final pingArrived = Completer<Packet>();
      final sub2 = connB.packets.listen((p) {
        if (p.type == 'kdeconnect.ping' && !pingArrived.isCompleted) {
          pingArrived.complete(p);
        }
      });
      await connA.sendPing('tes M0');
      final ping = await pingArrived.future.timeout(
        const Duration(seconds: 5),
      );
      expect(ping.body['message'], 'tes M0');

      await sub.cancel();
      await sub2.cancel();
      await connA.close();
      await connB.close();
      await listener.stop();
    } finally {
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('unpair notifies the peer and both sides forget the trust',
      () async {
    final dirA = await _tempDir('hyprconnect-unpair-a-');
    final dirB = await _tempDir('hyprconnect-unpair-b-');
    try {
      final idA = await LocalIdentity.loadOrCreate(
        dirA,
        deviceName: 'Phone A',
      );
      final idB = await LocalIdentity.loadOrCreate(
        dirB,
        deviceName: 'Phone B',
      );
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

      await connA.requestPair();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await connB.requestPair();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(connA.isPaired, isTrue);
      expect(connB.isPaired, isTrue);

      final bUnpaired = Completer<void>();
      final sub = connB.pairStates.listen((state) {
        if (state == PairState.unpaired && !bUnpaired.isCompleted) {
          bUnpaired.complete();
        }
      });
      await connA.unpair();
      await bUnpaired.future.timeout(const Duration(seconds: 5));
      expect(connA.isPaired, isFalse);
      expect(connB.isPaired, isFalse);
      expect(trustA.isTrusted(idB.deviceId), isFalse);
      expect(trustB.isTrusted(idA.deviceId), isFalse);
      expect(connA.isConnected, isFalse);

      await sub.cancel();
      await connB.close();
      await listener.stop();
    } finally {
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
