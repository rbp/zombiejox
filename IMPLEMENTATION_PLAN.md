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
- HCI snoop log is still on the table for the kg/lbs toggle question (see 0f).

### 0e. Document the protocol — ✅ done
- `docs/ble_protocol.md` is the live spec: UUIDs, frame format, opcodes, checksum, connection sequence, known unknowns.

### 0f. (Optional) HCI snoop for residual unknowns — ✅ mostly closed via static analysis
- **kg/lbs unit toggle**: no opcode exists for the dumbbell. The decompiled `EditUnitMeasureFragment` / `UserManager.setWeightUnit` write to a SharedPreferences key only; `FitnessManager` (the BLE-write class) has zero unit references. The dock has its own physical kg/lbs button; the app reads the current dock unit from `0xD1` byte 8 but never writes one. (The smart scale `SmartScaleManager.onSyncUnit` is a different device class.)
- **`0xD1` byte semantics**: fully recovered from `DumbBellReceivedDataCallback.h1(...)` + `DeviceStatus` field names (see `docs/ble_protocol.md` §`0xD1` byte semantics). Two bytes still need on-device confirmation: the `0/1` ↔ kg/lbs mapping for the unit byte at offset 8 (probe wired in `Dumbbell._onBytes` — see logging), and what byte 5 (`battery` per the APK, but values don't match the user-facing %) actually represents.
- **`0xD2` 24-bit fields**: per `ChangedManager.U0` log line, bytes 4–6 = time, byte 7 = flag, bytes 8–10 = count, byte 11 = weight index, bytes 12–13 = unknown. Workout-specific; not relevant for MVP.
- HCI snoop of the original app is blocked anyway — JaxJox cloud is gone, the app can't get past its login wall.

---

## Phase 1: Flutter MVP — 🟡 most of the user flow done; persistence/icon/edge-cases pending

Three PRs have landed against `main`:

- **PR #1** (`e091190`) — initial Flutter scaffold + protocol layer + single-device connect/control + protocol unit tests.
- **PR #2** (`0d322d2`) — multi-device foundations (state layer, `WeightGroup`, `ControlScreen` with N-device cards, extracted widgets), tests, plus multi-select on the scan screen so the user can connect to ≥ 2 dumbbells in one trip.
- **`phase1/permissions-and-settings` branch** — pre-permission rationale screen, Settings (lbs/kg toggle), About screen, reactive `Preferences` so the toggle takes effect mid-session.

After this branch merges, the app's user flow is: pre-permission rationale on first launch → grant → scan → tick dumbbells → "Connect (N)" → control screen with N cards + single weight grid + Settings/About reachable from any screen. Toggling kg/lbs in Settings re-labels everything live.

The remaining MVP gaps — remembered devices fast path, custom app icon, edge-case screens — are tracked in §1h.

### 1a. Create the Flutter project at the repo root — ✅ done

Project created with `flutter create --org net.isnomore.zombiejox --project-name zombiejox --platforms ios,android .` Repo-root layout is in place: `pubspec.yaml`, `lib/`, `android/`, `ios/`, `test/`, `analysis_options.yaml` all alongside the existing docs/assets/reverse-engineering trees.

### 1b. Dependencies (`pubspec.yaml`) — 🟡 partial

Installed:
- `flutter_blue_plus: ^2.3.1` ✅
- `permission_handler: ^12.0.1` ✅
- `shared_preferences: ^2.3.0` ✅ (units default + remembered-MAC plumbing)
- `cupertino_icons: ^1.0.8` (default Flutter cruft)

Dev dependencies wired in:
- `flutter_launcher_icons: ^0.14.1` ✅ — generates platform launcher icons from `assets/icon-1024.png` (legacy / iOS) and `assets/icon-foreground-1024.png` (Android adaptive foreground). Cream `#F4ECD4` adaptive-icon background defined in the same `pubspec.yaml` block.
- `flutter_native_splash: ^2.4.3` ✅ — generates the splash for Android (pre-12 + Android 12+) and iOS, using the same icons + background colour.

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

### 1d. Source layout — 🟡 partial (settings/about/permission screens done; remembered-devices/edge-cases pending)

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
    ble_service.dart                ✅
  devices/
    dumbbell.dart                   ✅
    weight_group.dart               ✅   N-device fan-out
  state/
    preferences.dart                ✅   units (reactive ValueListenable); remembered device IDs
    weights.dart                    ✅   index ↔ lbs ↔ kg lookup, formatWeight() helper
  screens/
    scan_screen.dart                ✅   multi-select + Connect (N) + Settings menu entry
    control_screen.dart             ✅   N device cards + weight grid (reactive to unit) + Settings menu entry
    permission_screen.dart          ✅   pre-permission rationale; Continue / denied state with retry / open settings
    settings_screen.dart            ✅   lbs/kg SegmentedButton toggle + link to About
    about_screen.dart               ✅   credits + license + protocol-doc reference + disclaimer
  widgets/
    weight_button.dart              ✅
    dumbbell_card.dart              ✅
    failed_device_card.dart         ✅   shown when a device's connect throws; has a refresh icon to retry inline
test/
  protocol/                         ✅   checksum_test, frame_test
  state/                            ✅   weights_test, preferences_test (incl. reactive listener)
  devices/                          ✅   weight_group_test
  widgets/                          ✅   weight_button_test, dumbbell_card_test
  screens/                          ✅   control_screen_test, scan_screen_test, permission_screen_test, settings_screen_test, about_screen_test
android/app/src/main/AndroidManifest.xml   ✅
ios/Runner/Info.plist                       ✅
```

Total test count: **83 tests, all passing.** `flutter analyze` clean. `dart format` clean.

### 1e. Platform setup — ✅ done

Android `<uses-permission>` entries (`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_CONNECT`) and iOS `NSBluetoothAlwaysUsageDescription` are configured per the PR. Android minSdk is 31 (Android 12); Android ≤11 isn't supported because it'd require `ACCESS_FINE_LOCATION` for BLE scanning, which would also require either dropping the privacy-friendly `neverForLocation` flag or maintaining two code paths. iOS does not request `Permission.locationWhenInUse` (which would otherwise crash without `NSLocationWhenInUseUsageDescription` in Info.plist).

### 1f. User flow — 🟡 most of it works; persistence + edge cases pending

What works:
- ✅ **First launch**: pre-permission rationale screen ("ZombieJox needs Bluetooth…") → Continue → OS prompt → scan. If the user denies, the screen flips to a "Permission was denied" state with `Open Settings` + `Try again` buttons.
- ✅ Routing on every cold start checks the actual `Permission.bluetoothScan` / `bluetoothConnect` status — granted goes straight to scan; revoked-since-last-launch (Android) re-shows the rationale automatically. No flag in Preferences.
- ✅ **Multi-select on scan**: tick the dumbbells you want, tap "Connect (N)".
- ✅ **Control screen with N device cards**: one card per connected dumbbell, single weight grid below; one tap fans `0xD6` to all of them.
- ✅ **Settings**: lbs/kg toggle (reactive — flipping it re-labels everything live across visible screens), link to About. Reachable from a gear icon on both scan and control screens.
- ✅ **About**: credits to Eamon Tuhami / X8IQ, original JaxJox engineering team, link to `docs/ble_protocol.md`, license, disclaimer.
- ✅ Manual weight changes (via dock buttons) reflected in the UI via `0xD2` byte 11.

What's still needed to hit the MVP target:
- ✅ **Warm start with remembered devices**: on cold start, if `Preferences.rememberedDeviceIds` is non-empty, ScanScreen navigates straight to ControlScreen and kicks off connects in parallel. The remembered set is saved each time the user taps Connect (N). Disconnect-all returns to ScanScreen without re-auto-navigating until the next cold start.
- ⏳ **Edge-case screens**: Bluetooth-off, all devices out of range, mid-session drops — currently undefined behaviour.
- ✅ **Custom logo wired into icon and splash** — pixel-art zombie + dumbbell on cream `#F4ECD4`, adaptive on Android (cream background + transparent foreground PNG with launcher-applied 16% safe-zone inset), full-bleed cream on iOS. Splash matches.

### 1g. Index ↔ weight lookup

| Idx | lbs  | kg   |
|-----|------|------|
| 0   |  8   |  3.6 |
| 1   | 14   |  6.4 |
| 2   | 20   |  9.1 |
| 3   | 26   | 11.8 |
| 4   | 32   | 14.5 |
| 5   | 38   | 17.2 |
| 6   | 44   | 19.9 |
| 7   | 50   | 22.7 |

(kg values are exact lb→kg conversion to 1 decimal place. Verify on a real kg-mode dumbbell once shippable.)

### 1h. Remaining work to close out Phase 1 (in priority order)

✅ Done across the multi-device-control, permissions-and-settings, and remembered-devices branches: `shared_preferences`; `state/weights.dart`; reactive `state/preferences.dart` (units + remembered device IDs); `devices/weight_group.dart`; `widgets/{weight_button,dumbbell_card,failed_device_card}.dart`; `screens/{control,scan,permission,settings,about}_screen.dart`; multi-select on the scan screen; settings/about reachable via gear icon; warm-start auto-reconnect to remembered dumbbells.

Still pending:

1. **Edge-case screens** — Bluetooth disabled, permission denied (mid-session revoke), all devices out of range. Currently undefined behaviour.

### 1i. Out of scope for MVP (deferred)

- Per-dumbbell weight override (asymmetric warmup) — Phase 2+
- Pushing the unit toggle to the dock physically (need 0f HCI snoop to find the opcode)
- History sync (`0xD3` / `0xD4`)
- Username (`0xC0`) — has no effect on motor control. Will not be implemented at all, unless we discover that there is a functional need.
- Other JaxJox products (Kettlebell, FoamRoller, PushUp, HRMs)

### Not to be implemented at any point

- Workout / exercise / social features (the original app's cloud "platform" — gone with JaxJox)

---

## Phase 2: Polish & hardening — ⏳ pending

Phase 2 fleshes out the MVP scaffold with proper error handling, edge-case hardening, and visual polish. Not a separate implementation pass — incremental work on top of Phase 1.

### 2a. State-stream robustness
- Reconnect-on-resume after app backgrounded
- Graceful handling when one of N connected devices drops mid-session
- Confirmed: dumbbells **reject OS-level bonding** — never call `createBond()` (see `docs/ble_protocol.md` §1)

### 2b. UX polish
- Smooth motion-state animations on weight buttons
- Better empty / loading / error states
- Per-device weight override (asymmetric setting), gated behind a Settings toggle

### 2c. Optional: kg/lbs unit toggle on the dock
- Requires HCI snoop (Phase 0f) to discover the opcode
- Once known, the units toggle in Settings also writes to the dock so its physical display matches

---

## Phase 3: Testing & distribution — ⏳ pending

### 3a. Real device testing
- Test on both Android and iOS physical devices
- Test connection reliability, reconnect-on-resume, weight change responsiveness
- Test with N dumbbells simultaneously (start with the user's pair)

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

---

## Recommended Order of Work

**Phase 0 is complete; Phase 1 is most of the way through.** Set + read weight on N dumbbells works end-to-end; pre-permission rationale, Settings (lbs/kg toggle), and About are landing in `phase1/permissions-and-settings`. Custom icon, remembered devices, and edge-case screens remain (see §1h above).

1. ✅ Phase 0 reverse-engineering (0a–0e done; 0f deferred as nice-to-have)
2. 🟡 Phase 1 — Flutter MVP (scaffold + protocol + single-device control merged in PR #1; multi-device control + tests merged in `phase1/multi-device-control`; settings/about/icon/persistence/permission-rationale remaining per §1h)
3. ⏳ Phase 2 — UX and UI improvements; make the app a joy to use.
4. ⏳ Phase 3 — Polish, error handling, edge-case hardening
5. ⏳ Phase 0/0f — HCI snoop for kg/lbs toggle opcode and remaining `0xD2` byte semantics
6. ⏳ Phase 3 — Testing & distribution

---

## Verification

### Done

- ✅ **Protocol correctness** — `0xD6 <idx>` sent from nRF Connect physically moves the dumbbell across all 8 indices on `DB200-0161997`.
- ✅ **Protocol unit tests** — `test/protocol/checksum_test.dart` and `test/protocol/frame_test.dart` exercise the checksum algorithm and the frame builder/parser round-trip.
- ✅ **State + group + widget + screen unit tests** — 78 tests total covering `state/{weights,preferences}`, `devices/weight_group`, `widgets/{weight_button,dumbbell_card,failed_device_card}`, `screens/{control,scan,permission,settings,about}_screen`. `flutter analyze` clean.
- ✅ **Multi-device fan-out (architectural)** — `WeightGroup.setWeightIndex` fan-out covered by unit tests against a fake-Dumbbell.

### Pending — needs on-device verification (Android + iOS)

The unit + widget test suites cover the pure-Dart and Flutter-widget layers, but they cannot exercise the BLE platform channels, the OS permission prompt UX, or actual motor motion. These need a **real device** for both platforms:

#### Android (primary dev platform)

- Permission rationale → Continue → OS prompt fires → grant → lands on scan screen.
- Permission rationale → Continue → OS prompt → deny → lands on the denied-state UI with `Open Settings` and `Try again`.
- `Try again` reverts to the rationale and re-requests on Continue.
- Revoke Bluetooth permission via Settings.app, relaunch app: rationale shows again (because `Permission.bluetoothScan.isGranted` is now false). Verifies the routing-on-status logic.
- Scan finds at least one `DB200` dumbbell when in range.
- Multi-select two devices → Connect (2) → both connect → control screen shows two cards.
- Tapping any weight button physically moves the dumbbell(s) to that setting.
- Tapping "8 lbs" / "50 lbs" hits the extremes correctly.
- Switching to kg in Settings re-labels every button across both visible screens **without** a navigation round-trip (validates the reactive `Preferences.unit` listener).
- About screen renders with credits, license, disclaimer, and the `docs/ble_protocol.md` reference visible without scrolling jankiness.
- Killing and reopening the app: scan finds the same device and a fresh connect-then-set-weight round-trip works.
- **Warm-start auto-reconnect**: after a successful Connect (N), kill the app and relaunch. The scan screen should not be visible — the app should land directly on the control screen, with the previously-connected dumbbell(s) reconnecting in parallel.
- On the warm-start path, if a remembered dumbbell is out of range / offline, the FailedDeviceCard should appear with a retry button (validates the same fallback as the cold-start connect-failure flow).
- Disconnect-all from the control screen → lands on the scan screen → kill and relaunch → app auto-navigates to control screen again (Disconnect-all does NOT forget remembered devices, only the next Connect (N) does).
- Battery percentage on each card matches what nRF Connect shows for the same device.
- Bluetooth turned off mid-session: cards grey out / re-enable: cards recover. (This is partially tracked under §1h "edge-case screens" but a pre-shipping spot-check is worth doing.)

#### iOS (verification platform)

- The whole list above on a real iPhone — flutter_blue_plus and `permission_handler` behave subtly differently from Android, and BLE absolutely does not work in the iOS simulator.
- **Specifically test the permission rationale's first-launch behaviour on iOS.** `permission_handler` reports `denied` for `Permission.bluetoothScan`/`bluetoothConnect` on iOS until the OS has prompted at least once, *but* the OS prompt itself is triggered by `flutter_blue_plus`'s first BLE op (controlled by `NSBluetoothAlwaysUsageDescription` in `ios/Runner/Info.plist`), not by our `permission_handler.request()` call. If the rationale screen doesn't show on first launch, or if Continue feels like a no-op (iOS already reported "granted" so we navigate to scan, then the OS prompt fires from `ScanScreen`'s first BLE call), we'll need to revisit the routing logic — possibly bring back a "rationale shown" flag specifically for iOS. The current implementation assumes iOS reports `denied` on first launch; this is the riskiest unverified assumption in the project right now.
- The lbs/kg toggle in Settings actually re-labels the buttons live (verifies `ValueListenable` works through the iOS Flutter render path).
- TestFlight build is producible with the current scaffold.
