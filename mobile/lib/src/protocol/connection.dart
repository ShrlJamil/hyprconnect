//! One encrypted channel to a peer device.
//!
//! Connection opening (mirrors the daemon's connect_to /
//! handle_incoming in src/main.rs):
//! - The TCP opener sends its identity in plaintext first, then acts
//!   as the TLS server; the acceptor acts as the TLS client. SNI names
//!   the peer device id.
//! - After TLS, the identity is re-sent over the encrypted channel.
//! - Certificates are self-signed; trust is trust-on-first-use at the
//!   app level (pairing), not at the handshake.
//!
//! Dart limitation, verified by probe (test/tls_test.dart): a Dart TLS
//! server only accepts a client certificate that is in its trusted
//! certificates. So the opener role needs the peer certificate up
//! front, from the trust store or from an earlier incoming connection.
//! First pairing with a never-seen desktop therefore starts from the
//! desktop (it connects to the phone, the phone is the TLS client and
//! accepts any certificate); after that the phone knows the desktop
//! certificate and can open connections itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'identity.dart';
import 'mpris.dart';
import 'mousepad.dart';
import 'runcommand.dart';
import 'packet.dart';
import 'payload.dart';
import 'presenter.dart';
import 'trust_store.dart';

enum PairState { unknown, unpaired, pendingOut, pendingIn, paired }

class DeviceConnection {
  final LocalIdentity identity;
  final TrustStore trust;
  final int tcpPort;

  SecureSocket? _socket;
  StreamSubscription<String>? _lineSubscription;
  final _packetController = StreamController<Packet>.broadcast();
  final _pairController = StreamController<PairState>.broadcast();

  String? remoteDeviceId;
  String? remoteName;
  String? remoteType;
  Uint8List? peerCertDer;
  Uint8List? peerSpki;

  /// Address of the peer on this channel, for payload connections
  /// (the receiver connects back to the sender's payload port).
  InternetAddress? remoteAddress;
  PairState _pairState = PairState.unknown;

  /// Plugins the user switched off for this peer. They are filtered
  /// out of the identity this channel advertises (see Packet.identity).
  /// Set before the handshake; changing it later only takes effect on
  /// the next connection.
  Set<String> disabledPlugins = const {};

  DeviceConnection({
    required this.identity,
    required this.trust,
    required this.tcpPort,
  });

  Stream<Packet> get packets => _packetController.stream;
  Stream<PairState> get pairStates => _pairController.stream;

  PairState get pairState => _pairState;
  bool get isPaired => _pairState == PairState.paired;
  bool get isConnected => _socket != null;

  /// The pairing verification key for this channel, or null when the
  /// peer certificate is not known yet. Computed exactly like the
  /// daemon's identity::verification_key.
  String? get verificationKey {
    final peer = peerSpki;
    if (peer == null) return null;
    return LocalIdentity.verificationKey(identity.spkiDer, peer);
  }

