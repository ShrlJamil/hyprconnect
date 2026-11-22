//! M3 protocol tests: runcommand list parsing (the list travels as
//! a JSON string inside the packet), output event parsing
//! (started / output / finished), and request packet shapes, plus a
//! request round-trip between two real DeviceConnections.

import 'dart:convert';
import 'dart:io';

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
  return (connA, connB, listener);
}

void main() {
  test('command list parses the JSON string, sorted by name', () {
    final packet = Packet.now('kdeconnect.runcommand', {
      'commandList': jsonEncode({
        'cmd2': {'name': 'Terminal', 'command': 'kitty'},
        'cmd1': {'name': 'Cek Disk', 'command': 'df -h'},
      }),
      'canAddCommand': true,
    });
    final list = parseCommandList(packet);
    expect(list, hasLength(2));
    expect(list.first.name, 'Cek Disk');
    expect(list.first.key, 'cmd1');
    expect(list.first.command, 'df -h');
    expect(list.last.name, 'Terminal');
    expect(canAddCommandOf(packet), isTrue);
  });

  test('missing or malformed command list parses as empty', () {
    expect(parseCommandList(Packet.now('kdeconnect.runcommand', {})), []);
    expect(
      parseCommandList(
        Packet.now('kdeconnect.runcommand', {'commandList': 'bukan json'}),
      ),
      [],
    );
    expect(
      parseCommandList(
        Packet.now('kdeconnect.runcommand', {'commandList': '[]'}),
      ),
      [],
    );
    expect(canAddCommandOf(Packet.now('kdeconnect.runcommand', {})), isFalse);
  });

  test('output events parse started, output, and finished', () {
    final started = RunCommandOutput.fromPacket(
      Packet.now('kdeconnect.runcommand.output', {
        'commandStarted': true,
        'id': 3,
        'command': 'echo halo',
      }),
    );
    expect(started?.kind, RunCommandOutput.started);
    expect(started?.id, 3);
    expect(started?.command, 'echo halo');

    final output = RunCommandOutput.fromPacket(
      Packet.now('kdeconnect.runcommand.output', {
        'commandOutput': true,
        'stdout': ['halo', 'baris dua'],
        'stderr': ['peringatan'],
        'id': 3,
      }),
    );
    expect(output?.kind, RunCommandOutput.output);
    expect(output?.stdoutLines, ['halo', 'baris dua']);
    expect(output?.stderrLines, ['peringatan']);

    final finished = RunCommandOutput.fromPacket(
      Packet.now('kdeconnect.runcommand.output', {
        'commandFinished': true,
        'success': true,
        'exitCode': 0,
        'id': 3,
      }),
    );
    expect(finished?.kind, RunCommandOutput.finished);
    expect(finished?.success, isTrue);
    expect(finished?.exitCode, 0);

    expect(
      RunCommandOutput.fromPacket(
        Packet.now('kdeconnect.runcommand.output', {
          'commandOutput': true,
          'stdout': ['x'],
        }),
      ),
      isNull,
      reason: 'output without an id is not an event',
    );
    expect(
      RunCommandOutput.fromPacket(
        Packet.now('kdeconnect.runcommand', {'commandList': '{}'}),
      ),
      isNull,
    );
  });

  test('request packet shapes', () {
    expect(runCommandRequestList().type, 'kdeconnect.runcommand.request');
    expect(runCommandRequestList().body['requestCommandList'], isTrue);
    expect(runCommandRun('cmd1').body['key'], 'cmd1');
    expect(runCommandStop().body['stop'], isTrue);
    expect(runCommandSetup().body['setup'], isTrue);
  });

  test('runcommand request round-trips over a real TLS channel', () async {
    final dirA = await Directory.systemTemp.createTemp('hyprconnect-m3a-');
    final dirB = await Directory.systemTemp.createTemp('hyprconnect-m3b-');
    final (connA, connB, listener) = await _pair(dirA, dirB);
    try {
      final listSeen = connB.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.runcommand.request' &&
            p.body['requestCommandList'] == true,
      );
      await connA.requestRunCommandList();
      await listSeen.timeout(const Duration(seconds: 10));
      final runSeen = connB.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.runcommand.request' &&
            p.body['key'] == 'cmd1',
      );
      await connA.runRemoteCommand('cmd1');
      final packet = await runSeen.timeout(const Duration(seconds: 10));
      expect(packet.body['key'], 'cmd1');
    } finally {
      await connA.close();
      await connB.close();
      await listener.stop();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
