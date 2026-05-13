import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/ble_scanner.dart';
import '../ble/device_ref.dart';
import '../ble/uuids.dart';
import '../devices/dumbbell.dart';
import '../devices/weight_group.dart';
import '../state/preferences.dart';
import '../state/unit_auto_matcher.dart';
import '../state/weights.dart';
import '../widgets/dumbbell_card.dart';
import '../widgets/failed_device_card.dart';
import '../widgets/weight_button.dart';
import 'permission_screen.dart';
import 'settings_screen.dart';

/// Single-screen entry point for a permissioned user. Merges what used to
/// be separate Scan and Control screens into one composable layout:
///
/// - **Top**: the user's *selected* dumbbells, rendered via
///   [DumbbellCard] / [FailedDeviceCard]. Seeded on cold start from
///   [Preferences.rememberedDeviceIds] so warm-start is instant — the
///   cards appear in `connecting` state immediately and the scanner
///   starts in parallel. Carries a placeholder hint when empty so the
///   layout doesn't jump when the first card arrives.
/// - **Middle**: the 8-tile weight grid, always visible. Buttons are
///   disabled when no member is ready.
/// - **Bottom**: live scan results that aren't already in the top
///   region, each as a tappable card. Tap → promote to the top region
///   + kick off `WeightGroup.add` immediately ("promote-on-tap"). Above
///   the bottom list sits a stop/refresh icon for the scanner.
///
/// Per-device removal lives on the cards themselves (the "×"
/// affordance). Bulk removal (the AppBar's bluetooth-off icon) clears
/// every selected device without leaving the screen.
///
/// All seams (scanner, group factory, permission check) accept overrides
/// so widget tests can run without touching the platform channels.
class HomeScreen extends StatefulWidget {
  final Preferences preferences;

  /// Override the Bluetooth-permission status check — used by widget tests
  /// to avoid the `permission_handler` platform channel. In production
  /// this is null and the screen reads the bluetoothScan/Connect statuses
  /// directly.
  final Future<bool> Function()? checkPermissionsGranted;

  /// Override the BLE scan source — tests pass a fake to avoid touching
  /// the `flutter_blue_plus` static API. Production uses
  /// [FlutterBluePlusScanner].
  final BleScanner? scanner;

  /// Override the [WeightGroup] factory — tests pass a factory that
  /// returns a [WeightGroup] backed by a fake dumbbell. Production
  /// constructs a default [WeightGroup].
  final WeightGroup Function()? createWeightGroup;

  const HomeScreen({
    super.key,
    required this.preferences,
    this.checkPermissionsGranted,
    this.scanner,
    this.createWeightGroup,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final BleScanner _scanner =
      widget.scanner ?? const FlutterBluePlusScanner();
  late final WeightGroup _group =
      widget.createWeightGroup?.call() ?? WeightGroup();
  late final UnitAutoMatcher _autoMatcher = UnitAutoMatcher(
    preferences: widget.preferences,
    onOutcome: _onAutoMatchOutcome,
  );

  StreamSubscription<GroupSnapshot>? _snapshotSub;
  GroupSnapshot _snapshot = GroupSnapshot.empty;

  /// The user's "selected" devices in tap order. Cards in the top region
  /// render in this order regardless of connection state — a retry that
  /// briefly leaves [GroupSnapshot.failed] before reappearing in
  /// [GroupSnapshot.connected] doesn't shuffle past its neighbours.
  /// Seeded from [Preferences.rememberedDeviceIds] on warm start, then
  /// grown by promote-on-tap and shrunk by per-card × / Disconnect-all.
  final List<DeviceRef> _selectedDevices = [];

  bool _checkingPermissions = true;
  bool _onAnyConnectedFired = false;

  @override
  void initState() {
    super.initState();
    _snapshot = _group.lastSnapshot;
    _snapshotSub = _group.snapshots.listen(_onSnapshot);
    _ensurePermissionsAndBootstrap();
  }

  /// Permissions should already be granted by the time the user lands
  /// here — `main.dart` routes a cold start through [PermissionScreen]
  /// when they're not, and that screen's success path `pushReplacement`s
  /// here. This is the defensive backstop for the OS-level-revocation
  /// case (Settings.app toggled while the app is alive). On miss we
  /// hand back to [PermissionScreen] rather than re-prompting inline —
  /// iOS won't re-prompt once denied.
  static Future<bool> _defaultCheckPermissionsGranted() async {
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    return scan.isGranted && connect.isGranted;
  }

  Future<void> _ensurePermissionsAndBootstrap() async {
    final granted = await (widget.checkPermissionsGranted ??
        _defaultCheckPermissionsGranted)();
    if (!mounted) return;
    if (!granted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PermissionScreen(preferences: widget.preferences),
        ),
      );
      return;
    }
    setState(() => _checkingPermissions = false);

    // Warm-start seed: rehydrate previously-connected devices into the
    // top region in `connecting` state, then fan out `_group.add` for
    // each. We do this *before* starting the scan so the seed cards
    // appear in the first frame after the permission check resolves.
    final remembered = widget.preferences.rememberedDeviceIds;
    if (remembered.isNotEmpty) {
      setState(() {
        for (final id in remembered) {
          _selectedDevices.add(DeviceRef(id: id));
        }
      });
      for (final id in remembered) {
        unawaited(_addOne(DeviceRef(id: id)));
      }
    }
    unawaited(_startScan());
  }

