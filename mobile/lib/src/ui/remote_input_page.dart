//! M4: remote input — a touchpad and a keyboard for the desktop
//! (kdeconnect.mousepad.request, same semantics as the daemon already
//! implements for the stock app).
//!
//! Touchpad: drag moves the pointer, tap is a left click, two quick
//! taps are a double click, holding still presses the left button
//! down until release (so a hold-then-drag drags), and the Gerak/Gulir
//! switch turns drags into scrolls. The pad tracks raw pointer events
//! on purpose: with a GestureDetector the long-press recogniser would
//! win the arena and swallow the drag that follows a hold.
//! Keyboard: typing in the field sends each character as it is typed
//! (edits are diffed against what was already sent, so backspace in
//! the field sends Backspace to the desktop); the modifier chips stay
//! on until tapped again and ride along with the next key; the arrow
//! keys, common special keys, and F1..F12 are buttons; Tempel sends
//! the phone clipboard as one typed string.

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import 'app_state.dart';

class RemoteInputPage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const RemoteInputPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  State<RemoteInputPage> createState() => _RemoteInputPageState();
}

class _RemoteInputPageState extends State<RemoteInputPage> {
  static const _tapSlop = 12.0;
  static const _tapMaxMs = 250;
  static const _doubleTapMaxMs = 350;
  static const _holdMs = 400;

  final _typeController = TextEditingController();

  bool _scrollMode = false;
  double _sensitivity = 1.0;
  bool _ctrl = false;
  bool _alt = false;
  bool _shift = false;
  bool _super = false;

  // Touchpad tracking for the single pointer currently down.
  int? _pointerId;
  Offset? _downPos;
  Offset? _lastPos;
  DateTime? _downAt;
  double _moved = 0;
  Timer? _holdTimer;
  Timer? _tapTimer;
  bool _holding = false;
  bool _dragging = false;

  /// Text already sent to the desktop, for diffing field edits.
  String _sentText = '';

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  MousepadModifiers get _modifiers => MousepadModifiers(
    ctrl: _ctrl,
    alt: _alt,
    shift: _shift,
    superKey: _super,
  );

  @override
  void dispose() {
    _holdTimer?.cancel();
    _tapTimer?.cancel();
    _typeController.dispose();
    super.dispose();
  }

  void _cancelTapTimer() {
    _tapTimer?.cancel();
    _tapTimer = null;
  }

