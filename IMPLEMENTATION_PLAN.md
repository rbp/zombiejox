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

### 0f. (Optional) HCI snoop for residual unknowns — ✅ closed via static analysis + on-device probe
- **kg/lbs unit toggle**: no opcode exists for the dumbbell. The decompiled `EditUnitMeasureFragment` / `UserManager.setWeightUnit` write to a SharedPreferences key only; `FitnessManager` (the BLE-write class) has zero unit references. The dock has its own hidden physical kg/lbs gesture; the app reads the current dock unit from `0xD1` byte 8 but never writes one. (The smart scale `SmartScaleManager.onSyncUnit` is a different device class.)
- **`0xD1` byte semantics**: fully recovered from `DumbBellReceivedDataCallback.h1(...)` + `DeviceStatus` field names (see `docs/ble_protocol.md` §`0xD1` byte semantics). Byte 8 (`unit`) mapping confirmed on-device via the debug-log probe wired in PR #9: **`0x00` = lbs, `0x01` = kg**. Byte 5 (`battery` per the APK name, but values don't match the user-facing %) is still unexplained, though it's not used by the app and doesn't block anything.
- **`0xD2` 24-bit fields**: per `ChangedManager.U0` log line, bytes 4–6 = time, byte 7 = flag, bytes 8–10 = count, byte 11 = weight index, bytes 12–13 = unknown. Workout-specific; not relevant for MVP.
- HCI snoop of the original app is blocked anyway — JaxJox cloud is gone, the app can't get past its login wall.

---

## Phase 1: Flutter MVP — 🟡 user flow complete; edge-case screens still pending

PRs merged against `main`:

- **PR #1** (`e091190`) — initial Flutter scaffold + protocol layer + single-device connect/control + protocol unit tests.
- **PR #2** (`0d322d2`) — multi-device foundations (state layer, `WeightGroup`, `ControlScreen` with N-device cards, extracted widgets), tests, plus multi-select on the scan screen so the user can connect to ≥ 2 dumbbells in one trip.
- **PR #3** (`43e29e9`) — pre-permission rationale screen, Settings (lbs/kg toggle), About screen, reactive `Preferences` so the toggle takes effect mid-session.
- **PR #7** (`00b349d`) — warm-start auto-reconnect to remembered dumbbells (skip the scan step when we already know what worked last time).
- **PR #8** (`d3d2a8c`) — custom zombie launcher icon + splash for both Android (legacy + adaptive) and iOS.
- **PR #10** (`a2fa089`) — `0xD1` byte-8 dock-unit parsing + auto-match the app's display unit to the connected dumbbells' on first connect.

The app's current user flow: rationale on first launch → grant → scan (skipped on warm start if remembered devices exist) → tick dumbbells → **Connect (N)** → control screen with N cards + a single weight grid + Settings/About reachable from any screen. Toggling kg/lbs in Settings re-labels everything live. On first connect, if the user hasn't picked a unit yet, the app silently matches whatever the docks are set to (or surfaces a SnackBar if they disagree).

The remaining MVP gap — **edge-case screens** (Bluetooth-off, all out of range, mid-session drops) — is tracked in §1h.

### 1a. Create the Flutter project at the repo root — ✅ done

Project created with `flutter create --org net.isnomore.zombiejox --project-name zombiejox --platforms ios,android .` Repo-root layout is in place: `pubspec.yaml`, `lib/`, `android/`, `ios/`, `test/`, `analysis_options.yaml` all alongside the existing docs/assets/reverse-engineering trees.

### 1b. Dependencies (`pubspec.yaml`) — ✅ done

Runtime:
- `flutter_blue_plus: ^2.3.1` — BLE.
- `permission_handler: ^12.0.1` — Bluetooth scan/connect permission.
- `shared_preferences: ^2.3.0` — units, remembered-device IDs, explicit-choice flag.
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

### 1d. Source layout — 🟡 only edge-case screens pending

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
    preferences.dart                ✅   units (reactive); remembered device IDs; explicit-unit-choice flag + auto-match-safe setter
    weights.dart                    ✅   index ↔ lbs ↔ kg lookup, formatWeight(), weightUnitFromRawByte() (0x00=lbs / 0x01=kg)
  screens/
    scan_screen.dart                ✅   multi-select + Connect (N) + Settings menu entry + warm-start auto-nav to ControlScreen
    control_screen.dart             ✅   N device cards + weight grid (reactive to unit) + Settings menu entry + auto-match-from-dock
    permission_screen.dart          ✅   pre-permission rationale; Continue / denied state with retry / open settings
    settings_screen.dart            ✅   lbs/kg SegmentedButton toggle + link to About
    about_screen.dart               ✅   credits + license + protocol-doc reference + disclaimer
  widgets/
    weight_button.dart              ✅
    dumbbell_card.dart              ✅
    failed_device_card.dart         ✅   shown when a device's connect throws; has a refresh icon to retry inline
