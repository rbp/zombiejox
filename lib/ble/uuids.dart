/// UUIDs and name prefixes from `docs/ble_protocol.md` §1 and §2.
class JaxJoxUuids {
  JaxJoxUuids._();

  static const String service = 'aae28f00-71b5-42a1-8c3c-f9cf6ac969d0';
  static const String txCharacteristic = 'aae28f02-71b5-42a1-8c3c-f9cf6ac969d0';
  static const String rxCharacteristic = 'aae28f01-71b5-42a1-8c3c-f9cf6ac969d0';

  static const String batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
}

/// Advertised-name prefixes the scan filter accepts. We deliberately only
/// match DumbbellConnect (`DB200`) — kettlebell / pushup / foam-roller
/// firmware speaks a related-but-not-identical protocol and is out of
/// scope (the on-screen weight grid is dumbbell-shaped, `setWeightIndex`
/// asserts on the dumbbell's 0..7 range, etc.). Add a prefix here when a
/// second product is actually wired up end-to-end. See
/// `docs/ble_protocol.md` §2 for the full prefix catalogue.
///
/// Names ending in `U` are firmware-update mode; skip them.
const List<String> kJaxJoxNamePrefixes = ['DB200'];