  void _cancelHoldTimer() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointerId != null) return;
    _pointerId = event.pointer;
    _downPos = event.position;
    _lastPos = event.position;
    _downAt = DateTime.now();
    _moved = 0;
    _dragging = false;
    _cancelHoldTimer();
    _holdTimer = Timer(const Duration(milliseconds: _holdMs), () {
      if (_pointerId == null || _dragging) return;
      _holding = true;
      _appState.sendMousepadHold(_entry.deviceId, true);
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointerId) return;
    final last = _lastPos;
    if (last == null) return;
    final delta = event.position - last;
    _lastPos = event.position;
    _moved += delta.distance;
    if (_moved > _tapSlop) {
      _dragging = true;
      _cancelHoldTimer();
    }
    if (!_dragging) return;
    final dx = delta.dx * _sensitivity;
    final dy = delta.dy * _sensitivity;
    if (_scrollMode) {
      _appState.sendMousepadScroll(_entry.deviceId, dx, dy);
    } else {
      _appState.sendMousepadMove(_entry.deviceId, dx, dy);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointerId) return;
    _pointerId = null;
    _cancelHoldTimer();
    if (_holding) {
      _holding = false;
      _appState.sendMousepadHold(_entry.deviceId, false);
      return;
    }
    if (_dragging) return;
    final downAt = _downAt;
    final downPos = _downPos;
    if (downAt == null || downPos == null) return;
    final quick =
        DateTime.now().difference(downAt).inMilliseconds <= _tapMaxMs &&
        _moved <= _tapSlop;
    if (!quick) return;
    if (_tapTimer != null) {
      // Second quick tap: a double click, not two singles.
      _cancelTapTimer();
      _appState.sendMousepadClick(_entry.deviceId, MousepadClick.doubleLeft);
    } else {
      _tapTimer = Timer(const Duration(milliseconds: _doubleTapMaxMs), () {
        _tapTimer = null;
        if (!mounted) return;
        _appState.sendMousepadClick(_entry.deviceId, MousepadClick.left);
      });
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointerId) return;
    _pointerId = null;
    _cancelHoldTimer();
    _cancelTapTimer();
    if (_holding) {
      _holding = false;
      _appState.sendMousepadHold(_entry.deviceId, false);
    }
  }

  /// The field changed: diff against what the desktop already has.
  /// Added text is typed, removed text costs one Backspace per
  /// character (the common-prefix diff also covers edits in the
  /// middle of the field).
  void _onTyped(String text) {
    final previous = _sentText;
    if (text == previous) return;
    var prefix = 0;
    while (prefix < previous.length &&
        prefix < text.length &&
        previous[prefix] == text[prefix]) {
      prefix++;
    }
    final removed = previous.length - prefix;
    final added = text.substring(prefix);
    _sentText = text;
    final modifiers = _modifiers;
    for (var i = 0; i < removed; i++) {
      _appState.sendMousepadSpecialKey(_entry.deviceId, 1, modifiers);
    }
    _sendText(added, modifiers);
  }

  void _sendText(String text, MousepadModifiers modifiers) {
    if (text.isEmpty) return;
    if (modifiers.any) {
      // A typed string ignores modifiers on the daemon side, so
      // send character by character when any modifier is on.
      for (final ch in text.split('')) {
        _appState.sendMousepadKey(_entry.deviceId, ch, modifiers);
      }
    } else if (text.length == 1) {
      _appState.sendMousepadKey(_entry.deviceId, text, modifiers);
    } else {
      _appState.sendMousepadType(_entry.deviceId, text);
    }
  }

  Future<void> _pasteClipboard() async {
    final pasted = await _appState.readClipboardText();
    if (pasted == null || pasted.isEmpty) return;
    // Setting the text fires onChanged, which diffs and sends it.
    _typeController.text = _typeController.text + pasted;
  }

  void _sendSpecial(int code) {
    _appState.sendMousepadSpecialKey(_entry.deviceId, code, _modifiers);
  }

  Widget _modifierChip(String label, bool on, ValueChanged<bool> set) {
    return FilterChip(
      label: Text(label),
      selected: on,
      onSelected: (value) => setState(() => set(value)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final conn = _appState.connectionFor(_entry.deviceId);
        return Scaffold(
          appBar: AppBar(title: const Text('Masukan jarak jauh')),
          body: conn == null
              ? const Center(child: Text('Tidak ada koneksi ke perangkat ini.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'Touchpad',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerCancel,
                      child: Container(
                        key: const ValueKey('touchpad'),
                        height: 240,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            _scrollMode
                                ? 'Seret untuk menggulir'
                                : 'Seret: gerakkan pointer\n'
                                      'Ketuk: klik kiri\n'
                                      'Ketuk dua kali: klik ganda\n'
                                      'Tekan lama: tahan, lalu seret',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.mouse),
                            label: const Text('Klik kanan'),
                            onPressed: () => _appState.sendMousepadClick(
                              _entry.deviceId,
                              MousepadClick.right,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.adjust),
                            label: const Text('Klik tengah'),
                            onPressed: () => _appState.sendMousepadClick(
                              _entry.deviceId,
                              MousepadClick.middle,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('Gerak'),
                          icon: Icon(Icons.open_with),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text('Gulir'),
                          icon: Icon(Icons.swap_vert),
                        ),
                      ],
                      selected: {_scrollMode},
                      onSelectionChanged: (selection) {
                        setState(() => _scrollMode = selection.first);
                      },
                    ),
                    Row(
                      children: [
                        const Text('Sensitivitas'),
                        Expanded(
                          child: Slider(
                            value: _sensitivity,
                            min: 0.5,
                            max: 3.0,
                            divisions: 10,
                            label: '${_sensitivity.toStringAsFixed(1)}x',
                            onChanged: (value) {
                              setState(() => _sensitivity = value);
                            },
                          ),
                        ),
                        Text('${_sensitivity.toStringAsFixed(1)}x'),
                      ],
                    ),
                    const Divider(height: 32),
                    const Text(
                      'Keyboard',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('type-field'),
                      controller: _typeController,
                      decoration: const InputDecoration(
                        labelText: 'Ketik di sini',
                        hintText: 'Huruf yang diketik langsung terkirim',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.done,
                      onChanged: _onTyped,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Tempel dari papan klip'),
                        onPressed: _pasteClipboard,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _modifierChip('Ctrl', _ctrl, (v) => _ctrl = v),
                        _modifierChip('Alt', _alt, (v) => _alt = v),
                        _modifierChip('Shift', _shift, (v) => _shift = v),
                        _modifierChip('Super', _super, (v) => _super = v),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Ctrl, Alt, Shift, dan Super tetap aktif sampai '
                      'dimatikan lagi, dan ikut pada tombol berikutnya.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final key in mousepadSpecialKeys)
                          OutlinedButton(
                            onPressed: () => _sendSpecial(key.code),
                            child: Text(key.label),
                          ),
                        PopupMenuButton<int>(
                          tooltip: 'Tombol fungsi F1 sampai F12',
                          onSelected: _sendSpecial,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('F1..F12'),
                                Icon(Icons.arrow_drop_down, size: 18),
                              ],
                            ),
                          ),
                          itemBuilder: (context) => [
                            for (final key in mousepadFunctionKeys)
                              PopupMenuItem(
                                value: key.code,
                                child: Text(key.label),
                              ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final key in mousepadArrowKeys)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: IconButton.filledTonal(
                              tooltip: key.label,
                              icon: Icon(switch (key.code) {
                                4 => Icons.arrow_back,
                                5 => Icons.arrow_upward,
                                6 => Icons.arrow_forward,
                                _ => Icons.arrow_downward,
                              }),
                              onPressed: () => _sendSpecial(key.code),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Tombol panah dan tombol khusus memakai tabel tombol '
                      'yang sama dengan aplikasi KDE Connect bawaan.',
                      style: TextStyle(fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
        );
      },
    );
  }
}
