//! Shared app state for the M1 shell: local identity, trusted devices,
//! plugin settings, discovery results, and live connections. The home
//! page and the device page both listen to this one object, so a
//! pairing accept, an incoming ping, or a dropped connection updates
//! every visible page at once.
//!
//! All networking still lives in the protocol layer (lib/src/protocol/);
//! this class only wires it to the UI.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../protocol/protocol.dart';
import '../settings/plugin_settings.dart';

/// One row of the home device list: a discovered device, a trusted
/// device that is currently offline, or both.
class DeviceListEntry {
  final String deviceId;
  final String name;
  final String deviceType;
  final InternetAddress? address;
  final int? tcpPort;

  /// Seen in a discovery broadcast recently.
  final bool online;

  /// Paired before (its certificate is in the trust store).
  final bool trusted;

  const DeviceListEntry({
    required this.deviceId,
    required this.name,
    required this.deviceType,
    required this.address,
    required this.tcpPort,
    required this.online,
    required this.trusted,
  });
}

/// Result of asking AppState to open a connection to a device.
enum ConnectOutcome {
  /// The encrypted channel is up.
  connected,

  /// The desktop is not in the trust store yet. First pairing must
  /// start from the desktop (see connection.dart); the UI explains this.
  needsDesktopPair,

  /// The connection attempt failed; details are in the log.
  failed,
}

class AppState extends ChangeNotifier {
  LocalIdentity? _identity;
  TrustStore? _trust;
  PluginSettings? _pluginSettings;
  TcpListener? _listener;
  Discovery? _discovery;
  final Map<String, DiscoveredDevice> _found = {};
  final Map<String, DeviceConnection> _connections = {};
  final List<String> _log = [];
  String _status = 'Memulai...';
  bool _started = false;

  LocalIdentity? get identity => _identity;
  TrustStore? get trust => _trust;

  /// Plugin settings; an in-memory default until initialize() loads
  /// the stored ones, so pages never see a null.
  PluginSettings get pluginSettings =>
      _pluginSettings ?? PluginSettings.inMemory();

  String get status => _status;
  List<String> get log => List.unmodifiable(_log);

  DeviceConnection? connectionFor(String deviceId) {
    return _connections[deviceId];
  }

  /// Home list: every discovered device, plus every trusted device
  /// that is not currently discovered (shown as offline).
  List<DeviceListEntry> get entries {
    final trust = _trust;
    final list = <DeviceListEntry>[];
    for (final device in _found.values) {
      list.add(
        DeviceListEntry(
          deviceId: device.deviceId,
          name: device.name,
          deviceType: device.deviceType,
          address: device.address,
          tcpPort: device.tcpPort,
          online: true,
          trusted: trust?.isTrusted(device.deviceId) ?? false,
        ),
      );
    }
    if (trust != null) {
      for (final trusted in trust.devices) {
        if (_found.containsKey(trusted.deviceId)) continue;
        list.add(
          DeviceListEntry(
            deviceId: trusted.deviceId,
            name: trusted.name,
            deviceType: trusted.deviceType,
            address: null,
            tcpPort: null,
            online: false,
            trusted: true,
          ),
        );
      }
    }
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// Test-only constructor: state with the given plugin settings and
  /// nothing started. Production code uses AppState() + initialize().
  AppState.test({required PluginSettings settings})
    : _pluginSettings = settings;

  AppState();

  Future<void> initialize() async {
    if (_started) return;
    _started = true;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final identity = await LocalIdentity.loadOrCreate(
        appDir,
        deviceName: 'HyprConnect',
      );
      final trust = await TrustStore.load(appDir);
      final pluginSettings = await PluginSettings.load(appDir);
      final listener = TcpListener();
      final port = await listener.start();
      final discovery = Discovery(identity: identity, tcpPort: port);
      unawaited(listener.connections.forEach(_onIncoming));
      discovery.devices.listen((device) {
        _found[device.deviceId] = device;
        notifyListeners();
      });
      await discovery.start();
      _identity = identity;
      _trust = trust;
      _pluginSettings = pluginSettings;
      _listener = listener;
      _discovery = discovery;
      _status = 'Mendengarkan di port $port';
      _logLine('Identitas: ${identity.deviceId}');
      notifyListeners();
    } catch (e) {
      _status = 'Gagal memulai: $e';
      notifyListeners();
    }
  }

