//! Widget tests for the M3 run-command page: no connection is stated
//! honestly, the command list renders, and streamed output events
//! (started / output / finished) land in AppState in order.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';
import 'package:hyprconnect_mobile/src/ui/app_state.dart';
import 'package:hyprconnect_mobile/src/ui/runcommand_page.dart';

const _deviceId = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

DeviceListEntry _entry() {
  return DeviceListEntry(
    deviceId: _deviceId,
    name: 'Desktop Tes',
    deviceType: 'desktop',
    address: InternetAddress('192.168.1.2'),
    tcpPort: 1714,
    online: true,
    trusted: true,
  );
}

Future<DeviceConnection> _fakeConn(WidgetTester tester) async {
  late final Directory dir;
  late final LocalIdentity identity;
  late final TrustStore trust;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('hyprconnect-m3-');
    identity = await LocalIdentity.loadOrCreate(dir, deviceName: 'Phone A');
    trust = await TrustStore.load(dir);
  });
  final conn = DeviceConnection(
    identity: identity,
    trust: trust,
    tcpPort: 1714,
  );
  conn.remoteName = 'Desktop Tes';
  conn.remoteDeviceId = _deviceId;
  addTearDown(() {
    dir.deleteSync(recursive: true);
  });
  return conn;
}

void main() {
  testWidgets('no connection is stated honestly', (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    await tester.pumpWidget(
      MaterialApp(home: RunCommandPage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tidak ada koneksi ke perangkat ini.'), findsOneWidget);
  });

  testWidgets('command list and streamed output land in order',
      (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    final conn = await _fakeConn(tester);
    await tester.runAsync(
      () => state.handleIncomingPacket(
        conn,
        Packet.now('kdeconnect.runcommand', {
          'commandList': jsonEncode({
            'cmd1': {'name': 'Cek Disk', 'command': 'df -h'},
          }),
          'canAddCommand': true,
        }),
      ),
    );
    expect(state.commandsFor(_deviceId), hasLength(1));
    expect(state.commandsFor(_deviceId).first.name, 'Cek Disk');
    expect(state.canAddCommandFor(_deviceId), isTrue);

    Future<void> feed(Map<String, dynamic> body) {
      return tester.runAsync(
        () => state.handleIncomingPacket(
          conn,
          Packet.now('kdeconnect.runcommand.output', body),
        ),
      );
    }

    await feed({'commandStarted': true, 'id': 7, 'command': 'df -h'});
    expect(state.runningCommandIdFor(_deviceId), 7);
    await feed({
      'commandOutput': true,
      'stdout': ['/dev/sda 100G'],
      'stderr': [],
      'id': 7,
    });
    await feed({
      'commandFinished': true,
      'success': true,
      'exitCode': 0,
      'id': 7,
    });
    expect(state.runningCommandIdFor(_deviceId), isNull);
    final events = state.commandEventsFor(_deviceId);
    expect(events, hasLength(3));
    expect(events[0].kind, RunCommandOutput.started);
    expect(events[1].stdoutLines, ['/dev/sda 100G']);
    expect(events[2].kind, RunCommandOutput.finished);
    expect(events[2].exitCode, 0);

    // With the connection registered, the page renders the list and
    // the streamed log.
    state.registerTestConnection(conn);
    await tester.pumpWidget(
      MaterialApp(home: RunCommandPage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cek Disk'), findsOneWidget);
    expect(find.text('df -h'), findsOneWidget);
    expect(find.text('\$ df -h'), findsOneWidget);
    expect(find.text('/dev/sda 100G'), findsOneWidget);
    // The console follows the stock app: a finished run adds no
    // line of its own.
    expect(find.textContaining('Selesai'), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
