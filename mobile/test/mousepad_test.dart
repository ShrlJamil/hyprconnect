//! M4 unit tests: mousepad packet shapes against the daemon's
//! handle_mousepad (src/main.rs) — every field name and every
//! special-key code comes from that table, not from a guess.

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';

void main() {
  group('mousepadMove / mousepadScroll', () {
    test('move carries dx/dy and nothing else', () {
      final packet = mousepadMove(12.5, -3.0);
      expect(packet.type, 'kdeconnect.mousepad.request');
      expect(packet.body['dx'], 12.5);
      expect(packet.body['dy'], -3.0);
      expect(packet.body.containsKey('scroll'), isFalse);
    });

    test('scroll flags scroll and keeps the deltas', () {
      final packet = mousepadScroll(0.0, -20.0);
      expect(packet.body['scroll'], isTrue);
      expect(packet.body['dx'], 0.0);
      expect(packet.body['dy'], -20.0);
    });

    test('non-finite deltas are refused', () {
      expect(() => mousepadMove(double.nan, 0), throwsArgumentError);
      expect(() => mousepadScroll(0, double.infinity), throwsArgumentError);
    });
  });

  group('mousepadClick / mousepadHold', () {
    test('each click variant sets its own field', () {
      expect(
        mousepadClick(MousepadClick.left).body,
        {'singleclick': true},
      );
      expect(
        mousepadClick(MousepadClick.doubleLeft).body,
        {'doubleclick': true},
      );
      expect(
        mousepadClick(MousepadClick.right).body,
        {'rightclick': true},
      );
      expect(
        mousepadClick(MousepadClick.middle).body,
        {'middleclick': true},
      );
    });

    test('hold down and release', () {
      expect(mousepadHold(true).body, {'singlehold': true});
      expect(mousepadHold(false).body, {'singlerelease': true});
    });
  });

  group('mousepadKey / mousepadType', () {
    test('one character, no modifiers by default', () {
      final packet = mousepadKey('a');
      expect(packet.body, {'key': 'a'});
    });

    test('modifiers ride along only when on', () {
      final packet = mousepadKey(
        'c',
        const MousepadModifiers(ctrl: true, shift: true),
      );
      expect(packet.body['key'], 'c');
      expect(packet.body['ctrl'], isTrue);
      expect(packet.body['shift'], isTrue);
      expect(packet.body.containsKey('alt'), isFalse);
      expect(packet.body.containsKey('super'), isFalse);
    });

    test('super modifier is spelled super, like the daemon reads it', () {
      final packet = mousepadKey(
        'l',
        const MousepadModifiers(superKey: true),
      );
      expect(packet.body['super'], isTrue);
    });

    test('key must be exactly one character', () {
      expect(() => mousepadKey(''), throwsArgumentError);
      expect(() => mousepadKey('ab'), throwsArgumentError);
    });

    test('type sends a whole string in one key field', () {
      expect(mousepadType('halo dunia').body, {'key': 'halo dunia'});
      expect(() => mousepadType(''), throwsArgumentError);
    });
  });

  group('mousepadSpecialKey', () {
    test('codes match the daemon table', () {
      expect(mousepadSpecialKey(1).body['specialKey'], 1);
      expect(mousepadSpecialKey(12).body['specialKey'], 12);
      expect(mousepadSpecialKey(14).body['specialKey'], 14);
      expect(mousepadSpecialKey(21).body['specialKey'], 21);
      expect(mousepadSpecialKey(32).body['specialKey'], 32);
    });

    test('modifiers combine with a special key', () {
      final packet = mousepadSpecialKey(
        9,
        const MousepadModifiers(ctrl: true),
      );
      expect(packet.body['specialKey'], 9);
      expect(packet.body['ctrl'], isTrue);
    });

    test('codes outside 1..32 are refused (daemon would only log them)',
        () {
      expect(() => mousepadSpecialKey(0), throwsArgumentError);
      expect(() => mousepadSpecialKey(33), throwsArgumentError);
      expect(() => mousepadSpecialKey(999), throwsArgumentError);
    });

    test('labels cover the table the UI shows', () {
      expect(specialKeyLabel(1), 'Backspace');
      expect(specialKeyLabel(2), 'Tab');
      expect(specialKeyLabel(4), 'Kiri');
      expect(specialKeyLabel(5), 'Atas');
      expect(specialKeyLabel(6), 'Kanan');
      expect(specialKeyLabel(7), 'Bawah');
      expect(specialKeyLabel(12), 'Enter');
      expect(specialKeyLabel(14), 'Esc');
      expect(specialKeyLabel(21), 'F1');
      expect(specialKeyLabel(32), 'F12');
      expect(specialKeyLabel(0), isNull);
      expect(specialKeyLabel(99), isNull);
    });
  });
}
