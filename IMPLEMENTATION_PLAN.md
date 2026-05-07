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

## Phase 1: Flutter MVP — ⏳ in progress

The MVP supports N connected DumbbellConnect devices, drives them all from a single weight grid, displays in lbs or kg per user preference, and remembers connected devices for fast warm-start. Detailed plan in `~/.claude/plans/wobbly-drifting-stardust.md`; summary follows.

### 1a. Create the Flutter project at the repo root

```
cd /Users/rbp/projects/zombiejox
flutter create --org net.isnomore.zombiejox --project-name zombiejox --platforms ios,android .
```

The trailing `.` adds Flutter scaffold (`pubspec.yaml`, `lib/`, `android/`, `ios/`, `test/`) directly to the repo root, alongside existing `README.md`, `docs/`, `assets/`, `reverse-engineering/`. `--platforms ios,android` keeps Flutter from generating `linux/` / `macos/` / `windows/` / `web/`.

### 1b. Dependencies (`pubspec.yaml`)

Runtime:
- `flutter_blue_plus: ^2.2.3` — current latest. **2.x line** (1.x docs floating around the web have a different API).
- `permission_handler: ^12.0.1` — Android 12+ runtime perms for `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT`.
- `shared_preferences: ^2.x` — units setting and remembered-device MACs.

Dev:
- `flutter_launcher_icons: ^0.14.x` — generates platform icon sets from a single PNG.
- `flutter_native_splash: ^2.x` — generates platform splash screens from a single PNG.

No state-management library yet — `StreamBuilder` over `flutter_blue_plus` streams + thin `Dumbbell` / `WeightGroup` classes are enough for MVP.

### 1c. Assets — icon and splash from existing SVG

```
rsvg-convert -w 1024 -h 1024 assets/zombiejox-logo-bg.svg -o assets/icon-1024.png
flutter pub run flutter_launcher_icons
flutter pub run flutter_native_splash:create
```

Use the cream-background variant (`zombiejox-logo-bg.svg`) since iOS rejects transparent icons.

### 1d. Source layout (paths relative to repo root)

```
lib/
  main.dart                         # MaterialApp, root navigator
  protocol/
    checksum.dart                   # Port from docs/ble_protocol.md §6
    frame.dart                      # buildFrame / parseFrame
    opcodes.dart                    # 0x08, 0xC0, 0xD1, 0xD2, 0xD6, …
    dumbbell_state.dart             # Parsed state from D2/D1 broadcasts
  ble/
    uuids.dart                      # Service / RX / TX UUIDs
    ble_service.dart                # FlutterBluePlus wrapper
  devices/
    dumbbell.dart                   # Single connection: connect, init, setWeightIndex, state stream
    weight_group.dart               # Collection of N dumbbells; fans set-weight to all members
  state/
    preferences.dart                # Units + remembered MACs (shared_preferences)
    weights.dart                    # Index ↔ lbs ↔ kg lookup
  screens/
    permission_screen.dart          # Pre-permission rationale + flow
    scan_screen.dart                # Discovery, remembered-device fast path
    control_screen.dart             # N device cards + single weight grid
    settings_screen.dart            # Units toggle
    about_screen.dart               # Credits + license + version
  widgets/
    weight_button.dart              # Selectable button with motion-pending state
    dumbbell_card.dart              # Per-device status card
test/                               # Unit tests for protocol/ + state/
android/app/src/main/AndroidManifest.xml
ios/Runner/Info.plist
```

The `protocol/` and `state/` layers are pure Dart — no Flutter or BLE imports, fully unit-testable.

### 1e. Platform setup

- **Android** (`android/app/src/main/AndroidManifest.xml`): `<uses-permission>` entries for `BLUETOOTH_SCAN` (with `usesPermissionFlags="neverForLocation"`), `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION` (Android 11 and below). `minSdkVersion` = 21+.
- **iOS** (`ios/Runner/Info.plist`): `NSBluetoothAlwaysUsageDescription` = `"ZombieJox uses Bluetooth to talk to your JaxJox dumbbells."`

### 1f. User flow (the "done" definition)

**Cold start:** splash → permission rationale → OS prompt → scan screen. Scan filters advertised names by prefix `DB200`. Tap device(s) to connect. Multi-select supported.

**Warm start:** splash → scan screen with remembered devices pinned at top + auto-reconnect kicked off in parallel. As soon as ≥ 1 connection lands, jump to control screen.

**Control screen:**
- One **dumbbell card** per connected device (name, connection dot, battery %, current weight, motor state).
- Layout scales: 1 device = single card; 2 = stacked / side-by-side; 3+ = vertical list.
- **Single 2×4 weight grid** below all cards: tapping a button fans `0xD6 <idx>` to every connected device in parallel.
- Tapped button shows "moving" state until `0xD1` motor-settle push (`byte 6 = 0x04`) arrives.
- Three-dot menu: Settings / About / Disconnect all.
- Manual weight changes (via the dumbbell's own buttons) reflect via `0xD2` byte 11 — no fight between user and dumbbell.

**Settings:** lbs / kg toggle (default from device locale), persisted via `shared_preferences`. Changes button labels only — same `0xD6 <idx>` is sent regardless. Note: doesn't change the dumbbell's physical display unit (we don't have that opcode yet — see 0f).

**Edge cases (must all be handled cleanly):** Bluetooth-off, permission-denied, out-of-range, mid-session connection drops. No infinite spinners.

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

### 1h. Out of scope for MVP (deferred)

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

**Phase 0 is complete.** Set-weight works end-to-end against a real dumbbell. Starting Phase 1.

1. ✅ Phase 0 reverse-engineering (0a–0e done; 0f deferred as nice-to-have)
2. ⏳ Phase 1 — Flutter MVP scaffold (current)
3. ⏳ Phase 2 — Polish, error handling, edge-case hardening
4. ⏳ 0f (optional, low priority) — HCI snoop for kg/lbs toggle opcode and remaining `0xD2` byte semantics
5. ⏳ Phase 3 — Testing & distribution

---

## Verification

- ✅ **Protocol correctness** — `0xD6 <idx>` sent from nRF Connect physically moves the dumbbell across all 8 indices on `DB200-0161997`.
- ⏳ **App functionality (MVP gate)**, run from repo root:
  - `flutter pub get` / `flutter analyze` / `flutter test` clean
  - Splash → permission rationale → OS prompt → scan screen
  - Scan finds the dumbbell when in range
  - Tapping any weight button physically moves the dumbbell to that setting
  - "8 lbs" → lowest setting; "50 lbs" → highest
  - Switching to kg in Settings re-labels all buttons; same action still works
  - Killing the app and reopening reconnects automatically (remembered MAC)
  - Battery percentage matches Battery Service value
- ⏳ **Multi-device** — connect to two dumbbells, set weight, both move
- ⏳ **Cross-platform** — same flow works on iOS (BLE doesn't work in simulators; physical device required)
- ⏳ **Edge cases** — toggle Bluetooth off mid-session: cards grey out, recover on re-enable
