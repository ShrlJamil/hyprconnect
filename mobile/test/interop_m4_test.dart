//! M4 live proof against the real daemon on this laptop (TCP 1714):
//! pair like M0/M2/M3, then remote input — pointer motion is proven
//! by reading the cursor position with hyprctl before and after a
//! move packet, and the key path is proven by the daemon journaling
//! an unknown specialKey (sent raw, so the strict builder is not
//! involved) with no side effect at all.
//!
//! Deliberately NOT proven live: clicks and scroll have no observable
//! signal on the daemon side except their effect (a click would press
//! whatever is under the cursor on the user's live desktop), so their
//! wire shapes are covered by the mousepad unit tests instead.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

const _cli = '/home/jyameel/.local/bin/hyprconnect';
const _daemonHost = '127.0.0.1';
const _daemonPort = 1714;

const _runtimeDir = '/run/user/1000';
const _hyprDir = '/run/user/1000/hypr';

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

Future<String> _hyprlandSignature() async {
  final entries = await Directory(_hyprDir).list().toList();
  if (entries.isEmpty) {
    throw StateError('tidak ada sesi Hyprland di $_hyprDir');
  }
  return entries.first.path.split('/').last;
}

/// Current cursor position in layout coordinates, via hyprctl.
Future<(int, int)> _cursorPos() async {
  final signature = await _hyprlandSignature();
  final result = await Process.run(
    'hyprctl',
    ['cursorpos'],
    environment: {
      'XDG_RUNTIME_DIR': _runtimeDir,
      'HYPRLAND_INSTANCE_SIGNATURE': signature,
    },
  );
  if (result.exitCode != 0) {
    throw StateError('hyprctl cursorpos gagal: ${result.stderr}');
  }
  final parts = (result.stdout as String).trim().split(',');
  return (int.parse(parts[0].trim()), int.parse(parts[1].trim()));
}

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtTime(DateTime t) {
  return '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

/// True once the daemon journal carries the unknown-key line.
Future<bool> _journalHasUnknownKey(DateTime since) async {
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
      'mousepad specialKey 999',
    ],
    environment: {'XDG_RUNTIME_DIR': _runtimeDir},
  );
  if (result.exitCode != 0) {
    throw StateError('journalctl gagal: ${result.stderr}');
  }
  return (result.stdout as String).contains('mousepad specialKey 999');
}

void main() {
  test('M4: remote input against the daemon', () async {
    final ss = await Process.run('ss', ['-ltn']);
    if (!(ss.stdout as String).contains(':$_daemonPort ')) {
      markTestSkipped(
        'daemon hyprconnect tidak jalan di $_daemonHost:$_daemonPort',
      );
      return;
    }
    // hyprctl is the only way to observe the pointer: skip honestly
    // when the compositor cannot be reached from this shell.
    try {
      await _cursorPos();
    } catch (e) {
      markTestSkipped('hyprctl cursorpos tidak bisa dibaca: $e');
      return;
    }

    final dir = await Directory.systemTemp.createTemp('hyprconnect-m4-');
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

      // --- Pointer motion: the cursor must move by the sent delta. ---
      final before = await _cursorPos();
      // Move towards the middle of the layout, never towards an edge
      // the pointer could already sit on (clamping would hide the delta).
      final dx = before.$1 < 1600 ? 60.0 : -60.0;
      final dy = before.$2 < 700 ? 40.0 : -40.0;
      await channel.sendMousepadMove(dx, dy);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final after = await _cursorPos();
      expect(
        after.$1,
        closeTo(before.$1 + dx, 8),
        reason: 'kursor tidak bergerak di x: $before -> $after (dx $dx)',
      );
      expect(
        after.$2,
        closeTo(before.$2 + dy, 8),
        reason: 'kursor tidak bergerak di y: $before -> $after (dy $dy)',
      );
      // Put the cursor back where it was (best effort).
      await channel.sendMousepadMove(-dx, -dy);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // --- Key path: an unknown specialKey is journaled, no side effect.
      final since = DateTime.now().subtract(const Duration(seconds: 5));
      await channel.sendPacket(
        Packet.now('kdeconnect.mousepad.request', {'specialKey': 999}),
      );
      final logged = await _waitUntil(
        () => _journalHasUnknownKey(since),
        timeout: const Duration(seconds: 15),
      );
      expect(
        logged,
        isTrue,
        reason: 'daemon tidak mencatat mousepad specialKey 999',
      );

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
