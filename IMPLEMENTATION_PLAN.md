<!-- markdownlint-disable -->
<!-- vale off -->
<!-- cspell:disable -->

# JaxJox Replacement Flutter App — Implementation Plan

## Context

JaxJox (smart fitness equipment company) has gone into administration. Their app has been removed from app stores, leaving Bluetooth-connected dumbbells without wireless weight control. The goal is to build an open-source Flutter app that restores this functionality, starting with DumbbellConnect weight adjustment, extensible to other JaxJox products later.

The BLE protocol is undocumented. One third-party developer (Eamon Tuhami / X8IQ) has successfully reverse-engineered it for an iOS-only app "JaxJox Connect", proving the protocol is tractable.

---

## Phase 0: Reconnaissance (before writing any code)

### 0a. Try "JaxJox Connect" iOS app — ✅ done
- Installed from App Store (ID: 6759603427)
- Result: connects to the dumbbells and adjusts weight successfully. Confirms the protocol is workable from a third-party client.

### 0b. BLE service discovery + protocol validation with nRF Connect — ✅ done
- nRF Connect on Android, GATT enumerated, all UUIDs confirmed
- Init flow validated: time-sync, query-status, set-username
- **Set-weight validated end-to-end** — physical motion confirmed across all 8 indices on `DB200-0161997`
- Major correction discovered: `0xD6` payload is a weight **index** (0–7) mapping to JaxJox's eight steps (8/14/20/26/32/38/44/50 lbs), NOT weight in lbs. The original Java field name was misleading.
- `0xD6` response is a **status byte** (`0x00` = ACK / `0x01` = NACK), not an echo of the requested value
- Also discovered: opcode `0x27` (sent by `FitnessManager.k1()`, dead code) **knocks the dumbbell offline temporarily** — ⚠️ documented prominently in `docs/ble_protocol.md`