test/
  protocol/                         ✅   checksum_test, frame_test (incl. 0xD1 unit-byte parse)
  state/                            ✅   weights_test (incl. weightUnitFromRawByte), preferences_test (units + remembered + explicit-choice flag)
  devices/                          ✅   weight_group_test
  widgets/                          ✅   weight_button_test, dumbbell_card_test, failed_device_card_test
  screens/                          ✅   control_screen_test (incl. auto-match), scan_screen_test (incl. warm-start auto-nav), permission_screen_test, settings_screen_test, about_screen_test
android/app/src/main/AndroidManifest.xml   ✅
ios/Runner/Info.plist                       ✅
```

Total test count: **108 tests, all passing.** `flutter analyze` clean. `dart format` clean.

### 1e. Platform setup — ✅ done

Android `<uses-permission>` entries (`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_CONNECT`) and iOS `NSBluetoothAlwaysUsageDescription` are configured per the PR. Android minSdk is 31 (Android 12); Android ≤11 isn't supported because it'd require `ACCESS_FINE_LOCATION` for BLE scanning, which would also require either dropping the privacy-friendly `neverForLocation` flag or maintaining two code paths. iOS does not request `Permission.locationWhenInUse` (which would otherwise crash without `NSLocationWhenInUseUsageDescription` in Info.plist).

### 1f. User flow — 🟡 user flow complete; edge-case screens still pending

What works:
- ✅ **First launch**: pre-permission rationale screen ("ZombieJox needs Bluetooth…") → Continue → OS prompt → scan. If the user denies, the screen flips to a "Permission was denied" state with `Open Settings` + `Try again` buttons.
- ✅ Routing on every cold start checks the actual `Permission.bluetoothScan` / `bluetoothConnect` status — granted goes straight to scan; revoked-since-last-launch (Android) re-shows the rationale automatically. No flag in Preferences.
- ✅ **Multi-select on scan**: tick the dumbbells you want, tap "Connect (N)".
- ✅ **Warm-start auto-reconnect**: on cold start, if `Preferences.rememberedDeviceIds` is non-empty, ScanScreen navigates straight to ControlScreen and kicks off connects in parallel. The remembered set is saved each time at least one member of the most-recent Connect (N) verifies a successful connect, so a failed attempt doesn't poison the warm-start fast path. Disconnect-all returns to ScanScreen without re-auto-navigating until the next cold start.
- ✅ **Control screen with N device cards**: one card per connected dumbbell, single weight grid below; one tap fans `0xD6` to all of them.
- ✅ **Settings**: lbs/kg toggle (reactive — flipping it re-labels everything live across visible screens), link to About. Reachable from a gear icon on both scan and control screens.
- ✅ **Auto-match dock unit**: on first connect, if the user hasn't explicitly picked a unit, the app reads `0xD1` byte 8 from each ready dumbbell (`0x00`=lbs, `0x01`=kg). All agree → silently match (SnackBar if it actually changed). Disagree → SnackBar pointing the user to Settings. Once they tap Settings, the auto-match is a no-op forever — their choice wins.
- ✅ **About**: credits to Eamon Tuhami / X8IQ, original JaxJox engineering team, link to `docs/ble_protocol.md`, license, disclaimer.
- ✅ Manual weight changes (via dock buttons) reflected in the UI via `0xD2` byte 11.
- ✅ **Custom logo wired into icon and splash** — pixel-art zombie + dumbbell on cream `#F4ECD4`, adaptive on Android (cream background + transparent foreground PNG with launcher-applied 16% safe-zone inset), full-bleed cream on iOS. Splash matches.

What's still needed to hit the MVP target:
- ⏳ **Edge-case screens**: Bluetooth-off, all devices out of range, mid-session drops — currently undefined behaviour.

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

### 1h. Remaining work to close out Phase 1

✅ Done: `shared_preferences`; `state/weights.dart` (incl. `weightUnitFromRawByte`); reactive `state/preferences.dart` (units + remembered device IDs + explicit-choice flag); `devices/weight_group.dart`; `widgets/{weight_button,dumbbell_card,failed_device_card}.dart`; `screens/{control,scan,permission,settings,about}_screen.dart`; multi-select on the scan screen; Settings/About reachable via gear icon; warm-start auto-reconnect to remembered dumbbells; auto-match-from-dock on first connect; `0xD1` byte-8 unit parsing with on-device-confirmed mapping; custom launcher icon + splash.

Still pending:

1. **Edge-case screens** — Bluetooth disabled, permission denied (mid-session revoke), all devices out of range. Currently undefined behaviour.

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

### 2c. About screen improvements

