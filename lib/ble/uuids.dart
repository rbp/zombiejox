/// UUIDs and name prefixes from `docs/ble_protocol.md` §1 and §2.
class JaxJoxUuids {
  JaxJoxUuids._();

  static const String service = 'aae28f00-71b5-42a1-8c3c-f9cf6ac969d0';
  static const String txCharacteristic = 'aae28f02-71b5-42a1-8c3c-f9cf6ac969d0';
  static const String rxCharacteristic = 'aae28f01-71b5-42a1-8c3c-f9cf6ac969d0';

  static const String batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  static const String deviceInformationService =
      '0000180a-0000-1000-8000-00805f9b34fb';
}

/// Advertised-name prefixes by product. Filter scan results to these.
/// Names ending in `U` are firmware-update mode; skip them.
const Map<String, String> kJaxJoxNamePrefixes = {
  'DumbbellConnect': 'DB200',
  'KettlebellConnect 2.0': 'KB200',
  'KettlebellConnect (legacy)': 'KB42',
  'PushUpConnect': 'PB220',
  'FoamRollerConnect': 'FR100',
};
