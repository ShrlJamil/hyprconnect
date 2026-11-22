//! Payload transfers for kdeconnect.share.request and the clipboard
//! size limit. Pure helpers (no sockets) so they are unit-testable;
//! the socket halves live on DeviceConnection (connection.dart).
//!
//! Wire rules, read from the daemon (src/main.rs):
//! - A file share is a kdeconnect.share.request with body
//!   {"filename": ...}, payloadSize, and payloadTransferInfo {"port": N}.
//!   The receiver connects to that port and the sender streams exactly
//!   payloadSize raw bytes over a second TLS connection (listener =
//!   TLS server, connector = TLS client, peer CN checked both ways).
//! - A text share rides in the packet itself (body "text") and the
//!   daemon applies it as clipboard; a url share (body "url") is only
//!   an event. The phone mirrors both.
//! - Clipboard content longer than the daemon's 512000 chars is
//!   dropped there, so the phone refuses to send it.

import 'dart:io';

/// Maximum clipboard content, in characters. Matches the daemon's
/// apply_remote_clipboard / on_local_clipboard_changed guard.
const maxClipboardChars = 512000;

/// One file received from a peer, saved under the app's receive dir.
class ReceivedFile {
  final String filename;
  final String path;
  final int size;
  final String deviceId;
  final String deviceName;
  final DateTime receivedAt;

  const ReceivedFile({
    required this.filename,
    required this.path,
    required this.size,
    required this.deviceId,
    required this.deviceName,
    required this.receivedAt,
  });
}

/// Reduce a shared file name to a plain base name, like the daemon's
/// unique_download_path does. Path separators, "..", and empty names
/// can never escape the receive directory.
String sanitizeSharedFilename(String? filename) {
  final raw = filename ?? '';
  // Take the last path segment on either separator style.
  final segments = raw.split(RegExp(r'[/\\]'));
  final base = segments.isEmpty ? '' : segments.last;
  final clean = base.trim();
  if (clean.isEmpty || clean == '.' || clean == '..') {
    return 'shared-file';
  }
  return clean;
}

/// A non-colliding path inside [dir] for [filename]: "name (1).ext",
/// "name (2).ext", ... exactly like the daemon's deduplication.
String uniqueFilePath(Directory dir, String filename) {
  final clean = sanitizeSharedFilename(filename);
  var candidate = File('${dir.path}/$clean');
  if (!candidate.existsSync()) return candidate.path;
  final dot = clean.lastIndexOf('.');
  final stem = dot > 0 ? clean.substring(0, dot) : clean;
  final ext = dot > 0 ? clean.substring(dot) : '';
  for (var i = 1; i < 1000; i++) {
    candidate = File('${dir.path}/$stem ($i)$ext');
    if (!candidate.existsSync()) return candidate.path;
  }
  return candidate.path;
}
