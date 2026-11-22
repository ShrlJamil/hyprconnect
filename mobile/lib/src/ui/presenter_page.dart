//! M5: presentation remote — gyro and drag pointer
//! (kdeconnect.presenter), slide controls (mousepad specialKeys,
//! stock semantics), monitor picker (HyprConnect daemon extension),
//! and per-slide presenter notes stored on this phone only.
//!
//! The page mirrors HyprPresenter's clicker layout: a slide-notes
//! card with a counter on top, big Previous/Next pills, and one
//! big pointer card at the bottom. Colours come from the app's own
//! theme, so the page does not stand out from the rest of the app.
//! The pointer follows the stock model: it only streams while the
//! card is held — gyro deltas and drag deltas both feed it — and
//! releasing the card ends the session with {"stop": true}.
//!
//! The monitor picker only appears when the desktop answered the
//! monitor-list request (the HyprConnect daemon does; a stock
//! kdeconnectd never does). Until then the pointer uses the
//! daemon's automatic monitor choice, so the remote still works.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

import 'package:sensors_plus/sensors_plus.dart';

import '../protocol/protocol.dart';
import 'app_state.dart';
import 'notes_editor_page.dart';
import 'slide_notes.dart';

class PresenterPage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  /// Gyroscope event stream to use instead of the device sensor.
  /// Tests inject a fake stream here; production passes nothing.
  final Stream<GyroscopeEvent>? gyroStream;

  const PresenterPage({
    super.key,
    required this.appState,
    required this.entry,
    this.gyroStream,
  });

  @override
  State<PresenterPage> createState() => _PresenterPageState();
}

class _PresenterPageState extends State<PresenterPage> {
  /// Gyro readings this small are sensor noise, not a hand moving.
  static const _gyroDeadZone = 0.0002;

  StreamSubscription<GyroscopeEvent>? _gyroSub;

  List<String> _notes = <String>[];
  int _slide = 1;

  /// Whether we believe the desktop presentation is fullscreen;
  /// flipped optimistically on each tap, like HyprPresenter.
  bool _fullscreen = false;

  /// True while the pointer card is held: the only time the
  /// pointer streams.
  bool _holding = false;
  bool _pointerActive = false;

