import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/settings/app_prefs.dart';

void main() {
  group('AppPrefs', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('app_prefs_test');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('defaults when no file exists', () async {
      final prefs = await AppPrefs.load(dir);
      expect(prefs.themeMode, ThemeMode.system);
      expect(prefs.manualAddresses, isEmpty);
      expect(prefs.setupComplete, isFalse);
    });

    test('round-trips theme, manual addresses and setup flag', () async {
      final prefs = await AppPrefs.load(dir);
      await prefs.setThemeMode(ThemeMode.dark);
      await prefs.addManualAddress('192.168.1.10');
      await prefs.addManualAddress('192.168.1.10');
      await prefs.addManualAddress('10.0.0.5');
      await prefs.markSetupComplete();

      final reloaded = await AppPrefs.load(dir);
      expect(reloaded.themeMode, ThemeMode.dark);
      expect(reloaded.manualAddresses, ['192.168.1.10', '10.0.0.5']);
      expect(reloaded.setupComplete, isTrue);

      await reloaded.removeManualAddress('192.168.1.10');
      final again = await AppPrefs.load(dir);
      expect(again.manualAddresses, ['10.0.0.5']);
    });

    test('a corrupt file falls back to defaults', () async {
      await File('${dir.path}/app_prefs.json').writeAsString('not json');
      final prefs = await AppPrefs.load(dir);
      expect(prefs.themeMode, ThemeMode.system);
      expect(prefs.manualAddresses, isEmpty);
      expect(prefs.setupComplete, isFalse);
    });
  });
}
