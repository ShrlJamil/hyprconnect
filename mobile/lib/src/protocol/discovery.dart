//! UDP discovery on port 1716: listen for identity broadcasts and
//! broadcast our own identity every 3 seconds, like the daemon's
//! discovery_task / announce_task (src/main.rs).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'identity.dart';
import 'packet.dart';

const int discoveryPort = 1716;

class DiscoveredDevice {
  final String deviceId;
  final String name;
  final String deviceType;
  final InternetAddress address;
  final int tcpPort;
  DateTime lastSeen;

  DiscoveredDevice({
    required this.deviceId,
    required this.name,
    required this.deviceType,
    required this.address,
    required this.tcpPort,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();
}

class Discovery {
  /// The identity we announce. Not final: renaming this device
  /// swaps in an updated identity so the next broadcast carries
  /// the new name without restarting discovery.
  LocalIdentity identity;
  final int tcpPort;

  RawDatagramSocket? _socket;
  Timer? _timer;
  final _controller = StreamController<DiscoveredDevice>.broadcast();

  Discovery({required this.identity, required this.tcpPort});

  Stream<DiscoveredDevice> get devices => _controller.stream;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    _socket!.broadcastEnabled = true;
    _socket!.listen(_onEvent);
    broadcastIdentity();
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => broadcastIdentity(),
    );
  }

  void broadcastIdentity() {
    final socket = _socket;
    if (socket == null) return;
    final packet = Packet.identity(
      deviceId: identity.deviceId,
      deviceName: identity.deviceName,
      tcpPort: tcpPort,
    );
    final data = utf8.encode(jsonEncode(packet.toJson()));
    socket.send(data, InternetAddress('255.255.255.255'), discoveryPort);
  }

  /// Announce ourselves straight to one address instead of the
  /// broadcast address: the "add device by IP" path, for desktops
  /// the broadcast cannot reach. A desktop that hears it connects
  /// back when it wants a channel (the daemon does exactly that
  /// for unpaired devices), so a few repeats are enough.
  Future<void> probeAddress(InternetAddress address) async {
    final socket = _socket;
    if (socket == null) return;
    final packet = Packet.identity(
      deviceId: identity.deviceId,
      deviceName: identity.deviceName,
      tcpPort: tcpPort,
    );
    final data = utf8.encode(jsonEncode(packet.toJson()));
    for (var i = 0; i < 3; i++) {
      socket.send(data, address, discoveryPort);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      _onDatagram(datagram!);
    }
  }

  void _onDatagram(Datagram datagram) {
    try {
      final json = jsonDecode(utf8.decode(datagram.data));
      if (json is! Map<String, dynamic>) return;
      final packet = Packet.fromJson(json);
      if (packet.type != 'kdeconnect.identity') return;
      final deviceId = packet.body['deviceId'] as String?;
      if (deviceId == null || !LocalIdentity.validDeviceId(deviceId)) return;
      if (deviceId == identity.deviceId) return;
      final tcpPort = (packet.body['tcpPort'] as num?)?.toInt();
      if (tcpPort == null) return;
      _controller.add(
        DiscoveredDevice(
          deviceId: deviceId,
          name: packet.body['deviceName'] as String? ?? '',
          deviceType: packet.body['deviceType'] as String? ?? '',
          address: datagram.address,
          tcpPort: tcpPort,
        ),
      );
    } catch (_) {
      // A malformed broadcast is ignored, like the daemon does.
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}
