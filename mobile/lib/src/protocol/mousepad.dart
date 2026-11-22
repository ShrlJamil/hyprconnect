//! Remote input (kdeconnect.mousepad.request). Wire rules read from the
//! daemon (src/main.rs handle_mousepad, special_key_evdev, char_key):
//!
//! - Pointer motion: {"dx": <double>, "dy": <double>}. The daemon
//!   accumulates deltas and flushes them to its virtual pointer at
//!   ~120 Hz, so a burst of small packets becomes smooth motion.
//!   Absolute {"x", "y"} packets are NOT supported (the daemon logs it
//!   once and ignores them), so this app never sends them.
//! - Scroll: {"scroll": true, "dx": ..., "dy": ...} (same deltas,
//!   routed to the pointer's scroll axis instead of motion).
//! - Buttons: {"singleclick": true} (left), {"doubleclick": true},
//!   {"rightclick": true}, {"middleclick": true};
//!   {"singlehold": true} presses the left button down and
//!   {"singlerelease": true} lets it up again (drag while held).
//! - Printable key: {"key": "<one character>"} — the daemon maps it
//!   through a US-layout evdev table (letters, digits, common
//!   punctuation; uppercase takes Shift, which it adds itself). A
//!   character the table does not know, sent with no modifiers, is
//!   typed wholesale with `ydotool type` instead; with modifiers it
//!   is silently ignored by the daemon.
//! - Longer text: {"key": "<string>"} with no modifiers is typed
//!   wholesale with `ydotool type`.
//! - Special key: {"specialKey": <code>} — 1 Backspace, 2 Tab,
//!   3 LineFeed, 4 Left, 5 Up, 6 Right, 7 Down, 8 PageUp, 9 PageDown,
//!   10 Home, 11 End, 12 Enter, 13 Delete, 14 Esc, 15 SysRq,
//!   16 ScrollLock, 17 LeftCtrl, 18 LeftAlt, 19 LeftShift, 20 LeftMeta,
//!   21..32 F1..F12. Any other code is logged as unknown by the daemon.
//! - Modifiers ride along as booleans: "ctrl", "alt", "shift", and
//!   "super" (the phone's name for the meta modifier; the daemon also
//!   accepts "meta"). They combine with a key or a specialKey.
//!
//! The phone's presentation remote (M5) reuses this packet type for
//! slide controls: next is specialKey 9, previous is 8.

import 'packet.dart';

/// Modifier keys held while a key or special key is sent.
class MousepadModifiers {
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool superKey;

  const MousepadModifiers({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.superKey = false,
  });

  bool get any => ctrl || alt || shift || superKey;

  /// Only the modifiers that are on (the daemon treats a missing
  /// boolean the same as false).
  Map<String, bool> toBody() {
    final body = <String, bool>{};
    if (ctrl) body['ctrl'] = true;
    if (alt) body['alt'] = true;
    if (shift) body['shift'] = true;
    if (superKey) body['super'] = true;
    return body;
  }
}

/// One special key the daemon knows, with the label the UI shows.
class MousepadSpecialKey {
  final int code;
  final String label;

  const MousepadSpecialKey(this.code, this.label);
}

/// Special keys offered as buttons on the remote input page, in
/// display order. Codes are the daemon's special_key_evdev table.
const List<MousepadSpecialKey> mousepadSpecialKeys = [
  MousepadSpecialKey(14, 'Esc'),
  MousepadSpecialKey(2, 'Tab'),
  MousepadSpecialKey(1, 'Backspace'),
  MousepadSpecialKey(13, 'Delete'),
  MousepadSpecialKey(12, 'Enter'),
  MousepadSpecialKey(10, 'Home'),
  MousepadSpecialKey(11, 'End'),
  MousepadSpecialKey(8, 'PgUp'),
  MousepadSpecialKey(9, 'PgDn'),
];

/// The four arrow keys, in display order.
const List<MousepadSpecialKey> mousepadArrowKeys = [
  MousepadSpecialKey(4, 'Kiri'),
  MousepadSpecialKey(5, 'Atas'),
  MousepadSpecialKey(7, 'Bawah'),
  MousepadSpecialKey(6, 'Kanan'),
];

