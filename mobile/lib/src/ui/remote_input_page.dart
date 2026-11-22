//! M4 rework: remote input shaped like the stock KDE Connect app's
//! page (his screenshots, 2026-11-22): a full-screen touchpad with
//! the usage text in the middle, a mouse-buttons row at the bottom
//! (left, middle, right), and the send-text and settings behind the
//! app bar actions instead of stacked below the pad. The keyboard
//! action shows the soft keyboard right on this page (his call,
//! 2026-11-22): a slim typing field plus the extra keys appear above
//! the buttons row, no separate page.
//!
//! Gestures follow the stock app and the per-device preferences
//! (remote_input_prefs.dart): one finger drags the pointer, two
//! fingers scroll, a tap with one/two/three fingers fires the
//! configured click, a double tap starts a drag when that behaviour
//! is on (press on the second tap, move, release), and holding the
//! on-screen left button while dragging with another finger drags
//! too. The gyro mouse, when enabled, tilts the pointer.
//!
//! The pad tracks raw pointer events on purpose: the multi-finger
//! tap/scroll decisions need every pointer, which a GestureDetector
//! arena would fight over.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

import 'package:sensors_plus/sensors_plus.dart';

import '../protocol/protocol.dart';
import '../settings/remote_input_prefs.dart';
import 'app_state.dart';
import 'remote_input_settings_page.dart';
import 'send_text_page.dart';

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
  static const _doubleTapWindowMs = 350;

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;
  RemoteInputPrefs get _prefs => _appState.remoteInputPrefsFor(_entry.deviceId);

  // ---- touch sequence state (valid while at least one pointer is
  // down on the pad) ----
  final Map<int, Offset> _pointers = {};
  int? _primaryId;
  Offset? _lastPrimaryPos;
  Offset? _centroid;
  DateTime? _seqDownAt;
  int _maxPointers = 0;
  double _movedTotal = 0;
  bool _dragging = false;
  bool _scrolled = false;
  bool _dragHold = false;
  bool _secondTap = false;
  DateTime? _lastTapEnd;
  Timer? _pendingTapTimer;

  // ---- gyro mouse ----
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gyroFactor = 100;

  // ---- inline keyboard (shown by the app bar keyboard action) ----
  final _typeController = TextEditingController();
  final _focusNode = FocusNode();
  bool _keyboardOpen = false;
  bool _ctrl = false;
  bool _alt = false;
  bool _shift = false;
  bool _super = false;

  /// Text already sent to the desktop, for diffing field edits.
  String _sentText = '';

  MousepadModifiers get _modifiers => MousepadModifiers(
    ctrl: _ctrl,
    alt: _alt,
    shift: _shift,
    superKey: _super,
  );

  void _toggleKeyboard() {
    setState(() => _keyboardOpen = !_keyboardOpen);
    if (_keyboardOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    } else {
      _focusNode.unfocus();
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

  /// The extra-keys panel shown above the buttons row while the
  /// soft keyboard is up: the typing field, the modifier chips, and
  /// one horizontally scrolling row of special keys, the F1..F12
  /// menu, and the arrow keys.
  Widget _keyboardPanel(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('type-field'),
                  controller: _typeController,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    labelText: context.l10n.typeHere,
                    hintText: context.l10n.typeFieldHint,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onChanged: _onTyped,
                ),
              ),
              IconButton(
                tooltip: context.l10n.pasteFromClipboard,
                icon: const Icon(Icons.content_paste),
                onPressed: _pasteClipboard,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _modifierChip('Ctrl', _ctrl, (v) => _ctrl = v),
              const SizedBox(width: 6),
              _modifierChip('Alt', _alt, (v) => _alt = v),
              const SizedBox(width: 6),
              _modifierChip('Shift', _shift, (v) => _shift = v),
              const SizedBox(width: 6),
              _modifierChip('Super', _super, (v) => _super = v),
            ],
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final key in mousepadSpecialKeys)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: OutlinedButton(
                      onPressed: () => _sendSpecial(key.code),
                      child: Text(key.label),
                    ),
                  ),
                PopupMenuButton<int>(
                  tooltip: context.l10n.functionKeys,
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
                      PopupMenuItem(value: key.code, child: Text(key.label)),
                  ],
                ),
                const SizedBox(width: 6),
                for (final key in mousepadArrowKeys)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
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
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pendingTapTimer?.cancel();
    _gyroSub?.cancel();
    _typeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _cancelPendingTap() {
    _pendingTapTimer?.cancel();
    _pendingTapTimer = null;
  }

  /// Fire a left click that was held back for the double-tap window.
  void _firePendingTap() {
    _cancelPendingTap();
    _appState.sendMousepadClick(_entry.deviceId, MousepadClick.left);
  }

  void _syncGyro(RemoteInputPrefs prefs) {
    _gyroFactor = prefs.gyroFactor;
    if (prefs.gyroEnabled && _gyroSub == null) {
      _gyroSub = gyroscopeEventStream().listen((event) {
        if (!mounted) return;
        const deadzone = 0.08;
        final dx = event.y.abs() > deadzone
            ? -event.y * _gyroFactor * 0.05
            : 0.0;
        final dy = event.x.abs() > deadzone
            ? -event.x * _gyroFactor * 0.05
            : 0.0;
        if (dx != 0 || dy != 0) {
          _appState.sendMousepadMove(_entry.deviceId, dx, dy);
        }
      });
    } else if (!prefs.gyroEnabled && _gyroSub != null) {
      _gyroSub?.cancel();
      _gyroSub = null;
    }
  }

  Offset _currentCentroid() {
    var sum = Offset.zero;
    for (final pos in _pointers.values) {
      sum += pos;
    }
    return sum / _pointers.length.toDouble();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      final now = DateTime.now();
      _seqDownAt = now;
      _maxPointers = 1;
      _movedTotal = 0;
      _dragging = false;
      _scrolled = false;
      _dragHold = false;
      final prefs = _prefs;
      _secondTap =
          prefs.doubleTapDrag &&
          prefs.tapOne == TapAction.left &&
          _lastTapEnd != null &&
          now.difference(_lastTapEnd!).inMilliseconds <= _doubleTapWindowMs;
      if (_secondTap) {
        // The held-back click belongs to a drag or a double click
        // now, not to a single tap.
        _cancelPendingTap();
      } else if (_pendingTapTimer != null) {
        _firePendingTap();
      }
      _primaryId = event.pointer;
      _lastPrimaryPos = event.position;
    }
    _pointers[event.pointer] = event.position;
    _maxPointers = math.max(_maxPointers, _pointers.length);
    if (_pointers.length == 2) {
      _centroid = _currentCentroid();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    final prefs = _prefs;
    if (_pointers.length == 1 && event.pointer == _primaryId) {
      final last = _lastPrimaryPos;
      if (last == null) return;
      final delta = event.position - last;
      _lastPrimaryPos = event.position;
      _movedTotal += delta.distance;
      if (_movedTotal <= _tapSlop) return;
      if (_secondTap && !_dragHold) {
        _appState.sendMousepadHold(_entry.deviceId, true);
        _dragHold = true;
      }
      _dragging = true;
      final speedGain =
          1 + prefs.acceleration.gain * math.min(delta.distance / 24, 1.5);
      final gain = prefs.sensitivity.factor * speedGain;
      _appState.sendMousepadMove(
        _entry.deviceId,
        delta.dx * gain,
        delta.dy * gain,
      );
    } else if (_pointers.length == 2 && !_dragHold) {
      final centroid = _currentCentroid();
      final last = _centroid;
      _centroid = centroid;
      if (last == null) return;
      final delta = centroid - last;
      if (delta == Offset.zero) return;
      _scrolled = true;
      final sign = prefs.reverseScroll ? -1.0 : 1.0;
      _appState.sendMousepadScroll(
        _entry.deviceId,
        delta.dx * prefs.scrollFactor * sign,
        delta.dy * prefs.scrollFactor * sign,
      );
    }
  }

  void _endSequence({required bool cancelled}) {
    if (_dragHold) {
      _appState.sendMousepadHold(_entry.deviceId, false);
      _dragHold = false;
      _lastTapEnd = null;
    } else if (!cancelled && !_dragging && !_scrolled) {
      final downAt = _seqDownAt;
      final quick =
          downAt != null &&
          DateTime.now().difference(downAt).inMilliseconds <= _tapMaxMs &&
          _movedTotal <= _tapSlop;
      if (quick) {
        if (_maxPointers == 1 && _secondTap) {
          _appState.sendMousepadClick(
            _entry.deviceId,
            MousepadClick.doubleLeft,
          );
          _lastTapEnd = null;
        } else {
          final prefs = _prefs;
          final action = switch (_maxPointers) {
            1 => prefs.tapOne,
            2 => prefs.tapTwo,
            3 => prefs.tapThree,
            _ => TapAction.none,
          };
          final click = switch (action) {
            TapAction.left => MousepadClick.left,
            TapAction.right => MousepadClick.right,
            TapAction.middle => MousepadClick.middle,
            TapAction.none => null,
          };
          if (click != null) {
            if (_maxPointers == 1 &&
                action == TapAction.left &&
                prefs.doubleTapDrag) {
              // Hold the click back for the double-tap window: a
              // second tap turns it into a double click or a drag.
              _cancelPendingTap();
              _pendingTapTimer = Timer(
                const Duration(milliseconds: _doubleTapWindowMs),
                () {
                  _pendingTapTimer = null;
                  if (!mounted) return;
                  _appState.sendMousepadClick(
                    _entry.deviceId,
                    MousepadClick.left,
                  );
                },
              );
              _lastTapEnd = DateTime.now();
            } else {
              _appState.sendMousepadClick(_entry.deviceId, click);
              _lastTapEnd = null;
            }
          } else {
            _lastTapEnd = null;
          }
        }
      } else {
        _lastTapEnd = null;
      }
    } else {
      _lastTapEnd = null;
    }
    _seqDownAt = null;
    _maxPointers = 0;
    _movedTotal = 0;
    _dragging = false;
    _scrolled = false;
    _secondTap = false;
    _primaryId = null;
    _lastPrimaryPos = null;
    _centroid = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) {
      if (event.pointer == _primaryId) {
        _primaryId = _pointers.keys.first;
        _lastPrimaryPos = _pointers[_primaryId];
      }
      _centroid = _currentCentroid();
      return;
    }
    _endSequence(cancelled: false);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) {
      _endSequence(cancelled: true);
    }
  }

  Widget _mouseButton({
    required Key key,
    required int flex,
    required bool filled,
    required Widget icon,
    GestureTapDownCallback? onTapDown,
    GestureTapUpCallback? onTapUp,
    GestureTapCancelCallback? onTapCancel,
    GestureTapCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      flex: flex,
      child: Material(
        key: key,
        color: filled ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTapDown: onTapDown,
          onTapUp: onTapUp,
          onTapCancel: onTapCancel,
          onTap: onTap,
          child: SizedBox(height: 72, child: Center(child: icon)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final conn = _appState.connectionFor(_entry.deviceId);
        final prefs = _prefs;
        _syncGyro(prefs);
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.pluginRemoteInputTile),
                Text(_entry.name, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            actions: [
              IconButton(
                tooltip: context.l10n.keyboard,
                icon: const Icon(Icons.keyboard),
                isSelected: _keyboardOpen,
                onPressed: conn == null ? null : _toggleKeyboard,
              ),
              IconButton(
                tooltip: context.l10n.sendText,
                icon: const Icon(Icons.edit_note),
                onPressed: conn == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              SendTextPage(appState: _appState, entry: _entry),
                        ),
                      ),
              ),
              IconButton(
                tooltip: context.l10n.remoteInputSettingsTitle,
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RemoteInputSettingsPage(
                      appState: _appState,
                      entry: _entry,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: conn == null
              ? Center(child: Text(context.l10n.noConnection))
              : Column(
                  children: [
                    Expanded(
                      child: Listener(
                        key: const ValueKey('touchpad'),
                        onPointerDown: _onPointerDown,
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerUp,
                        onPointerCancel: _onPointerCancel,
                        child: Container(
                          color: Colors.transparent,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            context.l10n.touchpadHint,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                    ),
                    if (_keyboardOpen) _keyboardPanel(context),
                    if (prefs.showMouseButtons)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                        child: Row(
                          children: [
                            _mouseButton(
                              key: const ValueKey('mouse-left'),
                              flex: 11,
                              filled: true,
                              icon: Icon(
                                Icons.near_me,
                                color: scheme.onPrimary,
                              ),
                              onTapDown: (_) => _appState.sendMousepadHold(
                                _entry.deviceId,
                                true,
                              ),
                              onTapUp: (_) => _appState.sendMousepadHold(
                                _entry.deviceId,
                                false,
                              ),
                              onTapCancel: () => _appState.sendMousepadHold(
                                _entry.deviceId,
                                false,
                              ),
                            ),
                            const SizedBox(width: 10),
                            _mouseButton(
                              key: const ValueKey('mouse-middle'),
                              flex: 5,
                              filled: false,
                              icon: Icon(
                                Icons.adjust,
                                color: scheme.onSurfaceVariant,
                              ),
                              onTap: () => _appState.sendMousepadClick(
                                _entry.deviceId,
                                MousepadClick.middle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            _mouseButton(
                              key: const ValueKey('mouse-right'),
                              flex: 11,
                              filled: true,
                              icon: Transform.flip(
                                flipX: true,
                                child: Icon(
                                  Icons.near_me,
                                  color: scheme.onPrimary,
                                ),
                              ),
                              onTap: () => _appState.sendMousepadClick(
                                _entry.deviceId,
                                MousepadClick.right,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
