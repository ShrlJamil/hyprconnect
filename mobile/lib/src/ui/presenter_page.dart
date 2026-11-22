//! M5: presentation remote — gyro and drag pointer
//! (kdeconnect.presenter), slide controls (mousepad specialKeys,
//! stock semantics), monitor picker (HyprConnect daemon extension),
//! and presenter notes stored on this phone only.
//!
//! Pointer: the first delta starts a session and shows the dot on
//! the desktop; no delta for 3 seconds times it out on the daemon,
//! and leaving this page sends {"stop": true}. Gyro follows the
//! stock app exactly (dx = -gyroZ, dy = -gyroX, sensitivity 0.036);
//! the drag pad sends the same packet with the drag delta as a
//! fraction of the pad, so a full-width drag crosses the monitor.
//! Slide controls go through the mousepad packet type like the
//! stock app: next is specialKey 9, previous 8, fullscreen 25,
//! exit 14.
//!
//! The monitor picker only appears when the desktop answered the
//! monitor-list request (the HyprConnect daemon does; a stock
//! kdeconnectd never does). Until then the pointer uses the
//! daemon's automatic monitor choice, so the remote still works.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../protocol/protocol.dart';
import 'app_state.dart';

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

  late final TextEditingController _notesController;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  bool _gyroOn = true;
  bool _gyroAvailable = true;
  bool _pointerActive = false;

  /// Last drag position on the pointer pad, for delta tracking.
  Offset? _lastPadPos;

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    _notesController = TextEditingController(
      text: _appState.presenterNotesFor(_entry.deviceId),
    );
    _appState.requestPresenterMonitors(_entry.deviceId);
    _subscribeGyro();
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    if (_pointerActive) {
      unawaited(_appState.stopPresenter(_entry.deviceId));
    }
    _notesController.dispose();
    super.dispose();
  }

  void _subscribeGyro() {
    if (!_gyroOn) return;
    final stream = widget.gyroStream ?? gyroscopeEventStream();
    _gyroSub = stream.listen(
      (event) {
        final delta = gyroToPresenterDelta(event.x, event.z);
        if (delta.dx.abs() < _gyroDeadZone &&
            delta.dy.abs() < _gyroDeadZone) {
          return;
        }
        _sendMove(delta.dx, delta.dy);
      },
      onError: (_) {
        _gyroSub?.cancel();
        _gyroSub = null;
        if (mounted) {
          setState(() => _gyroAvailable = false);
        }
      },
    );
  }

  void _setGyro(bool on) {
    setState(() => _gyroOn = on);
    if (on) {
      _subscribeGyro();
    } else {
      _gyroSub?.cancel();
      _gyroSub = null;
    }
  }

  void _sendMove(double dx, double dy) {
    if (!_pointerActive) {
      setState(() => _pointerActive = true);
    }
    unawaited(_appState.sendPresenterMove(_entry.deviceId, dx, dy));
  }

  Future<void> _stop() async {
    await _appState.stopPresenter(_entry.deviceId);
    if (mounted) setState(() => _pointerActive = false);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Presentation remote')),
      body: AnimatedBuilder(
        animation: _appState,
        builder: (context, _) {
          final conn = _appState.connectionFor(_entry.deviceId);
          if (conn == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Tidak ada koneksi ke perangkat ini.'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                _pointerActive
                    ? 'Pointer aktif di ${_appState.presenterMonitorFor(_entry.deviceId) ?? 'monitor otomatis'}'
                    : 'Pointer berhenti',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              _monitorSection(),
              const SizedBox(height: 16),
              _pointerPad(),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Pointer gyro'),
                subtitle: Text(
                  _gyroAvailable
                      ? 'Miringkan HP untuk menggerakkan pointer'
                      : 'Gyro tidak tersedia di perangkat ini, pakai seret',
                ),
                value: _gyroOn && _gyroAvailable,
                onChanged: _gyroAvailable ? _setGyro : null,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => unawaited(
                        _appState.presenterPrevious(_entry.deviceId),
                      ),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Sebelumnya'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => unawaited(
                        _appState.presenterNext(_entry.deviceId),
                      ),
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Berikutnya'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => unawaited(
                        _appState.presenterFullscreen(_entry.deviceId),
                      ),
                      child: const Text('Layar penuh'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => unawaited(
                        _appState.presenterEscape(_entry.deviceId),
                      ),
                      child: const Text('Keluar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _stop,
                      child: const Text('Berhenti'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Catatan presenter',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notesController,
                maxLines: 6,
                minLines: 4,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText:
                      'Catatan untukmu saat presentasi. Hanya tersimpan di HP ini.',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  await _appState.savePresenterNotes(
                    _entry.deviceId,
                    _notesController.text,
                  );
                  if (mounted) _snack('Catatan tersimpan di HP ini.');
                },
                child: const Text('Simpan catatan'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _monitorSection() {
    if (!_appState.hasMonitorListFor(_entry.deviceId)) {
      return Row(
        children: [
          const Expanded(
            child: Text(
              'Desktop ini tidak mengirim daftar monitor, pointer '
              'memakai monitor otomatis.',
            ),
          ),
          TextButton(
            onPressed: () =>
                _appState.requestPresenterMonitors(_entry.deviceId),
            child: const Text('Minta daftar monitor'),
          ),
        ],
      );
    }
    final monitors = _appState.monitorListFor(_entry.deviceId);
    return DropdownButtonFormField<String?>(
      decoration: const InputDecoration(
        labelText: 'Monitor presenter',
        border: OutlineInputBorder(),
      ),
      initialValue: _appState.presenterMonitorFor(_entry.deviceId),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('Otomatis'),
        ),
        for (final name in monitors)
          DropdownMenuItem<String?>(value: name, child: Text(name)),
      ],
      onChanged: (monitor) {
        _appState.setPresenterMonitor(_entry.deviceId, monitor);
      },
    );
  }

  Widget _pointerPad() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        const height = 220.0;
        return Container(
          height: height,
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outline,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Listener(
            key: const ValueKey('presenterPad'),
            onPointerDown: (event) => _lastPadPos = event.position,
            onPointerMove: (event) {
              final last = _lastPadPos;
              if (last == null) return;
              final delta = event.position - last;
              _lastPadPos = event.position;
              _sendMove(delta.dx / width, delta.dy / height);
            },
            onPointerUp: (_) => _lastPadPos = null,
            onPointerCancel: (_) => _lastPadPos = null,
            child: const Center(
              child: Text(
                'Seret di sini untuk menggerakkan pointer',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      },
    );
  }
}