  /// Last drag position on the pointer card, for delta tracking.
  Offset? _lastPadPos;

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    _notes = parseSlideNotes(_appState.presenterNotesFor(_entry.deviceId));
    _appState.requestPresenterMonitors(_entry.deviceId);
    _subscribeGyro();
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    if (_pointerActive) {
      unawaited(_appState.stopPresenter(_entry.deviceId));
    }
    super.dispose();
  }

  void _subscribeGyro() {
    final stream = widget.gyroStream ?? gyroscopeEventStream();
    _gyroSub = stream.listen(
      (event) {
        final delta = gyroToPresenterDelta(event.x, event.z);
        if (delta.dx.abs() < _gyroDeadZone && delta.dy.abs() < _gyroDeadZone) {
          return;
        }
        _sendMove(delta.dx, delta.dy);
      },
      onError: (_) {
        // No gyroscope on this device: the drag on the card
        // still works, the pointer just cannot be tilted.
        _gyroSub?.cancel();
        _gyroSub = null;
      },
    );
  }

  void _sendMove(double dx, double dy) {
    if (!_holding) return;
    if (!_pointerActive) {
      setState(() => _pointerActive = true);
    }
    unawaited(_appState.sendPresenterMove(_entry.deviceId, dx, dy));
  }

  Future<void> _stop() async {
    await _appState.stopPresenter(_entry.deviceId);
    if (mounted) setState(() => _pointerActive = false);
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    unawaited(_appState.presenterFullscreen(_entry.deviceId));
  }

  Future<void> _close() async {
    if (_pointerActive) {
      await _appState.stopPresenter(_entry.deviceId);
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _goNext() {
    unawaited(_appState.presenterNext(_entry.deviceId));
    setState(() => _slide++);
  }

  void _goPrevious() {
    unawaited(_appState.presenterPrevious(_entry.deviceId));
    if (_slide > 1) setState(() => _slide--);
  }

  void _reloadNotes() {
    setState(() {
      _notes = parseSlideNotes(_appState.presenterNotesFor(_entry.deviceId));
      if (_slide > _notes.length && _notes.isNotEmpty) {
        _slide = _notes.length;
      }
    });
  }

  Future<void> _openNotesEditor() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            NotesEditorPage(appState: _appState, deviceId: _entry.deviceId),
      ),
    );
    if (mounted) _reloadNotes();
  }

  Future<void> _openNotesFile() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['md', 'txt'],
      );
      if (picked == null || picked.path == null) return;
      final notes = parseSlideNotes(await File(picked.path!).readAsString());
      await _appState.savePresenterNotes(
        _entry.deviceId,
        notes.isEmpty ? '' : serializeSlideNotes(notes),
      );
      if (mounted) {
        setState(() {
          _notes = notes;
          _slide = 1;
        });
      }
    } catch (_) {
      // Cancelled or unreadable: the current notes stay as they are.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: context.l10n.back,
          onPressed: _close,
        ),
        actions: [
          IconButton(
            icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
            tooltip: context.l10n.fullscreen,
            onPressed: _toggleFullscreen,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _appState,
        builder: (context, _) {
          final conn = _appState.connectionFor(_entry.deviceId);
          if (conn == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(context.l10n.noConnection),
              ),
            );
          }
          final scheme = Theme.of(context).colorScheme;
          return SafeArea(
            child: Column(
              children: [
                _notesBox(scheme),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 92,
                          child: OutlinedButton.icon(
                            onPressed: _goPrevious,
                            icon: const Icon(Icons.skip_previous, size: 34),
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                context.l10n.previous,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 92,
                          child: FilledButton.icon(
                            onPressed: _goNext,
                            icon: const Icon(Icons.skip_next, size: 34),
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                context.l10n.next,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _pointerCard()),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The slide-notes card: header with the counter and re-sync
  /// chevrons, the current slide's note, and the create / open /
  /// edit buttons in the bottom-right corner.
  Widget _notesBox(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        height: 200,
        width: double.infinity,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 17,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.slideNotes,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (_notes.isNotEmpty) ...[
                    Text(
                      '$_slide / ${_notes.length}',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_left, size: 20),
                      visualDensity: VisualDensity.compact,
                      tooltip: context.l10n.previousSlideNotes,
                      onPressed: _slide > 1
                          ? () => setState(() => _slide--)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, size: 20),
                      visualDensity: VisualDensity.compact,
                      tooltip: context.l10n.nextSlideNotes,
                      onPressed: () => setState(() => _slide++),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _notes.isEmpty
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(
                        child: Text(
                          _slide - 1 < _notes.length ? _notes[_slide - 1] : '',
                          style: const TextStyle(fontSize: 15, height: 1.35),
                        ),
                      ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: _notes.isEmpty
                    ? [
                        IconButton.filledTonal(
                          icon: const Icon(Icons.note_add_outlined),
                          tooltip: context.l10n.createNotes,
                          onPressed: _openNotesEditor,
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.folder_open_outlined),
                          tooltip: context.l10n.openNotesFile,
                          onPressed: _openNotesFile,
                        ),
                      ]
                    : [
                        IconButton.filledTonal(
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: context.l10n.editNotes,
                          onPressed: _openNotesEditor,
                        ),
                      ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The pointer card: a header strip with the monitor dropdown
  /// (only when the desktop sent a monitor list) over the hold
  /// area. Holding the area streams the pointer; the card lights
  /// up while held.
  Widget _pointerCard() {
    final scheme = Theme.of(context).colorScheme;
    final hasMonitors = _appState.hasMonitorListFor(_entry.deviceId);
    final fg = _holding ? scheme.onPrimary : scheme.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: _holding ? scheme.primary : scheme.primaryContainer,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          children: [
            if (hasMonitors) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
                child: Row(
                  children: [
                    Icon(Icons.monitor, size: 20, color: fg),
                    const SizedBox(width: 10),
                    DropdownButton<String?>(
                      value: _appState.presenterMonitorFor(_entry.deviceId),
                      underline: const SizedBox.shrink(),
                      dropdownColor: scheme.surfaceContainerHigh,
                      iconEnabledColor: fg,
                      style: TextStyle(
                        color: fg,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(context.l10n.automatic),
                        ),
                        for (final name in _appState.monitorListFor(
                          _entry.deviceId,
                        ))
                          DropdownMenuItem<String?>(
                            value: name,
                            child: Text(name),
                          ),
                      ],
                      onChanged: (monitor) {
                        _appState.setPresenterMonitor(_entry.deviceId, monitor);
                      },
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: fg.withValues(alpha: 0.25),
              ),
            ],
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Listener(
                    key: const ValueKey('presenterPad'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) {
                      setState(() => _holding = true);
                      _lastPadPos = event.position;
                    },
                    onPointerMove: (event) {
                      final last = _lastPadPos;
                      if (last == null) return;
                      final delta = event.position - last;
                      _lastPadPos = event.position;
                      _sendMove(
                        delta.dx / constraints.maxWidth,
                        delta.dy / constraints.maxHeight,
                      );
                    },
                    onPointerUp: (_) => _release(),
                    onPointerCancel: (_) => _release(),
                    child: Center(
                      child: Icon(Icons.gps_fixed, size: 88, color: fg),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _release() {
    _lastPadPos = null;
    if (_holding) {
      setState(() => _holding = false);
    }
    if (_pointerActive) {
      unawaited(_stop());
    }
  }
}
