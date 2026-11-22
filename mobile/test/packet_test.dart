import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/protocol/packet.dart';

void main() {
  test('packet round-trips through JSON', () {
    final packet = Packet.now('kdeconnect.ping', {'message': 'halo'});
    final decoded = Packet.fromJson(
      jsonDecode(jsonEncode(packet.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.type, 'kdeconnect.ping');
    expect(decoded.body['message'], 'halo');
    expect(decoded.id, packet.id);
  });

  test('toLine is newline-terminated JSON', () {
    final line = Packet.pair(true).toLine();
    expect(line.endsWith('\n'), isTrue);
    final decoded = Packet.fromJson(
      jsonDecode(line.trim()) as Map<String, dynamic>,
    );
    expect(decoded.type, 'kdeconnect.pair');
    expect(decoded.body['pair'], isTrue);
  });

  test('payload fields are omitted when absent', () {
    final json = Packet.ping().toJson();
    expect(json.containsKey('payloadSize'), isFalse);
    expect(json.containsKey('payloadTransferInfo'), isFalse);
    final withPayload = Packet(
      id: 1,
      type: 'kdeconnect.share.request',
      body: {'filename': 'a.txt'},
      payloadSize: 42,
      payloadTransferInfo: {'port': 1739},
    ).toJson();
    expect(withPayload['payloadSize'], 42);
    expect(withPayload['payloadTransferInfo'], {'port': 1739});
  });

  test('identity packet has the protocol shape', () {
    final packet = Packet.identity(
      deviceId: 'a' * 32,
      deviceName: 'Test Phone',
      tcpPort: 1714,
    );
    expect(packet.type, 'kdeconnect.identity');
    expect(packet.body['deviceId'], 'a' * 32);
    expect(packet.body['deviceName'], 'Test Phone');
    expect(packet.body['deviceType'], 'phone');
    expect(packet.body['protocolVersion'], 7);
    expect(packet.body['tcpPort'], 1714);
    expect(packet.body['incomingCapabilities'], contains('kdeconnect.ping'));
    expect(packet.body['outgoingCapabilities'], contains('kdeconnect.ping'));
  });

  test('identity filters out disabled plugins capabilities', () {
    final packet = Packet.identity(
      deviceId: 'a' * 32,
      deviceName: 'Test Phone',
      tcpPort: 1714,
      disabledPlugins: {'share', 'clipboard'},
    );
    final incoming =
        (packet.body['incomingCapabilities'] as List).cast<String>();
    final outgoing =
        (packet.body['outgoingCapabilities'] as List).cast<String>();
    expect(incoming, isNot(contains('kdeconnect.share.request')));
    expect(outgoing, isNot(contains('kdeconnect.share.request')));
    expect(incoming, isNot(contains('kdeconnect.clipboard')));
    expect(incoming, isNot(contains('kdeconnect.clipboard.connect')));
    // Core traffic and runcommand are never gated (mirrors the daemon).
    expect(incoming, contains('kdeconnect.ping'));
    expect(incoming, contains('kdeconnect.mpris.request'));
    expect(incoming, contains('kdeconnect.runcommand'));
    expect(outgoing, contains('kdeconnect.runcommand.request'));
    expect(outgoing, contains('kdeconnect.runcommand.output'));
  });

  test('pluginForPacketType mirrors the daemon mapping', () {
    expect(pluginForPacketType('kdeconnect.ping'), isNull);
    expect(pluginForPacketType('kdeconnect.pair'), isNull);
    expect(pluginForPacketType('kdeconnect.runcommand'), isNull);
    expect(
      pluginForPacketType('kdeconnect.mousepad.request'),
      'remoteinput',
    );
    expect(pluginForPacketType('kdeconnect.presenter'), 'presenter');
    expect(pluginForPacketType('kdeconnect.findmyphone.request'),
        'findmyphone');
    expect(pluginForPacketType('kdeconnect.systemvolume'), 'systemvolume');
  });
}
