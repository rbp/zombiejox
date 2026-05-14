import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/state/selection_model.dart';

Future<Preferences> _prefs({
  List<String> remembered = const [],
  Map<String, String> customNames = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'remembered_device_ids': remembered,
    if (customNames.isNotEmpty)
      'custom_device_names':
          // Hand-rolled JSON to avoid an import for one test util.
          '{${customNames.entries.map((e) => '"${e.key}":"${e.value}"').join(',')}}',
  });
  return Preferences.load();
}

DeviceRef _device(String id, {String name = ''}) =>
    DeviceRef(id: id, name: name);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('hydration', () {
    test('starts empty when prefs are empty', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      expect(model.entries, isEmpty);
      expect(model.devices, isEmpty);
    });

    test('seeds from rememberedDeviceIds in order', () async {
      final prefs = await _prefs(remembered: ['AA:01', 'AA:02', 'AA:03']);
      final model = SelectionModel(preferences: prefs);
      expect(model.devices.map((d) => d.id), ['AA:01', 'AA:02', 'AA:03']);
    });

    test('seeds custom names alongside remembered ids', () async {
      final prefs = await _prefs(
        remembered: ['AA:01', 'AA:02'],
        customNames: {'AA:01': 'Left', 'AA:02': 'Right'},
      );
      final model = SelectionModel(preferences: prefs);
      expect(model.entries[0].customName, 'Left');
      expect(model.entries[1].customName, 'Right');
      expect(model.displayNameFor(_device('AA:01')), 'Left');
    });

    test(
        'a custom name stored for a non-remembered device is preserved on '
        'disk and applied when that device is later promoted', () async {
      final prefs = await _prefs(
        remembered: const [],
        customNames: {'AA:99': 'Old Faithful'},
      );
      final model = SelectionModel(preferences: prefs);
      expect(model.entries, isEmpty);

      model.add(_device('AA:99'));
      expect(model.entries.single.customName, 'Old Faithful',
          reason: 're-promoting a previously-renamed device restores the '
              'user-chosen name');
    });
  });

  group('add / remove', () {
    test('add appends and notifies', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      var notifications = 0;
      model.addListener(() => notifications++);

      model.add(_device('AA:01'));
      expect(model.devices.map((d) => d.id), ['AA:01']);
      expect(notifications, 1);
    });

    test('add is idempotent for the same id (no notify, no duplicate)',
        () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      model.add(_device('AA:01'));
      var notifications = 0;
      model.addListener(() => notifications++);

      model.add(_device('AA:01'));
      expect(model.devices.map((d) => d.id), ['AA:01']);
      expect(notifications, 0,
          reason: 'no state change ⇒ no notification fired');
    });

    test('remove drops the entry and notifies', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      model
        ..add(_device('AA:01'))
        ..add(_device('AA:02'));
      var notifications = 0;
      model.addListener(() => notifications++);

      model.remove(_device('AA:01'));
      expect(model.devices.map((d) => d.id), ['AA:02']);
      expect(notifications, 1);
    });

    test('remove for an unknown device is a silent no-op', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      var notifications = 0;
      model.addListener(() => notifications++);

      model.remove(_device('AA:99'));
      expect(notifications, 0);
    });
  });

  group('rename', () {
    test('rename sets a custom name and notifies', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs)..add(_device('AA:01'));
      var notifications = 0;
      model.addListener(() => notifications++);

      model.rename(_device('AA:01'), 'Left');
      expect(model.entries.single.customName, 'Left');
      expect(model.displayNameFor(_device('AA:01')), 'Left');
      expect(notifications, 1);
    });

    test('rename to null clears the custom name', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs)..add(_device('AA:01'));
      model.rename(_device('AA:01'), 'Left');
      var notifications = 0;
      model.addListener(() => notifications++);

      model.rename(_device('AA:01'), null);
      expect(model.entries.single.customName, isNull);
      expect(notifications, 1);
    });

    test(
        'rename with a whitespace-only string clears the custom name '
        '(same as null)', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs)
        ..add(_device('AA:01'))
        ..rename(_device('AA:01'), 'Left');

      model.rename(_device('AA:01'), '   ');
      expect(model.entries.single.customName, isNull);
    });

    test('rename trims surrounding whitespace', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs)..add(_device('AA:01'));
      model.rename(_device('AA:01'), '  Right  ');
      expect(model.entries.single.customName, 'Right');
    });

    test('rename to the existing value does not notify', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs)
        ..add(_device('AA:01'))
        ..rename(_device('AA:01'), 'Left');
      var notifications = 0;
      model.addListener(() => notifications++);

      model.rename(_device('AA:01'), 'Left');
      expect(notifications, 0);
    });

    test('rename for an unknown device is a silent no-op', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      var notifications = 0;
      model.addListener(() => notifications++);

      model.rename(_device('AA:99'), 'whatever');
      expect(notifications, 0);
      expect(prefs.customDeviceNames, isEmpty);
    });
  });

  group('persistence', () {
    test(
        'rememberedDeviceIds is NOT persisted until markVerified — a '
        'connect that never reaches ready cannot poison warm-start', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      model
        ..add(_device('AA:01'))
        ..add(_device('AA:02'));
      // Allow the (no-op) async pref write to settle.
      await Future<void>.delayed(Duration.zero);

      expect(prefs.rememberedDeviceIds, isEmpty,
          reason: 'unverified selection must not touch the warm-start anchor');
    });

    test(
        'markVerified persists current selection AND every subsequent '
        'add / remove', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      model.add(_device('AA:01'));
      await Future<void>.delayed(Duration.zero);
      expect(prefs.rememberedDeviceIds, isEmpty);

      model.markVerified();
      await Future<void>.delayed(Duration.zero);
      expect(prefs.rememberedDeviceIds, ['AA:01']);

      model.add(_device('AA:02'));
      await Future<void>.delayed(Duration.zero);
      expect(prefs.rememberedDeviceIds, ['AA:01', 'AA:02']);

      model.remove(_device('AA:01'));
      await Future<void>.delayed(Duration.zero);
      expect(prefs.rememberedDeviceIds, ['AA:02']);
    });

    test('markVerified is idempotent', () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs)..add(_device('AA:01'));
      model.markVerified();
      await Future<void>.delayed(Duration.zero);
      model.markVerified();
      await Future<void>.delayed(Duration.zero);
      expect(prefs.rememberedDeviceIds, ['AA:01']);
    });

    test('rename persists custom names regardless of markVerified', () async {
      final prefs = await _prefs();
      SelectionModel(preferences: prefs)
        ..add(_device('AA:01'))
        ..rename(_device('AA:01'), 'Left');
      await Future<void>.delayed(Duration.zero);

      expect(prefs.customDeviceNames, {'AA:01': 'Left'},
          reason: 'rename is user-typed metadata, not gated on a successful '
              'connect like the remembered-set');
    });

    test(
        'removing a renamed device preserves the rename on disk — a future '
        're-promote restores it', () async {
      final prefs = await _prefs();
      SelectionModel(preferences: prefs)
        ..add(_device('AA:01'))
        ..rename(_device('AA:01'), 'Left')
        ..remove(_device('AA:01'));
      await Future<void>.delayed(Duration.zero);

      expect(prefs.customDeviceNames, {'AA:01': 'Left'},
          reason: 'removing a device must not wipe its rename from prefs');
    });
  });

  group('displayName fallbacks', () {
    test('devices not in the selection fall back to DeviceRef.displayName',
        () async {
      final prefs = await _prefs();
      final model = SelectionModel(preferences: prefs);
      expect(
          model.displayNameFor(_device('AA:01', name: 'DB200-01')), 'DB200-01');
    });

    test(
        'a non-selected device with a saved custom name returns the '
        'custom name (so scan-list rows still reflect a rename)', () async {
      final prefs = await _prefs(customNames: {'AA:99': 'Old Faithful'});
      final model = SelectionModel(preferences: prefs);
      expect(model.contains(_device('AA:99')), isFalse);
      expect(model.displayNameFor(_device('AA:99')), 'Old Faithful');
    });

    test('entry.displayName uses the custom name when set', () async {
      final entry = SelectionEntry(
        device: _device('AA:01', name: 'advertised'),
        customName: 'My Left',
      );
      expect(entry.displayName, 'My Left');
    });

    test('entry.displayName falls back when custom name is null or blank',
        () async {
      expect(
          SelectionEntry(device: _device('AA:01', name: 'advertised'))
              .displayName,
          'advertised');
      expect(
          SelectionEntry(
            device: _device('AA:01', name: 'advertised'),
            customName: '   ',
          ).displayName,
          'advertised');
    });
  });

  group('customNameFor (§2h)', () {
    test('returns null when the user has not renamed', () async {
      final prefs = await _prefs(remembered: ['AA:01']);
      final model = SelectionModel(preferences: prefs);
      expect(model.customNameFor(_device('AA:01')), isNull,
          reason: 'no rename ⇒ no annotation in the §2h toast');
    });

    test('returns the user-set name for a selected device', () async {
      final prefs = await _prefs(
        remembered: ['AA:01'],
        customNames: {'AA:01': 'Left'},
      );
      final model = SelectionModel(preferences: prefs);
      expect(model.customNameFor(_device('AA:01')), 'Left');
    });

    test(
        'returns the user-set name for a non-selected device too — the '
        'toast on a re-promoted dumbbell should still annotate', () async {
      final prefs = await _prefs(customNames: {'AA:99': 'Old Faithful'});
      final model = SelectionModel(preferences: prefs);
      expect(model.contains(_device('AA:99')), isFalse);
      expect(model.customNameFor(_device('AA:99')), 'Old Faithful');
    });

    test(
        'whitespace-only custom name returns null — falls back to "no '
        r'annotation" rather than rendering "Device $id ( ) is …"', () async {
      final prefs = await _prefs(customNames: {'AA:01': '   '});
      final model = SelectionModel(preferences: prefs);
      expect(model.customNameFor(_device('AA:01')), isNull);
    });

    test('a cleared custom name returns null after rename(null)', () async {
      final prefs = await _prefs(
        remembered: ['AA:01'],
        customNames: {'AA:01': 'Left'},
      );
      final model = SelectionModel(preferences: prefs);
      expect(model.customNameFor(_device('AA:01')), 'Left');
      model.rename(_device('AA:01'), null);
      expect(model.customNameFor(_device('AA:01')), isNull);
    });

    test(
        'selected entry with null customName is authoritative — does NOT '
        'fall back to a stale value in Preferences.customDeviceNames '
        '(Copilot review on PR #28: a failed write or write race must '
        'not let the toast keep the old name)', () async {
      // Arrange: device is selected with no custom name in memory.
      final prefs = await _prefs(remembered: ['AA:01']);
      final model = SelectionModel(preferences: prefs);
      expect(model.customNameFor(_device('AA:01')), isNull);

      // Simulate prefs drifting out of sync with the in-memory entry —
      // the on-disk map says 'Stale' but the selected entry was never
      // renamed in this session.
      await prefs.setCustomDeviceNames({'AA:01': 'Stale'});

      // The in-memory entry must win for selected devices.
      expect(model.customNameFor(_device('AA:01')), isNull,
          reason: 'selected entry is authoritative — prefs fallback only '
              'applies to devices NOT in the selection');
    });
  });
}