  void _onSnapshot(GroupSnapshot snapshot) {
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
    _maybeFireOnAnyConnected();
    _tickAutoMatcher();
  }

  /// Fires the first time any member is ready and persists the current
  /// `_selectedDevices` set as the warm-start anchor — so a Connect that
  /// never reached `isReady` (every device out of range) doesn't poison
  /// the next cold start.
  void _maybeFireOnAnyConnected() {
    if (_onAnyConnectedFired) return;
    if (!_snapshot.anyReady) return;
    _onAnyConnectedFired = true;
    _persistRememberedIfVerified();
  }

  /// Persist `_selectedDevices` to remembered-storage, but only after at
  /// least one member has ever reached `isReady`. Called on first verified
  /// connect, then on every subsequent change to the selected set
  /// (promote-on-tap, ×-remove, Disconnect-all) — so the saved set always
  /// reflects what the user actually has.
  void _persistRememberedIfVerified() {
    if (!_onAnyConnectedFired) return;
    unawaited(
      widget.preferences.setRememberedDeviceIds(
        [for (final d in _selectedDevices) d.id],
      ),
    );
  }

  /// Feed the auto-matcher the current snapshot. `failedCount` /
  /// `attemptedCount` are the snapshot-derived values; the screen-level
  /// "user's intent" is `_selectedDevices.length` since failed and
  /// connecting devices both live there.
  void _tickAutoMatcher() {
    _autoMatcher.tick((
      knownUnits: _snapshot.knownUnits,
      knownUnitCount: _snapshot.knownUnitCount,
      failedCount: _snapshot.failed.length,
      attemptedCount: _selectedDevices.length,
    ));
  }

