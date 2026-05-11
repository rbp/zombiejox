/// JaxJox protocol opcodes the app actually sends or parses. See
/// `docs/ble_protocol.md` §4 and §5 for the full opcode catalogue (it
/// includes opcodes we know about — `0x08` syncTime, `0xC0` setUser,
/// `0xD3`/`0xD4` history sync — that this app deliberately doesn't use).
///
/// `0x27` is intentionally absent — sending it knocks the dumbbell offline.
/// Do not add it.
class Opcodes {
  Opcodes._();

  static const int queryStatus = 0xD1;
  static const int stateBroadcast = 0xD2;
  static const int setWeight = 0xD6;
}
