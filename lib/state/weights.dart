// Index ↔ display-weight lookup.
//
// `0xD6 <index>` is the BLE set-weight command. The dumbbell's hardware
// supports 8 settings (indices 0..7); see `docs/ble_protocol.md` §4.
//
// `kWeightLbsByIndex` is the canonical hardware fact (what JaxJox put on
// the box for the lbs SKU). `kWeightKgByIndex` is the exact lb→kg conversion
// to one decimal place — the kg SKU's own display rounding has not been
// independently verified yet (see TODO in `docs/ble_protocol.md` §2g).

const List<int> kWeightLbsByIndex = [8, 14, 20, 26, 32, 38, 44, 50];

const List<double> kWeightKgByIndex = [
  3.6,
  6.4,
  9.1,
  11.8,
  14.5,
  17.2,
  19.9,
  22.7,
];

/// Number of valid set-weight indices on DumbbellConnect.
const int kJaxJoxWeightCount = 8;

enum WeightUnit {
  lbs,
  kg;

  static WeightUnit fromName(String? raw) {
    switch (raw) {
      case 'kg':
        return WeightUnit.kg;
      case 'lbs':
      default:
        return WeightUnit.lbs;
    }
  }
}

/// Format a weight index for the user (e.g. `"32 lbs"` or `"14.5 kg"`).
///
/// Returns an empty string if `index` is out of range — callers should not
/// pass invalid indices, but the UI shouldn't crash if state is malformed.
String formatWeight(int index, WeightUnit unit) {
  if (index < 0 || index >= kJaxJoxWeightCount) return '';
  switch (unit) {
    case WeightUnit.lbs:
      return '${kWeightLbsByIndex[index]} lbs';
    case WeightUnit.kg:
      return '${kWeightKgByIndex[index]} kg';
  }
}
