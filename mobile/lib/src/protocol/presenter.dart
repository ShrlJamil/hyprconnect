//! Presentation remote (kdeconnect.presenter). Wire rules read from the
//! daemon (src/main.rs handle_presenter) and the stock Android app
//! (ref-kdeconnect-android PresenterPlugin / PresenterActivity):
//!
//! - Pointer: {"dx": <double>, "dy": <double>} — fractions of the
//!   session monitor (the daemon clamps the dot to 0..1 and scales dy
//!   by the monitor's width/height ratio). The first delta starts a
//!   session and shows the dot; no delta for 3 seconds times it out.
//! - Stop: {"stop": true} ends the session and hides the dot. The
//!   page sends it when leaving, and the daemon also times out.
//! - Slide controls are NOT presenter packets: the stock app sends
//!   them as kdeconnect.mousepad.request specialKeys — next is 9
//!   (PageDown), previous is 8 (PageUp), fullscreen is 25 (F5),
//!   exit is 14 (Esc). Zoom is a ctrl-modified "+" / "-" key packet.
//!   Those builders live in mousepad.dart; the constants below only
//!   name the codes the presenter page uses.
//! - Gyro: the stock activity sends dx = -gyroZ * sensitivity and
//!   dy = -gyroX * sensitivity, sensitivity 0.036 at the default
//!   preference (50). [gyroToPresenterDelta] is that exact mapping,
//!   so holding the phone like the stock app moves the dot the same
//!   way. Drag on the pointer pad sends the same packet with the
//!   drag delta as a fraction of the pad.
//! - Monitor extension (HyprConnect daemon only, additive): the app
//!   may ask for the monitor list ({"requestMonitorList": true}) or
//!   pin the pointer to one monitor ({"setMonitor": "<name>"}, "" for
//!   automatic). The daemon answers with a kdeconnect.presenter
//!   packet carrying "monitors" and "presenterMonitor". A stock
//!   kdeconnectd never answers, so the page degrades gracefully:
//!   pointer and slides still work, the picker just stays hidden.

import 'packet.dart';

/// Special-key codes the presenter page sends for slide controls
/// (daemon's special_key_evdev table, same as the stock app).
class PresenterKeys {
  static const int previous = 8; // PageUp
  static const int next = 9; // PageDown
  static const int fullscreen = 25; // F5
  static const int escape = 14; // Esc
}

/// Gyro sensitivity the stock app uses at its default preference
/// (50): ((50 + 10) / 100 / 10) * (6 / 10) = 0.036.
const double presenterGyroSensitivity = 0.036;

/// Map one gyroscope reading (rad/s, Android axes) to a presenter
/// pointer delta, exactly like the stock PresenterActivity:
/// dx = -gyroZ * sensitivity, dy = -gyroX * sensitivity.
({double dx, double dy}) gyroToPresenterDelta(
  double gyroX,
  double gyroZ, [
  double sensitivity = presenterGyroSensitivity,
]) {
  return (dx: -gyroZ * sensitivity, dy: -gyroX * sensitivity);
}

/// The sensor interval the stock sensitivity formula assumes:
/// the stock app listens at Android's game rate, one reading per
/// 20 ms, and folds each reading straight into a packet.
const double presenterReferenceIntervalSeconds = 0.02;

/// Scale one reading's delta by the interval the reading actually
/// covers, relative to the reference interval. Without this the
/// pointer speed (and chunkiness) depends on how fast the sensor
/// delivers: at the 200 ms default interval the stock formula
/// moves the dot in five huge steps per second and crawls. The
/// interval is clamped to 100 ms so a stall (or a fresh hold)
/// cannot make the dot leap.
({double dx, double dy}) scalePresenterDelta(
  ({double dx, double dy}) delta,
  double dtSeconds,
) {
  if (!dtSeconds.isFinite || dtSeconds <= 0) return (dx: 0, dy: 0);
  final clamped = dtSeconds > 0.1 ? 0.1 : dtSeconds;
  final k = clamped / presenterReferenceIntervalSeconds;
  return (dx: delta.dx * k, dy: delta.dy * k);
}

/// Move the presenter dot by a relative delta (fractions of the
/// session monitor). The first delta starts the session.
Packet presenterMove(double dx, double dy) {
  if (!dx.isFinite || !dy.isFinite) {
    throw ArgumentError('dx/dy must be finite (got $dx, $dy)');
  }
  return Packet.now('kdeconnect.presenter', {'dx': dx, 'dy': dy});
}

/// End the presenter session and hide the dot.
Packet presenterStop() {
  return Packet.now('kdeconnect.presenter', {'stop': true});
}

/// Ask the desktop for its monitor list (HyprConnect extension).
/// The answer is a kdeconnect.presenter packet with "monitors" and
/// "presenterMonitor"; a stock desktop never answers.
Packet presenterRequestMonitorList() {
  return Packet.now('kdeconnect.presenter', {'requestMonitorList': true});
}

/// Pin the presenter pointer to one monitor (HyprConnect extension).
/// Null (sent as "") means automatic: the daemon picks a non-laptop
/// monitor, else the focused one. The daemon answers with the
/// updated monitor list packet.
Packet presenterSetMonitor(String? monitor) {
  return Packet.now('kdeconnect.presenter', {'setMonitor': monitor ?? ''});
}

/// The monitor list a desktop reported, parsed from a
/// kdeconnect.presenter reply packet. Null when the packet is not a
/// monitor-list reply (a plain pointer packet, for example).
class PresenterMonitorList {
  /// Connected monitor names, in the desktop's order.
  final List<String> monitors;

  /// The monitor the presenter pointer is pinned to, or null for
  /// automatic (also null when the desktop did not say).
  final String? presenterMonitor;

  const PresenterMonitorList({
    required this.monitors,
    required this.presenterMonitor,
  });

  static PresenterMonitorList? fromPacket(Packet packet) {
    if (packet.type != 'kdeconnect.presenter') return null;
    final raw = packet.body['monitors'];
    if (raw is! List) return null;
    return PresenterMonitorList(
      monitors: raw.whereType<String>().toList(),
      presenterMonitor: packet.body['presenterMonitor'] as String?,
    );
  }
}
