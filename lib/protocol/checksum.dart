/// JaxJox BLE checksum, recovered from arm64 disassembly of `libfitness.so`
/// (`getChecksum` at offset 0x7f8). See `docs/ble_protocol.md` §6.
int jaxjoxChecksum(List<int> data) {
  if (data.isEmpty) return 0x3A;
  var sum = 0;
  for (final b in data) {
    sum += b;
  }
  return ((-sum) ^ 0x3A) & 0xFF;
}
