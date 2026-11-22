//! Wire packets: newline-delimited JSON objects, KDE Connect style.
//! Mirrors the daemon's src/packet.rs (same field names, same framing).

import 'dart:convert';

/// Packet types this app advertises, mirrored from the daemon's
/// capability lists (phone perspective: what the phone receives vs sends).
class Capabilities {
  /// Types the phone accepts.
  static const List<String> incoming = [
    'kdeconnect.ping',
    'kdeconnect.clipboard',
    'kdeconnect.clipboard.connect',
    'kdeconnect.share.request',
    'kdeconnect.notification.request',
    'kdeconnect.notification.reply',
    'kdeconnect.notification.action',
    'kdeconnect.mpris.request',
    'kdeconnect.systemvolume',
    'kdeconnect.sftp.request',
    'kdeconnect.battery.request',
    'kdeconnect.findmyphone.request',
    'kdeconnect.runcommand',
    'kdeconnect.mousepad.request',
  ];

  /// Types the phone sends.
  static const List<String> outgoing = [
    'kdeconnect.ping',
    'kdeconnect.clipboard',
    'kdeconnect.clipboard.connect',
    'kdeconnect.notification',
    'kdeconnect.mpris',
    'kdeconnect.mpris.request',
    'kdeconnect.systemvolume.request',
    'kdeconnect.sftp',
    'kdeconnect.presenter',
    'kdeconnect.mousepad.request',
    'kdeconnect.runcommand.request',
    'kdeconnect.runcommand.output',
    'kdeconnect.battery',
  ];
}

class Packet {
  final int id;
  final String type;
  final Map<String, dynamic> body;
  final int? payloadSize;
  final Map<String, dynamic>? payloadTransferInfo;

  const Packet({
    required this.id,
    required this.type,
    required this.body,
    this.payloadSize,
    this.payloadTransferInfo,
  });

  factory Packet.now(String type, [Map<String, dynamic> body = const {}]) {
    return Packet(
      id: DateTime.now().millisecondsSinceEpoch,
      type: type,
      body: body,
    );
  }

  factory Packet.fromJson(Map<String, dynamic> json) {
    return Packet(
      id: (json['id'] as num?)?.toInt() ?? 0,
      type: json['type'] as String? ?? '',
      body: (json['body'] as Map?)?.cast<String, dynamic>() ?? {},
      payloadSize: (json['payloadSize'] as num?)?.toInt(),
      payloadTransferInfo:
          (json['payloadTransferInfo'] as Map?)?.cast<String, dynamic>(),
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'type': type,
      'body': body,
    };
    if (payloadSize != null) map['payloadSize'] = payloadSize;
    if (payloadTransferInfo != null) {
      map['payloadTransferInfo'] = payloadTransferInfo;
    }
    return map;
  }

  /// One newline-terminated line, the wire framing.
  String toLine() => '${jsonEncode(toJson())}\n';

  static Packet identity({
    required String deviceId,
    required String deviceName,
    required int tcpPort,
  }) {
    return Packet.now('kdeconnect.identity', {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'deviceType': 'phone',
      'incomingCapabilities': Capabilities.incoming,
      'outgoingCapabilities': Capabilities.outgoing,
      'protocolVersion': 7,
      'tcpPort': tcpPort,
    });
  }

  static Packet pair(bool pair) {
    return Packet.now('kdeconnect.pair', {'pair': pair});
  }

  static Packet ping([String? message]) {
    return Packet.now(
      'kdeconnect.ping',
      message == null ? {} : {'message': message},
    );
  }
}
