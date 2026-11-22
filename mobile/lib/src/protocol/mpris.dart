//! Multimedia control (kdeconnect.mpris / kdeconnect.mpris.request).
//! Wire rules read from the daemon (src/main.rs handle_mpris_request,
//! mpris_state_packet, mpris_send_all_to):
//!
//! - Ask for the player list: kdeconnect.mpris.request with
//!   {"requestPlayerList": true}. The daemon answers with one
//!   kdeconnect.mpris state packet per player, then a final
//!   kdeconnect.mpris packet carrying {"playerList": [names]}.
//!   With no players it sends only {"playerList": []}.
//! - Ask for one player's state: {"player": name,
//!   "requestNowPlaying": true}.
//! - Actions: {"player": name, "action": "Play" | "Pause" |
//!   "PlayPause" | "Next" | "Previous" | "Stop"}. Anything else is
//!   logged and ignored by the daemon.
//! - Volume: {"player": name, "setVolume": 0..100} (percent, the
//!   daemon clamps and divides by 100 for MPRIS).
//! - Seek: {"player": name, "Seek": microseconds} (MPRIS-native,
//!   passed through untouched; 10 seconds is 10000000).
//! - Absolute position: {"player": name, "SetPosition": microseconds}
//!   (the daemon pairs it with the track id it last read).
//! - State packets (kdeconnect.mpris) carry player, title, artist,
//!   album, albumArtUrl, isPlaying, pos and length in milliseconds,
//!   canPlay/canPause/canGoNext/canGoPrevious/canSeek, and volume
//!   0..100. After any action the daemon re-reads the player and
//!   pushes a fresh state packet, so the phone never polls.
//! - Album art is a pull protocol: {"player": name, "albumArtUrl": url}
//!   (only for a file:// url that is still the player's current art)
//!   is answered with a kdeconnect.mpris packet flagged
//!   transferringAlbumArt, carrying the art as a payload on a second
//!   TLS connection (same payload mechanics as a file share).

import 'packet.dart';

/// Actions the daemon understands on kdeconnect.mpris.request.
const Set<String> mprisActions = {
  'Play',
  'Pause',
  'PlayPause',
  'Next',
  'Previous',
  'Stop',
};

/// One desktop player's now-playing state, as the daemon reports it.
/// All fields tolerate missing values: the daemon always sends the
/// full shape, but a stock kdeconnectd may send less.
class MprisPlayerState {
  final String player;
  final String title;
  final String artist;
  final String album;
  final String albumArtUrl;
  final bool isPlaying;
  final int posMs;
  final int lengthMs;
  final int volume;
  final bool canPlay;
  final bool canPause;
  final bool canGoNext;
  final bool canGoPrevious;
  final bool canSeek;

  const MprisPlayerState({
    required this.player,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtUrl = '',
    this.isPlaying = false,
    this.posMs = 0,
    this.lengthMs = 0,
    this.volume = 0,
    this.canPlay = false,
    this.canPause = false,
    this.canGoNext = false,
    this.canGoPrevious = false,
    this.canSeek = false,
  });

  factory MprisPlayerState.fromPacket(Packet packet) {
    final body = packet.body;
    return MprisPlayerState(
      player: body['player'] as String? ?? '',
      title: body['title'] as String? ?? '',
      artist: body['artist'] as String? ?? '',
      album: body['album'] as String? ?? '',
      albumArtUrl: body['albumArtUrl'] as String? ?? '',
      isPlaying: body['isPlaying'] as bool? ?? false,
      posMs: (body['pos'] as num?)?.toInt() ?? 0,
      lengthMs: (body['length'] as num?)?.toInt() ?? 0,
      volume: (body['volume'] as num?)?.toInt() ?? 0,
      canPlay: body['canPlay'] as bool? ?? false,
      canPause: body['canPause'] as bool? ?? false,
      canGoNext: body['canGoNext'] as bool? ?? false,
      canGoPrevious: body['canGoPrevious'] as bool? ?? false,
      canSeek: body['canSeek'] as bool? ?? false,
    );
  }

  /// Player names from a {"playerList": [...]} packet, or null when
  /// the packet is a state packet instead.
  static List<String>? playerListOf(Packet packet) {
    final list = packet.body['playerList'];
    if (list is! List) return null;
    return list.map((name) => name.toString()).toList();
  }

  /// True when this packet carries an album-art payload instead of
  /// a state update.
  static bool isAlbumArtPacket(Packet packet) {
    return packet.body['transferringAlbumArt'] as bool? ?? false;
  }
}

/// kdeconnect.mpris.request asking for the player list.
Packet mprisRequestPlayerList() {
  return Packet.now('kdeconnect.mpris.request', {'requestPlayerList': true});
}

/// kdeconnect.mpris.request asking for one player's current state.
Packet mprisRequestNowPlaying(String player) {
  return Packet.now('kdeconnect.mpris.request', {
    'player': player,
    'requestNowPlaying': true,
  });
}

/// kdeconnect.mpris.request with one playback action. Throws on an
/// action the daemon does not know.
Packet mprisAction(String player, String action) {
  if (!mprisActions.contains(action)) {
    throw ArgumentError('unknown mpris action $action');
  }
  return Packet.now('kdeconnect.mpris.request', {
    'player': player,
    'action': action,
  });
}

/// kdeconnect.mpris.request setting the volume, 0..100 (clamped).
Packet mprisSetVolume(String player, int volume) {
  return Packet.now('kdeconnect.mpris.request', {
    'player': player,
    'setVolume': volume.clamp(0, 100),
  });
}

/// kdeconnect.mpris.request seeking relative to the current position,
/// in MPRIS-native microseconds (10 seconds = 10000000).
Packet mprisSeek(String player, int microseconds) {
  return Packet.now('kdeconnect.mpris.request', {
    'player': player,
    'Seek': microseconds,
  });
}

/// kdeconnect.mpris.request jumping to an absolute position, in
/// MPRIS-native microseconds.
Packet mprisSetPosition(String player, int microseconds) {
  return Packet.now('kdeconnect.mpris.request', {
    'player': player,
    'SetPosition': microseconds,
  });
}

/// kdeconnect.mpris.request pulling the album art for a file:// url
/// the daemon currently reports for this player.
Packet mprisRequestAlbumArt(String player, String albumArtUrl) {
  return Packet.now('kdeconnect.mpris.request', {
    'player': player,
    'albumArtUrl': albumArtUrl,
  });
}
