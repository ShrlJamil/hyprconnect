//! Widget tests for the M1 shell: device page tiles and menu,
//! plugin settings toggling, encryption info page.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';
import 'package:hyprconnect_mobile/src/ui/app_state.dart';
import 'package:hyprconnect_mobile/src/ui/device_page.dart';
import 'package:hyprconnect_mobile/src/ui/encryption_info_page.dart';
import 'package:hyprconnect_mobile/src/ui/plugin_settings_page.dart';

const _deviceId = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

DeviceListEntry _entry({bool online = true}) {
  return DeviceListEntry(
    deviceId: _deviceId,
    name: 'Desktop Tes',
    deviceType: 'desktop',
    address: online ? InternetAddress('192.168.1.2') : null,
    tcpPort: online ? 1714 : null,
    online: online,
    trusted: false,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(home: child);
}

void main() {
  testWidgets('device page shows six tiles and a connect button',
      (tester) async {
    final state = AppState.test(
      settings: PluginSettings.inMemory(),
    );
    await tester.pumpWidget(
      _wrap(DevicePage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Desktop Tes'), findsWidgets);
    expect(find.text('Hubungkan'), findsOneWidget);
    for (final title in [
      'Kirim file',
      'Kirim papan klip',
      'Presentation remote',
      'Kendali multimedia',
      'Masukan jarak jauh',
      'Jalankan Perintah',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.byTooltip('Menu perangkat'), findsOneWidget);
  });

  testWidgets('three-dot menu lists ping, plugins, encryption, unpair',
      (tester) async {
    final state = AppState.test(
      settings: PluginSettings.inMemory(),
    );
    await tester.pumpWidget(
      _wrap(DevicePage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Menu perangkat'));
    await tester.pumpAndSettle();

    expect(find.text('Kirim ping'), findsOneWidget);
    expect(find.text('Pengesetan plugin'), findsOneWidget);
    expect(find.text('Info Enkripsi'), findsOneWidget);
    expect(find.text('Leraikan'), findsOneWidget);
  });

  testWidgets('tapping a tile while unpaired explains pairing is needed',
      (tester) async {
    final state = AppState.test(
      settings: PluginSettings.inMemory(),
    );
    await tester.pumpWidget(
      _wrap(DevicePage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kirim file'));
    await tester.pump();

    expect(find.textContaining('Pair dulu'), findsOneWidget);
  });

  testWidgets(
      'switching a plugin off greys out its tile and persists the choice',
      (tester) async {
    final settings = PluginSettings.inMemory();
    final state = AppState.test(settings: settings);
    final entry = _entry();

    await tester.pumpWidget(
      _wrap(PluginSettingsPage(appState: state, entry: entry)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Kirim file'), findsOneWidget);
    await tester.tap(find.text('Kirim file'));
    await tester.pump();
    expect(settings.isEnabled(_deviceId, 'share'), isFalse);

    await tester.pumpWidget(
      _wrap(DevicePage(appState: state, entry: entry)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Plugin nonaktif'), findsOneWidget);
  });

  testWidgets('encryption info page shows peer id and no-connection state',
      (tester) async {
    final state = AppState.test(
      settings: PluginSettings.inMemory(),
    );
    await tester.pumpWidget(
      _wrap(EncryptionInfoPage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Info Enkripsi'), findsOneWidget);
    expect(find.text('Belum terhubung'), findsOneWidget);
    expect(find.text('Kunci verifikasi'), findsOneWidget);
  });
}
