//! Widget tests for the M4 remote input page: rendering, touchpad
//! gestures, and keyboard sends are verified against a recording
//! connection (sendPacket is overridden to keep the packets, so no
//! socket is involved).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';
import 'package:hyprconnect_mobile/src/ui/app_state.dart';
import 'package:hyprconnect_mobile/src/ui/remote_input_page.dart';

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
  WidgetTester tester,
) async {
  late final Directory dir;
  late final LocalIdentity identity;
  late final TrustStore trust;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('hyprconnect-m4-');
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
  // what is on screen — with a short viewport the keys below the
  // fold would not exist for the finder at all.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState.test(settings: PluginSettings.inMemory());
  state.registerTestConnection(conn);
  await tester.pumpWidget(
    MaterialApp(
      home: RemoteInputPage(appState: state, entry: _entry()),
    ),
  );
  await tester.pumpAndSettle();
  return (conn, state);
}

Finder _pad() => find.byKey(const ValueKey('touchpad'));

void main() {
  testWidgets('no connection is stated honestly', (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteInputPage(appState: state, entry: _entry()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tidak ada koneksi ke perangkat ini.'), findsOneWidget);
  });

  testWidgets('touchpad and keyboard sections render', (tester) async {
    await _pumpedState(tester);
    expect(find.text('Touchpad'), findsOneWidget);
    expect(find.text('Keyboard'), findsOneWidget);
    expect(find.text('Klik kanan'), findsOneWidget);
    expect(find.text('Klik tengah'), findsOneWidget);
    expect(find.text('Enter'), findsOneWidget);
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('F1..F12'), findsOneWidget);
  });

  testWidgets('tap on the pad sends one left click', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(_pad());
    await tester.pump(const Duration(milliseconds: 400));
    expect(conn.sent.length, 1);
    expect(conn.sent.single.body, {'singleclick': true});
  });

  testWidgets('two quick taps send one double click, no single', (
    tester,
  ) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(_pad());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(_pad());
    await tester.pump(const Duration(milliseconds: 400));
    expect(conn.sent.length, 1);
    expect(conn.sent.single.body, {'doubleclick': true});
  });

  testWidgets('drag on the pad sends move deltas that sum to the drag', (
    tester,
  ) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.drag(_pad(), const Offset(20, 10));
    await tester.pump();
    final moves = conn.sent.where((p) => p.body['dx'] is num).toList();
    expect(moves, isNotEmpty);
    final totalDx = moves.fold<double>(
      0,
      (sum, p) => sum + (p.body['dx'] as num).toDouble(),
    );
    final totalDy = moves.fold<double>(
      0,
      (sum, p) => sum + (p.body['dy'] as num).toDouble(),
    );
    expect(totalDx, closeTo(20, 2));
    expect(totalDy, closeTo(10, 2));
    expect(moves.every((p) => !p.body.containsKey('scroll')), isTrue);
  });

  testWidgets('long press holds the left button until release', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.longPress(_pad());
    await tester.pump();
    expect(conn.sent.length, 2);
    expect(conn.sent[0].body, {'singlehold': true});
    expect(conn.sent[1].body, {'singlerelease': true});
  });

  testWidgets('Gulir mode turns a drag into scroll packets', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(find.text('Gulir'));
    await tester.pump();
    await tester.drag(_pad(), const Offset(0, -30));
    await tester.pump();
    final scrolls = conn.sent.where((p) => p.body['scroll'] == true).toList();
    expect(scrolls, isNotEmpty);
    final totalDy = scrolls.fold<double>(
      0,
      (sum, p) => sum + (p.body['dy'] as num).toDouble(),
    );
    expect(totalDy, closeTo(-30, 2));
  });

  testWidgets('Klik kanan and Klik tengah send their buttons', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(find.text('Klik kanan'));
    await tester.pump();
    await tester.tap(find.text('Klik tengah'));
    await tester.pump();
    expect(conn.sent.length, 2);
    expect(conn.sent[0].body, {'rightclick': true});
    expect(conn.sent[1].body, {'middleclick': true});
  });

  testWidgets('typing sends the text, edits send Backspace', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    final field = find.byKey(const ValueKey('type-field'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'ab');
    await tester.pump();
    expect(conn.sent.length, 1);
    expect(conn.sent.single.body, {'key': 'ab'});
    await tester.enterText(field, 'abc');
    await tester.pump();
    expect(conn.sent.length, 2);
    expect(conn.sent[1].body, {'key': 'c'});
    await tester.enterText(field, 'ab');
    await tester.pump();
    expect(conn.sent.length, 3);
    expect(conn.sent[2].body, {'specialKey': 1});
  });

  testWidgets('Enter button sends specialKey 12', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    final enter = find.text('Enter');
    await tester.tap(enter);
    await tester.pump();
    expect(conn.sent.length, 1);
    expect(conn.sent.single.body['specialKey'], 12);
  });

  testWidgets('a modifier chip rides along with the next key', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    final ctrl = find.text('Ctrl');
    await tester.tap(ctrl);
    await tester.pump();
    final enter = find.text('Enter');
    await tester.tap(enter);
    await tester.pump();
    expect(conn.sent.length, 1);
    expect(conn.sent.single.body['specialKey'], 12);
    expect(conn.sent.single.body['ctrl'], isTrue);
  });

  testWidgets('arrow buttons send the daemon arrow codes', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    expect(conn.sent.length, 2);
    expect(conn.sent[0].body['specialKey'], 5);
    expect(conn.sent[1].body['specialKey'], 7);
  });
}
