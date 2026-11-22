//! Shared app state for the M1 shell: local identity, trusted devices,
//! plugin settings, discovery results, and live connections. The home
//! page and the device page both listen to this one object, so a
//! pairing accept, an incoming ping, or a dropped connection updates
//! every visible page at once.
//!
//! All networking still lives in the protocol layer (lib/src/protocol/);
//! this class only wires it to the UI.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  Directory? _receiveDir;
  final List<ReceivedFile> _receivedFiles = [];
  String? _lastReceivedClipboard;
  String? _lastReceivedFrom;
  DateTime? _lastReceivedAt;
  Directory? _artDir;
  // M3: per-device multimedia state (deviceId -> ...).
  final Map<String, List<String>> _playerLists = {};
  final Map<String, Map<String, MprisPlayerState>> _playerStates = {};
  final Map<String, String> _selectedPlayers = {};
  final Map<String, String> _albumArtPaths = {};
  final Set<String> _artRequested = {};
  // M5: per-device presenter state (deviceId -> ...).
  final Map<String, List<String>> _monitorLists = {};
  final Map<String, String?> _presenterMonitors = {};
  // M5: presenter notes, kept on this phone only (deviceId -> text).
  final Map<String, String> _presenterNotes = {};
  File? _notesFile;
  // M3: per-device run-command state (deviceId -> ...).
  final Map<String, List<RunCommand>> _commandLists = {};
  final Map<String, bool> _canAddCommands = {};
  final Map<String, List<RunCommandOutput>> _commandEvents = {};
  final Map<String, int?> _runningCommandIds = {};
  String? _lastClipboardSent;
  String? _lastClipboardApplied;
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

  /// Files received from peers, newest first.
  List<ReceivedFile> get receivedFiles => List.unmodifiable(_receivedFiles);

  List<ReceivedFile> receivedFilesFor(String deviceId) {
    return _receivedFiles.where((f) => f.deviceId == deviceId).toList();
  }

  /// Last clipboard text received from a peer, if any.
  String? get lastReceivedClipboard => _lastReceivedClipboard;
  String? get lastReceivedFrom => _lastReceivedFrom;
  DateTime? get lastReceivedAt => _lastReceivedAt;

  /// Where files from peers are saved, if known yet.
  String? get receiveDirPath => _receiveDir?.path;

  /// M3: desktop player names known for a device (empty when none
  /// reported yet).
  List<String> playerListFor(String deviceId) {
    return List.unmodifiable(_playerLists[deviceId] ?? const []);
  }

  /// M3: last known now-playing state of one player, if any.
  MprisPlayerState? playerStateFor(String deviceId, String player) {
    return _playerStates[deviceId]?[player];
  }

  /// M3: the player the multimedia page currently controls, if any.
  String? selectedPlayerFor(String deviceId) => _selectedPlayers[deviceId];

  /// M3: local path of the downloaded album art for a player, if any.
  String? albumArtPathFor(String deviceId, String player) {
    return _albumArtPaths['$deviceId|$player'];
  }

  /// M3: predefined commands the desktop offers, if the list arrived.
  List<RunCommand> commandsFor(String deviceId) {
    return List.unmodifiable(_commandLists[deviceId] ?? const []);
  }

  /// M3: whether the desktop lets this phone open the command editor.
  bool canAddCommandFor(String deviceId) {
    return _canAddCommands[deviceId] ?? false;
  }

  /// M3: streamed output events of commands run on a device, oldest
  /// first (capped, so a chatty command cannot grow memory forever).
  List<RunCommandOutput> commandEventsFor(String deviceId) {
    return List.unmodifiable(_commandEvents[deviceId] ?? const []);
  }

  /// M3: id of the command currently running on a device, if any.
  int? runningCommandIdFor(String deviceId) => _runningCommandIds[deviceId];

  /// M5: monitor names the desktop reported (empty when it never
  /// answered the request — a stock desktop never does).
  List<String> monitorListFor(String deviceId) {
    return List.unmodifiable(_monitorLists[deviceId] ?? const []);
  }

  /// M5: whether the desktop answered the monitor list at all.
  bool hasMonitorListFor(String deviceId) {
    return _monitorLists.containsKey(deviceId);
  }

  /// M5: the monitor the presenter pointer is pinned to, or null
  /// for automatic (also null when nothing was ever reported).
  String? presenterMonitorFor(String deviceId) {
    return _presenterMonitors[deviceId];
  }

  /// M5: presenter notes stored on this phone for a device.
  String presenterNotesFor(String deviceId) {
    return _presenterNotes[deviceId] ?? '';
  }

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

  /// Test-only hook: register a connection built by a test so pages
  /// can render their connected UI without a live socket.
  @visibleForTesting
  void registerTestConnection(DeviceConnection conn) {
    _registerConnection(conn);
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
      _receiveDir = await _resolveReceiveDir();
      _artDir = Directory('${appDir.path}/album-art');
      await _artDir!.create(recursive: true);
      _notesFile = File('${appDir.path}/presenter_notes.json');
      await _loadPresenterNotes();
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

  /// Files from peers land in HyprConnect/ under external storage on
  /// Android (visible in a file manager); anywhere else, under the
  /// app documents directory.
  Future<Directory> _resolveReceiveDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dir = Directory('${ext.path}/HyprConnect');
        await dir.create(recursive: true);
        return dir;
      }
    } catch (_) {
      // External storage is unsupported on this platform.
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/HyprConnect');
    await dir.create(recursive: true);
    return dir;
  }

  /// M5: presenter notes live in presenter_notes.json under the app
  /// documents dir; a missing or broken file just means no notes yet.
  Future<void> _loadPresenterNotes() async {
    final file = _notesFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.value is String) {
            _presenterNotes[entry.key as String] = entry.value as String;
          }
        }
      }
    } catch (_) {
      // Notes are a convenience; never block startup over them.
    }
  }

  /// Handle one packet that arrived on [conn]: ping logging, clipboard
  /// receive (sets the phone clipboard), and share requests (text and
  /// url like the daemon handles them; files are downloaded to the
  /// receive dir). Errors are logged, never thrown to the read loop.
  Future<void> handleIncomingPacket(
    DeviceConnection conn,
    Packet packet,
  ) async {
    try {
      switch (packet.type) {
        case 'kdeconnect.ping':
          _logLine('Ping dari ${conn.remoteName}');
        case 'kdeconnect.clipboard':
        case 'kdeconnect.clipboard.connect':
          final content = packet.body['content'] as String?;
          if (content != null) {
            await _applyRemoteClipboard(conn, content);
          }
        case 'kdeconnect.share.request':
          await _handleShareRequest(conn, packet);
        case 'kdeconnect.mpris':
          await _handleMpris(conn, packet);
        case 'kdeconnect.runcommand':
          _handleRunCommandList(conn, packet);
        case 'kdeconnect.runcommand.output':
          _handleRunCommandOutput(conn, packet);
        case 'kdeconnect.presenter':
          _handlePresenter(conn, packet);
      }
    } catch (e) {
      _logLine('Gagal menangani ${packet.type}: $e');
    }
    notifyListeners();
  }

  /// M3: a kdeconnect.mpris packet arrived: a player list, a
  /// now-playing state, or an album-art payload. State updates pick
  /// the first player automatically; art is pulled once per url.
  Future<void> _handleMpris(DeviceConnection conn, Packet packet) async {
    final deviceId = conn.remoteDeviceId;
    if (deviceId == null) return;
    final list = MprisPlayerState.playerListOf(packet);
    if (list != null) {
      _playerLists[deviceId] = list;
      final selected = _selectedPlayers[deviceId];
      if ((selected == null || !list.contains(selected)) && list.isNotEmpty) {
        _selectedPlayers[deviceId] = list.first;
      }
      if (list.isEmpty) _selectedPlayers.remove(deviceId);
      return;
    }
    if (MprisPlayerState.isAlbumArtPacket(packet)) {
      await _saveAlbumArt(conn, packet);
      return;
    }
    final state = MprisPlayerState.fromPacket(packet);
    if (state.player.isEmpty) return;
    (_playerStates[deviceId] ??= {})[state.player] = state;
    _selectedPlayers.putIfAbsent(deviceId, () => state.player);
    final artUrl = state.albumArtUrl;
    if (artUrl.startsWith('file://') &&
        albumArtPathFor(deviceId, state.player) == null) {
      final key = '$deviceId|${state.player}|$artUrl';
      if (_artRequested.add(key)) {
        try {
          await conn.requestMprisAlbumArt(state.player, artUrl);
        } catch (e) {
          _logLine('Gagal meminta sampul album: $e');
        }
      }
    }
  }

  /// M3: the art payload for a player arrived; save it under the
  /// app's art dir and remember the path for the multimedia page.
  Future<void> _saveAlbumArt(DeviceConnection conn, Packet packet) async {
    final deviceId = conn.remoteDeviceId;
    final dir = _artDir;
    if (deviceId == null || dir == null) return;
    final player = packet.body['player'] as String? ?? '';
    final url = packet.body['albumArtUrl'] as String? ?? '';
    final ext = url.split('.').lastOrNull ?? '';
    final safePlayer = player.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final filename = ext.length <= 5 && ext.isNotEmpty
        ? '$deviceId-$safePlayer.$ext'
        : '$deviceId-$safePlayer';
    try {
      final bytes = await conn.receiveBytes(packet);
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);
      _albumArtPaths['$deviceId|$player'] = file.path;
      _logLine('Sampul album diterima untuk $player (${bytes.length} byte)');
    } catch (e) {
      _logLine('Gagal menerima sampul album: $e');
    }
  }

  /// M3: a kdeconnect.runcommand packet arrived with the desktop's
  /// predefined command list (a JSON string, see runcommand.dart).
  void _handleRunCommandList(DeviceConnection conn, Packet packet) {
    final deviceId = conn.remoteDeviceId;
    if (deviceId == null) return;
    _commandLists[deviceId] = parseCommandList(packet);
    _canAddCommands[deviceId] = canAddCommandOf(packet);
    _logLine(
      'Daftar perintah diterima dari ${conn.remoteName} '
      '(${_commandLists[deviceId]!.length} perintah)',
    );
  }

  /// M3: one streamed runcommand.output event arrived (started,
  /// output lines, or finished with the exit code).
  void _handleRunCommandOutput(DeviceConnection conn, Packet packet) {
    final deviceId = conn.remoteDeviceId;
    if (deviceId == null) return;
    final event = RunCommandOutput.fromPacket(packet);
    if (event == null) return;
    final events = _commandEvents[deviceId] ??= [];
    events.add(event);
    if (events.length > 500) events.removeRange(0, events.length - 500);
    switch (event.kind) {
      case RunCommandOutput.started:
        _runningCommandIds[deviceId] = event.id;
      case RunCommandOutput.finished:
        if (_runningCommandIds[deviceId] == event.id) {
          _runningCommandIds[deviceId] = null;
        }
      default:
        break;
    }
  }

  /// M5: a kdeconnect.presenter reply arrived (monitor list).
  /// Pointer packets never come back, so anything without
  /// "monitors" is ignored.
  void _handlePresenter(DeviceConnection conn, Packet packet) {
    final deviceId = conn.remoteDeviceId;
    if (deviceId == null) return;
    final list = PresenterMonitorList.fromPacket(packet);
    if (list == null) return;
    _monitorLists[deviceId] = list.monitors;
    _presenterMonitors[deviceId] = list.presenterMonitor;
    _logLine(
      'Daftar monitor diterima dari ${conn.remoteName} '
      '(${list.monitors.length} monitor)',
    );
  }

  /// Clipboard text arrived from a peer: set the phone clipboard,
  /// unless it is what we just sent or already applied (echo guard,
  /// same idea as the daemon's last_clipboard).
  Future<void> _applyRemoteClipboard(
    DeviceConnection conn,
    String content,
  ) async {
    if (content.isEmpty) return;
    if (content == _lastClipboardSent || content == _lastClipboardApplied) {
      return;
    }
    _lastClipboardApplied = content;
    _lastReceivedClipboard = content;
    _lastReceivedFrom = conn.remoteName ?? conn.remoteDeviceId ?? '';
    _lastReceivedAt = DateTime.now();
    await Clipboard.setData(ClipboardData(text: content));
    _logLine(
      'Papan klip diterima dari ${conn.remoteName} '
      '(${content.length} karakter)',
    );
  }

  /// A share.request arrived: text is applied as clipboard and url is
  /// only logged, exactly like the daemon; a file is downloaded over
  /// its payload connection into the receive dir.
  Future<void> _handleShareRequest(DeviceConnection conn, Packet packet) async {
    final text = packet.body['text'] as String?;
    if (text != null) {
      await _applyRemoteClipboard(conn, text);
      return;
    }
    final url = packet.body['url'] as String?;
    if (url != null) {
      _logLine('Tautan dibagikan dari ${conn.remoteName}: $url');
      return;
    }
    final dir = _receiveDir;
    if (dir == null) {
      _logLine('Tidak ada folder terima, file ditolak');
      return;
    }
    try {
      final received = await conn.receiveFile(packet, dir);
      _receivedFiles.insert(0, received);
      _logLine(
        'File diterima: ${received.filename} (${received.size} byte) '
        '-> ${received.path}',
      );
    } catch (e) {
      _logLine('Gagal menerima file dari ${conn.remoteName}: $e');
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
      unawaited(handleIncomingPacket(conn, packet));
    });
    notifyListeners();
  }

  void _logLine(String line) {
    _log.add(line);
    if (_log.length > 100) _log.removeRange(0, _log.length - 100);
  }

  /// Open a connection to a discovered device. With a known
  /// certificate the app opens the channel itself; for a first pairing
  /// it announces itself on discovery and waits for the desktop to
  /// connect back (see connection.dart for why).
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
    if (knownCert == null) {
      // First contact with this desktop. This app cannot open the
      // channel itself: as the TCP opener it would be the TLS server,
      // and a Dart TLS server only accepts a client certificate it
      // already trusts (see connection.dart). The desktop connects
      // back to unpaired devices it hears on discovery, so announce
      // ourselves and wait for its incoming channel.
      final existing = _connections[entry.deviceId];
      if (existing != null && existing.isConnected) {
        return ConnectOutcome.connected;
      }
      _logLine(
        'Menunggu ${entry.name} menghubungi balik untuk pairing pertama',
      );
      _discovery?.broadcastIdentity();
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final conn = _connections[entry.deviceId];
        if (conn != null && conn.isConnected) {
          _logLine('Kanal masuk dari ${entry.name} terbuka');
          return ConnectOutcome.connected;
        }
      }
      _logLine('${entry.name} tidak menghubungi balik dalam 25 detik');
      notifyListeners();
      return ConnectOutcome.failed;
    }
    try {
      final conn = DeviceConnection(
        identity: identity,
        trust: trust,
        tcpPort: listener.port,
      );
      conn.disabledPlugins = pluginSettings.disabledPluginsFor(entry.deviceId);
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

  /// M3: ask a device for its player list. State packets arrive on
  /// their own afterwards (the daemon pushes them when players
  /// appear, change, or answer an action).
  Future<void> requestMprisPlayers(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.requestMprisPlayerList();
    } catch (e) {
      _logLine('Gagal meminta daftar player: $e');
    }
    notifyListeners();
  }

  /// M3: pick which desktop player the multimedia page controls.
  /// The page also asks for a fresh state right away.
  Future<void> selectMprisPlayer(String deviceId, String player) async {
    _selectedPlayers[deviceId] = player;
    final conn = _connections[deviceId];
    if (conn != null) {
      try {
        await conn.requestMprisNowPlaying(player);
      } catch (e) {
        _logLine('Gagal meminta status player: $e');
      }
    }
    notifyListeners();
  }

  /// M3: send a playback action to the selected player.
  Future<void> sendMprisAction(String deviceId, String action) async {
    final conn = _connections[deviceId];
    final player = _selectedPlayers[deviceId];
    if (conn == null || player == null) return;
    try {
      await conn.sendMprisAction(player, action);
    } catch (e) {
      _logLine('Kendali multimedia gagal: $e');
    }
    notifyListeners();
  }

  /// M3: set the selected player's volume, 0..100.
  Future<void> setMprisVolume(String deviceId, int volume) async {
    final conn = _connections[deviceId];
    final player = _selectedPlayers[deviceId];
    if (conn == null || player == null) return;
    try {
      await conn.sendMprisVolume(player, volume);
    } catch (e) {
      _logLine('Atur volume gagal: $e');
    }
    notifyListeners();
  }

  /// M3: seek the selected player relative to now, in seconds
  /// (negative seeks back; the daemon takes microseconds).
  Future<void> seekMpris(String deviceId, int seconds) async {
    final conn = _connections[deviceId];
    final player = _selectedPlayers[deviceId];
    if (conn == null || player == null) return;
    try {
      await conn.sendMprisSeek(player, seconds * 1000000);
    } catch (e) {
      _logLine('Seek gagal: $e');
    }
    notifyListeners();
  }

  /// M3: jump the selected player to an absolute position, in seconds.
  Future<void> setMprisPosition(String deviceId, int seconds) async {
    final conn = _connections[deviceId];
    final player = _selectedPlayers[deviceId];
    if (conn == null || player == null) return;
    try {
      await conn.sendMprisSetPosition(player, seconds * 1000000);
    } catch (e) {
      _logLine('Pindah posisi gagal: $e');
    }
    notifyListeners();
  }

  /// M3: ask a device for its predefined command list.
  Future<void> requestRunCommands(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.requestRunCommandList();
    } catch (e) {
      _logLine('Gagal meminta daftar perintah: $e');
    }
    notifyListeners();
  }

  /// M3: run one predefined command on a device by its key. Output
  /// streams back as runcommand.output packets.
  Future<void> runCommand(String deviceId, String key) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.runRemoteCommand(key);
    } catch (e) {
      _logLine('Jalankan perintah gagal: $e');
    }
    notifyListeners();
  }

  /// M3: stop every command this phone started on a device.
  Future<void> stopCommands(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.stopRemoteCommands();
    } catch (e) {
      _logLine('Hentikan perintah gagal: $e');
    }
    notifyListeners();
  }

  /// M3: ask the desktop to open its command editor.
  Future<void> requestCommandSetup(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.requestRunCommandSetup();
    } catch (e) {
      _logLine('Buka editor perintah gagal: $e');
    }
    notifyListeners();
  }

  /// M4: move the desktop pointer by a relative delta. High-frequency
  /// traffic: successes stay silent, failures are logged.
  Future<void> sendMousepadMove(String deviceId, double dx, double dy) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadMove(dx, dy);
    } catch (e) {
      _logLine('Gerak pointer gagal: $e');
    }
  }

  /// M4: scroll by a relative delta (positive dy scrolls down).
  Future<void> sendMousepadScroll(String deviceId, double dx, double dy) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadScroll(dx, dy);
    } catch (e) {
      _logLine('Gulir gagal: $e');
    }
  }

  /// M4: click one mouse button.
  Future<void> sendMousepadClick(String deviceId, MousepadClick click) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadClick(click);
    } catch (e) {
      _logLine('Klik gagal: $e');
    }
    notifyListeners();
  }

  /// M4: press the left button down (true) or let it up (false).
  Future<void> sendMousepadHold(String deviceId, bool down) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadHold(down);
    } catch (e) {
      _logLine('Tahan klik gagal: $e');
    }
    notifyListeners();
  }

  /// M4: type one printable character, with optional modifiers.
  Future<void> sendMousepadKey(
    String deviceId,
    String char, [
    MousepadModifiers modifiers = const MousepadModifiers(),
  ]) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadKey(char, modifiers);
    } catch (e) {
      _logLine('Ketik gagal: $e');
    }
    notifyListeners();
  }

  /// M4: type a whole string at once.
  Future<void> sendMousepadType(String deviceId, String text) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadType(text);
    } catch (e) {
      _logLine('Ketik teks gagal: $e');
    }
    notifyListeners();
  }

  /// M4: press one special key by its daemon code, with optional
  /// modifiers.
  Future<void> sendMousepadSpecialKey(
    String deviceId,
    int code, [
    MousepadModifiers modifiers = const MousepadModifiers(),
  ]) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadSpecialKey(code, modifiers);
    } catch (e) {
      _logLine('Tombol khusus gagal: $e');
    }
    notifyListeners();
  }

  /// M5: move the presenter dot by a relative delta (fractions of
  /// the session monitor). High-frequency traffic: successes stay
  /// silent, failures are logged.
  Future<void> sendPresenterMove(String deviceId, double dx, double dy) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendPresenterMove(dx, dy);
    } catch (e) {
      _logLine('Gerak pointer presenter gagal: $e');
    }
  }

  /// M5: end the presenter session and hide the dot.
  Future<void> stopPresenter(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendPresenterStop();
    } catch (e) {
      _logLine('Berhenti presenter gagal: $e');
    }
    notifyListeners();
  }

  /// M5: ask the desktop for its monitor list (HyprConnect
  /// extension; a stock desktop never answers).
  Future<void> requestPresenterMonitors(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.requestPresenterMonitors();
    } catch (e) {
      _logLine('Gagal meminta daftar monitor: $e');
    }
    notifyListeners();
  }

  /// M5: pin the presenter pointer to one monitor (null = automatic).
  /// The stored value updates right away; the daemon confirms it by
  /// answering with the updated monitor list packet.
  Future<void> setPresenterMonitor(String deviceId, String? monitor) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    _presenterMonitors[deviceId] = monitor;
    try {
      await conn.setPresenterMonitor(monitor);
    } catch (e) {
      _logLine('Pilih monitor presenter gagal: $e');
    }
    notifyListeners();
  }

  /// M5: next slide (stock: mousepad specialKey 9, PageDown).
  Future<void> presenterNext(String deviceId) async {
    await sendMousepadSpecialKey(deviceId, PresenterKeys.next);
  }

  /// M5: previous slide (stock: mousepad specialKey 8, PageUp).
  Future<void> presenterPrevious(String deviceId) async {
    await sendMousepadSpecialKey(deviceId, PresenterKeys.previous);
  }

  /// M5: start fullscreen (stock: mousepad specialKey 25, F5).
  Future<void> presenterFullscreen(String deviceId) async {
    await sendMousepadSpecialKey(deviceId, PresenterKeys.fullscreen);
  }

  /// M5: exit the presentation (stock: mousepad specialKey 14, Esc).
  Future<void> presenterEscape(String deviceId) async {
    await sendMousepadSpecialKey(deviceId, PresenterKeys.escape);
  }

  /// M5: save presenter notes for a device, on this phone only.
  /// Without a notes file (tests) the text is kept in memory.
  Future<void> savePresenterNotes(String deviceId, String text) async {
    _presenterNotes[deviceId] = text;
    final file = _notesFile;
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode(_presenterNotes));
      } catch (e) {
        _logLine('Simpan catatan presenter gagal: $e');
      }
    }
    notifyListeners();
  }

  /// Send clipboard content to a device. Returns false when there is
  /// no connection or the content is empty; over-long content throws
  /// (the daemon would silently drop it).
  Future<bool> sendClipboard(String deviceId, String content) async {
    final conn = _connections[deviceId];
    if (conn == null || content.isEmpty) return false;
    _lastClipboardSent = content;
    try {
      await conn.sendClipboard(content);
      _logLine(
        'Papan klip terkirim ke ${conn.remoteName} '
        '(${content.length} karakter)',
      );
      notifyListeners();
      return true;
    } catch (e) {
      _logLine('Papan klip gagal: $e');
      notifyListeners();
      rethrow;
    }
  }

  /// Send a file to a device. [bytes] is streamed to the peer's
  /// payload connection; [onProgress] reports bytes sent.
  Future<void> sendFile(
    String deviceId, {
    required String filename,
    required int size,
    required Stream<List<int>> bytes,
    void Function(int sent)? onProgress,
  }) async {
    final conn = _connections[deviceId];
    if (conn == null) throw StateError('not connected');
    try {
      await conn.sendFile(
        filename: filename,
        size: size,
        bytes: bytes,
        onProgress: onProgress,
      );
      _logLine('File terkirim ke ${conn.remoteName}: $filename ($size byte)');
    } catch (e) {
      _logLine('File gagal: $e');
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// Current system clipboard text, or null when it holds no text.
  Future<String?> readClipboardText() async {
    final data = await Clipboard.getData('text/plain');
    return data?.text;
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
