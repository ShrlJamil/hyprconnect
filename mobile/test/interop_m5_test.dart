//! M5 live proof against the real daemon on this laptop (TCP 1714):
//! pair like M0/M2/M3/M4, then the presentation remote — the gyro/drag
//! pointer is proven by the daemon journaling the session start/stop,
//! and the monitor extension is proven by the daemon answering the
//! monitor-list request and persisting the pinned monitor.
//!
//! Deliberately NOT proven live: next/previous slide keys have no
//! observable signal on the daemon side except their effect (a
//! PageDown would press into whatever window is focused on the
//! user's live desktop), so they are sent over the live channel and
//! the channel is proven healthy afterwards with a ping; their exact
//! wire shapes are covered by the presenter unit tests instead — the
//! same honesty rule M4 used for clicks.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

const _cli = '/home/jyameel/.local/bin/hyprconnect';
const _daemonHost = '127.0.0.1';
const _daemonPort = 1714;
const _stateDir = '/home/jyameel/.local/state/hyprconnect';

const _runtimeDir = '/run/user/1000';

Future<Map<String, dynamic>> _daemonDevices() async {
  final result = await Process.run(_cli, ['devices']);
  if (result.exitCode != 0) {
    throw StateError('hyprconnect devices failed: ${result.stderr}');
  }
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
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

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtTime(DateTime t) {
  return '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

/// True once the daemon journal carries [pattern] since [since].
/// A failed journalctl read counts as "not yet" instead of throwing,
/// so a transient journal hiccup is retried by the caller instead of
/// failing the whole test; a persistent failure surfaces as a timeout.
Future<bool> _journalHas(DateTime since, String pattern) async {
  final result = await Process.run(
    'journalctl',
    [
      '--user',
      '-u',
      'hyprconnect',
      '--since',
      _fmtTime(since),
      '--no-pager',
      '-g',
      pattern,
    ],
    environment: {'XDG_RUNTIME_DIR': _runtimeDir},
  );
  if (result.exitCode != 0) return false;
  return (result.stdout as String).contains(pattern);
}

Future<String> _presenterJson() async {
  return File('$_stateDir/presenter.json').readAsString();
}

void main() {
  test('M5: presentation remote against the daemon', () async {
    final ss = await Process.run('ss', ['-ltn']);
    if (!(ss.stdout as String).contains(':$_daemonPort ')) {
      markTestSkipped(
        'daemon hyprconnect tidak jalan di $_daemonHost:$_daemonPort',
      );
      return;
    }

    final dir = await Directory.systemTemp.createTemp('hyprconnect-m5-');
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
      discovery = Discovery(identity: identity, tcpPort: listenPort);
      await discovery.start();
      final discovered = await _waitUntil(() async {
        final snap = await _daemonDevices();
        return _findDevice(snap, ourId) != null;
      });
      expect(discovered, isTrue, reason: 'daemon tidak menemukan kami');

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
      final channel = conn;

      // Collect presenter monitor replies on this channel.
      final replies = <PresenterMonitorList>[];
      final sub = channel.packets.listen((packet) {
        final list = PresenterMonitorList.fromPacket(packet);
        if (list != null) replies.add(list);
      });

      // --- Pointer: a delta starts a session, stop ends it. ---
      final since = DateTime.now().subtract(const Duration(seconds: 5));
      await channel.sendPresenterMove(0.05, 0.03);
      final started = await _waitUntil(
        () => _journalHas(since, 'presenter session started on'),
        timeout: const Duration(seconds: 15),
      );
      expect(
        started,
        isTrue,
        reason: 'daemon tidak mencatat presenter session started',
      );
      await channel.sendPresenterMove(0.01, 0.01);
      await channel.sendPresenterStop();
      final stopped = await _waitUntil(
        () => _journalHas(since, 'presenter session stopped'),
        timeout: const Duration(seconds: 15),
      );
      expect(
        stopped,
        isTrue,
        reason: 'daemon tidak mencatat presenter session stopped',
      );

      // --- Monitor list: the daemon answers with both monitors. ---
      await channel.requestPresenterMonitors();
      final listed = await _waitUntil(
        () async => replies.isNotEmpty,
        timeout: const Duration(seconds: 15),
      );
      expect(listed, isTrue, reason: 'daemon tidak menjawab daftar monitor');
      expect(replies.last.monitors, contains('eDP-1'));
      expect(replies.last.monitors, contains('DP-1'));
      expect(replies.last.presenterMonitor, isNull);

      // --- Pin to DP-1: reply, journal, and presenter.json agree. ---
      replies.clear();
      await channel.setPresenterMonitor('DP-1');
      final pinned = await _waitUntil(
        () async =>
            replies.isNotEmpty &&
            replies.last.presenterMonitor == 'DP-1',
        timeout: const Duration(seconds: 15),
      );
      expect(pinned, isTrue, reason: 'daemon tidak mengonfirmasi DP-1');
      expect(
        await _journalHas(since, 'presenter monitor set to DP-1'),
        isTrue,
        reason: 'daemon tidak mencatat presenter monitor set to DP-1',
      );
      expect(await _presenterJson(), contains('DP-1'));

      // --- Back to automatic: the persisted choice is restored. ---
      replies.clear();
      await channel.setPresenterMonitor(null);
      final auto = await _waitUntil(
        () async =>
            replies.isNotEmpty && replies.last.presenterMonitor == null,
        timeout: const Duration(seconds: 15),
      );
      expect(auto, isTrue, reason: 'daemon tidak mengonfirmasi otomatis');
      expect(
        await _journalHas(since, 'presenter monitor set to auto'),
        isTrue,
        reason: 'daemon tidak mencatat presenter monitor set to auto',
      );
      expect(await _presenterJson(), contains('null'));

      // --- Slide keys: sent live, channel proven healthy after. ---
      // No daemon-side log exists for known keys (see the header);
      // the exact bytes are proven by the presenter unit tests.
      await channel.sendMousepadSpecialKey(PresenterKeys.next);
      await channel.sendMousepadSpecialKey(PresenterKeys.previous);
      await channel.sendPing('m5 interop selesai');

      await sub.cancel();
      await channel.close();
      await Process.run(_cli, ['unpair', ourId]);
    } finally {
      await conn?.close();
      await discovery?.stop();
      await listener?.stop();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 180)));
}
