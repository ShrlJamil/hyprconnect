//! Minimal DER reader: enough to pull the subjectPublicKeyInfo (SPKI)
//! and the common name out of an X.509 certificate, without a full
//! X.509 stack. Used for the pairing verification key, which the
//! daemon computes over both devices' SPKI DER.

import 'dart:convert';
import 'dart:typed_data';

class _Tlv {
  final int tag;
  final int headerLength;
  final int length;
  final int valueOffset;
  final int totalLength;

  const _Tlv(this.tag, this.headerLength, this.length, this.valueOffset)
      : totalLength = headerLength + length;
}

_Tlv _readTlv(Uint8List bytes, int offset) {
  if (offset >= bytes.length) {
    throw const FormatException('DER truncated at tag');
  }
  final tag = bytes[offset];
  var pos = offset + 1;
  if (pos >= bytes.length) {
    throw const FormatException('DER truncated at length');
  }
  var lengthByte = bytes[pos];
  pos += 1;
  int length;
  if (lengthByte & 0x80 == 0) {
    length = lengthByte;
  } else {
    final lengthBytes = lengthByte & 0x7f;
    if (lengthBytes == 0 || lengthBytes > 4 || pos + lengthBytes > bytes.length) {
      throw const FormatException('DER unsupported length form');
    }
    length = 0;
    for (var i = 0; i < lengthBytes; i++) {
      length = (length << 8) | bytes[pos + i];
    }
    pos += lengthBytes;
  }
  if (pos + length > bytes.length) {
    throw const FormatException('DER value overruns buffer');
  }
  return _Tlv(tag, pos - offset, length, pos);
}

/// The child elements of a constructed value starting at [offset].
List<_Tlv> _children(Uint8List bytes, _Tlv parent) {
  final out = <_Tlv>[];
  var pos = parent.valueOffset;
  final end = parent.valueOffset + parent.length;
  while (pos < end) {
    final child = _readTlv(bytes, pos);
    out.add(child);
    pos += child.totalLength;
  }
  if (pos != end) {
    throw const FormatException('DER children overrun parent');
  }
  return out;
}

/// Raw DER bytes of the subjectPublicKeyInfo element of [certDer].
Uint8List extractSpki(Uint8List certDer) {
  final cert = _readTlv(certDer, 0);
  if (cert.tag != 0x30) throw const FormatException('certificate is not a SEQUENCE');
  final tbs = _readTlv(certDer, cert.valueOffset);
  if (tbs.tag != 0x30) throw const FormatException('TBSCertificate is not a SEQUENCE');
  final fields = _children(certDer, tbs);
  // TBSCertificate: [0] version (optional, present in v3),
  // serial, signature, issuer, validity, subject, subjectPublicKeyInfo.
  final hasVersion = fields.isNotEmpty && fields[0].tag == 0xa0;
  final spkiIndex = hasVersion ? 6 : 5;
  if (fields.length <= spkiIndex) {
    throw const FormatException('TBSCertificate has no SPKI field');
  }
  final spki = fields[spkiIndex];
  if (spki.tag != 0x30) throw const FormatException('SPKI is not a SEQUENCE');
  final spkiOffset = _elementOffset(certDer, tbs, spkiIndex);
  return Uint8List.sublistView(certDer, spkiOffset, spkiOffset + spki.totalLength);
}

int _elementOffset(Uint8List bytes, _Tlv parent, int index) {
  var pos = parent.valueOffset;
  for (var i = 0; i < index; i++) {
    pos += _readTlv(bytes, pos).totalLength;
  }
  return pos;
}

/// The common name of the certificate subject.
String extractCommonName(Uint8List certDer) {
  final cert = _readTlv(certDer, 0);
  final tbs = _readTlv(certDer, cert.valueOffset);
  final fields = _children(certDer, tbs);
  final hasVersion = fields.isNotEmpty && fields[0].tag == 0xa0;
  final subjectIndex = hasVersion ? 5 : 4;
  if (fields.length <= subjectIndex) {
    throw const FormatException('TBSCertificate has no subject field');
  }
  final subject = fields[subjectIndex];
  // Subject is a SEQUENCE of SETs of SEQUENCEs of (OID, value).
  final rdns = _children(certDer, subject);
  // OID 2.5.4.3 (commonName) encodes as 06 03 55 04 03.
  const cnOid = [0x06, 0x03, 0x55, 0x04, 0x03];
  for (final rdn in rdns) {
    if (rdn.tag != 0x31) continue; // SET
    for (final atv in _children(certDer, rdn)) {
      if (atv.tag != 0x30) continue; // SEQUENCE
      final parts = _children(certDer, atv);
      if (parts.length < 2) continue;
      final oid = parts[0];
      // Compare the OID element raw bytes.
      final oidStart = _elementOffset(certDer, atv, 0);
      final oidRaw = certDer.sublist(oidStart, oidStart + oid.totalLength);
      var matches = oidRaw.length == cnOid.length;
      if (matches) {
        for (var i = 0; i < cnOid.length; i++) {
          if (oidRaw[i] != cnOid[i]) matches = false;
        }
      }
      if (!matches) continue;
      final value = parts[1];
      final raw = certDer.sublist(
        value.valueOffset,
        value.valueOffset + value.length,
      );
      return utf8.decode(raw);
    }
  }
  throw const FormatException('certificate subject has no commonName');
}
