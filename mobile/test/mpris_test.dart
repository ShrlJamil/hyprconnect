//! M3 protocol tests: mpris.request packet shapes (player list,
//! now playing, actions, volume, seek, position, album art) and
//! parsing of kdeconnect.mpris state / playerList / album-art
//! packets, plus a request round-trip between two real
//! DeviceConnections.

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
  test('requestPlayerList packet shape', () {
    final packet = mprisRequestPlayerList();
    expect(packet.type, 'kdeconnect.mpris.request');
    expect(packet.body['requestPlayerList'], isTrue);
    final decoded = Packet.fromJson(packet.toJson());
    expect(decoded.body['requestPlayerList'], isTrue);
  });

  test('requestNowPlaying names the player', () {
    final packet = mprisRequestNowPlaying('mpv');
    expect(packet.body['player'], 'mpv');
    expect(packet.body['requestNowPlaying'], isTrue);
  });

  test('actions are the six the daemon handles', () {
    for (final action in [
      'Play',
      'Pause',
      'PlayPause',
      'Next',
      'Previous',
      'Stop',
    ]) {
      final packet = mprisAction('mpv', action);
      expect(packet.body['action'], action);
      expect(packet.body['player'], 'mpv');
    }
    expect(() => mprisAction('mpv', 'FastForward'), throwsArgumentError);
  });

  test('setVolume clamps to 0..100', () {
    expect(mprisSetVolume('mpv', 42).body['setVolume'], 42);
    expect(mprisSetVolume('mpv', 150).body['setVolume'], 100);
    expect(mprisSetVolume('mpv', -5).body['setVolume'], 0);
  });

  test('seek and setPosition use microseconds', () {
    expect(mprisSeek('mpv', 10000000).body['Seek'], 10000000);
    expect(mprisSetPosition('mpv', 45000000).body['SetPosition'], 45000000);
  });

  test('album art request names player and url', () {
    final packet = mprisRequestAlbumArt(
      'mpv',
      'file:///home/jyameel/.cache/cover.jpg',
    );
    expect(packet.body['player'], 'mpv');
    expect(packet.body['albumArtUrl'], 'file:///home/jyameel/.cache/cover.jpg');
  });

  test('state packet parses the full daemon shape', () {
    final packet = Packet.now('kdeconnect.mpris', {
      'player': 'mpv',
      'title': 'Lagu Tes',
      'artist': 'Artis',
      'album': 'Album',
      'albumArtUrl': 'file:///tmp/cover.jpg',
      'supportAlbumArtPayload': true,
      'nowPlaying': 'Lagu Tes',
      'isPlaying': true,
      'pos': 12345,
      'length': 200000,
      'canPlay': true,
      'canPause': true,
      'canGoNext': true,
      'canGoPrevious': false,
      'canSeek': true,
      'canFastForward': true,
      'canRewind': true,
      'volume': 75,
    });
    final state = MprisPlayerState.fromPacket(packet);
    expect(state.player, 'mpv');
    expect(state.title, 'Lagu Tes');
    expect(state.artist, 'Artis');
    expect(state.album, 'Album');
    expect(state.albumArtUrl, 'file:///tmp/cover.jpg');
    expect(state.isPlaying, isTrue);
    expect(state.posMs, 12345);
    expect(state.lengthMs, 200000);
    expect(state.volume, 75);
    expect(state.canGoPrevious, isFalse);
    expect(state.canSeek, isTrue);
    expect(MprisPlayerState.playerListOf(packet), isNull);
    expect(MprisPlayerState.isAlbumArtPacket(packet), isFalse);
  });

  test('partial state packet tolerates missing fields', () {
    final state = MprisPlayerState.fromPacket(
      Packet.now('kdeconnect.mpris', {'player': 'spotify'}),
    );
    expect(state.title, '');
    expect(state.isPlaying, isFalse);
    expect(state.posMs, 0);
    expect(state.volume, 0);
  });

  test('playerList packet parses names, empty list included', () {
    final packet = Packet.now('kdeconnect.mpris', {
      'playerList': ['mpv', 'spotify'],
    });
    expect(MprisPlayerState.playerListOf(packet), ['mpv', 'spotify']);
    final empty = Packet.now('kdeconnect.mpris', {'playerList': []});
    expect(MprisPlayerState.playerListOf(empty), isEmpty);
  });

  test('album art packet is flagged, not a state update', () {
    final packet = Packet.now('kdeconnect.mpris', {
      'transferringAlbumArt': true,
      'player': 'mpv',
      'albumArtUrl': 'file:///tmp/cover.jpg',
    });
    expect(MprisPlayerState.isAlbumArtPacket(packet), isTrue);
    expect(MprisPlayerState.playerListOf(packet), isNull);
  });

  test('mpris request round-trips over a real TLS channel', () async {
    final dirA = await Directory.systemTemp.createTemp('hyprconnect-m3a-');
    final dirB = await Directory.systemTemp.createTemp('hyprconnect-m3b-');
    final (connA, connB, listener) = await _pair(dirA, dirB);
    try {
      final seen = connB.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.mpris.request' &&
            p.body['requestPlayerList'] == true,
      );
      await connA.requestMprisPlayerList();
      final packet = await seen.timeout(const Duration(seconds: 10));
      expect(packet.body['requestPlayerList'], isTrue);
      final actionSeen = connB.packets.firstWhere(
        (p) =>
            p.type == 'kdeconnect.mpris.request' &&
            p.body['action'] == 'PlayPause',
      );
      await connA.sendMprisAction('mpv', 'PlayPause');
      expect(
        (await actionSeen.timeout(const Duration(seconds: 10))).body['player'],
        'mpv',
      );
    } finally {
      await connA.close();
      await connB.close();
      await listener.stop();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