### 0c. Decompile the original APK with JADX — ✅ done
- Pulled v3.1.0 from apkpure.net (the apkpure.com download URL was JS-gated; v3.3.3 wasn't reachable via curl). v3.1.0 already contains the BLE code path needed.
- Installed jadx via Homebrew, decompiled to `reverse-engineering/decompiled/`.
- Findings (full detail in `docs/ble_protocol.md`):
  - Custom service `AAE28F00-71B5-42A1-8C3C-F9CF6AC969D0`, RX `…F01…`, TX `…F02…`
  - Frame: `[0xFF, length, opcode, ...payload, checksum]`, length = `payload + 4`
  - Opcodes: `0xD1` query status, `0xD6` set weight (1-byte INDEX 0–7), `0xC0` set username (length-prefixed), `0x08` sync timestamp
  - Notification opcodes: 0xC0 user-account echo, 0xD1 query reply / motor-state push, 0xD2 1 Hz state broadcast (byte 11 = current index), 0xD6 set-weight ACK/NACK, 0xD3/0xD4 history (untested)
  - **DO NOT SEND** opcode `0x27` (`FitnessManager.k1()`, dead code) — knocks the dumbbell temporarily offline
  - Device-name prefixes for scan filter: `DB200` (DumbbellConnect), `KB200`/`KB42` (KettlebellConnect), `PB220` (PushUpConnect), `FR100` (FoamRollerConnect), `JJ Scale`, plus Chileaf HRM prefixes (`CL8xx`, `JJ HRM`)

### 0d. Recover the native checksum — ✅ done (replaces planned HCI-snoop step)
- The Java checksum is implemented natively in `libfitness.so` (`Java_com_android_jaxjox_fitness_FitnessManager_checkSum`).
- Disassembled with Xcode's `llvm-objdump` (already on the machine — no Ghidra/Hopper needed).
- Algorithm: `((-sum_of_bytes) ^ 0x3A) & 0xFF` over the pre-checksum frame.
- Also disassembled `fetchPassCode` and `fetchBeat` — both belong to Chileaf HRM support, not the dumbbells. **No hidden auth on DumbbellConnect.**

### 0e. Document the protocol — ✅ done
- `docs/ble_protocol.md` is the live spec: UUIDs, frame format, opcodes, checksum, connection sequence, known unknowns.

### 0f. (Optional) HCI snoop for residual unknowns — ✅ closed via static analysis + on-device probe
- **kg/lbs unit toggle**: no opcode exists for the dumbbell. The decompiled `EditUnitMeasureFragment` / `UserManager.setWeightUnit` write to a SharedPreferences key only; `FitnessManager` (the BLE-write class) has zero unit references. The dock has its own hidden physical kg/lbs gesture; the app reads the current dock unit from `0xD1` byte 8 but never writes one. (The smart scale `SmartScaleManager.onSyncUnit` is a different device class.)
- **`0xD1` byte semantics**: fully recovered from `DumbBellReceivedDataCallback.h1(...)` + `DeviceStatus` field names (see `docs/ble_protocol.md` §`0xD1` byte semantics). Byte 8 (`unit`) mapping confirmed on-device: **`0x00` = lbs, `0x01` = kg**. Byte 5 (`battery` per the APK name, but values don't match the user-facing %) is still unexplained, though it's not used by the app and doesn't block anything.
- **`0xD2` 24-bit fields**: per `ChangedManager.U0` log line, bytes 4–6 = time, byte 7 = flag, bytes 8–10 = count, byte 11 = weight index, bytes 12–13 = unknown. Workout-specific; not relevant for MVP.
- HCI snoop of the original app is blocked anyway — JaxJox cloud is gone, the app can't get past its login wall.

---

## Phase 1: Flutter MVP — ✅ complete

PRs merged against `main`:

- **PR #1** (`e091190`) — initial Flutter scaffold + protocol layer + single-device connect/control + protocol unit tests.
- **PR #2** (`0d322d2`) — multi-device foundations (state layer, `WeightGroup`, `ControlScreen` with N-device cards, extracted widgets), tests, plus multi-select on the scan screen so the user can connect to ≥ 2 dumbbells in one trip.
- **PR #3** (`43e29e9`) — pre-permission rationale screen, Settings (lbs/kg toggle), About screen, reactive `Preferences` so the toggle takes effect mid-session.
- **PR #7** (`00b349d`) — warm-start auto-reconnect to remembered dumbbells (skip the scan step when we already know what worked last time).
- **PR #8** (`d3d2a8c`) — custom zombie launcher icon + splash for both Android (legacy + adaptive) and iOS.
- **PR #10** (`a2fa089`) — `0xD1` byte-8 dock-unit parsing + auto-match the app's display unit to the connected dumbbells' on first connect.
- **PR #14** (`refactor/ble-port`) — bind `flutter_blue_plus` behind a port/adapter (`DeviceRef`, `BleConnectionState`, `BleTransport`, `BleScanner`). The plugin's `BluetoothDevice` / `BluetoothConnectionState` / `DeviceIdentifier` / `ScanResult` types no longer appear above `lib/ble/`. Closes off the top item on PR #12's review list and makes a future plugin swap a one-file change.
- **PR #15** (`d41d472`) — fix: index 6 kg display is `20`, not `19.9` (on-device verified).
- **PR #16** (`537eec6`) — refactor: extract `PermissionRequestFlow` from `PermissionScreen` so the rationale → requesting → denied / granted transitions are testable as plain Dart, no widget pump.
- **PR #17** (`f58e2aa`) — chore: delete the unused `Dumbbell.withTransport` seam (test-only-API sweep).
- **PR #18** (`89eefbe`) — refactor: `WeightGroup` owns its full state. New `GroupSnapshot` value type carries `connected` / `failed` / `consensusIndex` / `anyMoving` / `anyReady` / `knownUnits` / `knownUnitCount`; consumers subscribe once to `WeightGroup.snapshots` and render as a pure projection. Removes per-dumbbell stream subscriptions and failed-devices bookkeeping from the screen layer.
- **PR #19** (`65760c0`) — feat(design): §2d PR 1 — visual system + component restyle (no UX change). New `lib/theme/app_theme.dart` (dark M3 scheme seeded from aubergine `#4A1942`); `WeightButton` dropped the `FilledButton` / `FilledButton.tonal` swap in favour of a rounded tile with scheme-driven fill; `DumbbellCard` / `FailedDeviceCard` restyled as button-shaped surfaces with a small status chip; stop icon → `Icons.stop_circle`; weight grid switched to `SliverGridDelegateWithMaxCrossAxisExtent` + `FittedBox(scaleDown)` for TextScaler ≤ 2× safety; 600 dp max-width cap on every screen.
- **PR #20** (`24dcadf`) — feat(design): §2d PR 2 — single Home screen. Merges scan + control into `lib/screens/home_screen.dart` with three stacked regions (top: selected device cards; middle: weight grid; bottom: scan results minus the top, with a Divider between middle and bottom). Promote-on-tap on scan cards; per-card "×" remove via new optional `onRemove` on both card widgets. Warm-start seeds the top region in `connecting` state immediately and starts the scanner in parallel — no more `pushReplacement` dance. New `WeightGroup.remove(DeviceRef)` primitive (drops a single device from `connected` and/or `failed`, with a race guard in `add`'s catch block). `scan_screen.dart` / `control_screen.dart` and their tests deleted.

The app's current user flow: rationale on first launch → grant → home screen. Home shows the selected devices at the top (seeded from warm-start memory on cold launch), the always-visible 8-tile weight grid in the middle, and live scan results in the bottom region. Tapping a scan card promotes it to the top + connects; tapping × on a top card disconnects and drops the slot. Settings/About via the AppBar gear. Toggling kg/lbs in Settings re-labels every weight tile live; on first connect, if the user hasn't picked a unit yet, the app silently matches whatever the docks are set to (SnackBar) or surfaces a "set one in Settings" hint if the docks disagree.

All edge-case states the user can land in — Bluetooth off, permission revoked mid-session, all dumbbells out of range, a connected dumbbell drops mid-session — have explicit UI now (§1h). Mid-session drops then auto-reconnect via §2a's supervisor without user intervention. Remaining gates to ship are on-device verification (Phase 2 / 3); no implementation work outstanding for Phase 1.

### 1a. Create the Flutter project at the repo root — ✅ done

Project created with `flutter create --org net.isnomore.zombiejox --project-name zombiejox --platforms ios,android .` Repo-root layout is in place: `pubspec.yaml`, `lib/`, `android/`, `ios/`, `test/`, `analysis_options.yaml` all alongside the existing docs/assets/reverse-engineering trees.

### 1b. Dependencies (`pubspec.yaml`) — ✅ done

Runtime:
- `flutter_blue_plus: ^2.3.1` — BLE.
- `permission_handler: ^12.0.1` — Bluetooth scan/connect permission.
- `shared_preferences: ^2.3.0` — units, remembered-device IDs, explicit-choice flag.
- `url_launcher: ^6.3.1` — opens external URLs (the About screen's GitHub link and `mailto:` author email) via the OS handler.
- `cupertino_icons: ^1.0.8` (default Flutter cruft).

Dev:
- `flutter_launcher_icons: ^0.14.1` — generates platform launcher icons from `assets/icon-1024.png` (legacy / iOS) and `assets/icon-foreground-1024.png` (Android adaptive foreground). Cream `#F4ECD4` adaptive-icon background defined in the same `pubspec.yaml` block.
- `flutter_native_splash: ^2.4.3` — splash for Android (pre-12 + Android 12+) and iOS, using the same icons + background colour.

### 1c. Assets — icon and splash — ✅ done

`assets/icon-1024.png` (full-bleed, cream background) and `assets/icon-foreground-1024.png` (transparent foreground, full-bleed — `flutter_launcher_icons` applies the 16% safe-zone inset automatically) are committed alongside the existing `assets/zombiejox-logo*.svg`. The generators run from `pubspec.yaml` and emit:

- Android: `mipmap-*/ic_launcher.png` (non-adaptive), `mipmap-anydpi-v26/ic_launcher.xml` (adaptive: foreground PNG + cream colour), `drawable*/launch_background.xml` and `values-v31/styles.xml` for splash (pre-12 and Android-12+).
- iOS: every size in `AppIcon.appiconset/`, plus `LaunchImage` and `LaunchScreen.storyboard` for the splash.

Regenerate from a clean checkout:

```
rsvg-convert -w 1024 -h 1024 assets/zombiejox-logo-bg.svg -o assets/icon-1024.png
rsvg-convert -w 1024 -h 1024 assets/zombiejox-logo.svg    -o assets/icon-foreground-1024.png
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

### 1d. Source layout — ✅ done

```
lib/
  main.dart                         ✅   loads Preferences; gates first-launch on rationale screen
  protocol/
    checksum.dart                   ✅
    frame.dart                      ✅
    opcodes.dart                    ✅
    dumbbell_state.dart             ✅
  ble/
    uuids.dart                      ✅
    device_ref.dart                 ✅   plugin-agnostic peripheral handle (id + name + displayName fallback)
    ble_connection_state.dart       ✅   3-state enum replacing the plugin's BluetoothConnectionState
    ble_transport.dart              ✅   per-device transport interface (the protocol-side seam)
    ble_scanner.dart                ✅   scan interface + ScanHit value type + FlutterBluePlusScanner adapter
    ble_service.dart                ✅   BleConnection — production BleTransport adapter backed by flutter_blue_plus
  devices/
    dumbbell.dart                   ✅   PR §2a: + handleTransportDrop / reconnect (WG-internal API); _ble non-final; lazy connectionState forwarder
    weight_group.dart               ✅   N-device fan-out. PR §2a: + reconnect supervisor (RetryState/RetryPhase, _retryTimers/_retryStates/_everReady/_connSubs, kickReconnectsForResume)
  state/
    preferences.dart                ✅   units (reactive); remembered device IDs; explicit-unit-choice flag + auto-match-safe setter
    permission_request_flow.dart    ✅   PR #16: state machine for rationale → requesting → granted / denied transitions
    unit_auto_matcher.dart          ✅   PR #10/#12: dock-unit decision logic, lifted out of the screen layer
    weights.dart                    ✅   index ↔ lbs ↔ kg lookup, formatWeight(), weightUnitFromRawByte() (0x00=lbs / 0x01=kg)
  theme/
    app_theme.dart                  ✅   PR #19: dark M3 scheme seeded from aubergine #4A1942; structured so adding lightTheme later is one block
  screens/
    home_screen.dart                ✅   PR #20: single screen — selected cards (top) + weight grid (middle) + scan results (bottom). Promote-on-tap; per-card × remove; warm-start seeding; auto-match-from-dock
    permission_screen.dart          ✅   pre-permission rationale; Continue / denied state with retry / open settings
    settings_screen.dart            ✅   lbs/kg SegmentedButton toggle + link to About
    about_screen.dart               ✅   credits + license + protocol-doc reference + disclaimer
                                        scan_screen.dart and control_screen.dart deleted in PR #20.
  widgets/
    weight_button.dart              ✅   PR #19: rounded tile with FittedBox(scaleDown) for large-font safety
    dumbbell_card.dart              ✅   PR #19: rounded surface + status chip. PR #20: optional onRemove. PR §2a: optional `retryState` prop → "Reconnecting…" chip
    failed_device_card.dart         ✅   shown when a device's connect throws; refresh + optional × icons
test/
  protocol/                         ✅   checksum_test, frame_test (incl. 0xD1 unit-byte parse)
  state/                            ✅   weights_test (incl. weightUnitFromRawByte), preferences_test, permission_request_flow_test, unit_auto_matcher_test
  devices/                          ✅   dumbbell_test, weight_group_test (incl. GroupSnapshot derivations + remove() race guard)
  widgets/                          ✅   weight_button_test (incl. TextScaler 1.6× large-font safety), dumbbell_card_test, failed_device_card_test
  screens/                          ✅   home_screen_test (warm-start, promote-on-tap, retry, ×-remove, auto-match, unit toggle live re-label, consensus, motor-active, persisted-set), permission_screen_test, settings_screen_test, about_screen_test
android/app/src/main/AndroidManifest.xml   ✅
ios/Runner/Info.plist                       ✅
```

Total test count: **167 tests, all passing.** `flutter analyze` clean. `dart format` clean. All tests above `lib/ble/` use the port types — no test imports `package:flutter_blue_plus/` outside the adapter.

### 1e. Platform setup — ✅ done

Android `<uses-permission>` entries (`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_CONNECT`) and iOS `NSBluetoothAlwaysUsageDescription` are configured per the PR. Android minSdk is 31 (Android 12); Android ≤11 isn't supported because it'd require `ACCESS_FINE_LOCATION` for BLE scanning, which would also require either dropping the privacy-friendly `neverForLocation` flag or maintaining two code paths. iOS does not request `Permission.locationWhenInUse` (which would otherwise crash without `NSLocationWhenInUseUsageDescription` in Info.plist).

### 1f. User flow — ✅ done

What works:
- ✅ **First launch**: pre-permission rationale screen ("ZombieJox needs Bluetooth…") → Continue → OS prompt → Home. If the user denies, the screen flips to a "Permission was denied" state with `Open Settings` + `Try again` buttons.
- ✅ Routing on every cold start checks the actual `Permission.bluetoothScan` / `bluetoothConnect` status — granted goes straight to Home; revoked-since-last-launch (Android) re-shows the rationale automatically. No flag in Preferences.
- ✅ **Joint Home screen** (§2d PR #20): one screen with selected device cards on top, the 8-tile weight grid in the middle, and live scan results at the bottom. Promote-on-tap on a scan card adds it to the top region and kicks off the connect immediately; per-card "×" removes it (disconnect + drop the slot). One weight tap fans `0xD6` to every ready member.
- ✅ **Warm-start auto-reconnect**: on cold start, if `Preferences.rememberedDeviceIds` is non-empty, the Home screen seeds the top region with those device refs in `connecting` state on the first frame and kicks off `WeightGroup.add` for each, while the scanner starts in parallel. The remembered set is saved on the first verified ready of any member, then kept in sync on every later promote / × so a failed attempt doesn't poison the warm-start fast path.
- ✅ **Settings**: lbs/kg toggle (reactive — flipping it re-labels every weight tile live without a navigation round-trip), link to About. Reachable from the gear icon on the Home screen's AppBar.
- ✅ **Auto-match dock unit**: on first connect, if the user hasn't explicitly picked a unit, the app reads `0xD1` byte 8 from each ready dumbbell (`0x00`=lbs, `0x01`=kg). All agree → silently match (SnackBar if it actually changed). Disagree → SnackBar pointing the user to Settings. Once they tap Settings, the auto-match is a no-op forever — their choice wins.
- ✅ **About** (§2c PR #21): logo at the top, tappable GitHub + author-email rows, credits to Eamon Tuhami / X8IQ, original JaxJox engineering team, link to `docs/ble_protocol.md`, license, disclaimer.
- ✅ Manual weight changes (via dock buttons) reflected in the UI via `0xD2` byte 11.
- ✅ **Custom logo wired into icon and splash** — pixel-art zombie + dumbbell on cream `#F4ECD4`, adaptive on Android (cream background + transparent foreground PNG with launcher-applied 16% safe-zone inset), full-bleed cream on iOS. Splash matches.

Edge-case states (§1h):
- ✅ **Bluetooth adapter off / unsupported**: HomeScreen subscribes to `BleScanner.adapterState` (new). When the radio isn't `on`, an inline error-coloured banner appears at the top of the body with an Open Settings button, and the scan list's empty-state copy switches to "Turn Bluetooth on to scan." The banner disappears when the user toggles BT back on.
- ✅ **Permission revoked mid-session**: HomeScreen registers a `WidgetsBindingObserver`; on `AppLifecycleState.resumed` it re-runs the permission check and `pushReplacement`s back to `PermissionScreen` if BT permission was revoked while backgrounded.
- ✅ **All dumbbells out of range**: when the scanner stops with zero hits, the scan-list placeholder switches from "Scanning for JaxJox devices…" to "No JaxJox dumbbells found. Make sure they're powered on and in range." plus a tonal "Scan again" button. The empty state is wrapped in a `SingleChildScrollView` so a tight bottom-region height (small phones, large-font scales) doesn't flex-overflow.
- ✅ **Mid-session drop**: `DumbbellCard` distinguishes `BleConnectionState.disconnected` (after a successful connect) from the initial connecting state. The status chip flips to an error-coloured "Disconnected" and the body line spells it out, instead of falsely showing "Connecting…".

### 1g. Index ↔ weight lookup

| Idx | lbs  | kg   |
|-----|------|------|
| 0   |  8   |  3.6 |
| 1   | 14   |  6.4 |
| 2   | 20   |  9.1 |
| 3   | 26   | 11.8 |
| 4   | 32   | 14.5 |
| 5   | 38   | 17.2 |
| 6   | 44   | 20   |
| 7   | 50   | 22.7 |

(kg values match what the dock displays in kg mode — mostly the exact lb→kg conversion to 1 decimal, except index 6 which the dock shows as a whole `20`, not the converted `19.9`. On-device verified.)

### 1h. Remaining work to close out Phase 1 — ✅ done

✅ Done: `shared_preferences`; `state/weights.dart` (incl. `weightUnitFromRawByte`); reactive `state/preferences.dart` (units + remembered device IDs + explicit-choice flag); `state/{permission_request_flow,unit_auto_matcher}.dart`; `devices/{dumbbell,weight_group}.dart` (with `GroupSnapshot` + `remove()`); `widgets/{weight_button,dumbbell_card,failed_device_card}.dart` (incl. disconnect-aware status); `theme/app_theme.dart`; `screens/{home,permission,settings,about}_screen.dart`; promote-on-tap selection on the joint Home screen; per-card "×" remove; Settings/About reachable via gear icon; warm-start auto-reconnect to remembered dumbbells (seeds the top region in `connecting` state on the first frame); auto-match-from-dock on first connect; `0xD1` byte-8 unit parsing with on-device-confirmed mapping; custom launcher icon + splash; edge-case states (BT off banner with Open Settings, permission-revoked-on-resume re-route to PermissionScreen, scan-empty hint with "Scan again", `DumbbellCard` "Disconnected" state for mid-session drops); new `BleScanner.adapterState` port surface backed by `FlutterBluePlus.adapterState`.

### 1i. Out of scope for MVP (deferred)

- Per-dumbbell weight override (asymmetric warmup) — Phase 2+
- History sync (`0xD3` / `0xD4`)
- Username (`0xC0`) — has no effect on motor control. Will not be implemented at all, unless we discover that there is a functional need.
- Other JaxJox products (Kettlebell, FoamRoller, PushUp, HRMs)

### Confirmed impossible (not in scope at any point)

- **Pushing a kg/lbs setting from app to dock**: there is no BLE opcode for this. Search of `FitnessManager`, `DumbBellManager`, `KettleBellManager` finds zero unit-write paths; the original JaxJox app's Settings toggle is a pure SharedPreferences write. The dock has its own hidden physical kg/lbs gesture, and we read the result from `0xD1` byte 8 — that's the only direction of data flow. The app-side auto-match-from-dock UX (§1f) is what we built instead.

### Not to be implemented at any point

- Workout / exercise / social features (the original app's cloud "platform" — gone with JaxJox)

---

## Phase 2: Polish & hardening — 🟡 partially shipped

Phase 2 fleshes out the MVP scaffold with proper error handling, edge-case hardening, and visual polish. Not a separate implementation pass — incremental work on top of Phase 1.

Shipped so far: §2a (state-stream robustness — auto-reconnect on drop + resume kick), §2c (About screen restructure), §2d (Design v1). Outstanding: §2b (UX polish — animations, refined empty/error states), §2e (rename dumbbells), §2f (per-device weight override), §2g (pull-down to refresh).

### ADR-001 — four sources of truth in the running app

Recorded post-Phase-1 multi-agent code review (Round 2). The app keeps four state spaces; **each is owned by exactly one module** and consumers read it from there:

1. **Transport state** — per-device BLE connection liveness, owned by `BleTransport` (production: `BleConnection`) inside `Dumbbell`. Surfaced to callers via `Dumbbell.connectionState` (`Stream<BleConnectionState>`).
2. **Protocol state** — the last parsed `DumbbellState` per device (weight index, motor active, battery, unit byte), owned by `Dumbbell.lastState` and emitted via `Dumbbell.states`.
3. **Group snapshot** — the projected `GroupSnapshot` (membership, failed map, consensus, motor, units), owned by `WeightGroup` and emitted on `WeightGroup.snapshots`. Computed inside `_computeSnapshot`; consumers don't recompute.
4. **User intent** — the user's *selected* device list (today: `HomeScreen._selectedDevices`; planned: extracted into a `SelectionModel` under `lib/state/` when §2e rename + §2f per-device override land, because they're per-`DeviceRef` user-owned metadata in the same lifecycle).

**Consequences:**

- The `BleTransport` port is still bound by `Dumbbell`'s default constructor (`Dumbbell(this.device) : _ble = BleConnection(device)`). §2a's reconnect path swaps `_ble` internally for a fresh `BleConnection(device)` after a drop — so `_ble` is now non-final, but the constructor seam (an optional `BleTransport` parameter for tests) is still deferred. Tests fake `Dumbbell` by subclassing it directly and overriding public methods; the constructor seam adds no value while that pattern works.
- `DumbbellCard` currently subscribes to (1) and (2) separately and re-derives connection / motor labels. This is the one remaining place where a screen-side widget computes derived state that could live on (3). §2a added a `retryState: RetryState?` prop wired from `GroupSnapshot.retryStates[device]` — that's one more piece of derived state pushed onto the snapshot, but the card still owns the `connState`/`state` subscriptions. The intended fix is to extend `GroupSnapshot` with a per-`DeviceRef` view-model so the card becomes a pure `Stateless` projection over a single value object. Tracked as Phase 2 cleanup.
- Adding "rename" or "per-device weight override" without first extracting (4) into `lib/state/` will push `HomeScreen` past the junction-box threshold. Don't.

### 2a. State-stream robustness — ✅ done

Shipped as one PR alongside this plan refresh.

**What works:**

- **Auto-reconnect after a mid-session drop.** `WeightGroup` subscribes to each member's `Dumbbell.connectionState`. When a member that has ever reached `isReady` reports `disconnected` (and the consumer still cares — `_consumerStillCares` race guard), the supervisor calls `Dumbbell.handleTransportDrop()` (clears `_last` / `_pendingBatteryPct` / `_rxSub` so `isReady` flips false synchronously) and schedules a backoff retry. Backoff is `[0s, 2s, 5s, 15s, 30s, 60s]`, repeating at 60s indefinitely — cancel UI is the × button on the card, not a give-up timeout.
- **Reconnect-on-resume.** `HomeScreen.didChangeAppLifecycleState(resumed)` re-checks permissions; on `granted`, calls `WeightGroup.kickReconnectsForResume()` which fast-forwards every `RetryPhase.waiting` timer to fire immediately. Members in `RetryPhase.attempting` (in-flight `Dumbbell.reconnect()`) are skipped — re-issuing would race the awaiting connect. The same kick fires on a `BleAdapterState` off → on transition (BT toggled in-foreground), so a user who flips Bluetooth doesn't sit through a 60 s backoff window.
- **`Dumbbell.reconnect()`.** Tears down the old `_ble`, constructs a fresh `BleConnection(device)`, re-wires the lazy `connectionState` forwarder if listeners are attached, then runs the normal `connect()` flow. `_ble` is no longer `final`; subscribers to `Dumbbell.connectionState` / `Dumbbell.states` stay attached across the swap via Dumbbell-owned broadcast controllers. `Dumbbell.handleTransportDrop()` and `Dumbbell.reconnect()` are public methods documented as WeightGroup-internal — only the supervisor should call them.
- **Snapshot surface.** New `GroupSnapshot.retryStates: Map<DeviceRef, RetryState>` with a `RetryState { phase, attempt }` value type (phases: `waiting`, `attempting`; entries vanish on next state arrival or on `remove()` / `disconnectAll()`). `DumbbellCard` accepts an optional `retryState` prop wired by `HomeScreen` from the snapshot; the new "Reconnecting…" status chip preempts the bare "Disconnected" fallback that's now a defensive fallback only.
- **Cancellation correctness.** `WeightGroup.remove()` cancels the per-device retry `Timer` synchronously, removes from `_retryStates`/`_everReady`/`_connSubs`/`_stateSubs`, and the `_consumerStillCares` probe in the retry callback short-circuits any racing reconnect. `disconnectAll()` cancels every timer synchronously before tearing down subs.
- **Confirmed:** dumbbells **reject OS-level bonding** — never call `createBond()` (see `docs/ble_protocol.md` §1). Reconnect goes through the same `flutter_blue_plus` `BluetoothDevice.connect(autoConnect: false)` path as initial connect.

**Pre-existing soundness gap that §2a also closes:** before this PR, `Dumbbell.isReady` stayed `true` after a mid-session drop (nothing in `Dumbbell` reacted to its own `connectionState` going `disconnected`). The weight grid stayed enabled and writes silent-failed. `Dumbbell.handleTransportDrop()` clears `_last` synchronously so `isReady` returns false and `WeightGroup._computeSnapshot` immediately stops counting the dropped dumbbell.

### 2b. UX polish
- Smooth motion-state animations on weight buttons
- Better empty / loading / error states

### 2c. About screen improvements — ✅ done

Restructured the About screen per the spec below:

- Logo (`assets/icon-1024.png`, the cream-background launcher icon, clipped to a rounded rectangle) above the app name + tagline.
- "What it is" pitch unchanged.
- Two new rows below it: a fully-tappable GitHub link (`github.com/rbp/zombiejox`) and a "Created by Rodrigo Pimentel \<rbp@isnomore.net\>" row where only the email span is tappable (the surrounding text and the leading icon are inert). Both launch the OS handler via `url_launcher` (new dependency); a failing launch surfaces a SnackBar rather than an uncaught error.
- Existing Credits / Protocol / License / Disclaimer sections kept verbatim.

Test seam: `AboutScreen.launchUri` accepts a `Future<bool> Function(Uri)` override so widget tests can assert on the URIs without hitting the `url_launcher` platform channel.

Original notes (kept for reference):

- It should have the logo at the top. Either the app name and below it, the logo; or the other way round.
- Below "what it is", a link back to the app's GitHub page
- Then, "Rodrigo Pimentel <rbp@isnomore.net> started this project"
- Then, the rest of the README contents, which is what the About screen currently shows.

### 2d. Design - v1 — ✅ done (PR #19 + PR #20)

Shipped in two PRs along a visual-vs-structural seam (see `PLAN_2D.md`):

- **PR #19** — visual system + component restyle. Dark M3 theme seeded from aubergine `#4A1942` in `lib/theme/app_theme.dart`; rounded weight tiles with `FittedBox(scaleDown)` for large-font safety; rounded `DumbbellCard` / `FailedDeviceCard` with a status chip ("Connecting" / "Connected" / "Moving" / "Failed"); `Icons.stop_circle` for the scanner stop; weight grid switched to `SliverGridDelegateWithMaxCrossAxisExtent` so cells reflow on narrow / wide / tablet layouts; 600 dp max-width cap on every screen for tablet / landscape; widget test pumping at `TextScaler.linear(1.6)`.
- **PR #20** — single Home screen. `lib/screens/home_screen.dart` merges scan + control: top region for selected/remembered cards (min-height ≈ 2 cards, with an empty-state hint), always-visible middle weight grid, divider, bottom scan list with stop/refresh icon. Promote-on-tap (no batched "Connect (N)" button) and per-card "×" remove via new optional `onRemove` on both card widgets. Warm-start seeds the top region in `connecting` state immediately and runs the scanner in parallel — no more `pushReplacement` dance through scan → control. New `WeightGroup.remove(DeviceRef)` primitive with a race guard. Old `scan_screen.dart` / `control_screen.dart` and their tests deleted.

Original notes (kept for reference):

#### Principles

It should feel modern and smooth. Not too minimalist that it feels cold, but definitely not frilly. It should definitely feel designed, not something that a backend developer would make (i.e., not simple text elements on a white background).

Each dumbbell card should look like a button that's either selected or not (instead of looking like an unstyled html checkbox like on the scan screen). The weight selection buttons should all have the same dimensions, and should be rectangular with slightly rounded corners.

The iOS app https://apps.apple.com/nl/app/jaxjox-connect/id6759603427 is good inspiration. We don't make to make a clone of it, but it has decent design.

#### Overall UX

Currently we show one screen where devices are scanned, select devices, and click "connect". Then we are taken to a screen with the chosen devices (connection pending, may fail or succeed), and from there we can choose the weight for the connected dumbbells.

Instead, how about: after bluetooth permissions are granted, we have one *single* screen. The screen shows, in order:
1) The cards for the selected or remembered devices; these can be ready, idle, failed or any of the currently available states. If there are no selected devices, this list is empty. The minimum height for even the empty list is the height of two dumbbell cards.
2) The weights. Selecting a weight changes the weight on all the dumbbells listed about, that are succesfully connected. If there are no dumbbells successfully connected, these weight cards are still there, but disabled.
3) The list of scanned devices (that aren't yet on the selected list above). Just above this list, to the right, is the stop/re-scan button.

#### Colour themes

Eventually, the app should allow a "light" and a "dark" themes. To beging with, let's make it primarily dark. The primary colour can be a dark aubergine, and you can derive other colours from there.

#### Accessibility

The app should be accessible from the start. There's no reason why someone with a disability shouldn't be able to use it. In particular, the app should be usable if the font is very large.


#### Portability

The app should work:
- On wide phones
- On narrow phones
- In portrait and landscape modes
- On tablets (portrait and landscape)
- On watches (though that can be deferred, since the UX and UI will need thinking)

#### Misc

The small "stop" / "retry" button on top-right of the scan screen is confusing - especially the "stop" button, which is simply a filled square that looks like an asset is missing. It should have a circle around it, like https://fontawesome.com/icons/duotone/solid/circle-stop

### 2e. Allow user to change the display name of dumbbells

Currently, the name displayed is the device's uid, and is what shows up across the Home screen (top region cards and the bottom scan list). A simple approach is: when the user taps on the portion of the dumbbell card containing the display name (currently, the UUID), a pop-up with a single input field is displayed, prompting the user to rename the dumbbells. If the user then taps "ok", we store and always use that name for that dumbbell. If they tap "cancel", nothing is changed.

### 2f. Per-device weight override
i.e., asymmetric setting, gated behind a Settings toggle

### 2g. Pull-down to refresh

Pulling down from the main screen refreshes: re-fetches the weights of connected dumbbells, and refreshes the list of availabe dumbbells.

### 2h. Tapping the bluetooth status pill

The bluetooth status pill may be truncated (e.g., "Conne..."). If the user taps that side of the dumbbell card, the app should display a message for a few seconds, saying "Device $UUID ($displayName) is $state" where ($displayName) is only shown if the user has set a specific name (see 2f), do not show the UUID again.


### ~~kg/lbs unit toggle on the dock~~ — confirmed impossible
- No app-to-dock unit-write opcode exists (see §1i → *Confirmed impossible*). The user changes the dock's display unit via its own hidden physical gesture; the app reads the result via `0xD1` byte 8 and auto-matches its own display unit (already done in PR #10).

---

## Phase 3: Testing & distribution — ⏳ pending

### 3a. Real device testing
- Test on both Android and iOS physical devices
- Test connection reliability, reconnect-on-resume, weight change responsiveness
- Test with N dumbbells simultaneously (start with the user's pair)

- Write a TESTING.md guide for testing. There should be a short session showing which commands to call for running automated tests, and a thorough but succint "Manual testing" session, with complete instructions for each platform.

### 3b. Build & distribute
- Android: build APK/AAB, distribute via GitHub releases (sideload — Google Play won't host hobby apps for orphaned hardware)
- iOS: TestFlight for personal use, or App Store submission
- Open-source release for the JaxJox community

---

## Key Risks & Mitigations

| Risk | Status |
|------|--------|
| Protocol uses encryption/auth beyond standard BLE pairing | **Resolved** — static + native analysis shows no auth on DumbbellConnect. The two native exports that looked auth-shaped (`fetchPassCode`, `fetchBeat`) are Chileaf-HRM logic, not used for dumbbells. |
| APK is heavily obfuscated | **Mostly resolved** — JADX decompiled with 45 minor errors; the protocol surface (BLE callbacks, packet builder, opcodes) decompiled cleanly. |
| Firmware requires specific app signature/certificate | **Unlikely** — X8IQ's iOS app works without the cloud; user confirmed in 0a. |
| N dumbbells need simultaneous control | **Designed in** — `WeightGroup` abstraction fans out a single `setWeightIndex` to all connected devices in parallel. `flutter_blue_plus` supports concurrent connections. |
| BLE plugin lock-in (breaking changes on upgrade, no path to a second transport) | **Mitigated by PR #14** — `flutter_blue_plus` is now confined to `lib/ble/` behind `BleTransport` + `BleScanner`. A plugin swap (or a parallel transport for wear OS / web BLE) is a single-file change, not a codebase-wide refactor. |

---

## Recommended Order of Work

**Phase 0 + Phase 1 are complete; §2a state-stream robustness + §2c About + §2d Design v1 have landed.** End-to-end: set + read weight on N dumbbells via a single Home screen with promote-on-tap and per-card × remove, warm-start seeding, Settings/About with reactive unit toggle, auto-match-from-dock, dark M3 theme, large-font + tablet portability, custom icon + splash. Edge-case states (BT off, all out of range, mid-session drops with auto-reconnect, permission revoked mid-session) all have explicit UI. Remaining work is on-device verification + further Phase 2 polish.

1. ✅ Phase 0 reverse-engineering (0a–0e done; 0f closed via static analysis — no HCI snoop needed)
2. ✅ Phase 1 — Flutter MVP — PRs merged: #1, #2, #3, #7, #8, #10, #14–#20, plus the edge-case PR closing §1h.
3. 🟡 Phase 2 — UX and UI improvements. §2a (state-stream robustness — auto-reconnect on drop + resume kick) + §2c (About screen) + §2d (Design v1) shipped. Still pending: §2b (UX polish), §2e (rename dumbbells), §2f (per-device weight override), §2g (pull-down to refresh).
4. ⏳ Phase 3 — Testing & distribution

---

## Verification

### Done

- ✅ **Protocol correctness** — `0xD6 <idx>` sent from nRF Connect physically moves the dumbbell across all 8 indices on `DB200-0161997`.
- ✅ **Protocol unit tests** — `test/protocol/checksum_test.dart` and `test/protocol/frame_test.dart` exercise the checksum algorithm and the frame builder/parser round-trip.
- ✅ **State + group + widget + screen unit tests** — 167 tests total covering `state/{weights,preferences,unit_auto_matcher,permission_request_flow}`, `devices/{dumbbell,weight_group}` (incl. `GroupSnapshot` derivations + `remove()` race guard + §2a reconnect supervisor: trigger conditions, backoff schedule via `fake_async`, `remove()`-mid-`waiting`, `remove()`-mid-`attempting`, `disconnectAll()` cancel, `kickReconnectsForResume`, in-flight protection, `setWeightIndex` skips reconnecting members), `widgets/{weight_button,dumbbell_card,failed_device_card}` (incl. `TextScaler` 1.6× large-font safety + the optional `onRemove` affordance + the mid-session-drop "Disconnected" state + the §2a "Reconnecting…" state via `retryState` prop), `screens/{home,permission,settings,about}_screen` (warm-start seeding, promote-on-tap, retry, ×-remove, auto-match-from-dock, unit-toggle live re-label, consensus / motor-active, persisted-set, BT-adapter-off banner, permission-revoked-on-resume re-route, scan-empty hint + Scan again, §2a mid-session drop renders "Reconnecting…" + resume kick fires reconnect + revoked-permissions resume blocks reconnect). Includes the `0xD1` byte-8 parse. All tests above `lib/ble/` consume the port types — none import `package:flutter_blue_plus/`. `flutter analyze` clean.
- ✅ **Multi-device fan-out (architectural)** — `WeightGroup.setWeightIndex` fan-out covered by unit tests against a fake-Dumbbell.

### Pending — needs on-device verification (Android + iOS)

The unit + widget test suites cover the pure-Dart and Flutter-widget layers, but they cannot exercise the BLE platform channels, the OS permission prompt UX, or actual motor motion. These need a **real device** for both platforms:

#### Android (primary dev platform)

- Permission rationale → Continue → OS prompt fires → grant → lands on the Home screen.
- Permission rationale → Continue → OS prompt → deny → lands on the denied-state UI with `Open Settings` and `Try again`.
- `Try again` reverts to the rationale and re-requests on Continue.
- Revoke Bluetooth permission via Settings.app, relaunch app: rationale shows again (because `Permission.bluetoothScan.isGranted` is now false). Verifies the routing-on-status logic.
- Cold launch with no remembered devices: top region shows "Tap a dumbbell below to connect"; bottom region scans and lists at least one `DB200` dumbbell when in range.
- Tap a scan card → it moves to the top region in `connecting` state and the connect kicks off immediately (promote-on-tap).
- Tap × on a top card: dumbbell disconnects, slot drops, scanner keeps running. If you do it while still `connecting`, the racing connect doesn't resurrect the slot.
- Tap weight buttons → physically moves the dumbbell(s) to that setting. Extremes "8 lbs" / "50 lbs" both work.
- Switching to kg in Settings re-labels every weight tile live **without** a navigation round-trip (validates the reactive `Preferences.unit` listener).
- About screen renders: logo at the top (cream-background app icon, rounded, crisp on a high-DPR device — the `cacheWidth` / `cacheHeight` plumbing should decode at display size), app name + tagline, "What it is", a tappable GitHub row, a "Created by Rodrigo Pimentel <rbp@isnomore.net>" line where **only the email span is tappable** (icon + surrounding text inert), and the Credits / Protocol / License / Disclaimer sections readable without scrolling jankiness. Tap GitHub → browser opens to the repo; tap email → mail composer pre-filled to `rbp@isnomore.net`.
- **Warm-start**: after a verified connect, kill the app and relaunch. The Home screen seeds the top region with the previously-connected dumbbells in `connecting` state on the first frame; the scanner also starts immediately. No flash of an empty top region.
- On the warm-start path, if a remembered dumbbell is out of range / offline, the `FailedDeviceCard` appears with a refresh icon for retry and an × for dismissal.
- Battery percentage on each card matches what nRF Connect shows for the same device.
- **Auto-match dock unit (no prior Settings choice)**: with both docks on kg via the physical gesture, connect → "Unit set to kg to match your dumbbells." SnackBar, weight buttons re-label to `3.6 kg` … `22.7 kg`. Disconnect, flip one dock to lbs, reconnect → "Dumbbells are set to different units — pick one in Settings" SnackBar; app display unit unchanged.
- **Auto-match no-op after explicit pick**: open Settings, tap the lbs/kg toggle (either side counts as explicit). Reconnect with any unit combination → no SnackBar, no preference change.
- **Auto-match across post-connect race**: the post-connect battery read makes a dumbbell `isReady` before the `0xD1` reply arrives. The auto-match should *not* fire on the bare battery-ready state — it should wait for the unit byte and then fire. Easiest probe: clear app data, connect; the SnackBar should arrive within ~1.5s of "Connecting…" disappearing on the cards, not instantly.
- **Edge-case spot-checks** (§1h):
  - Bluetooth turned off mid-session (Android): the error-coloured "Bluetooth is off" banner appears at the top of the Home body, the scan area copy switches to "Turn Bluetooth on to scan.", and the banner CTA reads **"Enable Bluetooth"** — tapping it pops the OS's in-app "Allow Bluetooth?" dialog (via `BluetoothAdapter.ACTION_REQUEST_ENABLE` through `flutter_blue_plus.turnOn()`). User accepts → BT turns on → banner + copy disappear, scan resumes, supervisor's BT-on kick fast-forwards any waiting reconnects. On iOS the same banner shows but has no CTA — iOS doesn't expose a programmatic toggle; the copy instructs the user to flip BT in Settings or Control Center.
  - All dumbbells out of range: after the 30 s scan timeout the bottom region shows "No JaxJox dumbbells found. Make sure they're powered on and in range." with a tonal Scan again button. Tap → scan restarts.
  - Mid-session drop: power off a connected dumbbell — its card flips to a "Reconnecting…" chip + body line (§2a; was "Disconnected" before §2a landed). Power it back on within a couple of minutes — the card returns to "Connected" without user intervention. Tap × on the card to give up reconnecting and drop the slot.
  - Permission revocation (Android): with HomeScreen visible, background the app, revoke "Nearby devices" in Settings.app, foreground it → HomeScreen pushes back to PermissionScreen automatically.
- **§2a reconnect spot-checks:**
  - Mid-session drop on one of N: with two dumbbells connected and ready, power one off. Its card flips to "Reconnecting…" within ~2 s. The weight grid stays enabled (the other member is still ready) and any tap on the grid is fanned out only to the still-ready peer. Power the dropped dumbbell back on — within seconds its card flips back through "Connecting…" to "Connected" / "Idle". The current weight may differ from the consensus until the post-reconnect state arrives.
  - Drop on the *only* connected dumbbell: weight grid disables (no ready member). When it reconnects, grid re-enables.
  - Long drop: power a connected dumbbell off and leave it off. Card stays on "Reconnecting…" indefinitely (retry repeats at the 60 s cap once the schedule is exhausted). Tap × on the card → slot disappears, no further retries fire, and the dumbbell is removed from `rememberedDeviceIds`.
  - Resume kick: connect, power off, background the app for ≥ 60 s, power back on, foreground. The dumbbell reconnects within seconds of the resume — *not* after the next 60 s tick of the backoff. (Without the resume kick, the test would have to wait out a full retry cycle.)
  - **BT-adapter toggle**: connect, then toggle Bluetooth off in the OS quick-settings panel (the "BT is off" banner appears at the top of Home, cards flip to "Reconnecting…" as the supervisor's retries fail in succession against the off adapter). Toggle BT back on — within seconds the cards reconnect, not after a 60 s backoff wait. This is the in-foreground analogue of the resume kick.
  - **Half-responsive device**: a depleted-battery dock may briefly wake its BLE radio (the OS-level connect succeeds) but never reply to `queryStatus`. In this state the card stays on "Connecting…" with a "—" weight, the weight grid stays disabled, and tapping × is the recovery affordance — the supervisor doesn't kick in here because the dumbbell never reached `isReady` (this is initial-connect territory, not mid-session).
  - Resume with revoked permissions (Android): connect, power off so the card is "Reconnecting…", background, revoke "Nearby devices", foreground → HomeScreen routes to PermissionScreen and no reconnect attempt fires during the resume window (verifies the order in `_recheckPermissions`).

#### iOS (verification platform)

- The whole list above on a real iPhone — flutter_blue_plus and `permission_handler` behave subtly differently from Android, and BLE absolutely does not work in the iOS simulator.
- **Specifically test the permission rationale's first-launch behaviour on iOS.** `permission_handler` reports `denied` for `Permission.bluetoothScan`/`bluetoothConnect` on iOS until the OS has prompted at least once, *but* the OS prompt itself is triggered by `flutter_blue_plus`'s first BLE op (controlled by `NSBluetoothAlwaysUsageDescription` in `ios/Runner/Info.plist`), not by our `permission_handler.request()` call. If the rationale screen doesn't show on first launch, or if Continue feels like a no-op (iOS already reported "granted" so we navigate to Home, then the OS prompt fires from `HomeScreen`'s first BLE call), we'll need to revisit the routing logic — possibly bring back a "rationale shown" flag specifically for iOS. The current implementation assumes iOS reports `denied` on first launch; this is the riskiest unverified assumption in the project right now.
- The lbs/kg toggle in Settings actually re-labels the buttons live (verifies `ValueListenable` works through the iOS Flutter render path).
- §2a reconnect on iOS: the drop event timing is plugin-specific. Verify the mid-session-drop spot-check on iOS — `flutter_blue_plus` may emit `disconnected` with different latency than Android, and CoreBluetooth's "system kills the connection when the peripheral goes out of range" semantics differ from Android's. The supervisor logic doesn't care about latency (it triggers on any `disconnected` for an ever-ready member), but the user-visible "card flips to Reconnecting…" delay is worth pinning down on real hardware.
- TestFlight build is producible with the current scaffold.
