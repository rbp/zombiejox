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

### 0f. (Optional) HCI snoop for residual unknowns — ⏳ deferred
- Capture only needed if we want to nail down: kg/lbs unit toggle opcode, status response (0xD1) byte semantics, set-weight ack (0xD2) byte semantics. None block MVP.
- On Android: Developer Options → "Enable Bluetooth HCI snoop log", use the original app, then `adb bugreport bugreport.zip` and open `FS/data/misc/bluetooth/logs/btsnoop_hci.log` in Wireshark with filter `btatt`.

---

## Phase 1: Flutter MVP — 🟡 scaffold merged, advanced UX pending

The Flutter scaffold landed in PR #1 (commit `e091190`, "Phase 1: scaffold Flutter app with DumbbellConnect MVP"). The protocol layer, BLE service, single-device connect/control flow, and protocol unit tests are all in. The advanced UX features from the agreed plan — multi-device support, settings/units toggle, remembered devices, custom icon wiring, permission-rationale screen — are pending and tracked in the "Remaining" subsection at the end of this phase.

The MVP target supports N connected DumbbellConnect devices, drives them all from a single weight grid, displays in lbs or kg per user preference, and remembers connected devices for fast warm-start. Detailed plan in `~/.claude/plans/wobbly-drifting-stardust.md`; summary follows.

### 1a. Create the Flutter project at the repo root — ✅ done

Project created with `flutter create --org net.isnomore.zombiejox --project-name zombiejox --platforms ios,android .` Repo-root layout is in place: `pubspec.yaml`, `lib/`, `android/`, `ios/`, `test/`, `analysis_options.yaml` all alongside the existing docs/assets/reverse-engineering trees.

### 1b. Dependencies (`pubspec.yaml`) — 🟡 partial

Installed:
- `flutter_blue_plus: ^2.3.1` ✅ (newer minor than the planned 2.2.3 — current latest at time of PR; fine)
- `permission_handler: ^12.0.1` ✅
- `cupertino_icons: ^1.0.8` (default Flutter cruft)

Not yet installed (needed for remaining UX work):
- `shared_preferences` — for units setting and remembered-device MACs
- `flutter_launcher_icons` (dev) — for wiring the custom logo into platform icon sets
- `flutter_native_splash` (dev) — for the splash screen

### 1c. Assets — icon and splash — ⏳ default Flutter icon still in place

Platform icon files exist (`android/app/src/main/res/mipmap-*/ic_launcher.png`, `ios/Runner/Assets.xcassets/AppIcon.appiconset/*`) but they're the default Flutter blue logo from `flutter create`, not our zombie. To finish:

```
rsvg-convert -w 1024 -h 1024 assets/zombiejox-logo-bg.svg -o assets/icon-1024.png
# add flutter_launcher_icons + flutter_native_splash to dev deps and configure
flutter pub run flutter_launcher_icons
flutter pub run flutter_native_splash:create
```

### 1d. Source layout — 🟡 partial (single-device pieces in; multi-device + state/ + extra screens pending)

```
lib/
  main.dart                         ✅
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
    weight_group.dart               ⏳   N-device fan-out (needed for multi-dumbbell)
  state/                            ⏳   directory not created yet
    preferences.dart                ⏳   units + remembered MACs (shared_preferences)
    weights.dart                    ⏳   Index ↔ lbs ↔ kg lookup
  screens/
    scan_screen.dart                ✅   currently a single-tap-to-connect; needs multi-select + remembered pinning
    dumbbell_screen.dart            ✅   single-device control screen (works); will be replaced/renamed by control_screen.dart
    permission_screen.dart          ⏳   pre-permission rationale (critical on iOS)
    control_screen.dart             ⏳   N device cards + single weight grid
    settings_screen.dart            ⏳   units toggle
    about_screen.dart               ⏳   credits + license + version
  widgets/                          ⏳   directory not created yet
    weight_button.dart              ⏳
    dumbbell_card.dart              ⏳
test/
  protocol/
    checksum_test.dart              ✅
    frame_test.dart                 ✅
android/app/src/main/AndroidManifest.xml   ✅   BLE perms in place
ios/Runner/Info.plist                       ✅   Bluetooth usage description in place
```

### 1e. Platform setup — ✅ done

Android `<uses-permission>` entries (`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION`) and iOS `NSBluetoothAlwaysUsageDescription` are configured per the PR.

### 1f. User flow — 🟡 partial

What works in the merged scaffold:
- ✅ Cold start: OS permission prompt (no rationale screen) → scan screen → tap device → connect → single-device control screen
- ✅ Single-device control screen with weight grid; `0xD6 <idx>` writes physically move the dumbbell

