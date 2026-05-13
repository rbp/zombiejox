import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, PlatformException;
import 'package:permission_handler/permission_handler.dart';

import '../ble/ble_scanner.dart';
import '../ble/device_ref.dart';
import '../ble/uuids.dart';
import '../devices/dumbbell.dart';
import '../devices/weight_group.dart';
import '../state/preferences.dart';
import '../state/selection_model.dart';
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
/// affordance) — there's no bulk-disconnect action; with promote-on-tap
/// and per-card ×, an N-dumbbell setup is N taps either way.
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final BleScanner _scanner = widget.scanner ?? const FlutterBluePlusScanner();
  late final WeightGroup _group = widget.createWeightGroup?.call() ?? WeightGroup();
  late final UnitAutoMatcher _autoMatcher = UnitAutoMatcher(
    preferences: widget.preferences,
    onOutcome: _onAutoMatchOutcome,
  );

  /// User-intent state (ADR-001 §4) — selected devices in tap order
  /// plus per-device user-owned metadata (custom display names from
  /// §2e; planned per-device weight override from §2f). The model
  /// hydrates from [Preferences] on construction; we just subscribe
  /// for change notifications and let it own the persistence path.
  late final SelectionModel _selection =
      SelectionModel(preferences: widget.preferences);

  StreamSubscription<GroupSnapshot>? _snapshotSub;
  GroupSnapshot _snapshot = GroupSnapshot.empty;
  StreamSubscription<BleAdapterState>? _adapterSub;
  BleAdapterState _adapter = BleAdapterState.unknown;

  bool _onAnyConnectedFired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selection.addListener(_onSelectionChanged);
    _snapshot = _group.lastSnapshot;
    _snapshotSub = _group.snapshots.listen(_onSnapshot);
    _adapterSub = _scanner.adapterState.listen((s) {
      if (!mounted) return;
      final wasOff = _adapter != BleAdapterState.on;
      setState(() => _adapter = s);
      // BT just came back on: members whose connections were torn down
      // by the OS during the off window are sitting in the supervisor's
      // backoff (failures during BT-off pushed each retry up to the
      // 60 s cap). Fast-forward any waiting timers so the user doesn't
      // wait out a backoff window after flipping BT back on.
      // Distinct from the resume kick in `_recheckPermissions`: an app
      // that stays foregrounded through a BT-off → BT-on flap never
      // fires the lifecycle event.
      if (wasOff && s == BleAdapterState.on) {
        _group.kickReconnectsForResume();
      }
    });
    // No initial permission check here — `main.dart` (or the route
    // pushing us) already verified that permissions are granted; the
    // platform-channel call is therefore duplicated work and shows up
    // as a one-frame spinner flash on every cold start. Revocation
    // while we're alive is caught by `didChangeAppLifecycleState`
    // below; the window between main's check and our mount is
    // microseconds and not worth the duplicated work.
    _bootstrap();
  }

  /// Warm-start seed + scan kick-off. Pulled out of [initState] so the
  /// lifecycle is readable. The [SelectionModel] hydrated its entries
  /// from [Preferences.rememberedDeviceIds] in its constructor, so all
  /// we have to do here is kick off a connect for each one.
  void _bootstrap() {
    for (final device in _selection.devices) {
      unawaited(_addOne(device));
    }
    unawaited(_startScan());
  }

  /// Rebuild when the selection (membership or custom names) changes.
  /// The model is the source of truth for the top-region order and
  /// the displayed names; reading off it on each build is cheap.
  void _onSelectionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// Re-check Bluetooth permissions whenever the app comes back to the
  /// foreground — covers the Android "user toggled permission off in
  /// Settings while the app was backgrounded" case. iOS doesn't expose
  /// a way to revoke once granted, so this is effectively a no-op
  /// there, but the cost is one async status read.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_recheckPermissions());
  }

  Future<void> _recheckPermissions() async {
    final bool granted;
    try {
      granted = await (widget.checkPermissionsGranted ?? _defaultCheckPermissionsGranted)();
    } on PlatformException catch (e, st) {
      // Narrow catch: a flaky platform channel on resume shouldn't
      // tear the screen down, but a Dart-side bug (e.g. a test
      // injecting a synchronous throw) should still surface. The
      // next resume will retry the check; if BT permission really
      // has been revoked, we'll catch it then.
      debugPrint('permission recheck failed: $e\n$st');
      return;
    }
    if (!mounted) return;
    if (granted) {
      // §2a: a backgrounded app may have accumulated transport drops on
      // its remembered dumbbells while suspended. Fast-forward any
      // waiting retry timers so the user doesn't sit through the next
      // 60s backoff window after un-backgrounding. In-flight attempts
      // are left alone — re-issuing would race the awaiting connect.
      _group.kickReconnectsForResume();
      return;
    }
    final navigator = Navigator.of(context);
    // `pushAndRemoveUntil` (not `pushReplacement`): the user may have a
    // Settings or About route pushed on top of Home when permissions
    // get revoked. pushReplacement would replace whatever's on top —
    // leaving a duplicated HomeScreen underneath and double state
    // when PermissionScreen later re-pushes Home. Clear the stack
    // entirely so the rationale screen is the only route, mirroring
    // a fresh launch.
    unawaited(
      navigator.pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(
          builder: (_) => PermissionScreen(preferences: widget.preferences),
        ),
        (route) => false,
      ),
    );
  }

  /// Default for the lifecycle re-check seam (see [_recheckPermissions]).
  /// iOS won't re-prompt once denied, so we hand the user back to
  /// [PermissionScreen] rather than re-prompting inline — the rationale
  /// + denied + Open-Settings UI lives in one place.
  static Future<bool> _defaultCheckPermissionsGranted() async {
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    return scan.isGranted && connect.isGranted;
  }

  /// Devices for which a reconnect-failure SnackBar has already been
  /// shown for the current drop. Cleared per-device once the device
  /// disappears from `snapshot.retryStates` (i.e. it reconnected, or
  /// the user removed it) — a future drop is treated as a fresh
  /// incident worth surfacing again.
  final Set<DeviceRef> _reconnectFailureShown = {};

  void _onSnapshot(GroupSnapshot snapshot) {
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
    _maybeFireOnAnyConnected();
    _maybeShowReconnectFailureSnackBar(snapshot);
    _tickAutoMatcher();
  }

  /// Surface a single SnackBar the *first* time a member's reconnect
  /// attempt fails for a given drop — so the user knows the supervisor
  /// is actually working in the background, rather than the
  /// "Reconnecting…" chip silently sitting on the card forever. Reset
  /// per-device once the entry leaves `retryStates`.
  void _maybeShowReconnectFailureSnackBar(GroupSnapshot next) {
    // Clear shown markers for devices that are no longer in retry —
    // either they reconnected or were removed. Next time they drop,
    // we'll surface the SnackBar again.
    _reconnectFailureShown.removeWhere(
      (ref) => !next.retryStates.containsKey(ref),
    );
    for (final entry in next.retryStates.entries) {
      final ref = entry.key;
      // attempt >= 1 means the immediate first attempt failed and the
      // supervisor is now in backoff. attempt == 0 is the initial
      // post-drop scheduling — too noisy to surface every time.
      if (entry.value.attempt < 1) continue;
      if (_reconnectFailureShown.contains(ref)) continue;
      _reconnectFailureShown.add(ref);
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${ref.displayName}: lost connection — retrying in the '
            'background.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Fires the first time any member is ready and flips
  /// [SelectionModel.markVerified] so subsequent membership changes
  /// (and the current set) flow through to
  /// [Preferences.rememberedDeviceIds]. A Connect that never reaches
  /// `isReady` (every device out of range) doesn't poison the next
  /// cold start.
  void _maybeFireOnAnyConnected() {
    if (_onAnyConnectedFired) return;
    if (!_snapshot.anyReady) return;
    _onAnyConnectedFired = true;
    _selection.markVerified();
  }

  /// Feed the auto-matcher the current snapshot. `attemptedCount`
  /// reflects the user's intent for the active session — failed and
  /// connecting devices both live in the selection model.
  void _tickAutoMatcher() {
    _autoMatcher.tick((
      knownUnits: _snapshot.knownUnits,
      knownUnitCount: _snapshot.knownUnitCount,
      failedCount: _snapshot.failed.length,
      attemptedCount: _selection.entries.length,
    ));
  }

  void _onAutoMatchOutcome(AutoMatchResult result) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result.outcome) {
      case AutoMatchOutcome.matched:
        final label = result.unit == WeightUnit.lbs ? 'lbs' : 'kg';
        messenger.showSnackBar(
          SnackBar(content: Text('Unit set to $label to match your dumbbells.')),
        );
      case AutoMatchOutcome.disagreement:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Dumbbells are set to different units — pick one in Settings'),
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
  /// off the connect. The model's [SelectionModel.add] is a no-op for
  /// an already-present device.
  void _onPromote(DeviceRef device) {
    if (_selection.contains(device)) return;
    _selection.add(device);
    unawaited(_addOne(device));
  }

  /// User tapped × on a top card. Drop from the selection and
  /// disconnect / clear the failure entry on the group. [SelectionModel.remove]
  /// is a silent no-op for an unknown device, so the explicit guard
  /// here is just so we skip [WeightGroup.remove] too (which has its
  /// own no-op behavior but the call is unnecessary).
  Future<void> _onRemove(DeviceRef device) async {
    if (!_selection.contains(device)) return;
    _selection.remove(device);
    await _group.remove(device);
  }

  /// User committed a rename through the dialog on either card
  /// variant. The raw string from the dialog is handed off to the
  /// model, which trims and treats empty / whitespace-only as "clear
  /// the custom name." (§2e)
  void _onRename(DeviceRef device, String name) {
    _selection.rename(device, name);
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
      // advertisement churn. Authoritative filtering is
      // `isJaxJoxLiveDeviceName` (from `lib/ble/uuids.dart`) applied to
      // the stream results below — that's what also rejects DFU names.
      await _scanner.startScan(
        withKeywords: kJaxJoxNamePrefixes,
        timeout: const Duration(seconds: 30),
      );
    } catch (e, st) {
      debugPrint('startScan failed: $e\n$st');
    }
  }

  /// §2g pull-to-refresh. Re-queries every ready dumbbell for its
  /// current state and restarts the BLE scan in parallel. Resolves once
  /// both kicks have returned — at which point the [RefreshIndicator]
  /// stops spinning. Fresh state frames and new scan results continue
  /// to arrive asynchronously through their normal streams.
  Future<void> _onRefresh() async {
    await Future.wait<void>([
      _group.refresh(),
      _startScan(),
    ]);
  }

  Future<void> _onSelectIndex(int idx) async {
    // §2b: haptic confirms the tap registered before the BLE write
    // round-trips. The grid's `canPress` already gates on `anyReady`,
    // so by the time this runs at least one member is ready to receive
    // the write. If the write later throws, the SnackBar still
    // surfaces — the haptic conveys "tap received," not "write
    // succeeded." `selectionClick` is the lightest of the four
    // canonical haptics and the semantically-correct one for a
    // user-driven setting change.
    unawaited(HapticFeedback.selectionClick());
    try {
      await _group.setWeightIndex(idx);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to set weight: $e')),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    _autoMatcher.dispose();
    unawaited(_snapshotSub?.cancel() ?? Future<void>.value());
    unawaited(_adapterSub?.cancel() ?? Future<void>.value());
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZombieJox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(preferences: widget.preferences),
                ),
              ),
            ),
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
              selectedDevices: _selection.devices,
              displayNameFor: _selection.displayNameFor,
              scanner: _scanner,
              adapterState: _adapter,
              scanFilter: isJaxJoxLiveDeviceName,
              onSelectIndex: _onSelectIndex,
              onRetry: _addOne,
              onRemove: _onRemove,
              onPromote: _onPromote,
              onRename: _onRename,
              onToggleScan: _toggleScan,
              onRefresh: _onRefresh,
              onOpenAppSettings: openAppSettings,
              onEnableBluetooth: _scanner.turnOnBluetooth,
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

  /// Resolves a device to its user-facing name (custom name if set,
  /// else the advertised name or raw id). Threaded from
  /// [SelectionModel.displayNameFor] so the top region AND the scan
  /// list agree on the same name. (§2e)
  final String Function(DeviceRef) displayNameFor;

  final BleScanner scanner;
  final BleAdapterState adapterState;
  final bool Function(String name) scanFilter;
  final Future<void> Function(int) onSelectIndex;
  final Future<void> Function(DeviceRef) onRetry;
  final Future<void> Function(DeviceRef) onRemove;
  final void Function(DeviceRef) onPromote;

  /// User committed a rename for [device] via either card variant's
  /// inline dialog. The raw string is forwarded as-is; the model
  /// trims and treats empty / whitespace-only as "clear."
  final void Function(DeviceRef device, String name) onRename;

  final Future<void> Function(bool currentlyScanning) onToggleScan;

  /// §2g pull-to-refresh. Re-queries connected dumbbells AND restarts
  /// the BLE scan. The [RefreshIndicator] spins until this resolves.
  final Future<void> Function() onRefresh;

  final Future<bool> Function() onOpenAppSettings;
  final Future<bool> Function() onEnableBluetooth;

  const _Body({
    required this.snapshot,
    required this.unit,
    required this.selectedDevices,
    required this.displayNameFor,
    required this.scanner,
    required this.adapterState,
    required this.scanFilter,
    required this.onSelectIndex,
    required this.onRetry,
    required this.onRemove,
    required this.onPromote,
    required this.onRename,
    required this.onToggleScan,
    required this.onRefresh,
    required this.onOpenAppSettings,
    required this.onEnableBluetooth,
  });

  Widget _cardFor(
    DeviceRef device,
    Map<DeviceRef, Dumbbell> dumbbellByDevice,
  ) {
    final dumbbell = dumbbellByDevice[device];
    final name = displayNameFor(device);
    if (dumbbell != null) {
      return DumbbellCard(
        key: ValueKey('connected-${device.id}'),
        dumbbell: dumbbell,
        unit: unit,
        onRemove: () => onRemove(device),
        retryState: snapshot.retryStates[device],
        displayName: name,
        onRename: (newName) => onRename(device, newName),
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
        displayName: name,
        onRename: (newName) => onRename(device, newName),
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
    // Per-device slot key on the AnimatedSwitcher itself — not just its
    // child. Without this, removing a card mid-list re-uses the
    // AnimationController of slot N+1 for what was slot N, and the user
    // sees the wrong cross-fade. The `ValueKey('slot-${device.id}')`
    // makes each slot a stable identity across selection edits; the
    // inner `_cardFor` keys (`connected-…`/`failed-…`/`pending-…`)
    // continue to drive the switcher's connected ↔ failed cross-fade
    // within a slot.
    final selectedCards = <Widget>[
      for (final device in selectedDevices)
        AnimatedSwitcher(
          key: ValueKey('slot-${device.id}'),
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
          child: _cardFor(device, dumbbellByDevice),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // BT-off banner is inline at the top of the body so it shifts
          // the rest of the regions down instead of overlapping (a
          // MaterialBanner via ScaffoldMessenger would float and cover
          // cards). Auto-hides when the adapter comes back to `on`.
          if (adapterState != BleAdapterState.on) ...[
            _BluetoothBanner(
              state: adapterState,
              onOpenSettings: onOpenAppSettings,
              onEnableBluetooth: onEnableBluetooth,
            ),
            const SizedBox(height: 12),
          ],
          // TOP — selected devices. Bounded share of the Column so
          // overflow scrolls *within* the region instead of pushing the
          // grid / scan list off-screen. flex matches the bottom for
          // visual symmetry; on a tall phone two cards fit comfortably,
          // on a small phone (~140 dp top region) only one card fits
          // without scrolling — the ListView absorbs the rest.
          //
          // The region is wrapped in a RefreshIndicator so pulling
          // down on the user's dumbbells fires `onRefresh` (re-query
          // connected weights + restart scan). The inner scrollable uses
          // `AlwaysScrollableScrollPhysics` so the gesture activates
          // even when the content is short — and the empty hint is
          // rendered through a `ListView` for the same reason.
          // TODO:
          // 1. Since only the top region is wrapped in the RefreshIndicator,
          // pulling to refresh requires pulling from the very top of the screen.
          // 2. The "refresh" icon feels too fast, even when pulling slowly. This might be
          // a result of a small area being wrapped in RefreshIndicator.
          Expanded(
            flex: 2,
            child: RefreshIndicator(
              onRefresh: onRefresh,
              child: selectedDevices.isEmpty
                  // CustomScrollView + SliverFillRemaining so the empty
                  // hint stays vertically centred in the region (matching
                  // the pre-§2g layout) while still being scrollable —
                  // RefreshIndicator's pull gesture needs a scrollable
                  // child with `AlwaysScrollableScrollPhysics`.
                  ? CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: const [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _TopEmptyHint(),
                        ),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: selectedCards.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => selectedCards[i],
                    ),
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
          // Divider visually separates "your current rig" (selected
          // cards + weight grid) from "find more dumbbells" (scan
          // results). M3 Divider uses `outlineVariant`, which is muted
          // enough on the dark scheme not to compete with the cards.
          // `height: 24` reserves the same total vertical space the old
          // SizedBox(12) + line would have occupied.
          const Divider(height: 24),
          // BOTTOM — scan results minus the top region, with a header
          // row that hosts the stop/refresh icon.
          _ScanHeader(scanner: scanner, onToggle: onToggleScan),
          const SizedBox(height: 4),
          Expanded(
            flex: 2,
            child: StreamBuilder<bool>(
              stream: scanner.isScanning,
              initialData: scanner.isScanningNow,
              builder: (context, scanningSnap) {
                final scanning = scanningSnap.data == true;
                return StreamBuilder<List<ScanHit>>(
                  stream: scanner.results,
                  initialData: const [],
                  builder: (context, snap) {
                    final selectedSet = selectedDevices.toSet();
                    final results = (snap.data ?? const <ScanHit>[])
                        .where((r) => scanFilter(r.device.name) && !selectedSet.contains(r.device))
                        .toList();
                    return _ScanResults(
                      results: results,
                      scanning: scanning,
                      adapterState: adapterState,
                      onPromote: onPromote,
                      onScanAgain: () => onToggleScan(false),
                      displayNameFor: displayNameFor,
                    );
                  },
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
            color: theme.textTheme.titleSmall?.color?.withValues(alpha: 0.7),
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

  /// User-facing name. When null, falls back to `hit.device.displayName`.
  /// HomeScreen resolves this through [SelectionModel.displayNameFor] so
  /// a previously-renamed dumbbell shows the user's name in the scan
  /// list too — even before it's promoted into the selection. (§2e)
  final String? displayName;

  const ScanResultCard({
    super.key,
    required this.hit,
    required this.onTap,
    this.displayName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = displayName ?? hit.device.displayName;
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
                    Text(name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      'RSSI ${hit.rssi}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
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
  final bool scanning;
  final BleAdapterState adapterState;
  final void Function(DeviceRef) onPromote;
  final VoidCallback onScanAgain;
  final String Function(DeviceRef) displayNameFor;

  const _ScanResults({
    required this.results,
    required this.scanning,
    required this.adapterState,
    required this.onPromote,
    required this.onScanAgain,
    required this.displayNameFor,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      final theme = Theme.of(context);
      final mutedStyle = theme.textTheme.bodyMedium?.copyWith(
        color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
      );
      if (adapterState != BleAdapterState.on) {
        // BT isn't usable; the banner above already explains *why*.
        // Tailor the scan-area copy so it matches the banner's
        // wording — a single "Turn Bluetooth on" line would be wrong
        // for unsupported (can't), unauthorized (permission, not
        // power), or unknown (we don't know yet what's wrong).
        final String hint;
        switch (adapterState) {
          case BleAdapterState.off:
            hint = 'Turn Bluetooth on to scan.';
          case BleAdapterState.unauthorized:
            hint = 'Grant Bluetooth permission to scan.';
          case BleAdapterState.unsupported:
            hint = 'Scanning is unavailable on this device.';
          case BleAdapterState.unknown:
            hint = 'Waiting for Bluetooth…';
          case BleAdapterState.on:
            // Unreachable — the outer `if` excludes it.
            hint = '';
        }
        return Center(
          child: Text(
            hint,
            style: mutedStyle,
            textAlign: TextAlign.center,
          ),
        );
      }
      if (scanning) {
        return Center(
          child: Text(
            'Scanning for JaxJox devices…',
            style: mutedStyle,
            textAlign: TextAlign.center,
          ),
        );
      }
      // Scan finished with no hits — the dumbbells are probably out of
      // range or powered off. Spell out what to check and offer a
      // one-tap retry so the user doesn't have to find the toolbar
      // refresh icon. Wrapped in a SingleChildScrollView so the empty
      // state survives tight bottom-region heights (small phones in
      // landscape, large-font scales) instead of triggering a flex
      // overflow.
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No JaxJox dumbbells found.',
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Make sure they\'re powered on and in range.',
              style: mutedStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onScanAgain,
              icon: const Icon(Icons.refresh),
              label: const Text('Scan again'),
            ),
          ],
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
          displayName: displayNameFor(r.device),
        );
      },
    );
  }
}

/// "Bluetooth is off" inline banner. Wording + CTA adapts to the adapter
/// state and platform:
///   - `off` (Android): "Enable Bluetooth" button → in-app system
///     prompt via `BluetoothAdapter.ACTION_REQUEST_ENABLE`. No settings
///     detour, the user accepts and the radio is on.
///   - `off` (iOS): no CTA — iOS doesn't expose a programmatic toggle.
///     Wording instructs the user to flip BT in Control Center / Settings.
///   - `unauthorized`: "Open Settings" → app's permission page.
///   - `unsupported` / `unknown`: text only, no CTA (terminal or
///     transient states where Settings doesn't help).
class _BluetoothBanner extends StatelessWidget {
  final BleAdapterState state;
  final Future<bool> Function() onOpenSettings;
  final Future<bool> Function() onEnableBluetooth;

  const _BluetoothBanner({
    required this.state,
    required this.onOpenSettings,
    required this.onEnableBluetooth,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // `defaultTargetPlatform` is web-safe (the `Platform` from `dart:io`
    // throws on web), and stable across builds for a given target.
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final String message;
    final IconData icon;
    switch (state) {
      case BleAdapterState.off:
        // On Android the CTA pops the in-app enable prompt; the message
        // can be terse. On iOS we have to tell the user to do it
        // themselves — there's no CTA we can wire to a programmatic
        // toggle.
        message = isAndroid
            ? 'Bluetooth is off. Tap Enable Bluetooth to turn it on.'
            : 'Bluetooth is off. Turn it on in Settings or Control '
                'Center to scan and connect.';
        icon = Icons.bluetooth_disabled;
      case BleAdapterState.unauthorized:
        message = 'Bluetooth permission was denied. Open Settings to grant '
            'it.';
        icon = Icons.no_encryption_gmailerrorred;
      case BleAdapterState.unsupported:
        message = 'Bluetooth Low Energy is not available on this device.';
        icon = Icons.error_outline;
      case BleAdapterState.unknown:
        message = 'Waiting for Bluetooth…';
        icon = Icons.bluetooth_searching;
      case BleAdapterState.on:
        // Unreachable — caller checks `!= on` before rendering. Kept
        // as a defensive case so a future enum addition doesn't break
        // the switch.
        return const SizedBox.shrink();
    }
    // Pick the CTA based on state + platform. `off` on Android maps to
    // the in-app enable prompt (the right thing); `off` on iOS shows
    // no CTA (text-only instruction); `unauthorized` goes to app
    // settings; `unsupported` / `unknown` show no CTA.
    final String? ctaLabel;
    final Future<bool> Function()? ctaAction;
    if (state == BleAdapterState.off && isAndroid) {
      ctaLabel = 'Enable Bluetooth';
      ctaAction = onEnableBluetooth;
    } else if (state == BleAdapterState.unauthorized) {
      ctaLabel = 'Open Settings';
      ctaAction = onOpenSettings;
    } else {
      ctaLabel = null;
      ctaAction = null;
    }
    return Material(
      color: scheme.errorContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(icon, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            if (ctaLabel != null && ctaAction != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => unawaited(ctaAction!()),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                ),
                child: Text(ctaLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
