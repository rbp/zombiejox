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
const List<String> kJaxJoxNamePrefixes = ['DB200'];

/// True iff [advName] looks like a live JaxJox dumbbell — has one of
/// [kJaxJoxNamePrefixes] AND isn't in DFU (firmware-update) mode.
/// Centralised so the screen layer doesn't have to know about the
/// DFU naming convention.
///
/// The original Android APK skips names ending in `U` for DFU
/// (`DeviceManager.java`); we transcribe the same rule here.
bool isJaxJoxLiveDeviceName(String advName) {
  if (advName.isEmpty) return false;
  if (advName.endsWith('U')) return false; // DFU mode
  return kJaxJoxNamePrefixes.any(advName.startsWith);
}