  SecurityContext _clientContext() {
    return SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certPem))
      ..usePrivateKeyBytes(utf8.encode(identity.keyPem));
  }

  SecurityContext _serverContext(Uint8List peerCertDer) {
    return SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certPem))
      ..usePrivateKeyBytes(utf8.encode(identity.keyPem))
      // The peer's own self-signed certificate is the trust anchor
      // for its client certificate (see the module doc).
      ..setTrustedCertificatesBytes(_pemOf(peerCertDer));
  }

  List<int> _pemOf(Uint8List certDer) {
    final base64 = base64Encode(certDer);
    final buf = StringBuffer('-----BEGIN CERTIFICATE-----\n');
    for (var i = 0; i < base64.length; i += 64) {
      final end = i + 64 < base64.length ? i + 64 : base64.length;
      buf.writeln(base64.substring(i, end));
    }
    buf.write('-----END CERTIFICATE-----\n');
    return utf8.encode(buf.toString());
  }

  /// Open a connection to a peer: TCP connect, plaintext identity,
  /// then TLS as the server. [peerCertDer] must be the peer's
  /// certificate (from the trust store or an earlier connection).
  Future<void> connectOutgoing({
    required InternetAddress address,
    required int tcpPort,
    required String deviceId,
    required String name,
    required String deviceType,
    required Uint8List peerCertDer,
  }) async {
    remoteDeviceId = deviceId;
    remoteName = name;
    remoteType = deviceType;
    final raw = await Socket.connect(
      address,
      tcpPort,
      timeout: const Duration(seconds: 10),
    );
    raw.write(_identityPacket().toLine());
    await raw.flush();
    final secure = await SecureSocket.secureServer(
      raw,
      _serverContext(peerCertDer),
      requestClientCertificate: true,
      requireClientCertificate: true,
    ).timeout(const Duration(seconds: 10));
    await _finishHandshake(secure);
  }

  /// Accept a connection the peer opened: read its plaintext identity,
  /// then TLS as the client (SNI names the peer device id).
  Future<void> acceptIncoming(Socket raw) async {
    final line = await _readLine(raw);
    if (line == null) {
      throw const SocketException('peer closed before plaintext identity');
    }
    final parsed = jsonDecode(line);
    if (parsed is! Map<String, dynamic>) {
      throw const FormatException('plaintext identity is not JSON');
    }
    final packet = Packet.fromJson(parsed);
    if (packet.type != 'kdeconnect.identity') {
      throw FormatException('first packet is not identity: ${packet.type}');
    }
    final deviceId = packet.body['deviceId'] as String?;
    if (deviceId == null || !LocalIdentity.validDeviceId(deviceId)) {
      throw const FormatException('invalid device id in identity');
    }
    remoteDeviceId = deviceId;
    remoteName = packet.body['deviceName'] as String? ?? '';
    remoteType = packet.body['deviceType'] as String? ?? '';
    final secure = await SecureSocket.secure(
      raw,
      host: deviceId,
      context: _clientContext(),
      onBadCertificate: (_) => true,
    ).timeout(const Duration(seconds: 10));
    await _finishHandshake(secure);
  }

  Future<void> _finishHandshake(SecureSocket secure) async {
    final peerCert = secure.peerCertificate;
    if (peerCert == null) {
      await secure.close();
      throw const SocketException('peer presented no certificate');
    }
    final certDer = peerCert.der;
    final info = LocalIdentity.certInfo(certDer);
    if (info.commonName != remoteDeviceId) {
      await secure.close();
      throw SocketException(
        'certificate CN ${info.commonName} does not match '
        'identity deviceId $remoteDeviceId',
      );
    }
    peerCertDer = certDer;
    peerSpki = info.spki;
    remoteAddress = secure.remoteAddress;
    _socket = secure;
    await sendPacket(_identityPacket());
    _setPairState(
      trust.certMatches(remoteDeviceId!, certDer)
          ? PairState.paired
          : PairState.unpaired,
    );
    _startReadLoop(secure);
  }

  Packet _identityPacket() {
    return Packet.identity(
      deviceId: identity.deviceId,
      deviceName: identity.deviceName,
      tcpPort: tcpPort,
      disabledPlugins: disabledPlugins,
    );
  }

  /// Read one newline-terminated line from [socket], keeping the
  /// subscription paused (not cancelled) so the TLS upgrade keeps any
  /// bytes already buffered. Returns null on timeout/close.
  Future<String?> _readLine(Socket socket) async {
    final buffer = <int>[];
    final completer = Completer<String?>();
    late StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        final newline = buffer.indexOf(10);
        if (newline >= 0) {
          final line = utf8.decode(buffer.sublist(0, newline)).trim();
          subscription.pause();
          if (!completer.isCompleted) completer.complete(line);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
      cancelOnError: true,
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await subscription.cancel();
      return null;
    }
  }

  void _startReadLoop(SecureSocket secure) {
    _lineSubscription = secure
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (_) => close(), onDone: () => close());
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      final json = jsonDecode(trimmed);
      if (json is! Map<String, dynamic>) return;
      final packet = Packet.fromJson(json);
      if (packet.type == 'kdeconnect.identity') {
        // Encrypted identity exchange: the device id must not change
        // mid-channel (daemon's register_channel does the same check).
        if (packet.body['deviceId'] != remoteDeviceId) {
          close();
        }
        return;
      }
      _handlePacket(packet);
      _packetController.add(packet);
    } catch (_) {
      // A malformed line is ignored, like the daemon does.
    }
  }

  void _handlePacket(Packet packet) {
    if (packet.type != 'kdeconnect.pair') return;
    final pair = packet.body['pair'] as bool? ?? false;
    if (pair) {
      if (_pairState == PairState.pendingOut) {
        _completePairing();
      } else if (_pairState != PairState.paired) {
        _setPairState(PairState.pendingIn);
      }
    } else {
      _setPairState(PairState.unpaired);
      final id = remoteDeviceId;
      if (id != null) unawaited(trust.remove(id));
    }
  }

  Future<void> _completePairing() async {
    final id = remoteDeviceId;
    final cert = peerCertDer;
    if (id != null && cert != null) {
      await trust.add(
        TrustedDevice(
          deviceId: id,
          name: remoteName ?? '',
          deviceType: remoteType ?? '',
          certHex: hexEncode(cert),
        ),
      );
    }
    _setPairState(PairState.paired);
  }

  void _setPairState(PairState state) {
    _pairState = state;
    _pairController.add(state);
  }

  /// Ask the peer to pair. If the peer asked first, this accepts and
  /// completes pairing immediately (mirrors the daemon's accept_pair).
  Future<void> requestPair() async {
    await sendPacket(Packet.pair(true));
    if (_pairState == PairState.pendingIn) {
      await _completePairing();
    } else if (_pairState != PairState.paired) {
      _setPairState(PairState.pendingOut);
    }
  }

  /// End pairing with this peer: send pair:false (the daemon
  /// treats it as unpair), forget the trusted certificate, and close
  /// the channel. The peer stays discoverable; pairing again starts
  /// from scratch.
  Future<void> unpair() async {
    await sendPacket(Packet.pair(false));
    final id = remoteDeviceId;
    if (id != null) await trust.remove(id);
    _setPairState(PairState.unpaired);
    await close();
  }

  /// Decline an incoming pair request: send pair:false without
  /// touching the trust store (an existing trust entry, if any, is
  /// kept, unlike unpair which removes it).
  Future<void> rejectPair() async {
    await sendPacket(Packet.pair(false));
    _setPairState(PairState.unpaired);
  }

  /// Send clipboard content to the peer (kdeconnect.clipboard).
  /// Content longer than the daemon's limit is refused up front:
  /// the daemon would silently drop it.
  Future<void> sendClipboard(String content) async {
    if (content.length > maxClipboardChars) {
      throw ArgumentError(
        'clipboard content exceeds $maxClipboardChars characters',
      );
    }
    await sendPacket(Packet.now('kdeconnect.clipboard', {'content': content}));
  }

  /// Offer a file to the peer (kdeconnect.share.request + payload).
  /// Mirrors the daemon's send_file: listen on a payload port, send
  /// the share packet naming it, then serve [bytes] over one TLS
  /// connection where this side is the server (natural payload roles).
  /// [filename] is sent as-is; the receiver sanitizes it. [onProgress]
  /// reports bytes streamed so the UI can show progress.
  Future<void> sendFile({
    required String filename,
    required int size,
    required Stream<List<int>> bytes,
    void Function(int sent)? onProgress,
  }) async {
    final peerCert = peerCertDer;
    final peerId = remoteDeviceId;
    if (peerCert == null || peerId == null) {
      throw StateError('not connected');
    }
    if (size < 0) throw ArgumentError('negative file size');
    // Payload port: first free port in 1739-1764 like the daemon,
    // then any ephemeral port.
    ServerSocket? server;
    for (var port = 1739; port <= 1764; port++) {
      try {
        server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        break;
      } on SocketException {
        continue;
      }
    }
    server ??= await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      await sendPacket(
        Packet(
          id: DateTime.now().millisecondsSinceEpoch,
          type: 'kdeconnect.share.request',
          body: {'filename': filename},
          payloadSize: size,
          payloadTransferInfo: {'port': server.port},
        ),
      );
      final raw = await server.first.timeout(const Duration(seconds: 120));
      final secure = await SecureSocket.secureServer(
        raw,
        _serverContext(peerCert),
        requestClientCertificate: true,
        requireClientCertificate: true,
      ).timeout(const Duration(seconds: 10));
      final presented = secure.peerCertificate;
      if (presented == null) {
        await secure.close();
        throw const SocketException('payload peer presented no certificate');
      }
      final info = LocalIdentity.certInfo(presented.der);
      if (info.commonName != peerId) {
        await secure.close();
        throw SocketException(
          'payload peer CN ${info.commonName} is not $peerId',
        );
      }
      var sent = 0;
      await for (final chunk in bytes) {
        secure.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent);
      }
      await secure.flush();
      await secure.close();
    } finally {
      await server.close();
    }
  }

  /// Receive a file the peer offered with a share.request packet:
  /// connect to its payload port as the TLS client (natural payload
  /// roles), verify the peer certificate CN, read exactly
  /// payloadSize bytes, and save them under [saveDir] with a
  /// sanitized, deduplicated name. Throws when the packet carries no
  /// payload info or the stream ends early (a partial file is deleted).
  Future<ReceivedFile> receiveFile(Packet packet, Directory saveDir) async {
    final peerId = remoteDeviceId;
    final address = remoteAddress;
    if (peerId == null || address == null) {
      throw StateError('not connected');
    }
    final size = packet.payloadSize;
    final port = (packet.payloadTransferInfo?['port'] as num?)?.toInt();
    if (size == null || size < 0 || port == null) {
      throw const FormatException('share.request without payload info');
    }
    final filename = sanitizeSharedFilename(packet.body['filename'] as String?);
    final raw = await Socket.connect(
      address,
      port,
      timeout: const Duration(seconds: 10),
    );
    final secure = await SecureSocket.secure(
      raw,
      host: peerId,
      context: _clientContext(),
      onBadCertificate: (_) => true,
    ).timeout(const Duration(seconds: 10));
    final presented = secure.peerCertificate;
    if (presented == null) {
      await secure.close();
      throw const SocketException('payload peer presented no certificate');
    }
    final info = LocalIdentity.certInfo(presented.der);
    if (info.commonName != peerId) {
      await secure.close();
      throw SocketException(
        'payload peer CN ${info.commonName} is not $peerId',
      );
    }
    await saveDir.create(recursive: true);
    final file = File(uniqueFilePath(saveDir, filename));
    final sink = file.openWrite();
    var remaining = size;
    try {
      await for (final chunk in secure) {
        if (remaining <= 0) break;
        final take = chunk.length <= remaining
            ? chunk
            : chunk.sublist(0, remaining);
        sink.add(take);
        remaining -= take.length;
        if (remaining == 0) break;
      }
      await sink.flush();
    } finally {
      await sink.close();
      await secure.close();
    }
    if (remaining > 0) {
      await file.delete();
      throw StateError(
        'payload ended early, $remaining of $size bytes missing',
      );
    }
    return ReceivedFile(
      filename: filename,
      path: file.path,
      size: size,
      deviceId: peerId,
      deviceName: remoteName ?? '',
      receivedAt: DateTime.now(),
    );
  }

  /// Multimedia control (M3): ask for the desktop player list.
  /// The daemon answers with one kdeconnect.mpris state packet per
  /// player plus a final {"playerList": [...]} packet.
  Future<void> requestMprisPlayerList() async {
    await sendPacket(mprisRequestPlayerList());
  }

  /// Ask for one player's current now-playing state.
  Future<void> requestMprisNowPlaying(String player) async {
    await sendPacket(mprisRequestNowPlaying(player));
  }

  /// Send one playback action (Play, Pause, PlayPause, Next,
  /// Previous, Stop). The daemon pushes a fresh state packet after
  /// the action lands.
  Future<void> sendMprisAction(String player, String action) async {
    await sendPacket(mprisAction(player, action));
  }

  /// Set the player volume, 0..100 (clamped by the packet builder).
  Future<void> sendMprisVolume(String player, int volume) async {
    await sendPacket(mprisSetVolume(player, volume));
  }

  /// Seek relative to the current position, in microseconds
  /// (10 seconds = 10000000).
  Future<void> sendMprisSeek(String player, int microseconds) async {
    await sendPacket(mprisSeek(player, microseconds));
  }

  /// Jump to an absolute position, in microseconds.
  Future<void> sendMprisSetPosition(String player, int microseconds) async {
    await sendPacket(mprisSetPosition(player, microseconds));
  }

  /// Pull the album art for a file:// url the daemon currently
  /// reports for this player. The answer is a kdeconnect.mpris
  /// packet flagged transferringAlbumArt with a payload; read it
  /// with [receiveBytes].
  Future<void> requestMprisAlbumArt(String player, String url) async {
    await sendPacket(mprisRequestAlbumArt(player, url));
  }

  /// Run commands (M3): ask for the desktop's predefined list.
  Future<void> requestRunCommandList() async {
    await sendPacket(runCommandRequestList());
  }

  /// Run one predefined command by its key. The daemon streams
  /// kdeconnect.runcommand.output packets back on this channel.
  Future<void> runRemoteCommand(String key) async {
    await sendPacket(runCommandRun(key));
  }

  /// Stop every command this phone started (the daemon kills them).
  Future<void> stopRemoteCommands() async {
    await sendPacket(runCommandStop());
  }

  /// Ask the desktop to open its command editor.
  Future<void> requestRunCommandSetup() async {
    await sendPacket(runCommandSetup());
  }

  /// Remote input (M4): move the desktop pointer by a relative delta,
  /// in layout pixels. The daemon accumulates deltas and flushes them
  /// to its virtual pointer, so callers can send every drag update.
  Future<void> sendMousepadMove(double dx, double dy) async {
    await sendPacket(mousepadMove(dx, dy));
  }

  /// Remote input (M4): scroll by a relative delta (positive dy
  /// scrolls down).
  Future<void> sendMousepadScroll(double dx, double dy) async {
    await sendPacket(mousepadScroll(dx, dy));
  }

  /// Remote input (M4): click one mouse button.
  Future<void> sendMousepadClick(MousepadClick click) async {
    await sendPacket(mousepadClick(click));
  }

  /// Remote input (M4): press the left button down (true) or let it
  /// up again (false), for dragging while the touchpad is held.
  Future<void> sendMousepadHold(bool down) async {
    await sendPacket(mousepadHold(down));
  }

  /// Remote input (M4): type one printable character, with optional
  /// modifiers (Ctrl/Alt/Shift/Super).
  Future<void> sendMousepadKey(
    String char, [
    MousepadModifiers modifiers = const MousepadModifiers(),
  ]) async {
    await sendPacket(mousepadKey(char, modifiers));
  }

  /// Remote input (M4): type a whole string at once (the daemon runs
  /// `ydotool type`).
  Future<void> sendMousepadType(String text) async {
    await sendPacket(mousepadType(text));
  }

  /// Remote input (M4): press one special key by its daemon code
  /// (1 Backspace, 12 Enter, 14 Esc, 21..32 F1..F12, ...), with
  /// optional modifiers.
  Future<void> sendMousepadSpecialKey(
    int code, [
    MousepadModifiers modifiers = const MousepadModifiers(),
  ]) async {
    await sendPacket(mousepadSpecialKey(code, modifiers));
  }

  /// Presentation remote (M5): move the presenter dot by a relative
  /// delta (fractions of the session monitor). The first delta
  /// starts the session on the desktop.
  Future<void> sendPresenterMove(double dx, double dy) async {
    await sendPacket(presenterMove(dx, dy));
  }

  /// End the presenter session and hide the dot.
  Future<void> sendPresenterStop() async {
    await sendPacket(presenterStop());
  }

  /// Ask the desktop for its monitor list (HyprConnect extension).
  /// The answer arrives as a kdeconnect.presenter packet with
  /// "monitors" and "presenterMonitor"; a stock desktop never
  /// answers, and the caller just keeps the picker hidden.
  Future<void> requestPresenterMonitors() async {
    await sendPacket(presenterRequestMonitorList());
  }

  /// Pin the presenter pointer to one monitor (HyprConnect
  /// extension). Null means automatic. The daemon answers with the
  /// updated monitor list packet.
  Future<void> setPresenterMonitor(String? monitor) async {
    await sendPacket(presenterSetMonitor(monitor));
  }

  /// Receive a payload the peer offered (album art, or any packet
  /// with payloadSize/payloadTransferInfo) into memory: connect to
  /// its payload port as the TLS client, verify the peer CN, and
  /// read exactly payloadSize bytes.
  Future<Uint8List> receiveBytes(Packet packet) async {
    final peerId = remoteDeviceId;
    final address = remoteAddress;
    if (peerId == null || address == null) {
      throw StateError('not connected');
    }
    final size = packet.payloadSize;
    final port = (packet.payloadTransferInfo?['port'] as num?)?.toInt();
    if (size == null || size < 0 || port == null) {
      throw const FormatException('packet without payload info');
    }
    final raw = await Socket.connect(
      address,
      port,
      timeout: const Duration(seconds: 10),
    );
    final secure = await SecureSocket.secure(
      raw,
      host: peerId,
      context: _clientContext(),
      onBadCertificate: (_) => true,
    ).timeout(const Duration(seconds: 10));
    try {
      final presented = secure.peerCertificate;
      if (presented == null) {
        throw const SocketException('payload peer presented no certificate');
      }
      final info = LocalIdentity.certInfo(presented.der);
      if (info.commonName != peerId) {
        throw SocketException(
          'payload peer CN ${info.commonName} is not $peerId',
        );
      }
      final out = BytesBuilder();
      var remaining = size;
      await for (final chunk in secure) {
        if (remaining <= 0) break;
        final take = chunk.length <= remaining
            ? chunk
            : chunk.sublist(0, remaining);
        out.add(take);
        remaining -= take.length;
        if (remaining == 0) break;
      }
      if (remaining > 0) {
        throw StateError(
          'payload ended early, $remaining of $size bytes missing',
        );
      }
      return out.takeBytes();
    } finally {
      await secure.close();
    }
  }

  Future<void> sendPing([String? message]) async {
    await sendPacket(Packet.ping(message));
  }

  Future<void> sendPacket(Packet packet) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('not connected');
    }
    socket.write(packet.toLine());
    await socket.flush();
  }

  Future<void> close() async {
    await _lineSubscription?.cancel();
    _lineSubscription = null;
    await _socket?.close();
    _socket = null;
  }
}