- It should have the logo at the top. Either the app name and below it, the logo; or the other way round.
- Below "what it is", a link back to the app's Github page
- Then, "Rodrigo Pimentel <rbp@isnomore.net> started this project"
- Then, the rest of the README contents, which is what the About screen currently shows.

### 2d. Design - v1

Now it's time to make the app look good.

#### Principles

It should feel modern and smooth. Not too minimalist that it feels cold, but definitely not frilly. It should definitely feel designed, not something that a backend developer would make (i.e., not simple text elements on a white background).

Each dumbbell card should look like a button that's either selected or not (instead of looking like an unstyled html checkbox). The weight buttons should all have the same dimensions, and should be rectangular with slightly rouded corners.

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

### 2e. ~~kg/lbs unit toggle on the dock~~ — confirmed impossible
- No app-to-dock unit-write opcode exists (see §1i). The user changes the dock's display unit via its own hidden physical gesture; the app reads the result via `0xD1` byte 8 and auto-matches its own display unit (already done in PR #10).

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

**Phase 0 is complete; Phase 1 is one screen away.** End-to-end: set + read weight on N dumbbells, multi-select scan, warm-start auto-reconnect, Settings/About with reactive unit toggle, auto-match-from-dock, custom icon + splash. Only edge-case screens (BT off, all out of range, mid-session drops) remain.

1. ✅ Phase 0 reverse-engineering (0a–0e done; 0f closed via static analysis — no HCI snoop needed)
2. 🟡 Phase 1 — Flutter MVP — six PRs merged (#1, #2, #3, #7, #8, #10); only edge-case screens (§1h) outstanding.
3. ⏳ Phase 2 — UX and UI improvements; make the app a joy to use.
4. ⏳ Phase 3 — Polish, error handling, edge-case hardening
5. ⏳ Phase 3 — Testing & distribution

---

## Verification

### Done

- ✅ **Protocol correctness** — `0xD6 <idx>` sent from nRF Connect physically moves the dumbbell across all 8 indices on `DB200-0161997`.
- ✅ **Protocol unit tests** — `test/protocol/checksum_test.dart` and `test/protocol/frame_test.dart` exercise the checksum algorithm and the frame builder/parser round-trip.
- ✅ **State + group + widget + screen unit tests** — 108 tests total covering `state/{weights,preferences}`, `devices/weight_group`, `widgets/{weight_button,dumbbell_card,failed_device_card}`, `screens/{control,scan,permission,settings,about}_screen`. Includes the auto-match-from-dock debounce + decision logic and the `0xD1` byte-8 parse. `flutter analyze` clean.
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
- **Auto-match dock unit (no prior Settings choice)**: with both docks on kg via the physical gesture, connect → "Unit set to kg to match your dumbbells." SnackBar, weight buttons re-label to `3.6 kg` … `22.7 kg`. Disconnect, flip one dock to lbs, reconnect → "Dumbbells are set to different units — pick one in Settings" SnackBar; app display unit unchanged.
- **Auto-match no-op after explicit pick**: open Settings, tap the lbs/kg toggle (either side counts as explicit). Reconnect with any unit combination → no SnackBar, no preference change.
- **Auto-match across post-connect race**: the post-connect battery read makes a dumbbell `isReady` before the `0xD1` reply arrives. The auto-match should *not* fire on the bare battery-ready state — it should wait for the unit byte and then fire. Easiest probe: clear app data, connect; the SnackBar should arrive within ~1.5s of "Connecting…" disappearing on the cards, not instantly.
- Bluetooth turned off mid-session: cards grey out / re-enable: cards recover. (This is partially tracked under §1h "edge-case screens" but a pre-shipping spot-check is worth doing.)

#### iOS (verification platform)

- The whole list above on a real iPhone — flutter_blue_plus and `permission_handler` behave subtly differently from Android, and BLE absolutely does not work in the iOS simulator.
- **Specifically test the permission rationale's first-launch behaviour on iOS.** `permission_handler` reports `denied` for `Permission.bluetoothScan`/`bluetoothConnect` on iOS until the OS has prompted at least once, *but* the OS prompt itself is triggered by `flutter_blue_plus`'s first BLE op (controlled by `NSBluetoothAlwaysUsageDescription` in `ios/Runner/Info.plist`), not by our `permission_handler.request()` call. If the rationale screen doesn't show on first launch, or if Continue feels like a no-op (iOS already reported "granted" so we navigate to scan, then the OS prompt fires from `ScanScreen`'s first BLE call), we'll need to revisit the routing logic — possibly bring back a "rationale shown" flag specifically for iOS. The current implementation assumes iOS reports `denied` on first launch; this is the riskiest unverified assumption in the project right now.
- The lbs/kg toggle in Settings actually re-labels the buttons live (verifies `ValueListenable` works through the iOS Flutter render path).
- TestFlight build is producible with the current scaffold.
