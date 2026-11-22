//! Widget tests for the M3 multimedia page: no connection is stated
//! honestly, an empty player list explains itself, and a playerList
//! + state packet pair renders the now-playing card with working
//! controls (state is fed through AppState.handleIncomingPacket with
//! a fake connection, like the M2 clipboard widget test).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';
import 'package:hyprconnect_mobile/src/ui/app_state.dart';
import 'package:hyprconnect_mobile/src/ui/multimedia_page.dart';

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
  testWidgets('no connection is stated, empty list explains itself',
      (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    await tester.pumpWidget(
      MaterialApp(home: MultimediaPage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tidak ada koneksi ke perangkat ini.'), findsOneWidget);
  });

  testWidgets('player list and state render the now-playing card',
      (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    final conn = await _fakeConn(tester);
    await tester.runAsync(
      () => state.handleIncomingPacket(
        conn,
        Packet.now('kdeconnect.mpris', {
          'playerList': ['mpv'],
        }),
      ),
    );
    await tester.runAsync(
      () => state.handleIncomingPacket(
        conn,
        Packet.now('kdeconnect.mpris', {
          'player': 'mpv',
          'title': 'Lagu Tes',
          'artist': 'Artis',
          'album': 'Album',
          'isPlaying': true,
          'pos': 30000,
          'length': 200000,
          'canPlay': true,
          'canPause': true,
          'canGoNext': true,
          'canGoPrevious': true,
          'canSeek': true,
          'volume': 75,
        }),
      ),
    );
    expect(state.playerListFor(_deviceId), ['mpv']);
    expect(state.selectedPlayerFor(_deviceId), 'mpv');
    final parsed = state.playerStateFor(_deviceId, 'mpv');
    expect(parsed?.title, 'Lagu Tes');
    expect(parsed?.isPlaying, isTrue);
    expect(parsed?.volume, 75);

    // With the connection registered, the page renders the card.
    state.registerTestConnection(conn);
    await tester.pumpWidget(
      MaterialApp(home: MultimediaPage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lagu Tes'), findsOneWidget);
    expect(find.text('Artis'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('Memutar'), findsOneWidget);
    expect(find.text('mpv'), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('3:20'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    // Pause is offered while playing; tapping it sends the action
    // (no live socket here, so it is logged and ignored, not a crash).
    await tester.tap(find.byTooltip('Jeda'));
    await tester.pumpAndSettle();
    expect(find.text('Lagu Tes'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('state updates replace the previous player state',
      (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    final conn = await _fakeConn(tester);
    Future<void> feed(Map<String, dynamic> body) {
      return tester.runAsync(
        () => state.handleIncomingPacket(
          conn,
          Packet.now('kdeconnect.mpris', body),
        ),
      );
    }

    await feed({'playerList': ['mpv', 'spotify']});
    expect(state.playerListFor(_deviceId), ['mpv', 'spotify']);
    expect(state.selectedPlayerFor(_deviceId), 'mpv');
    await feed({'player': 'mpv', 'title': 'Satu', 'isPlaying': true});
    await feed({'player': 'mpv', 'title': 'Dua', 'isPlaying': false});
    expect(state.playerStateFor(_deviceId, 'mpv')?.title, 'Dua');
    expect(state.playerStateFor(_deviceId, 'mpv')?.isPlaying, isFalse);
    // Selecting the other player sticks.
    await tester.runAsync(
      () => state.selectMprisPlayer(_deviceId, 'spotify'),
    );
    expect(state.selectedPlayerFor(_deviceId), 'spotify');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
