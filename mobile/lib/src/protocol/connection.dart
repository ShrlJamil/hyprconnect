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
import 'packet.dart';
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
  PairState _pairState = PairState.unknown;

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
      throw FormatException(
        'first packet is not identity: ${packet.type}',
      );
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
        .listen(
          _onLine,
          onError: (_) => close(),
          onDone: () => close(),
        );
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
