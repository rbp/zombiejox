import 'dart:typed_data';

import 'checksum.dart';

/// `[0xFF, length, opcode, ...payload, checksum]` — see `docs/ble_protocol.md` §3.
///
/// `length` is the total transmitted byte count (`payload.length + 4`).
Uint8List buildFrame(int opcode, List<int> payload) {
  final length = payload.length + 4;
  final pre = <int>[0xFF, length, opcode, ...payload];
  return Uint8List.fromList([...pre, jaxjoxChecksum(pre)]);
}

class ParsedFrame {
  final int opcode;
  final Uint8List payload;
  ParsedFrame(this.opcode, this.payload);
}

/// Returns null if the frame is malformed or has a bad checksum.
ParsedFrame? parseFrame(List<int> bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] != 0xFF) return null;
  final length = bytes[1];
  if (length != bytes.length) return null;
  final pre = bytes.sublist(0, bytes.length - 1);
  if (jaxjoxChecksum(pre) != bytes.last) return null;
  return ParsedFrame(
      bytes[2], Uint8List.fromList(bytes.sublist(3, bytes.length - 1)));
}
