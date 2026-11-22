//! Widget tests for the reworked remote input page (KDE Connect
//! shape): the full-screen touchpad with multi-finger gestures, the
//! mouse buttons row, the keyboard as its own page, and the settings
//! page. Verified against a recording connection (sendPacket is
//! overridden to keep the packets, so no socket is involved).
//!
//! The prefs store handed to the state has pointer acceleration off,
//! so drag deltas sum exactly; everything else stays at the stock
//! defaults (left/right/middle taps, double-tap drag on).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';
import 'package:hyprconnect_mobile/src/settings/remote_input_prefs.dart';
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

List<Packet> _with(_RecordingConnection conn, String field) {
  return conn.sent.where((p) => p.body.containsKey(field)).toList();
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
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final prefsStore = RemoteInputPrefsStore.inMemory();
  await prefsStore.save(
    _deviceId,
    RemoteInputPrefs(acceleration: AccelerationPreset.off),
  );
  final state = AppState.test(
    settings: PluginSettings.inMemory(),
    remoteInputPrefs: prefsStore,
  );
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

  testWidgets('pad, help text, and mouse buttons render', (tester) async {
    await _pumpedState(tester);
    expect(_pad(), findsOneWidget);
    expect(find.textContaining('Geser satu jari di layar'), findsOneWidget);
    expect(find.byKey(const ValueKey('mouse-left')), findsOneWidget);
    expect(find.byKey(const ValueKey('mouse-middle')), findsOneWidget);
    expect(find.byKey(const ValueKey('mouse-right')), findsOneWidget);
    expect(find.byTooltip('Keyboard'), findsOneWidget);
    expect(find.byTooltip('Kirim teks'), findsOneWidget);
    expect(find.byTooltip('Pengaturan Masukan jarak jauh'), findsOneWidget);
  });

  testWidgets('tap on the pad sends one left click', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(_pad());
    await tester.pump(const Duration(milliseconds: 400));
    expect(_with(conn, 'singleclick'), hasLength(1));
    expect(_with(conn, 'doubleclick'), isEmpty);
  });

  testWidgets('two quick taps send one double click, no single', (
    tester,
  ) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(_pad());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(_pad());
    await tester.pump(const Duration(milliseconds: 400));
    expect(_with(conn, 'doubleclick'), hasLength(1));
    expect(_with(conn, 'singleclick'), isEmpty);
  });

  testWidgets('drag on the pad sends move deltas that sum to the drag', (
    tester,
  ) async {
    final (conn, _) = await _pumpedState(tester);
    final center = tester.getCenter(_pad());
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(100, 40));
    await gesture.up();
    await tester.pump();
    final moves = _with(
      conn,
      'dx',
    ).where((p) => !p.body.containsKey('scroll')).toList();
    expect(moves, isNotEmpty);
    final sumDx = moves.fold<double>(
      0,
      (sum, p) => sum + (p.body['dx'] as num),
    );
    final sumDy = moves.fold<double>(
      0,
      (sum, p) => sum + (p.body['dy'] as num),
    );
    expect(sumDx, closeTo(100, 0.001));
    expect(sumDy, closeTo(40, 0.001));
  });

  testWidgets('double tap then drag holds the button while moving', (
    tester,
  ) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(_pad());
    await tester.pump(const Duration(milliseconds: 100));
    final center = tester.getCenter(_pad());
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(_with(conn, 'singlehold'), hasLength(1));
    expect(_with(conn, 'singleclick'), isEmpty);
    await gesture.up();
    await tester.pump();
    expect(_with(conn, 'singlerelease'), hasLength(1));
  });

  testWidgets('two finger tap sends a right click', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    final center = tester.getCenter(_pad());
    final g1 = await tester.startGesture(center);
    final g2 = await tester.startGesture(center + const Offset(80, 0));
    await g1.up();
    await g2.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_with(conn, 'rightclick'), hasLength(1));
  });

  testWidgets('three finger tap sends a middle click', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    final center = tester.getCenter(_pad());
    final g1 = await tester.startGesture(center);
    final g2 = await tester.startGesture(center + const Offset(80, 0));
    final g3 = await tester.startGesture(center + const Offset(160, 0));
    await g1.up();
    await g2.up();
    await g3.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_with(conn, 'middleclick'), hasLength(1));
  });

  testWidgets('two finger drag scrolls', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    final center = tester.getCenter(_pad());
    final g1 = await tester.startGesture(center);
    final g2 = await tester.startGesture(center + const Offset(80, 0));
    await g1.moveBy(const Offset(0, 30));
    await g2.moveBy(const Offset(0, 30));
    await g1.up();
    await g2.up();
    await tester.pump();
    final scrolls = _with(conn, 'scroll');
    expect(scrolls, isNotEmpty);
    final sumDy = scrolls.fold<double>(
      0,
      (sum, p) => sum + (p.body['dy'] as num),
    );
    // Centroid travel 30, default scroll factor 0.2 + 1.8 * 0.9.
    expect(sumDy, closeTo(30 * 1.82, 1.5));
  });

  testWidgets('mouse buttons row sends its clicks and holds', (tester) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(find.byKey(const ValueKey('mouse-right')));
    await tester.pump();
    expect(_with(conn, 'rightclick'), hasLength(1));
    await tester.tap(find.byKey(const ValueKey('mouse-middle')));
    await tester.pump();
    expect(_with(conn, 'middleclick'), hasLength(1));
    final left = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mouse-left'))),
    );
    await tester.pump();
    expect(_with(conn, 'singlehold'), hasLength(1));
    await left.up();
    await tester.pump();
    expect(_with(conn, 'singlerelease'), hasLength(1));
  });

  testWidgets('settings page toggles the mouse buttons row', (tester) async {
    await _pumpedState(tester);
    await tester.tap(find.byTooltip('Pengaturan Masukan jarak jauh'));
    await tester.pumpAndSettle();
    expect(find.text('Setel aksi ketuk satu jari'), findsOneWidget);
    expect(find.text('Pengaturan Masukan jarak jauh'), findsWidgets);
    final tile = find.ancestor(
      of: find.text('Tampilkan tombol tetikus'),
      matching: find.byType(SwitchListTile),
    );
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mouse-left')), findsNothing);
  });

  testWidgets('inline keyboard: typing, edits, specials, modifiers, arrows', (
    tester,
  ) async {
    final (conn, _) = await _pumpedState(tester);
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('type-field'));
    expect(field, findsOneWidget);
    expect(find.text('Enter'), findsOneWidget);
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('F1..F12'), findsOneWidget);

    await tester.enterText(field, 'halo');
    await tester.pump();
    final typed = _with(conn, 'key').map((p) => p.body['key']).toList();
    expect(typed, contains('halo'));

    await tester.enterText(field, 'hal');
    await tester.pump();
    final backspaces = conn.sent
        .where((p) => p.body['specialKey'] == 1)
        .toList();
    expect(backspaces, hasLength(1));

    await tester.tap(find.text('Enter'));
    await tester.pump();
    expect(conn.sent.where((p) => p.body['specialKey'] == 12), hasLength(1));

    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    await tester.enterText(field, 'hala');
    await tester.pump();
    final ctrlKey = conn.sent.lastWhere((p) => p.body['key'] == 'a');
    expect(ctrlKey.body['ctrl'], isTrue);

    await tester.ensureVisible(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(conn.sent.where((p) => p.body['specialKey'] == 5), hasLength(1));
  });

  test('remote input prefs roundtrip keeps changed values', () {
    final prefs = RemoteInputPrefs(
      tapTwo: TapAction.left,
      sensitivity: SensitivityPreset.fast,
      reverseScroll: true,
      gyroEnabled: true,
      showMouseButtons: false,
    );
    final back = RemoteInputPrefs.fromJson(prefs.toJson());
    expect(back.tapTwo, TapAction.left);
    expect(back.sensitivity, SensitivityPreset.fast);
    expect(back.reverseScroll, isTrue);
    expect(back.gyroEnabled, isTrue);
    expect(back.showMouseButtons, isFalse);
    final defaults = RemoteInputPrefs.fromJson(const {});
    expect(defaults.tapOne, TapAction.left);
    expect(defaults.acceleration, AccelerationPreset.medium);
    expect(defaults.doubleTapDrag, isTrue);
  });
}
