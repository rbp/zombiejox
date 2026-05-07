/// JaxJox protocol opcodes. See `docs/ble_protocol.md` §4 and §5.
///
/// `0x27` is intentionally absent — sending it knocks the dumbbell offline.
/// Do not add it.
class Opcodes {
  Opcodes._();

  static const int syncTime = 0x08;
  static const int setUser = 0xC0;
  static const int queryStatus = 0xD1;
  static const int stateBroadcast = 0xD2;
  static const int historyChunk = 0xD3;
  static const int historyComplete = 0xD4;
  static const int setWeight = 0xD6;
}