  Future<void> _onIncoming(Socket raw) async {
    final identity = _identity;
    final trust = _trust;
    final listener = _listener;
    if (identity == null || trust == null || listener == null) {
      await raw.close();
      return;
    }
    try {
      final conn = DeviceConnection(
        identity: identity,
        trust: trust,
        tcpPort: listener.port,
      );
      await conn.acceptIncoming(raw);
      conn.disabledPlugins = pluginSettings.disabledPluginsFor(
        conn.remoteDeviceId ?? '',
      );
      _registerConnection(conn);
      _logLine(
        'Terhubung (masuk) dari ${conn.remoteName} (${conn.remoteDeviceId})',
      );
    } catch (e) {
      _logLine('Koneksi masuk gagal: $e');
      await raw.close();
    }
  }

  void _registerConnection(DeviceConnection conn) {
    final id = conn.remoteDeviceId;
    if (id == null) return;
    unawaited(_connections[id]?.close());
    _connections[id] = conn;
    conn.pairStates.listen((state) {
      _logLine('Pair ${conn.remoteName}: $state');
      notifyListeners();
    });
    conn.packets.listen((packet) {
      if (packet.type == 'kdeconnect.ping') {
        _logLine('Ping dari ${conn.remoteName}');
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void _logLine(String line) {
    _log.add(line);
    if (_log.length > 100) _log.removeRange(0, _log.length - 100);
  }

  /// Open a connection to a discovered device. The peer certificate
  /// must already be known (see ConnectOutcome.needsDesktopPair).
  Future<ConnectOutcome> connectTo(DeviceListEntry entry) async {
    final identity = _identity;
    final trust = _trust;
    final listener = _listener;
    if (identity == null || trust == null || listener == null) {
      return ConnectOutcome.failed;
    }
    final address = entry.address;
    final tcpPort = entry.tcpPort;
    if (address == null || tcpPort == null) return ConnectOutcome.failed;
    final knownCert = trust.storedCert(entry.deviceId);
    if (knownCert == null) return ConnectOutcome.needsDesktopPair;
    try {
      final conn = DeviceConnection(
        identity: identity,
        trust: trust,
        tcpPort: listener.port,
      );
      conn.disabledPlugins = pluginSettings.disabledPluginsFor(
        entry.deviceId,
      );
      await conn.connectOutgoing(
        address: address,
        tcpPort: tcpPort,
        deviceId: entry.deviceId,
        name: entry.name,
        deviceType: entry.deviceType,
        peerCertDer: knownCert,
      );
      _registerConnection(conn);
      _logLine('Terhubung (keluar) ke ${entry.name}');
      return ConnectOutcome.connected;
    } catch (e) {
      _logLine('Gagal terhubung ke ${entry.name}: $e');
      notifyListeners();
      return ConnectOutcome.failed;
    }
  }

  Future<void> requestPair(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.requestPair();
      _logLine('Meminta pairing ke ${conn.remoteName}');
    } catch (e) {
      _logLine('Pairing gagal: $e');
    }
    notifyListeners();
  }

  Future<void> rejectPair(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.rejectPair();
      _logLine('Menolak pairing dari ${conn.remoteName}');
    } catch (e) {
      _logLine('Tolak pairing gagal: $e');
    }
    notifyListeners();
  }

  Future<void> sendPing(String deviceId, [String? message]) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendPing(message ?? 'Halo dari HyprConnect');
      _logLine('Ping terkirim ke ${conn.remoteName}');
    } catch (e) {
      _logLine('Ping gagal: $e');
    }
    notifyListeners();
  }

  /// Unpair and drop the connection; the device stays listed.
  Future<void> unpair(String deviceId) async {
    final conn = _connections.remove(deviceId);
    if (conn == null) return;
    try {
      await conn.unpair();
      _logLine('Leraikan pairing dengan ${conn.remoteName}');
    } catch (e) {
      _logLine('Leraikan gagal: $e');
    }
    notifyListeners();
  }

  /// Switch a plugin on or off for one device. The tile and the
  /// settings page update at once; the filtered capability list
  /// applies to the next connection to that device.
  Future<void> setPluginEnabled(
    String deviceId,
    String pluginId,
    bool enabled,
  ) async {
    await pluginSettings.setEnabled(deviceId, pluginId, enabled);
    final conn = _connections[deviceId];
    if (conn != null) {
      conn.disabledPlugins = pluginSettings.disabledPluginsFor(deviceId);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final conn in _connections.values) {
      unawaited(conn.close());
    }
    unawaited(_discovery?.stop());
    unawaited(_listener?.stop());
    super.dispose();
  }
}
