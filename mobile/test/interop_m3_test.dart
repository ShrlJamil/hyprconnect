//! M3 live proof against the real daemon on this laptop (TCP 1714):
//! pair like M0/M2, then multimedia control against a running mpv
//! (player list, state, pause/play, volume, seek to position) and
//! run commands against the daemon's predefined list (list, run with
//! streamed output, finished with exit code).
//!
//! Fixtures (set up before running, see PROGRESS.md): mpv playing a
//! looped tone file, and a "m3-interop-echo" command in the daemon's
//! commands.json. The test skips gracefully when either fixture is
//! missing, like the M2 interop test skips when the daemon is down.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

const _cli = '/home/jyameel/.local/bin/hyprconnect';
const _daemonHost = '127.0.0.1';
const _daemonPort = 1714;

const _echoKey = 'm3-interop-echo';
const _echoLine1 = 'm3-interop-hello';
const _echoLine2 = 'baris-kedua';

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

void main() {
  test('M3: multimedia control and run commands against the daemon', () async {
    final ss = await Process.run('ss', ['-ltn']);
    if (!(ss.stdout as String).contains(':$_daemonPort ')) {
      markTestSkipped(
        'daemon hyprconnect tidak jalan di $_daemonHost:$_daemonPort',
      );
      return;
    }

    final dir = await Directory.systemTemp.createTemp('hyprconnect-m3-');
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

      // --- Multimedia: player list must name mpv (fixture). ---
      final listSeen = channel.packets.firstWhere(
        (p) => MprisPlayerState.playerListOf(p) != null,
      );
      final stateSeen = channel.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.mpris' &&
            p.body['player'] == 'mpv' &&
            (p.body['title'] as String? ?? '').isNotEmpty,
      );
      await channel.requestMprisPlayerList();
      final listPacket = await listSeen.timeout(const Duration(seconds: 20));
      final players = MprisPlayerState.playerListOf(listPacket)!;
      if (!players.contains('mpv')) {
        markTestSkipped('mpv tidak jalan di desktop (playerList: $players)');
        return;
      }
      final state = MprisPlayerState.fromPacket(
        await stateSeen.timeout(const Duration(seconds: 20)),
      );
      expect(state.player, 'mpv');
      expect(state.isPlaying, isTrue, reason: 'mpv harusnya sedang memutar');

      // Pause -> fresh state says paused; play -> playing again.
      Future<MprisPlayerState> nextState() async {
        final packet = await channel.packets
            .firstWhere(
              (p) =>
                  p.type == 'kdeconnect.mpris' &&
                  p.body['player'] == 'mpv' &&
                  p.body['isPlaying'] is bool,
            )
            .timeout(const Duration(seconds: 20));
        return MprisPlayerState.fromPacket(packet);
      }

      var paused = nextState();
      await channel.sendMprisAction('mpv', 'Pause');
      expect(
        (await paused).isPlaying,
        isFalse,
        reason: 'daemon tidak mengirim state paused',
      );
      var playing = nextState();
      await channel.sendMprisAction('mpv', 'Play');
      expect(
        (await playing).isPlaying,
        isTrue,
        reason: 'daemon tidak mengirim state playing',
      );

      // Volume 50 -> fresh state reads 50 back.
      var volumed = nextState();
      await channel.sendMprisVolume('mpv', 50);
      expect(
        (await volumed).volume,
        50,
        reason: 'daemon tidak mengirim state volume 50',
      );

      // Absolute position 5 s -> fresh state reads about 5 s.
      var positioned = nextState();
      await channel.sendMprisSetPosition('mpv', 5000000);
      final pos = (await positioned).posMs;
      expect(
        pos,
        inInclusiveRange(4000, 9000),
        reason: 'posisi setelah SetPosition 5 detik: $pos ms',
      );

      // --- Run commands: list must carry the echo fixture. ---
      final cmdListSeen = channel.packets.firstWhere(
        (p) => p.type == 'kdeconnect.runcommand',
      );
      await channel.requestRunCommandList();
      final cmdListPacket = await cmdListSeen.timeout(
        const Duration(seconds: 20),
      );
      final commands = parseCommandList(cmdListPacket);
      final echo = commands.where((c) => c.key == _echoKey).toList();
      if (echo.isEmpty) {
        markTestSkipped('perintah $_echoKey tidak ada di daemon');
        return;
      }
      expect(echo.first.command, contains('echo'));

      // Run it: started, then streamed stdout lines, then finished 0.
      final startedSeen = channel.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.runcommand.output' &&
            p.body['commandStarted'] == true,
      );
      final outputSeen = channel.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.runcommand.output' &&
            p.body['commandOutput'] == true &&
            (p.body['stdout'] as List? ?? []).contains(_echoLine1),
      );
      final finishedSeen = channel.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.runcommand.output' &&
            p.body['commandFinished'] == true,
      );
      await channel.runRemoteCommand(_echoKey);
      final started = RunCommandOutput.fromPacket(
        await startedSeen.timeout(const Duration(seconds: 20)),
      );
      expect(started?.kind, RunCommandOutput.started);
      final output = RunCommandOutput.fromPacket(
        await outputSeen.timeout(const Duration(seconds: 20)),
      );
      expect(output?.stdoutLines, contains(_echoLine1));
      expect(output?.stdoutLines, contains(_echoLine2));
      final finished = RunCommandOutput.fromPacket(
        await finishedSeen.timeout(const Duration(seconds: 20)),
      );
      expect(finished?.kind, RunCommandOutput.finished);
      expect(finished?.success, isTrue);
      expect(finished?.exitCode, 0);

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