What's still needed to hit the MVP target:
- ⏳ **Pre-permission rationale screen** before invoking the OS prompt (critical on iOS where denied = unrecoverable without going to Settings.app)
- ⏳ **Multi-select on scan**: connect to N devices in one trip
- ⏳ **Warm start with remembered devices**: pinned-at-top, auto-reconnect in parallel
- ⏳ **Control screen overhaul**: N device cards + single weight grid below; tapping fans `0xD6` to all connected devices
- ⏳ **Settings screen**: lbs/kg toggle (default from locale), persisted in `shared_preferences`
- ⏳ **About screen**: credits + license + protocol-doc link
- ⏳ **Edge-case screens**: Bluetooth-off, permission-denied, mid-session drops — currently undefined behaviour
- ⏳ **Custom logo wired into icon and splash**

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

1. Add `shared_preferences` runtime dep + `flutter_launcher_icons`/`flutter_native_splash` dev deps to `pubspec.yaml`; run `flutter pub get`.
2. Wire the custom logo: generate `assets/icon-1024.png` from `zombiejox-logo-bg.svg`, run the icon and splash generators.
3. Create `lib/state/weights.dart` (index↔lbs↔kg lookup) and `lib/state/preferences.dart` (units + remembered-MAC persistence).
4. Create `lib/devices/weight_group.dart` and refactor the control screen to drive a `WeightGroup` instead of a single `Dumbbell`.
5. Create `lib/screens/permission_screen.dart` (pre-permission rationale) and route to it on cold start.
6. Refactor `scan_screen.dart` to support multi-select + remembered-device pinning + auto-reconnect on warm start.
7. Replace `dumbbell_screen.dart` with `control_screen.dart` that handles N device cards.
8. Add `lib/screens/settings_screen.dart` (units toggle) and `about_screen.dart`.
9. Extract reusable widgets: `widgets/weight_button.dart`, `widgets/dumbbell_card.dart`.
10. Add explicit edge-case screens (Bluetooth disabled, permission denied, all devices out of range).

### 1i. Out of scope for MVP (deferred)

- Per-dumbbell weight override (asymmetric warmup) — Phase 2+
- Pushing the unit toggle to the dock physically (need 0f HCI snoop to find the opcode)
- History sync (`0xD3` / `0xD4`)
- Username (`0xC0`) — has no effect on motor control
- Other JaxJox products (Kettlebell, FoamRoller, PushUp, HRMs)
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

**Phase 0 is complete; Phase 1 scaffold is merged (PR #1).** Single-device flow works; multi-device + persistence + units/about screens remain (see Phase 1.1h above).

1. ✅ Phase 0 reverse-engineering (0a–0e done; 0f deferred as nice-to-have)
2. 🟡 Phase 1 — Flutter MVP (scaffold + protocol layer + single-device control merged; remaining MVP features tracked in §1h)
3. ⏳ Phase 2 — Polish, error handling, edge-case hardening
4. ⏳ 0f (optional, low priority) — HCI snoop for kg/lbs toggle opcode and remaining `0xD2` byte semantics
5. ⏳ Phase 3 — Testing & distribution

---

## Verification

- ✅ **Protocol correctness** — `0xD6 <idx>` sent from nRF Connect physically moves the dumbbell across all 8 indices on `DB200-0161997`.
- ✅ **Protocol unit tests** — `test/protocol/checksum_test.dart` and `test/protocol/frame_test.dart` exercise the checksum algorithm and the frame builder/parser round-trip.
- 🟡 **App functionality (MVP gate)**, run from repo root:
  - 🟡 Code paths for `flutter pub get` / `flutter analyze` / `flutter test` exist in the scaffold; runtime "clean" status not re-checked since merge.
  - ⏳ Splash → permission rationale → OS prompt → scan screen (rationale screen pending)
  - 🟡 `ScanScreen` filters by name prefix `DB200`; runtime confirmation against a real device pending.
  - 🟡 `DumbbellScreen` wires weight buttons to `Dumbbell.setWeightIndex`; physical-motion confirmation against the merged build pending.
  - ⏳ Switching to kg in Settings re-labels all buttons (Settings screen pending)
  - ⏳ Killing the app and reopening reconnects automatically (remembered MAC — pending)
  - 🟡 `Dumbbell` reads battery via the Battery Service; runtime cross-check pending.
- ⏳ **Multi-device** — connect to two dumbbells, set weight, both move (pending `WeightGroup`)
- ⏳ **Cross-platform** — same flow works on iOS (BLE doesn't work in simulators; physical device required)
- ⏳ **Edge cases** — toggle Bluetooth off mid-session: cards grey out, recover on re-enable
