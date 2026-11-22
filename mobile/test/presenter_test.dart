//! M5 unit tests: presenter packet shapes, monitor-list parsing, and
//! the gyro mapping — all against the daemon source and the stock
//! Android app, never guessed.

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

void main() {
  group('presenter packets', () {
    test('move carries dx/dy as doubles on kdeconnect.presenter', () {
      final packet = presenterMove(0.02, -0.03);
      expect(packet.type, 'kdeconnect.presenter');
      expect(packet.body['dx'], 0.02);
      expect(packet.body['dy'], -0.03);
      expect(packet.body.containsKey('stop'), isFalse);
    });

    test('move rejects non-finite deltas', () {
      expect(() => presenterMove(double.nan, 0), throwsArgumentError);
      expect(() => presenterMove(0, double.infinity), throwsArgumentError);
    });

    test('stop is exactly {"stop": true}', () {
      final packet = presenterStop();
      expect(packet.type, 'kdeconnect.presenter');
      expect(packet.body, {'stop': true});
    });

    test('monitor list request is exactly the extension field', () {
      final packet = presenterRequestMonitorList();
      expect(packet.type, 'kdeconnect.presenter');
      expect(packet.body, {'requestMonitorList': true});
    });

    test('set monitor sends the name; null sends "" for automatic', () {
      expect(
        presenterSetMonitor('DP-1').body,
        {'setMonitor': 'DP-1'},
      );
      expect(presenterSetMonitor(null).body, {'setMonitor': ''});
    });
  });

  group('slide controls reuse the stock mousepad specialKeys', () {
    test('next is 9 (PageDown), previous 8 (PageUp)', () {
      expect(PresenterKeys.next, 9);
      expect(PresenterKeys.previous, 8);
      expect(
        mousepadSpecialKey(PresenterKeys.next).body,
        {'specialKey': 9},
      );
      expect(
        mousepadSpecialKey(PresenterKeys.previous).body,
        {'specialKey': 8},
      );
    });

    test('fullscreen is 25 (F5), exit is 14 (Esc)', () {
      expect(PresenterKeys.fullscreen, 25);
      expect(PresenterKeys.escape, 14);
      expect(
        mousepadSpecialKey(PresenterKeys.fullscreen).body,
        {'specialKey': 25},
      );
      expect(
        mousepadSpecialKey(PresenterKeys.escape).body,
        {'specialKey': 14},
      );
    });
  });

  group('gyro mapping matches the stock PresenterActivity', () {
    test('default sensitivity is the stock default 0.036', () {
      expect(presenterGyroSensitivity, 0.036);
    });

    test('dx = -gyroZ * s, dy = -gyroX * s', () {
      final d = gyroToPresenterDelta(0.5, -1.0);
      expect(d.dx, closeTo(0.036, 1e-9));
      expect(d.dy, closeTo(-0.018, 1e-9));
    });

    test('no rotation means no delta', () {
      final d = gyroToPresenterDelta(0, 0);
      expect(d.dx, 0);
      expect(d.dy, 0);
    });
  });

  group('monitor list replies', () {
    test('parses monitors and the pinned monitor', () {
      final list = PresenterMonitorList.fromPacket(
        Packet.now('kdeconnect.presenter', {
          'monitors': ['eDP-1', 'DP-1'],
          'presenterMonitor': 'DP-1',
        }),
      );
      expect(list, isNotNull);
      expect(list!.monitors, ['eDP-1', 'DP-1']);
      expect(list.presenterMonitor, 'DP-1');
    });

    test('null presenterMonitor means automatic', () {
      final list = PresenterMonitorList.fromPacket(
        Packet.now('kdeconnect.presenter', {
          'monitors': ['eDP-1'],
          'presenterMonitor': null,
        }),
      );
      expect(list!.presenterMonitor, isNull);
    });

    test('a plain pointer packet is not a monitor list', () {
      expect(
        PresenterMonitorList.fromPacket(presenterMove(0.01, 0.01)),
        isNull,
      );
      expect(PresenterMonitorList.fromPacket(presenterStop()), isNull);
    });

    test('other packet types are ignored', () {
      expect(
        PresenterMonitorList.fromPacket(
          Packet.now('kdeconnect.ping', {
            'monitors': ['eDP-1'],
          }),
        ),
        isNull,
      );
    });

    test('non-string monitor entries are dropped', () {
      final list = PresenterMonitorList.fromPacket(
        Packet.now('kdeconnect.presenter', {
          'monitors': ['eDP-1', 7, null],
          'presenterMonitor': null,
        }),
      );
      expect(list!.monitors, ['eDP-1']);
    });
  });
}
