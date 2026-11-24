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

import '../platform/native_bridge.dart';
import '../protocol/protocol.dart';
import '../settings/app_prefs.dart';
import '../settings/plugin_settings.dart';
import '../settings/remote_input_prefs.dart';

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
  RemoteInputPrefsStore? _remoteInputPrefs;
  AppPrefs? _prefs;
  Directory? _appDir;
  TcpListener? _listener;
  Discovery? _discovery;
  final Map<String, DiscoveredDevice> _found = {};

  /// Auto-connect bookkeeping: trusted devices heard on discovery
  /// are connected without the user tapping anything, with a short
  /// cooldown so a flapping peer is not dialled in a tight loop.
  final Set<String> _autoConnectInFlight = {};
  final Map<String, DateTime> _autoConnectLast = {};
  final Map<String, DeviceConnection> _connections = {};
  final List<String> _log = [];
  Directory? _receiveDir;
  final List<ReceivedFile> _receivedFiles = [];
  // Battery reporting: the last state sent per device, so the
  // periodic refresh only talks when something changed.
  final Map<String, String> _lastBatterySent = {};
  Timer? _batteryTimer;
  String? _lastReceivedClipboard;
  String? _lastReceivedFrom;
  DateTime? _lastReceivedAt;
  Directory? _artDir;
  // M3: per-device multimedia state (deviceId -> ...).
  final Map<String, List<String>> _playerLists = {};
  final Map<String, List<SinkState>> _sinks = {};
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
  String _status = 'Starting...';
  bool _started = false;

  LocalIdentity? get identity => _identity;
  TrustStore? get trust => _trust;

  /// Plugin settings; an in-memory default until initialize() loads
  /// the stored ones, so pages never see a null.
  PluginSettings get pluginSettings =>
      _pluginSettings ?? PluginSettings.inMemory();

  RemoteInputPrefsStore get remoteInputPrefsStore =>
      _remoteInputPrefs ?? RemoteInputPrefsStore.inMemory();

  /// App-wide preferences (theme, devices added by IP, setup
  /// gate). An in-memory default until one is injected, so pages
  /// and tests never see a null.
  AppPrefs get prefs => _prefs ?? _fallbackPrefs;
  final AppPrefs _fallbackPrefs = AppPrefs.inMemory();

  /// The remote input (mousepad) preferences for one device.
  RemoteInputPrefs remoteInputPrefsFor(String deviceId) =>
      remoteInputPrefsStore.forDevice(deviceId);

  Future<void> updateRemoteInputPrefs(
    String deviceId,
    RemoteInputPrefs prefs,
  ) async {
    await remoteInputPrefsStore.save(deviceId, prefs);
    notifyListeners();
  }

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
  /// Where received files end up for the user: they are staged
  /// in the app's private dir during transfer, then published
  /// into the public Download/HyprConnect folder. This label is
  /// what the settings page shows.
  String? get receiveDirPath =>
      _receiveDir == null ? null : 'Download/HyprConnect';

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
  AppState.test({
    required PluginSettings settings,
    RemoteInputPrefsStore? remoteInputPrefs,
  }) : _pluginSettings = settings {
    _remoteInputPrefs = remoteInputPrefs;
  }

  AppState({AppPrefs? prefs}) {
    _prefs = prefs;
  }

  Future<void> initialize() async {
    if (_started) return;
    _started = true;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _appDir = appDir;
      final identity = await LocalIdentity.loadOrCreate(
        appDir,
        deviceName: 'HyprConnect',
      );
      final trust = await TrustStore.load(appDir);
      final pluginSettings = await PluginSettings.load(appDir);
      final remoteInputPrefs = await RemoteInputPrefsStore.load(appDir);
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
        _maybeAutoConnect(device);
        notifyListeners();
      });
      await discovery.start();
      unawaited(() async {
        final report = await NativeBridge.startKeepAlive();
        if (report != null) _logLine('Keep-alive service: $report');
      }());
      _identity = identity;
      _trust = trust;
      _pluginSettings = pluginSettings;
      _remoteInputPrefs = remoteInputPrefs;
      _listener = listener;
      _discovery = discovery;
      if (!prefs.setupComplete && trust.devices.isNotEmpty) {
        // An install that already has paired devices is not a
        // fresh install: the first-run setup gate does not
        // apply to it.
        await prefs.markSetupComplete();
      }
      for (final ip in prefs.manualAddresses) {
        final address = InternetAddress.tryParse(ip);
        if (address != null) unawaited(discovery.probeAddress(address));
      }
      _status = 'Listening on port $port';
      _logLine('Identity: ${identity.deviceId}');
      // Battery levels drift while a connection lives: re-check
      // every minute and report only changes (explicit requests
      // from the desktop are answered separately, in the packet
      // dispatch).
      _batteryTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        for (final conn in _connections.values) {
          unawaited(_sendBattery(conn));
        }
      });
      notifyListeners();
    } catch (e) {
      _status = 'Failed to start: $e';
      notifyListeners();
    }
  }

  /// Staging dir for incoming files: HyprConnect/ under the
  /// app-specific external dir on Android. Files only pass
  /// through here; on completion they are published into the
  /// public Download/HyprConnect folder (see
  /// _publishReceivedFile), because the app-specific dir is
  /// hidden from file managers on modern Android.
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
          _logLine('Ping from ${conn.remoteName}');
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
        case 'kdeconnect.systemvolume':
          _handleSystemVolume(conn, packet);
        case 'kdeconnect.runcommand':
          _handleRunCommandList(conn, packet);
        case 'kdeconnect.runcommand.output':
          _handleRunCommandOutput(conn, packet);
        case 'kdeconnect.presenter':
          _handlePresenter(conn, packet);
        case 'kdeconnect.battery.request':
          if (packet.body['request'] == true) {
            await _sendBattery(conn, force: true);
          }
        case 'kdeconnect.sftp.request':
          await _handleSftpRequest(conn);
      }
    } catch (e) {
      _logLine('Failed to handle ${packet.type}: $e');
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
          _logLine('Failed to request album art: $e');
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
      _logLine('Album art received for $player (${bytes.length} bytes)');
    } catch (e) {
      _logLine('Failed to receive album art: $e');
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
      'Command list received from ${conn.remoteName} '
      '(${_commandLists[deviceId]!.length} commands)',
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
      'Monitor list received from ${conn.remoteName} '
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
      'Clipboard received from ${conn.remoteName} '
      '(${content.length} characters)',
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
      _logLine('Link shared from ${conn.remoteName}: $url');
      return;
    }
    final dir = _receiveDir;
    if (dir == null) {
      _logLine('No receive folder, file rejected');
      return;
    }
    try {
      final received = await conn.receiveFile(packet, dir);
      final published = await _publishReceivedFile(received);
      _receivedFiles.insert(0, published);
      _logLine(
        'File received: ${published.filename} (${published.size} bytes) '
        '-> ${published.path}',
      );
    } catch (e) {
      _logLine('Failed to receive file from ${conn.remoteName}: $e');
    }
  }

  /// Publish a freshly received file from the private staging
  /// dir into the public Download/HyprConnect folder, where the
  /// user can actually find it in a file manager. Falls back to
  /// the staged copy when the export is unavailable.
  Future<ReceivedFile> _publishReceivedFile(ReceivedFile received) async {
    final publicPath = await NativeBridge.exportToDownloads(
      received.path,
      received.filename,
    );
    if (publicPath == null) return received;
    try {
      await File(received.path).delete();
    } catch (_) {
      // A leftover staged copy is harmless.
    }
    return ReceivedFile(
      filename: received.filename,
      path: publicPath,
      size: received.size,
      deviceId: received.deviceId,
      deviceName: received.deviceName,
      receivedAt: received.receivedAt,
    );
  }

  /// Answer a battery request (and report changes while a
  /// connection lives): read the phone's battery natively and
  /// send the kdeconnect.battery packet the daemon stores for
  /// the desktop's device page. [force] bypasses the unchanged
  /// check for explicit requests.
  Future<void> _sendBattery(
    DeviceConnection conn, {
    bool force = false,
  }) async {
    if (!conn.isPaired || conn.disabledPlugins.contains('battery')) return;
    final status = await NativeBridge.batteryStatus();
    if (status == null) return;
    final level = (status['level'] as num?)?.toInt();
    final id = conn.remoteDeviceId;
    if (level == null || id == null) return;
    final charging = status['charging'] == true;
    final signature = '$level|$charging';
    if (!force && _lastBatterySent[id] == signature) return;
    _lastBatterySent[id] = signature;
    await conn.sendPacket(
      Packet.now('kdeconnect.battery', {
        'currentCharge': level,
        'isCharging': charging,
        'thresholdEvent': 0,
      }),
    );
  }

  /// A desktop wants to browse this phone: start the embedded
  /// SFTP server and answer with the kdeconnect.sftp parameter
  /// packet, like the stock app does. Without all-files access
  /// the shared storage cannot be served; the refusal is logged
  /// here and the desktop shows its own error.
  Future<void> _handleSftpRequest(DeviceConnection conn) async {
    if (!conn.isPaired || conn.disabledPlugins.contains('sftp')) return;
    await conn.sendPacket(
      Packet.now('kdeconnect.sftp', {'serverRunning': false}),
    );
    if (!await NativeBridge.hasAllFilesAccess()) {
      _logLine(
        'SFTP browse from ${conn.remoteName} refused: '
        'all-files access is not granted',
      );
      return;
    }
    final server = await NativeBridge.startSftpServer();
    if (server == null) {
      _logLine('SFTP server failed to start for ${conn.remoteName}');
      return;
    }
    final ip = await _localAddressFor(conn.remoteAddress);
    if (ip == null) {
      _logLine('SFTP: no local address to advertise');
      return;
    }
    await conn.sendPacket(
      Packet.now('kdeconnect.sftp', {
        'ip': ip,
        'port': server['port'],
        'user': server['user'],
        'password': server['password'],
        'path': '/storage/emulated/0',
        'multiPaths': ['/storage/emulated/0'],
        'pathNames': ['Internal storage'],
      }),
    );
    _logLine(
      'SFTP server started for ${conn.remoteName} on port ${server['port']}',
    );
  }

  /// The local IPv4 address a peer can reach us at: the one on
  /// the same subnet as the peer when that can be determined.
  Future<String?> _localAddressFor(InternetAddress? remote) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = [for (final iface in interfaces) ...iface.addresses];
      if (addresses.isEmpty) return null;
      if (remote != null && remote.type == InternetAddressType.IPv4) {
        final remoteParts = remote.address.split('.');
        for (final address in addresses) {
          final parts = address.address.split('.');
          if (parts.length == 4 &&
              remoteParts.length == 4 &&
              parts[0] == remoteParts[0] &&
              parts[1] == remoteParts[1] &&
              parts[2] == remoteParts[2]) {
            return address.address;
          }
        }
      }
      return addresses.first.address;
    } catch (_) {
      return null;
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
      final remoteId = conn.remoteDeviceId;
      if (remoteId != null && !_found.containsKey(remoteId)) {
        // First contact that did not come through a discovery
        // broadcast (for example a desktop added by IP that
        // connected back): give it a list entry so it can be
        // paired and opened like any discovered device. The
        // tcpPort is the protocol's first port; a broadcast
        // heard later corrects it.
        _found[remoteId] = DiscoveredDevice(
          deviceId: remoteId,
          name: conn.remoteName ?? '',
          deviceType: '',
          address: raw.remoteAddress,
          tcpPort: 1714,
        );
      }
      _logLine(
        'Connected (incoming) from ${conn.remoteName} (${conn.remoteDeviceId})',
      );
    } catch (e) {
      _logLine('Incoming connection failed: $e');
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
      if (state == PairState.pendingIn) {
        unawaited(
          NativeBridge.showPairingNotification(
            deviceName: conn.remoteName ?? '',
            deviceId: id,
          ),
        );
      } else {
        unawaited(NativeBridge.cancelPairingNotification(id));
      }
      notifyListeners();
    });
    conn.packets.listen(
      (packet) {
        unawaited(handleIncomingPacket(conn, packet));
      },
      onDone: () {
        // The channel ended: forget the connection so offline
        // devices disappear from the drawer and the shell again.
        if (_connections[id] == conn) {
          _connections.remove(id);
          _lastBatterySent.remove(id);
          // The browse server only exists for a live peer.
          unawaited(NativeBridge.stopSftpServer());
          notifyListeners();
        }
      },
    );
    notifyListeners();
  }

  void _logLine(String line) {
    _log.add(line);
    if (_log.length > 100) _log.removeRange(0, _log.length - 100);
  }

  /// Re-announce ourselves and retry auto-connects when the app
  /// comes back to the foreground: whatever the system did to the
  /// network while we were backgrounded, this is the cheap moment
  /// to heal the connection.
  void onResumed() {
    unawaited(() async {
      final status = await NativeBridge.keepAliveStatus();
      if (status != null) {
        _logLine('Keep-alive status: $status');
        if (status.startsWith('running=false')) {
          final report = await NativeBridge.startKeepAlive();
          if (report != null) _logLine('Keep-alive restart: $report');
        }
      }
    }());
    _discovery?.broadcastIdentity();
    final discovery = _discovery;
    if (discovery != null) {
      for (final ip in prefs.manualAddresses) {
        final address = InternetAddress.tryParse(ip);
        if (address != null) unawaited(discovery.probeAddress(address));
      }
    }
    for (final device in _found.values) {
      _maybeAutoConnect(device);
    }
    for (final conn in _connections.values) {
      unawaited(_sendBattery(conn));
    }
  }

  /// Connect to a trusted device that discovery just heard, unless
  /// it is already connected or an attempt is fresh. First pairing
  /// stays a deliberate user action and is never auto-started.
  void _maybeAutoConnect(DiscoveredDevice device) {
    final trust = _trust;
    if (trust == null || !trust.isTrusted(device.deviceId)) return;
    if (_connections[device.deviceId]?.isConnected ?? false) return;
    if (!_autoConnectInFlight.add(device.deviceId)) return;
    final last = _autoConnectLast[device.deviceId];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 10)) {
      _autoConnectInFlight.remove(device.deviceId);
      return;
    }
    _autoConnectLast[device.deviceId] = DateTime.now();
    final entry = DeviceListEntry(
      deviceId: device.deviceId,
      name: device.name,
      deviceType: device.deviceType,
      address: device.address,
      tcpPort: device.tcpPort,
      online: true,
      trusted: true,
    );
    unawaited(
      connectTo(entry)
          .whenComplete(() => _autoConnectInFlight.remove(device.deviceId)),
    );
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
      _logLine('Waiting for ${entry.name} to connect back for first pairing');
      _discovery?.broadcastIdentity();
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final conn = _connections[entry.deviceId];
        if (conn != null && conn.isConnected) {
          _logLine('Incoming channel from ${entry.name} is open');
          return ConnectOutcome.connected;
        }
      }
      _logLine('${entry.name} did not connect back within 25 seconds');
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
      _logLine('Connected (outgoing) to ${entry.name}');
      return ConnectOutcome.connected;
    } catch (e) {
      _logLine('Failed to connect to ${entry.name}: $e');
      notifyListeners();
      return ConnectOutcome.failed;
    }
  }

  /// Rename this device. The new name is stored in device.json
  /// (the identity's own file), swapped into the live identity,
  /// and announced at once; channels that are already open keep
  /// the name they were opened with until they reconnect.
  Future<void> setDeviceName(String name) async {
    final identity = _identity;
    final dir = _appDir;
    final trimmed = name.trim();
    if (identity == null || dir == null || trimmed.isEmpty) return;
    if (trimmed == identity.deviceName) return;
    await File('${dir.path}/device.json').writeAsString(
      jsonEncode({'deviceId': identity.deviceId, 'deviceName': trimmed}),
    );
    final updated = LocalIdentity(
      deviceId: identity.deviceId,
      deviceName: trimmed,
      certPem: identity.certPem,
      keyPem: identity.keyPem,
      certDer: identity.certDer,
      spkiDer: identity.spkiDer,
    );
    _identity = updated;
    final discovery = _discovery;
    if (discovery != null) {
      discovery.identity = updated;
      discovery.broadcastIdentity();
    }
    _logLine('Device name changed to $trimmed');
    notifyListeners();
  }

  /// Store an address added by hand and announce ourselves to
  /// it right away.
  Future<void> addManualAddress(String address) async {
    await prefs.addManualAddress(address);
    probeManualAddress(address);
    notifyListeners();
  }

  Future<void> removeManualAddress(String address) async {
    await prefs.removeManualAddress(address);
    notifyListeners();
  }

  /// Announce ourselves directly to one stored address.
  void probeManualAddress(String address) {
    final discovery = _discovery;
    final parsed = InternetAddress.tryParse(address);
    if (discovery == null || parsed == null) return;
    unawaited(discovery.probeAddress(parsed));
  }

  /// True while this is a fresh install (no paired devices yet)
  /// whose first-run setup gate has not been completed.
  bool get setupGateRequired {
    if (prefs.setupComplete) return false;
    final trust = _trust;
    if (trust == null) return false;
    return trust.devices.isEmpty;
  }

  /// Mark the first-run setup gate as passed.
  Future<void> completeSetup() async {
    await prefs.markSetupComplete();
    notifyListeners();
  }

  /// Write the session log to a file in the received files
  /// folder, where it can be found with a file manager. Returns
  /// the file's path, or null when the folder is not known yet.
  Future<String?> exportLog() async {
    final dir = _receiveDir;
    if (dir == null) return null;
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final file = File('${dir.path}/hyprconnect-log-$stamp.txt');
    final buffer = StringBuffer()
      ..writeln('HyprConnect session log, exported $now')
      ..writeln(
        'Identity: ${_identity?.deviceId ?? '-'} '
        '(${_identity?.deviceName ?? '-'})',
      )
      ..writeln('Status: $_status')
      ..writeln();
    for (final line in _log) {
      buffer.writeln(line);
    }
    await file.writeAsString(buffer.toString());
    // Publish into Download/HyprConnect like received files, so
    // the export is findable with a file manager too.
    final publicPath = await NativeBridge.exportToDownloads(
      file.path,
      file.uri.pathSegments.last,
    );
    if (publicPath != null) {
      try {
        await file.delete();
      } catch (_) {}
      _logLine('Log exported to $publicPath');
      return publicPath;
    }
    _logLine('Log exported to ${file.path}');
    return file.path;
  }

  Future<void> requestPair(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.requestPair();
      _logLine('Requesting pairing with ${conn.remoteName}');
    } catch (e) {
      _logLine('Pairing failed: $e');
    }
    notifyListeners();
  }

  Future<void> rejectPair(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.rejectPair();
      _logLine('Rejecting pairing from ${conn.remoteName}');
    } catch (e) {
      _logLine('Reject pairing failed: $e');
    }
    notifyListeners();
  }

  /// The desktop's audio sinks as last reported, for the
  /// multimedia page's Peranti tab.
  List<SinkState> sinksFor(String deviceId) {
    return List.unmodifiable(_sinks[deviceId] ?? const []);
  }

  /// A kdeconnect.systemvolume packet arrived: either the full
  /// sink list or one sink's volume / mute update.
  void _handleSystemVolume(DeviceConnection conn, Packet packet) {
    final deviceId = conn.remoteDeviceId;
    if (deviceId == null) return;
    final list = SinkState.sinkListOf(packet);
    if (list != null) {
      _sinks[deviceId] = list;
      return;
    }
    final name = packet.body['name'] as String?;
    if (name == null) return;
    final sinks = _sinks[deviceId];
    if (sinks == null) return;
    final index = sinks.indexWhere((sink) => sink.name == name);
    if (index < 0) return;
    final volume = (packet.body['volume'] as num?)?.toInt();
    final muted = packet.body['muted'] as bool?;
    if (volume == null && muted == null) return;
    sinks[index] = sinks[index].copyWith(volume: volume, muted: muted);
  }

  /// Ask a device for its audio sink list (the Peranti tab).
  Future<void> requestSinks(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.requestSinks();
    } catch (e) {
      _logLine('Failed to request audio device list: $e');
    }
    notifyListeners();
  }

  /// Set one sink's volume from a 0..100 percent (the daemon works
  /// in raw PulseAudio units). Setting the volume unmutes.
  Future<void> setSinkVolume(
    String deviceId,
    SinkState sink,
    int percent,
  ) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    final raw = (percent.clamp(0, 100) * sink.maxVolume / 100).round();
    try {
      await conn.sendSinkVolume(sink.name, raw);
    } catch (e) {
      _logLine('Failed to set device volume: $e');
    }
    notifyListeners();
  }

  /// Mute or unmute one sink.
  Future<void> setSinkMuted(String deviceId, SinkState sink, bool muted) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendSinkMuted(sink.name, muted);
    } catch (e) {
      _logLine('Failed to set device mute: $e');
    }
    notifyListeners();
  }

  /// Make one sink the desktop's default output.
  Future<void> selectSink(String deviceId, SinkState sink) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendSinkEnabled(sink.name);
    } catch (e) {
      _logLine('Failed to select audio device: $e');
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
      _logLine('Failed to request player list: $e');
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
        _logLine('Failed to request player status: $e');
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
      _logLine('Multimedia control failed: $e');
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
      _logLine('Failed to set volume: $e');
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
      _logLine('Seek failed: $e');
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
      _logLine('Failed to set position: $e');
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
      _logLine('Failed to request command list: $e');
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
      _logLine('Run command failed: $e');
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
      _logLine('Stop commands failed: $e');
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
      _logLine('Failed to open command editor: $e');
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
      _logLine('Pointer move failed: $e');
    }
  }

  /// M4: scroll by a relative delta (positive dy scrolls down).
  Future<void> sendMousepadScroll(String deviceId, double dx, double dy) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadScroll(dx, dy);
    } catch (e) {
      _logLine('Scroll failed: $e');
    }
  }

  /// M4: click one mouse button.
  Future<void> sendMousepadClick(String deviceId, MousepadClick click) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendMousepadClick(click);
    } catch (e) {
      _logLine('Click failed: $e');
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
      _logLine('Click hold failed: $e');
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
      _logLine('Typing failed: $e');
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
      _logLine('Type text failed: $e');
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
      _logLine('Special key failed: $e');
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
      _logLine('Presenter pointer move failed: $e');
    }
  }

  /// M5: end the presenter session and hide the dot.
  Future<void> stopPresenter(String deviceId) async {
    final conn = _connections[deviceId];
    if (conn == null) return;
    try {
      await conn.sendPresenterStop();
    } catch (e) {
      _logLine('Presenter stop failed: $e');
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
      _logLine('Failed to request monitor list: $e');
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
      _logLine('Failed to set presenter monitor: $e');
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
        _logLine('Failed to save presenter notes: $e');
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
        'Clipboard sent to ${conn.remoteName} '
        '(${content.length} characters)',
      );
      notifyListeners();
      return true;
    } catch (e) {
      _logLine('Clipboard failed: $e');
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
      _logLine('File sent to ${conn.remoteName}: $filename ($size bytes)');
    } catch (e) {
      _logLine('File failed: $e');
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
      await conn.sendPing(message ?? 'Hello from HyprConnect');
      _logLine('Ping sent to ${conn.remoteName}');
    } catch (e) {
      _logLine('Ping failed: $e');
    }
    notifyListeners();
  }

  /// Unpair and drop the connection; the device stays listed.
  Future<void> unpair(String deviceId) async {
    final conn = _connections.remove(deviceId);
    if (conn == null) return;
    try {
      await conn.unpair();
      _logLine('Unpaired from ${conn.remoteName}');
    } catch (e) {
      _logLine('Unpair failed: $e');
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
    _batteryTimer?.cancel();
    for (final conn in _connections.values) {
      unawaited(conn.close());
    }
    unawaited(_discovery?.stop());
    unawaited(_listener?.stop());
    super.dispose();
  }
}