  void _onAutoMatchOutcome(AutoMatchResult result) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result.outcome) {
      case AutoMatchOutcome.matched:
        final label = result.unit == WeightUnit.lbs ? 'lbs' : 'kg';
        messenger.showSnackBar(
          SnackBar(
              content: Text('Unit set to $label to match your dumbbells.')),
        );
      case AutoMatchOutcome.disagreement:
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
                'Dumbbells are set to different units — pick one in Settings'),
          ),
        );
    }
  }

  /// Wrap [WeightGroup.add] so a retry tap racing the screen's dispose
  /// flow doesn't surface a noisy `StateError` — the group emits the
  /// failure as a snapshot, not a thrown future, in every other case.
  Future<void> _addOne(DeviceRef device) async {
    try {
      await _group.add(device);
    } on StateError {
      // Group disposed mid-flight; nothing to recover.
    }
  }

  /// User tapped a scan result. Promote the device to the top region
  /// (so the card appears immediately in `connecting` state) and kick
  /// off the connect.
  void _onPromote(DeviceRef device) {
    if (_selectedDevices.contains(device)) return;
    setState(() => _selectedDevices.add(device));
    _persistRememberedIfVerified();
    unawaited(_addOne(device));
  }

  /// User tapped × on a top card. Drop from `_selectedDevices` and
  /// disconnect / clear the failure entry on the group.
  Future<void> _onRemove(DeviceRef device) async {
    setState(() => _selectedDevices.remove(device));
    _persistRememberedIfVerified();
    await _group.remove(device);
  }

  /// User tapped the AppBar's "Disconnect all". Drop every selected
  /// device — composed from the per-device [_onRemove] so we don't need
  /// a parallel "reset everything" code path. The group stays alive so
  /// the user can keep scanning and pick new devices.
  Future<void> _onDisconnectAll() async {
    final toRemove = List<DeviceRef>.from(_selectedDevices);
    setState(() => _selectedDevices.clear());
    _persistRememberedIfVerified();
    await Future.wait([for (final d in toRemove) _group.remove(d)]);
  }

  Future<void> _startScan() async {
    // Same swallow-and-log as the old ScanScreen: an adapter-state error
    // (BT off, channel hiccup) isn't recoverable inline — the user has
    // a refresh icon they can hit once the underlying issue is fixed.
    try {
      if (_scanner.isScanningNow) {
        await _scanner.stopScan();
      }
      // Native `withKeywords` is an efficiency hint that cuts BLE
      // advertisement churn. Authoritative filtering is `_isJaxJox`
      // applied to the stream results below.
      await _scanner.startScan(
        withKeywords: kJaxJoxNamePrefixes,
        timeout: const Duration(seconds: 30),
      );
    } catch (e, st) {
      debugPrint('startScan failed: $e\n$st');
    }
  }

  Future<void> _onSelectIndex(int idx) async {
    try {
      await _group.setWeightIndex(idx);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to set weight: $e')),
      );
    }
  }

  bool _isJaxJox(String name) {
    if (name.isEmpty) return false;
    if (name.endsWith('U')) return false; // DFU mode
    return kJaxJoxNamePrefixes.any(name.startsWith);
  }

  @override
  void dispose() {
    _autoMatcher.dispose();
    unawaited(_snapshotSub?.cancel() ?? Future<void>.value());
    // Best-effort: a plugin-channel failure here would be a useless
    // crash since we're tearing down anyway.
    try {
      if (_scanner.isScanningNow) {
        unawaited(_scanner.stopScan().catchError((_) {}));
      }
    } catch (_) {}
    unawaited(_group.disconnectAll());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingPermissions) {
      // Brief frame or two while the permission check resolves. On miss
      // we pushReplacement to PermissionScreen so this never becomes a
      // stuck state.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZombieJox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(preferences: widget.preferences),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth_disabled),
            tooltip: 'Disconnect all',
            onPressed:
                _selectedDevices.isEmpty ? null : _onDisconnectAll,
          ),
        ],
      ),
      body: ValueListenableBuilder<WeightUnit>(
        valueListenable: widget.preferences.unit,
        builder: (context, unit, _) => Center(
          // 600 dp cap so the layout doesn't stretch absurdly wide on
          // tablets / landscape. Phones are unaffected.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _Body(
              snapshot: _snapshot,
              unit: unit,
              selectedDevices: _selectedDevices,
              scanner: _scanner,
              scanFilter: _isJaxJox,
              onSelectIndex: _onSelectIndex,
              onRetry: _addOne,
              onRemove: _onRemove,
              onPromote: _onPromote,
              onToggleScan: _toggleScan,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleScan(bool currentlyScanning) async {
    if (currentlyScanning) {
      await _scanner.stopScan();
    } else {
      await _startScan();
    }
  }
}

/// Stateless presentation layer. Receives everything it needs to render
/// the three regions; mutations happen via the callbacks. Splitting this
/// out of [_HomeScreenState] keeps the build method readable and the
/// widget tree shallow enough to test in isolation.
class _Body extends StatelessWidget {
  final GroupSnapshot snapshot;
  final WeightUnit unit;
  final List<DeviceRef> selectedDevices;
  final BleScanner scanner;
  final bool Function(String name) scanFilter;
  final Future<void> Function(int) onSelectIndex;
  final Future<void> Function(DeviceRef) onRetry;
  final Future<void> Function(DeviceRef) onRemove;
  final void Function(DeviceRef) onPromote;
  final Future<void> Function(bool currentlyScanning) onToggleScan;

  const _Body({
    required this.snapshot,
    required this.unit,
    required this.selectedDevices,
    required this.scanner,
    required this.scanFilter,
    required this.onSelectIndex,
    required this.onRetry,
    required this.onRemove,
    required this.onPromote,
    required this.onToggleScan,
  });

  Widget _cardFor(
    DeviceRef device,
    Map<DeviceRef, Dumbbell> dumbbellByDevice,
  ) {
    final dumbbell = dumbbellByDevice[device];
    if (dumbbell != null) {
      return DumbbellCard(
        key: ValueKey('connected-${device.id}'),
        dumbbell: dumbbell,
        unit: unit,
        onRemove: () => onRemove(device),
      );
    }
    final error = snapshot.failed[device];
    if (error != null) {
      return FailedDeviceCard(
        key: ValueKey('failed-${device.id}'),
        device: device,
        error: error,
        onRetry: () => onRetry(device),
        onRemove: () => onRemove(device),
      );
    }
    // Slot is "pending" — the device is in `selectedDevices` but
    // `WeightGroup` has neither connected nor failed yet (the very
    // first frame between promote-on-tap and the WeightGroup.add()
    // synchronous bookkeeping). Renders an empty placeholder; the
    // connecting card replaces it within a tick.
    return SizedBox.shrink(
      key: ValueKey('pending-${device.id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = snapshot.consensusIndex;
    final canPress = snapshot.anyReady && !snapshot.anyMoving;

    final dumbbellByDevice = {
      for (final d in snapshot.connected) d.device: d,
    };
    final selectedCards = <Widget>[
      for (final device in selectedDevices)
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _cardFor(device, dumbbellByDevice),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // TOP — selected devices. Min height ~= 2 cards so the layout
          // doesn't jump when the first card arrives. ListView so >2
          // cards scroll within the region instead of pushing the grid
          // down.
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 168),
            child: selectedDevices.isEmpty
                ? const _TopEmptyHint()
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: selectedCards.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => selectedCards[i],
                  ),
          ),
          const SizedBox(height: 12),
          // MIDDLE — always-visible weight grid.
          Expanded(
            flex: 3,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.6,
              ),
              itemCount: kJaxJoxWeightCount,
              itemBuilder: (_, i) => WeightButton(
                index: i,
                unit: unit,
                selected: selected == i,
                onPressed: canPress ? () => onSelectIndex(i) : null,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // BOTTOM — scan results minus the top region, with a header
          // row that hosts the stop/refresh icon.
          _ScanHeader(scanner: scanner, onToggle: onToggleScan),
          const SizedBox(height: 4),
          Expanded(
            flex: 2,
            child: StreamBuilder<List<ScanHit>>(
              stream: scanner.results,
              initialData: const [],
              builder: (context, snap) {
                final selectedSet = selectedDevices.toSet();
                final results = (snap.data ?? const <ScanHit>[])
                    .where((r) =>
                        scanFilter(r.device.name) &&
                        !selectedSet.contains(r.device))
                    .toList();
                return _ScanResults(
                  results: results,
                  unit: unit,
                  onPromote: onPromote,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty-state placeholder for the top region. Sized so it occupies the
/// same vertical space as 1-2 cards would, keeping the page from
/// jumping when the first card arrives.
class _TopEmptyHint extends StatelessWidget {
  const _TopEmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Tap a dumbbell below to connect',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _ScanHeader extends StatelessWidget {
  final BleScanner scanner;
  final Future<void> Function(bool currentlyScanning) onToggle;

  const _ScanHeader({required this.scanner, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          'Available dumbbells',
          style: theme.textTheme.titleSmall?.copyWith(
            color:
                theme.textTheme.titleSmall?.color?.withValues(alpha: 0.7),
          ),
        ),
        const Spacer(),
        StreamBuilder<bool>(
          stream: scanner.isScanning,
          // Seed with the synchronous getter — the stream is a broadcast
          // and the first emission may have already fired before this
          // builder subscribes (HomeScreen calls startScan during init,
          // before the body subtree is in the tree).
          initialData: scanner.isScanningNow,
          builder: (context, snap) {
            final scanning = snap.data == true;
            return IconButton(
              icon: Icon(
                scanning ? Icons.stop_circle : Icons.refresh,
              ),
              tooltip: scanning ? 'Stop scanning' : 'Scan again',
              onPressed: () => onToggle(scanning),
            );
          },
        ),
      ],
    );
  }
}

/// Renders scan-result cards in the bottom region. Pure UI — every
/// mutation flows through [onPromote].
@visibleForTesting
class ScanResultCard extends StatelessWidget {
  final ScanHit hit;
  final VoidCallback onTap;

  const ScanResultCard({super.key, required this.hit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.fitness_center, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(hit.device.displayName,
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      'RSSI ${hit.rssi}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color
                            ?.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.add_circle_outline, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanResults extends StatelessWidget {
  final List<ScanHit> results;
  final WeightUnit unit;
  final void Function(DeviceRef) onPromote;

  const _ScanResults({
    required this.results,
    required this.unit,
    required this.onPromote,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Text(
          'Scanning for JaxJox devices…',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final r = results[i];
        return ScanResultCard(
          key: ValueKey('scan-${r.device.id}'),
          hit: r,
          onTap: () => onPromote(r.device),
        );
      },
    );
  }
}
