//! M0 live proof against the real daemon on this laptop (TCP 1714):
//! discovery broadcast -> daemon-initiated pairing (phone is the TLS
//! client) -> verification key cross-check -> ping round-trip ->
//! phone-initiated connection (phone is the TLS server) -> ping again.
//! Skips gracefully when the daemon is not reachable.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

const _cli = '/home/jyameel/.local/bin/hyprconnect';
const _daemonHost = '127.0.0.1';
const _daemonPort = 1714;

Future<Map<String, dynamic>> _daemonDevices() async {
  final result = await Process.run(_cli, ['devices']);
  if (result.exitCode != 0) {
    throw StateError('hyprconnect devices failed: ${result.stderr}');
  }
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

Future<String> _daemonLog() async {
  final result = await Process.run('journalctl', [
    '--user',
    '-u',
    'hyprconnect',
    '--no-pager',
    '-n',
    '300',
  ]);
  return result.stdout as String;
}

Future<bool> _waitUntil(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 20),
  Duration interval = const Duration(milliseconds: 300),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return true;
    await Future<void>.delayed(interval);
  }
  return false;
}

Map<String, dynamic>? _findDevice(Map<String, dynamic> snapshot, String id) {
  final devices = snapshot['devices'] as List;
  for (final d in devices) {
    final map = (d as Map).cast<String, dynamic>();
    if (map['deviceId'] == id) return map;
  }
  return null;
}

void main() {
  test('M0: pair and ping against the real daemon', () async {
    // Skip gracefully when the daemon is not running here. (Checked
    // via ss, not a TCP probe: opening a bare TCP connection would
    // leave a 'peer closed before plaintext identity' line in the
    // daemon log.)
    final ss = await Process.run('ss', ['-ltn']);
    if (!(ss.stdout as String).contains(':$_daemonPort ')) {
      markTestSkipped('daemon hyprconnect tidak jalan di $_daemonHost:$_daemonPort');
      return;
    }

    final dir = await Directory.systemTemp.createTemp('hyprconnect-m0-');
    DeviceConnection? conn;
    Discovery? discovery;
    TcpListener? listener;
    try {
      final identity = await LocalIdentity.loadOrCreate(
        dir,
        deviceName: 'HyprConnect Test',
      );
      final trust = await TrustStore.load(dir);
      final ourId = identity.deviceId;

      listener = TcpListener();
      final listenPort = await listener.start();

      // The daemon discovers us from our broadcast.
      discovery = Discovery(identity: identity, tcpPort: listenPort);
      await discovery.start();
      final discovered = await _waitUntil(() async {
        final snap = await _daemonDevices();
        return _findDevice(snap, ourId) != null;
      });
      expect(discovered, isTrue, reason: 'daemon tidak menemukan kami');

      // First pairing starts from the desktop: the daemon opens the
      // TCP connection, so the phone is the TLS client here.
      final pairResult = await Process.run(_cli, ['pair', ourId]);
      expect(pairResult.exitCode, 0, reason: pairResult.stdout as String);

      final raw = await listener.connections.first.timeout(
        const Duration(seconds: 15),
      );
      conn = DeviceConnection(
        identity: identity,
        trust: trust,
        tcpPort: listenPort,
      );
      await conn.acceptIncoming(raw);
      expect(conn.remoteDeviceId, isNotNull);
      final daemonId = conn.remoteDeviceId!;
      expect(conn.peerCertDer, isNotNull);

      // The daemon sends its pair request once the channel is up.
      final asked = await _waitUntil(
        () async => conn!.pairState == PairState.pendingIn,
      );
      expect(asked, isTrue, reason: 'daemon tidak mengirim pair request');

      await conn.requestPair();
      final paired = await _waitUntil(() async {
        if (!conn!.isPaired) return false;
        final snap = await _daemonDevices();
        return _findDevice(snap, ourId)?['paired'] == true;
      });
      expect(paired, isTrue, reason: 'pairing tidak selesai di kedua sisi');

      // Verification key: ours must equal the daemon's own computation
      // (shown in its device snapshot).
      final snap = await _daemonDevices();
      final daemonView = _findDevice(snap, ourId);
      expect(daemonView, isNotNull);
      expect(daemonView!['verificationKey'], conn.verificationKey);
      expect(trust.isTrusted(daemonId), isTrue);
      expect(trust.certMatches(daemonId, conn.peerCertDer!), isTrue);

      // Ping round-trip over the daemon-initiated channel.
      await conn.sendPing('M0 interop masuk');
      final pingLogged = await _waitUntil(
        () async => (await _daemonLog()).contains(
          'ping from $ourId: M0 interop masuk',
        ),
      );
      expect(pingLogged, isTrue, reason: 'daemon tidak mencatat ping');

      // Phone-initiated connection (phone is the TLS server). The
      // daemon's sweeper may reconnect first, so retry on a lost race.
      await discovery.stop();
      var outgoingOk = false;
      for (var attempt = 0; attempt < 3 && !outgoingOk; attempt++) {
        await conn?.close();
        conn = DeviceConnection(
          identity: identity,
          trust: trust,
          tcpPort: listenPort,
        );
        try {
          await conn.connectOutgoing(
            address: InternetAddress(_daemonHost),
            tcpPort: _daemonPort,
            deviceId: daemonId,
            name: 'arch-acer',
            deviceType: 'desktop',
            peerCertDer: trust.storedCert(daemonId)!,
          );
        } catch (_) {
          // Lost the race to the daemon's own reconnect; try again.
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
        outgoingOk = conn.isConnected;
        if (!outgoingOk) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      expect(outgoingOk, isTrue, reason: 'koneksi outgoing tidak bertahan');
      final outgoing = conn!;
      expect(outgoing.isPaired, isTrue, reason: 'trust tidak dikenali');

      await outgoing.sendPing('M0 interop keluar');
      final ping2Logged = await _waitUntil(
        () async => (await _daemonLog()).contains(
          'ping from $ourId: M0 interop keluar',
        ),
      );
      expect(ping2Logged, isTrue, reason: 'daemon tidak mencatat ping kedua');

      // Leave the daemon clean: unpair the throwaway test device.
      await outgoing.close();
      await Process.run(_cli, ['unpair', ourId]);
    } finally {
      await conn?.close();
      await discovery?.stop();
      await listener?.stop();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 180)));
}
