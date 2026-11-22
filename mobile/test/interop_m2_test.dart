//! M2 live proof against the real daemon on this laptop (TCP 1714):
//! pair like M0, then clipboard push (daemon log), file push (daemon
//! downloads it to ~/Downloads), file pull (CLI `hyprconnect send`
//! -> payload download here), and clipboard pull (wl-copy on the
//! desktop -> clipboard packet here). Skips gracefully when the
//! daemon is not reachable.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

const _cli = '/home/jyameel/.local/bin/hyprconnect';
const _daemonHost = '127.0.0.1';
const _daemonPort = 1714;
const _home = '/home/jyameel';

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
  test('M2: share and clipboard against the real daemon', () async {
    final ss = await Process.run('ss', ['-ltn']);
    if (!(ss.stdout as String).contains(':$_daemonPort ')) {
      markTestSkipped(
        'daemon hyprconnect tidak jalan di $_daemonHost:$_daemonPort',
      );
      return;
    }

    final dir = await Directory.systemTemp.createTemp('hyprconnect-m2-');
    DeviceConnection? conn;
    Discovery? discovery;
    TcpListener? listener;
    String? downloadedPath;
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

      // 1. Clipboard push: phone -> daemon (daemon log proves it).
      const clipText = 'M2 interop papan klip';
      await channel.sendClipboard(clipText);
      final clipLogged = await _waitUntil(
        () async => (await _daemonLog()).contains(
          'clipboard received (${clipText.length} chars), applying',
        ),
      );
      expect(clipLogged, isTrue, reason: 'daemon tidak mencatat clipboard');

      // 2. File push: phone -> daemon (daemon downloads to ~/Downloads).
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'm2-interop-$stamp.txt';
      final fileBytes = Uint8List.fromList(
        utf8.encode('HyprConnect M2 interop file $stamp\n'),
      );
      final sendFuture = channel.sendFile(
        filename: fileName,
        size: fileBytes.length,
        bytes: Stream<List<int>>.value(fileBytes),
      );
      final receivedLogged = await _waitUntil(() async {
        final log = await _daemonLog();
        final marker = 'received $fileName (${fileBytes.length} bytes) -> ';
        final idx = log.indexOf(marker);
        if (idx < 0) return false;
        final rest = log.substring(idx + marker.length);
        downloadedPath = rest.split('\n').first.trim();
        return true;
      });
      await sendFuture.timeout(const Duration(seconds: 30));
      expect(
        receivedLogged,
        isTrue,
        reason: 'daemon tidak mencatat file masuk',
      );
      expect(downloadedPath, isNotNull);
      expect(downloadedPath, startsWith('$_home/Downloads/$fileName'));
      expect(await File(downloadedPath!).readAsBytes(), fileBytes);

      // 3. File pull: daemon -> phone via CLI `hyprconnect send`.
      final daemonFile = File('${dir.path}/m2-daemon-file.txt');
      final daemonBytes = Uint8List.fromList(
        utf8.encode('File dari daemon untuk M2 $stamp\n'),
      );
      await daemonFile.writeAsBytes(daemonBytes);
      final shareSeen = channel.packets.firstWhere(
        (p) => p.type == 'kdeconnect.share.request',
      );
      final sendResult = await Process.run(_cli, [
        'send',
        ourId,
        daemonFile.path,
      ]);
      expect(sendResult.exitCode, 0, reason: sendResult.stdout as String);
      final packet = await shareSeen.timeout(const Duration(seconds: 20));
      final received = await channel
          .receiveFile(packet, Directory('${dir.path}/inbox'))
          .timeout(const Duration(seconds: 20));
      expect(received.filename, 'm2-daemon-file.txt');
      expect(await File(received.path).readAsBytes(), daemonBytes);

      // 4. Clipboard pull: wl-copy on the desktop -> packet here.
      const pulledText = 'M2 interop dari desktop';
      final clipPulled = channel.packets.firstWhere(
        (p) =>
            (p.type == 'kdeconnect.clipboard' ||
                p.type == 'kdeconnect.clipboard.connect') &&
            p.body['content'] == pulledText,
      );
      // wl-copy forks a child that holds the clipboard; that child
      // inherits the parent's stdout/stderr, so a plain Process.run
      // waits forever for EOF on the pipes. Launch it detached with
      // stdio to /dev/null instead (the daemon still sees the change).
      final wlCopy = await Process.run(
        'sh',
        ['-c', 'wl-copy "\$0" >/dev/null 2>&1 < /dev/null &', pulledText],
        environment: {
          'WAYLAND_DISPLAY': 'wayland-1',
          'XDG_RUNTIME_DIR': '/run/user/1000',
        },
      );
      expect(wlCopy.exitCode, 0, reason: 'wl-copy gagal: ${wlCopy.stderr}');
      final pulled = await clipPulled.timeout(const Duration(seconds: 20));
      expect(pulled.body['content'], pulledText);

      await channel.close();
      await Process.run(_cli, ['unpair', ourId]);
    } finally {
      await conn?.close();
      await discovery?.stop();
      await listener?.stop();
      if (downloadedPath != null) {
        await File(downloadedPath!).delete().catchError((_) => File(''));
      }
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 180)));
}
