//! M3: control the desktop's media players (kdeconnect.mpris).
//! The page asks for the player list on open; the daemon pushes a
//! fresh state packet after every action, so the display follows the
//! desktop without polling. Album art, when the daemon offers a
//! file:// url, is pulled once and shown from the app's art dir.

import 'dart:io';

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import 'app_state.dart';

String _formatMs(int ms) {
  final total = ms ~/ 1000;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class MultimediaPage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const MultimediaPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  State<MultimediaPage> createState() => _MultimediaPageState();
}

class _MultimediaPageState extends State<MultimediaPage> {
  double? _dragPos;
  double? _dragVolume;

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    _appState.requestMprisPlayers(_entry.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final conn = _appState.connectionFor(_entry.deviceId);
        final players = _appState.playerListFor(_entry.deviceId);
        final selected = _appState.selectedPlayerFor(_entry.deviceId);
        final state = selected == null
            ? null
            : _appState.playerStateFor(_entry.deviceId, selected);
        final artPath = selected == null
            ? null
            : _appState.albumArtPathFor(_entry.deviceId, selected);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Kendali multimedia'),
            actions: [
              IconButton(
                tooltip: 'Muat ulang daftar player',
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    _appState.requestMprisPlayers(_entry.deviceId),
              ),
            ],
          ),
          body: conn == null
              ? const Center(
                  child: Text('Tidak ada koneksi ke perangkat ini.'),
                )
              : players.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Tidak ada player media di desktop saat ini.\n'
                          'Putar sesuatu di desktop, lalu muat ulang.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _playerPicker(players, selected),
                        const SizedBox(height: 16),
                        if (state != null) ...[
                          _nowPlaying(state, artPath),
                          const SizedBox(height: 16),
                          _progress(state),
                          const SizedBox(height: 8),
                          _controls(state),
                          const SizedBox(height: 16),
                          _volume(state),
                        ] else
                          const Text(
                            'Menunggu status player dari desktop...',
                          ),
                      ],
                    ),
        );
      },
    );
  }

  Widget _playerPicker(List<String> players, String? selected) {
    return DropdownButtonFormField<String>(
      initialValue: players.contains(selected) ? selected : null,
      decoration: const InputDecoration(
        labelText: 'Player',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final name in players)
          DropdownMenuItem(value: name, child: Text(name)),
      ],
      onChanged: (name) {
        if (name != null) {
          _appState.selectMprisPlayer(_entry.deviceId, name);
        }
      },
    );
  }

  Widget _nowPlaying(MprisPlayerState state, String? artPath) {
    final artFile = artPath == null ? null : File(artPath);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            image: artFile != null && artFile.existsSync()
                ? DecorationImage(
                    image: FileImage(artFile),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: artFile == null || !artFile.existsSync()
              ? const Icon(Icons.music_note, size: 48)
              : null,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.title.isEmpty ? '(tanpa judul)' : state.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              if (state.artist.isNotEmpty) Text(state.artist),
              if (state.album.isNotEmpty)
                Text(
                  state.album,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 4),
              Text(
                state.isPlaying ? 'Memutar' : 'Jeda',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progress(MprisPlayerState state) {
    final length = state.lengthMs;
    final pos = _dragPos ?? state.posMs.toDouble();
    return Column(
      children: [
        Slider(
          value: length > 0 ? pos.clamp(0, length.toDouble()) : 0,
          max: length > 0 ? length.toDouble() : 1,
          onChanged: state.canSeek
              ? (value) => setState(() => _dragPos = value)
              : null,
          onChangeEnd: state.canSeek
              ? (value) {
                  setState(() => _dragPos = null);
                  _appState.setMprisPosition(
                    _entry.deviceId,
                    value ~/ 1000,
                  );
                }
              : null,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatMs(pos.toInt())),
            Text(_formatMs(length)),
          ],
        ),
      ],
    );
  }

  Widget _controls(MprisPlayerState state) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: 'Mundur 10 detik',
          icon: const Icon(Icons.replay_10),
          onPressed: state.canSeek
              ? () => _appState.seekMpris(_entry.deviceId, -10)
              : null,
        ),
        IconButton(
          tooltip: 'Sebelumnya',
          icon: const Icon(Icons.skip_previous),
          onPressed: state.canGoPrevious
              ? () => _appState.sendMprisAction(_entry.deviceId, 'Previous')
              : null,
        ),
        IconButton.filled(
          tooltip: state.isPlaying ? 'Jeda' : 'Putar',
          iconSize: 36,
          icon: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow),
          onPressed: (state.isPlaying ? state.canPause : state.canPlay)
              ? () => _appState.sendMprisAction(
                    _entry.deviceId,
                    state.isPlaying ? 'Pause' : 'Play',
                  )
              : null,
        ),
        IconButton(
          tooltip: 'Berikutnya',
          icon: const Icon(Icons.skip_next),
          onPressed: state.canGoNext
              ? () => _appState.sendMprisAction(_entry.deviceId, 'Next')
              : null,
        ),
        IconButton(
          tooltip: 'Maju 10 detik',
          icon: const Icon(Icons.forward_10),
          onPressed: state.canSeek
              ? () => _appState.seekMpris(_entry.deviceId, 10)
              : null,
        ),
        IconButton(
          tooltip: 'Berhenti',
          icon: const Icon(Icons.stop),
          onPressed: () => _appState.sendMprisAction(_entry.deviceId, 'Stop'),
        ),
      ],
    );
  }

  Widget _volume(MprisPlayerState state) {
    final volume = _dragVolume ?? state.volume.toDouble();
    return Row(
      children: [
        const Icon(Icons.volume_down),
        Expanded(
          child: Slider(
            value: volume.clamp(0, 100),
            max: 100,
            divisions: 100,
            label: '${volume.round()}%',
            onChanged: (value) => setState(() => _dragVolume = value),
            onChangeEnd: (value) {
              setState(() => _dragVolume = null);
              _appState.setMprisVolume(_entry.deviceId, value.round());
            },
          ),
        ),
        const Icon(Icons.volume_up),
        SizedBox(
          width: 44,
          child: Text('${volume.round()}%'),
        ),
      ],
    );
  }
}