/// F1..F12 (codes 21..32 in the daemon's table).
const List<MousepadSpecialKey> mousepadFunctionKeys = [
  MousepadSpecialKey(21, 'F1'),
  MousepadSpecialKey(22, 'F2'),
  MousepadSpecialKey(23, 'F3'),
  MousepadSpecialKey(24, 'F4'),
  MousepadSpecialKey(25, 'F5'),
  MousepadSpecialKey(26, 'F6'),
  MousepadSpecialKey(27, 'F7'),
  MousepadSpecialKey(28, 'F8'),
  MousepadSpecialKey(29, 'F9'),
  MousepadSpecialKey(30, 'F10'),
  MousepadSpecialKey(31, 'F11'),
  MousepadSpecialKey(32, 'F12'),
];

/// Human label for a special-key code (F-keys generated); null when
/// the daemon does not know the code.
String? specialKeyLabel(int code) {
  for (final key in mousepadSpecialKeys) {
    if (key.code == code) return key.label;
  }
  for (final key in mousepadArrowKeys) {
    if (key.code == code) return key.label;
  }
  for (final key in mousepadFunctionKeys) {
    if (key.code == code) return key.label;
  }
  return switch (code) {
    3 => 'LineFeed',
    15 => 'SysRq',
    16 => 'ScrollLock',
    17 => 'Ctrl',
    18 => 'Alt',
    19 => 'Shift',
    20 => 'Meta',
    _ => null,
  };
}

/// Which mouse button a click packet presses.
enum MousepadClick { left, doubleLeft, right, middle }

/// Move the desktop pointer by a relative delta, in layout pixels.
Packet mousepadMove(double dx, double dy) {
  if (!dx.isFinite || !dy.isFinite) {
    throw ArgumentError('dx/dy must be finite (got $dx, $dy)');
  }
  return Packet.now('kdeconnect.mousepad.request', {'dx': dx, 'dy': dy});
}

/// Scroll by a relative delta (positive dy scrolls down, like a
/// two-finger drag on the stock app).
Packet mousepadScroll(double dx, double dy) {
  if (!dx.isFinite || !dy.isFinite) {
    throw ArgumentError('dx/dy must be finite (got $dx, $dy)');
  }
  return Packet.now('kdeconnect.mousepad.request', {
    'scroll': true,
    'dx': dx,
    'dy': dy,
  });
}

/// Click one mouse button (left, double left, right, middle).
Packet mousepadClick(MousepadClick click) {
  final field = switch (click) {
    MousepadClick.left => 'singleclick',
    MousepadClick.doubleLeft => 'doubleclick',
    MousepadClick.right => 'rightclick',
    MousepadClick.middle => 'middleclick',
  };
  return Packet.now('kdeconnect.mousepad.request', {field: true});
}

/// Press the left button down (true) or let it up again (false),
/// for dragging while the touchpad is held.
Packet mousepadHold(bool down) {
  return Packet.now('kdeconnect.mousepad.request', {
    down ? 'singlehold' : 'singlerelease': true,
  });
}

/// Type one printable character, with optional modifiers. The
/// character must be exactly one character long; longer text goes
/// through [mousepadType].
Packet mousepadKey(
  String char, [
  MousepadModifiers modifiers = const MousepadModifiers(),
]) {
  if (char.length != 1) {
    throw ArgumentError('key must be exactly one character (got "$char")');
  }
  return Packet.now('kdeconnect.mousepad.request', {
    'key': char,
    ...modifiers.toBody(),
  });
}

/// Type a whole string at once (the daemon runs `ydotool type`).
/// Modifiers are not accepted here: the daemon only types a string
/// when no modifier is set.
Packet mousepadType(String text) {
  if (text.isEmpty) {
    throw ArgumentError('cannot type an empty string');
  }
  return Packet.now('kdeconnect.mousepad.request', {'key': text});
}

/// Press one special key (see the table at the top of this file),
/// with optional modifiers. Codes outside 1..32 are refused: the
/// daemon would only log them as unknown.
Packet mousepadSpecialKey(
  int code, [
  MousepadModifiers modifiers = const MousepadModifiers(),
]) {
  if (code < 1 || code > 32) {
    throw ArgumentError('unknown specialKey $code (daemon only knows 1..32)');
  }
  return Packet.now('kdeconnect.mousepad.request', {
    'specialKey': code,
    ...modifiers.toBody(),
  });
}
