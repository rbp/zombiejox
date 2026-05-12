import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/devices/dumbbell.dart';

void main() {
  group('setWeightIndex bounds', () {
    // The check fires before any BLE I/O, so a freshly constructed
    // Dumbbell that has not connected is safe to probe directly.
    test('throws RangeError for negative indices', () async {
      final d = Dumbbell(BluetoothDevice(remoteId: DeviceIdentifier('AA:01')));
      expect(() => d.setWeightIndex(-1), throwsRangeError);
    });

    test('throws RangeError for indices >= 8', () async {
      final d = Dumbbell(BluetoothDevice(remoteId: DeviceIdentifier('AA:01')));
      expect(() => d.setWeightIndex(8), throwsRangeError);
      expect(() => d.setWeightIndex(99), throwsRangeError);
    });

    test('the boundaries 0 and 7 are NOT a RangeError', () {
      // On an unconnected Dumbbell, in-range indices still throw — but
      // they throw `StateError` from the BLE layer ("not connected"),
      // *not* `RangeError`. That distinction is what callers will
      // disambiguate on, so pin it down.
      final d = Dumbbell(BluetoothDevice(remoteId: DeviceIdentifier('AA:01')));
      expect(() => d.setWeightIndex(0), isNot(throwsRangeError));
      expect(() => d.setWeightIndex(7), isNot(throwsRangeError));
    });
  });
}
