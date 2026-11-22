//! TCP listener for incoming connections (the daemon connects back to
//! trusted devices it discovers). Tries ports 1714-1764, like the
//! daemon's TCP_FIRST..TCP_LAST range.

import 'dart:async';
import 'dart:io';

class TcpListener {
  ServerSocket? _server;
  // Single-subscription on purpose: it buffers connections that
  // arrive before the app starts listening, so a fast peer is
  // never dropped (a broadcast stream would lose it).
  final _controller = StreamController<Socket>();

  Stream<Socket> get connections => _controller.stream;

  int get port => _server?.port ?? 0;

  bool get isListening => _server != null;

  /// Bind the first free port in 1714-1764 and return it.
  Future<int> start() async {
    for (var port = 1714; port <= 1764; port++) {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        break;
      } on SocketException {
        continue;
      }
    }
    final server = _server;
    if (server == null) {
      throw const SocketException('no free TCP port in 1714-1764');
    }
    server.listen(_controller.add, onError: _controller.addError);
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}
