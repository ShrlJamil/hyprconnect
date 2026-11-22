//! System volume (kdeconnect.systemvolume /
//! kdeconnect.systemvolume.request). Wire rules read from the
//! daemon (src/main.rs send_sink_list, handle_systemvolume_request,
//! sink_refresh_and_broadcast):
//!
//! - Ask for the list: kdeconnect.systemvolume.request with
//!   {"requestSinks": true}. The daemon answers with one
//!   kdeconnect.systemvolume packet carrying {"sinkList": [...]};
//!   each sink is {name, description, muted, volume, maxVolume,
//!   enabled}, volume in raw PulseAudio units (maxVolume 65536)
//!   and enabled marking the default sink. The daemon also pushes
//!   the list on connect and whenever the sink structure changes.
//! - Incremental updates arrive as kdeconnect.systemvolume packets
//!   with {"name", "volume"} or {"name", "muted"}.
//! - Set a sink's volume: request with {"name", "volume": raw}.
//!   Setting the volume unmutes the sink, like the KDE plugin.
//! - Mute: {"name", "muted": bool}. Make a sink the default:
//!   {"name", "enabled": true}.

import 'packet.dart';

/// One desktop audio output (sink), as the daemon reports it.
/// Volume is kept in raw PulseAudio units; [volumePercent] is the
/// 0..100 view the UI works with.
class SinkState {
  final String name;
  final String description;
  final int volume;
  final int maxVolume;
  final bool muted;
  final bool enabled;

  const SinkState({
    required this.name,
    required this.description,
    required this.volume,
    required this.maxVolume,
    required this.muted,
    required this.enabled,
  });

  /// What the UI shows: the description ("Built-in Audio Analog
  /// Stereo"), falling back to the raw sink name.
  String get label => description.isNotEmpty ? description : name;

  int get volumePercent =>
      maxVolume <= 0 ? 0 : (volume * 100 / maxVolume).round().clamp(0, 100);

  SinkState copyWith({int? volume, bool? muted, bool? enabled}) {
    return SinkState(
      name: name,
      description: description,
      volume: volume ?? this.volume,
      maxVolume: maxVolume,
      muted: muted ?? this.muted,
      enabled: enabled ?? this.enabled,
    );
  }

  static SinkState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'] as String? ?? '';
    if (name.isEmpty) return null;
    return SinkState(
      name: name,
      description: raw['description'] as String? ?? '',
      volume: (raw['volume'] as num?)?.toInt() ?? 0,
      maxVolume: (raw['maxVolume'] as num?)?.toInt() ?? 65536,
      muted: raw['muted'] as bool? ?? false,
      enabled: raw['enabled'] as bool? ?? false,
    );
  }

  /// The full sink list of a kdeconnect.systemvolume packet, or
  /// null when the packet is an incremental update instead.
  static List<SinkState>? sinkListOf(Packet packet) {
    final raw = packet.body['sinkList'];
    if (raw is! List) return null;
    return [for (final entry in raw) ?SinkState.fromJson(entry)];
  }
}

/// Ask the desktop for its full sink list.
Packet systemVolumeRequestSinks() {
  return Packet.now('kdeconnect.systemvolume.request', {'requestSinks': true});
}

/// Set one sink's volume, in raw PulseAudio units (0..maxVolume).
Packet systemVolumeSetVolume(String name, int rawVolume) {
  return Packet.now('kdeconnect.systemvolume.request', {
    'name': name,
    'volume': rawVolume,
  });
}

/// Mute or unmute one sink.
Packet systemVolumeSetMuted(String name, bool muted) {
  return Packet.now('kdeconnect.systemvolume.request', {
    'name': name,
    'muted': muted,
  });
}

/// Make one sink the desktop's default output.
Packet systemVolumeSetEnabled(String name) {
  return Packet.now('kdeconnect.systemvolume.request', {
    'name': name,
    'enabled': true,
  });
}
