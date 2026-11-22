//! Widget tests for the M2 clipboard page: empty send is refused,
//! paste fills the field from the system clipboard, and a clipboard
//! packet received from the peer shows up as "last received" (and is
//! written to the system clipboard).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/protocol.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';
import 'package:hyprconnect_mobile/src/ui/app_state.dart';
import 'package:hyprconnect_mobile/src/ui/clipboard_page.dart';

const _deviceId = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

DeviceListEntry _entry() {
  return DeviceListEntry(
    deviceId: _deviceId,
    name: 'Desktop Tes',
    deviceType: 'desktop',
    address: InternetAddress('192.168.1.2'),
    tcpPort: 1714,
    online: true,
    trusted: true,
  );
}

void main() {
  testWidgets('empty send is refused, paste fills, no connection noted',
      (tester) async {
    final state = AppState.test(settings: PluginSettings.inMemory());
    final setCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      setCalls.add(call);
      if (call.method == 'Clipboard.getData') {
        return {'text': 'isi tempel'};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(home: ClipboardPage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Kirim papan klip'), findsOneWidget);
    expect(find.text('Belum ada papan klip diterima'), findsOneWidget);

    // Empty send is refused with a hint, nothing leaves the phone.
    await tester.tap(find.text('Kirim'));
    await tester.pumpAndSettle();
    expect(find.text('Tulis dulu isi papan klip.'), findsOneWidget);
    expect(
      setCalls.where((c) => c.method == 'Clipboard.setData'),
      isEmpty,
    );

    // Paste fills the field from the system clipboard.
    await tester.tap(find.text('Tempel dari papan klip'));
    await tester.pumpAndSettle();
    expect(find.text('isi tempel'), findsOneWidget);

    // With text but no connection, sending reports that honestly.
    await tester.tap(find.text('Kirim'));
    await tester.pumpAndSettle();
    expect(find.text('Tidak ada koneksi ke perangkat ini.'), findsOneWidget);
  });

  testWidgets('incoming clipboard packet sets the clipboard and shows',
      (tester) async {
    // Real file IO stalls in the widget test's fake-async zone, so
    // everything touching disk runs in runAsync (real async).
    late final Directory dir;
    final state = AppState.test(settings: PluginSettings.inMemory());
    final setTexts = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments as Map;
        setTexts.add(args['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    late final LocalIdentity identity;
    late final TrustStore trust;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('hyprconnect-m2-');
      identity = await LocalIdentity.loadOrCreate(
        dir,
        deviceName: 'Phone A',
      );
      trust = await TrustStore.load(dir);
    });
    final conn = DeviceConnection(
      identity: identity,
      trust: trust,
      tcpPort: 1714,
    );
    conn.remoteName = 'Desktop Tes';
    conn.remoteDeviceId = _deviceId;

    await tester.runAsync(
      () => state.handleIncomingPacket(
        conn,
        Packet.now(
          'kdeconnect.clipboard',
          {'content': 'teks dari desktop'},
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: ClipboardPage(appState: state, entry: _entry())),
    );
    await tester.pumpAndSettle();

    expect(setTexts, ['teks dari desktop']);
    expect(state.lastReceivedClipboard, 'teks dari desktop');
    expect(find.text('teks dari desktop'), findsOneWidget);
    expect(find.textContaining('Dari Desktop Tes'), findsOneWidget);

    // The same text again is an echo: not applied twice.
    await tester.runAsync(
      () => state.handleIncomingPacket(
        conn,
        Packet.now(
          'kdeconnect.clipboard',
          {'content': 'teks dari desktop'},
        ),
      ),
    );
    expect(setTexts, ['teks dari desktop']);
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
