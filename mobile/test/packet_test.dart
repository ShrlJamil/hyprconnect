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
}
