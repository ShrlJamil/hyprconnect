//! Widget tests for the M5 presenter page: rendering, slide buttons,
//! drag and gyro pointer, monitor picker, and notes — verified
//! against a recording connection (sendPacket is overridden to keep
//! the packets, so no socket is involved).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';
import 'package:hyprconnect_mobile/src/ui/app_state.dart';
import 'package:hyprconnect_mobile/src/ui/presenter_page.dart';
import 'package:sensors_plus/sensors_plus.dart';

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

/// A connection that never touches a socket: it records every packet
/// the page sends, so the test can check the exact wire shape.
class _RecordingConnection extends DeviceConnection {
  final List<Packet> sent = [];

  _RecordingConnection({
    required super.identity,
    required super.trust,
    required super.tcpPort,
  });

  @override
  Future<void> sendPacket(Packet packet) async {
    sent.add(packet);
  }
}

Future<(_RecordingConnection, AppState)> _pumpedState(
  WidgetTester tester, {
  Stream<GyroscopeEvent>? gyroStream,
}) async {
  late final Directory dir;
  late final LocalIdentity identity;
  late final TrustStore trust;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('hyprconnect-m5-');
    identity = await LocalIdentity.loadOrCreate(dir, deviceName: 'Phone A');
    trust = await TrustStore.load(dir);
  });
  final conn = _RecordingConnection(
    identity: identity,
    trust: trust,
    tcpPort: 1714,
  );
  conn.remoteName = 'Desktop Tes';
  conn.remoteDeviceId = _deviceId;
  addTearDown(() {
    dir.deleteSync(recursive: true);
  });
  // A tall viewport: the page is one ListView, which only builds
  // what is on screen — with a short viewport the notes below the
  // fold would not exist for the finder at all.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState.test(settings: PluginSettings.inMemory());
  state.registerTestConnection(conn);
  await tester.pumpWidget(
    MaterialApp(
      home: PresenterPage(
        appState: state,
        entry: _entry(),
        gyroStream: gyroStream ?? const Stream<GyroscopeEvent>.empty(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (conn, state);
}

void main() {
  testWidgets('no connection is stated honestly', (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    await tester.pumpWidget(
      MaterialApp(
        home: PresenterPage(appState: state, entry: _entry()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tidak ada koneksi ke perangkat ini.'), findsOneWidget);
  });

  testWidgets('page renders notes card, slide pills, pointer card', (
    tester,
  ) async {
    await _pumpedState(tester);
    expect(find.text('Catatan slide'), findsOneWidget);
    expect(find.text('Sebelumnya'), findsOneWidget);
    expect(find.text('Berikutnya'), findsOneWidget);
    expect(find.byIcon(Icons.gps_fixed), findsOneWidget);
    expect(find.byTooltip('Layar penuh'), findsOneWidget);
    expect(find.byTooltip('Kembali'), findsOneWidget);
    // Notes are empty: create and open-file buttons, no counter.
    expect(find.byTooltip('Buat catatan'), findsOneWidget);
    expect(find.byTooltip('Buka file catatan'), findsOneWidget);
    // No monitor list yet: no dropdown in the card header, and the
    // pointer still works (the daemon picks the monitor).
    expect(find.text('Otomatis'), findsNothing);
  });

  testWidgets('opening the page asks for the monitor list', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    expect(
      conn.sent.any(
        (p) =>
            p.type == 'kdeconnect.presenter' &&
            p.body['requestMonitorList'] == true,
      ),
      isTrue,
    );
  });

  testWidgets('slide buttons send the stock specialKeys', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    conn.sent.clear();

    await tester.tap(find.text('Berikutnya'));
    await tester.pump();
    expect(conn.sent, hasLength(1));
    expect(conn.sent.single.type, 'kdeconnect.mousepad.request');
    expect(conn.sent.single.body, {'specialKey': 9});

    await tester.tap(find.text('Sebelumnya'));
    await tester.pump();
    expect(conn.sent, hasLength(2));
    expect(conn.sent.last.body, {'specialKey': 8});

    await tester.tap(find.byTooltip('Layar penuh'));
    await tester.pump();
    expect(conn.sent.last.body, {'specialKey': 25});
  });

  testWidgets('drag on the pad sends presenter deltas', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    conn.sent.clear();

    await tester.drag(
      find.byKey(const ValueKey('presenterPad')),
      const Offset(100, 50),
    );
    await tester.pump();
    final moves = conn.sent
        .where(
          (p) => p.type == 'kdeconnect.presenter' && p.body.containsKey('dx'),
        )
        .toList();
    expect(moves, isNotEmpty);
    // Drag right and down: both deltas positive, fractions of the pad.
    expect(moves.first.body['dx'] as double, greaterThan(0));
    expect(moves.first.body['dx'] as double, lessThan(1));
    expect(moves.first.body['dy'] as double, greaterThan(0));
    expect(moves.first.body['dy'] as double, lessThan(1));
  });

  testWidgets('gyro events move the pointer with the stock mapping', (
    tester,
  ) async {
    final gyro = StreamController<GyroscopeEvent>();
    addTearDown(gyro.close);
    final (conn, _) = await _pumpedState(tester, gyroStream: gyro.stream);
    conn.sent.clear();

    // The pointer only streams while the card is held.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('presenterPad'))),
    );
    await tester.runAsync(() async {
      gyro.add(GyroscopeEvent(0.5, 0.0, -1.0, DateTime.now()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await gesture.up();
    final moves = conn.sent
        .where(
          (p) => p.type == 'kdeconnect.presenter' && p.body.containsKey('dx'),
        )
        .toList();
    expect(moves, hasLength(1));
    expect(moves.single.body['dx'], closeTo(0.036, 1e-9));
    expect(moves.single.body['dy'], closeTo(-0.018, 1e-9));
  });

  testWidgets('releasing the pad sends stop:true', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.drag(
      find.byKey(const ValueKey('presenterPad')),
      const Offset(50, 0),
    );
    await tester.pump();
    final stops = conn.sent
        .where(
          (p) => p.type == 'kdeconnect.presenter' && p.body['stop'] == true,
        )
        .toList();
    expect(stops, hasLength(1));
  });

  testWidgets('monitor list reply shows the picker and pins a monitor', (
    tester,
  ) async {
    final (conn, state) = await _pumpedState(tester);
    await tester.runAsync(
      () => state.handleIncomingPacket(
        conn,
        Packet.now('kdeconnect.presenter', {
          'monitors': ['eDP-1', 'DP-1'],
          'presenterMonitor': null,
        }),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Otomatis'), findsOneWidget);

    await tester.tap(find.text('Otomatis'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DP-1').last);
    await tester.pump();
    final sets = conn.sent
        .where((p) => p.body['setMonitor'] == 'DP-1')
        .toList();
    expect(sets, hasLength(1));
  });

  testWidgets('notes are edited per slide and saved on this phone', (
    tester,
  ) async {
    final (_, state) = await _pumpedState(tester);
    await tester.tap(find.byTooltip('Buat catatan'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'Buka dengan pertanyaan, jangan dengan definisi.',
    );
    await tester.pump();
    // Every keystroke is saved: no save button anywhere.
    expect(
      state.presenterNotesFor(_deviceId),
      contains('Buka dengan pertanyaan, jangan dengan definisi.'),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Back on the clicker the note shows with its slide counter.
    expect(
      find.text('Buka dengan pertanyaan, jangan dengan definisi.'),
      findsOneWidget,
    );
    expect(find.text('1 / 1'), findsOneWidget);
  });
}
