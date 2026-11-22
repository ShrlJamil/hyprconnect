//! HyprConnect mobile — M0 shell: protocol foundation with a minimal
//! working UI (device identity, discovery list, connect / pair / ping,
//! live log). The KDE Connect-style shell arrives in M1.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/protocol/protocol.dart';

void main() {
  runApp(const HyprConnectApp());
}

class HyprConnectApp extends StatelessWidget {
  const HyprConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyprConnect',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LocalIdentity? _identity;
  TrustStore? _trust;
  TcpListener? _listener;
  Discovery? _discovery;
  final Map<String, DiscoveredDevice> _found = {};
  final Map<String, DeviceConnection> _connections = {};
  final List<String> _log = [];
  String _status = 'Memulai...';

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final identity = await LocalIdentity.loadOrCreate(
        appDir,
        deviceName: 'HyprConnect',
      );
      final trust = await TrustStore.load(appDir);
      final listener = TcpListener();
      final port = await listener.start();
      final discovery = Discovery(identity: identity, tcpPort: port);
      unawaited(
        listener.connections.forEach(_onIncoming),
      );
      discovery.devices.listen((device) {
        setState(() => _found[device.deviceId] = device);
      });
      await discovery.start();
      setState(() {
        _identity = identity;
        _trust = trust;
        _listener = listener;
        _discovery = discovery;
        _status = 'Mendengarkan di port $port';
      });
      _logLine('Identitas: ${identity.deviceId}');
    } catch (e) {
      setState(() => _status = 'Gagal memulai: $e');
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
      if (!mounted) return;
      setState(() {});
      _logLine('Pair ${conn.remoteName}: $state');
    });
    conn.packets.listen((packet) {
      if (packet.type == 'kdeconnect.ping') {
        _logLine('Ping dari ${conn.remoteName}');
      }
    });
    setState(() {});
  }

  void _logLine(String line) {
    if (!mounted) return;
    setState(() {
      _log.add(line);
      if (_log.length > 100) _log.removeRange(0, _log.length - 100);
    });
  }

  Future<void> _connectTo(DiscoveredDevice device) async {
    final identity = _identity;
    final trust = _trust;
    final listener = _listener;
    if (identity == null || trust == null || listener == null) return;
    final knownCert = trust.storedCert(device.deviceId);
    if (knownCert == null) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pairing pertama'),
          content: Text(
            'Perangkat ini belum dikenal. Pairing pertama harus dimulai '
            'dari desktop, jalankan di sana:\n\n'
            'hyprconnect pair ${device.deviceId}\n\n'
            'Setelah desktop meminta pairing, kunci verifikasi muncul di '
            'sini dan kamu bisa menekan Terima.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    try {
      final conn = DeviceConnection(
        identity: identity,
        trust: trust,
        tcpPort: listener.port,
      );
      await conn.connectOutgoing(
        address: device.address,
        tcpPort: device.tcpPort,
        deviceId: device.deviceId,
        name: device.name,
        deviceType: device.deviceType,
        peerCertDer: knownCert,
      );
      _registerConnection(conn);
      _logLine('Terhubung (keluar) ke ${device.name}');
    } catch (e) {
      _logLine('Gagal terhubung ke ${device.name}: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal terhubung: $e')),
        );
      }
    }
  }

  Future<void> _requestPair(DeviceConnection conn) async {
    try {
      await conn.requestPair();
      _logLine('Meminta pairing ke ${conn.remoteName}');
    } catch (e) {
      _logLine('Pairing gagal: $e');
    }
  }

  Future<void> _sendPing(DeviceConnection conn) async {
    try {
      await conn.sendPing('Halo dari HyprConnect');
      _logLine('Ping terkirim ke ${conn.remoteName}');
    } catch (e) {
      _logLine('Ping gagal: $e');
    }
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

  @override
  Widget build(BuildContext context) {
    final identity = _identity;
    final devices = _found.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      appBar: AppBar(title: const Text('HyprConnect')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: const Text('Perangkat ini'),
              subtitle: identity == null
                  ? Text(_status)
                  : SelectableText(
                      '${identity.deviceName}\n'
                      '${identity.deviceId}\n$_status',
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Perangkat ditemukan (${devices.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (devices.isEmpty)
            const ListTile(
              title: Text('Belum ada perangkat di jaringan ini'),
              subtitle: Text(
                'Pastikan desktop dan HP berada di Wi-Fi yang sama.',
              ),
            ),
          for (final device in devices)
            _DeviceTile(
              device: device,
              connection: _connections[device.deviceId],
              onTap: () => _connectTo(device),
              onPair: (conn) => _requestPair(conn),
              onPing: (conn) => _sendPing(conn),
            ),
          const SizedBox(height: 16),
          Text('Log', style: Theme.of(context).textTheme.titleMedium),
          Card(
            child: Container(
              height: 220,
              padding: const EdgeInsets.all(8),
              child: ListView(
                children: [
                  for (final line in _log)
                    Text(line, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final DiscoveredDevice device;
  final DeviceConnection? connection;
  final VoidCallback onTap;
  final void Function(DeviceConnection) onPair;
  final void Function(DeviceConnection) onPing;

  const _DeviceTile({
    required this.device,
    required this.connection,
    required this.onTap,
    required this.onPair,
    required this.onPing,
  });

  @override
  Widget build(BuildContext context) {
    final conn = connection;
    final paired = conn?.isPaired ?? false;
    final pendingIn = conn?.pairState == PairState.pendingIn;
    return Card(
      child: ListTile(
        title: Text(
          device.name.isEmpty ? device.deviceId : device.name,
        ),
        subtitle: Text(
          '${device.deviceType} - ${device.address.address}'
          '${conn == null ? '' : ' - terhubung'}'
          '${paired ? ' - paired' : ''}'
          '${pendingIn ? '\nKunci verifikasi: ${conn?.verificationKey ?? '-'}' : ''}',
        ),
        isThreeLine: pendingIn,
        onTap: conn == null ? onTap : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pendingIn && conn != null)
              TextButton(
                onPressed: () => onPair(conn),
                child: const Text('Terima'),
              )
            else if (conn != null && !paired)
              TextButton(
                onPressed: () => onPair(conn),
                child: const Text('Pair'),
              )
            else if (paired && conn != null)
              IconButton(
                onPressed: () => onPing(conn),
                icon: const Icon(Icons.send),
                tooltip: 'Kirim ping',
              ),
          ],
        ),
      ),
    );
  }
}
