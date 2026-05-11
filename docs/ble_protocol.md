# JaxJox BLE Protocol

Reverse-engineered from decompiled `com.jaxjox.mobile` v3.1.0 APK. All paths below are relative to `reverse-engineering/decompiled/sources/`.

> **Status**: Set-weight + status query + time-sync + username are all validated end-to-end against a real DumbbellConnect (`DB200-0161997`, hardware V1.0, firmware V1.0, software V1.1.4db). Setting a weight from the app side physically moves the dumbbell. Open items: exact meaning of `0xD1` byte 5 (Java field name `battery` but doesn't match the user-facing % — see below), the integer-value mapping for `0xD1` byte 8 (unit; `0`/`1` ↔ lbs/kg unknown, needs on-device probe), `0xD2` 24-bit fields (likely reps/volume/power, untested without a workout), history sync (opcodes `0xD3`/`0xD4`). **There is no app-to-dock kg/lbs push opcode** — the decompiled code shows the app's unit toggle is purely a display preference, not a BLE write.

---

## ⚠️  DO NOT SEND — opcode `0x27`

Sending the packet `FF 04 27 EC` (opcode `0x27`, no payload) **knocks the dumbbell offline temporarily**: the device immediately disconnects, refuses reconnection attempts, and disappears from BLE scans. It self-recovers after some delay and accepts connections normally again. The recovery delay has only been observed indirectly (the device was reachable again after ~45 minutes of inactivity); the actual lockout could be much shorter and has not been measured.

The exact effect is unknown — most likely candidates are: entering DFU/firmware-update mode (with a timeout), entering a deep-sleep state, or a soft-fault that requires watchdog recovery. The original JaxJox app contains a method `FitnessManager.k1()` that sends this packet, but the method has no callers in any app code path we can find — it's effectively dead code. **It must never be called from any client implementation.**

If a user accidentally triggers this: leave the dumbbell alone and try again after a few minutes. Don't power-cycle; recovery is automatic.

**TODO**: measure the actual recovery time experimentally so we can report it precisely.

---

## 1. UUIDs

All confirmed in `com/android/jaxjox/fitness/FitnessManager.java:143-155`.

### Custom JaxJox service
| Role | UUID | Properties |
|------|------|------------|
| Service | `AAE28F00-71B5-42A1-8C3C-F9CF6AC969D0` | — |
| TX (write, app → device) | `AAE28F02-71B5-42A1-8C3C-F9CF6AC969D0` | Write / Write No Response |
| RX (notify, device → app) | `AAE28F01-71B5-42A1-8C3C-F9CF6AC969D0` | Notify (with CCCD `0x2902`) |
| Unknown / OEM-reserved | `AAE21541-71B5-42A1-8C3C-F9CF6AC969D0` | Notify (with CCCD `0x2902`) |

The `AAE21541-…` characteristic is exposed by the firmware but **does not appear in the JaxJox app's decompiled sources or in `libfitness.so`**. It's almost certainly a Chileaf OEM-reserved characteristic (DFU/factory/diagnostics) that JaxJox never wired up. Safe to ignore for normal use.

### Standard services also used
- **Battery Service** `0000180F-…` / Battery Level `00002A19-…` (Notify + Read; reads as a single byte percentage, e.g. `0x64` = 100%).
- **Device Information Service** `0000180A-…`:
  - `0x2A29` Manufacturer Name → ASCII string `chileaf` (the dumbbells are Chileaf-OEM'd hardware; JaxJox is the brand on the box only).
  - `0x2A24` Model Number → e.g. `DB200`.
  - `0x2A27` Hardware Revision → e.g. `V1.0`.
  - `0x2A26` Firmware Revision → e.g. `V1.0`.
  - `0x2A28` Software Revision → e.g. `V1.1.4db` (the `db` suffix on this user's unit indicates the dumbbell variant).
  - `0x2A23` System ID → 8-byte vendor-specific identifier.

### Bonding behaviour

The dumbbells **reject OS-level BLE bonding** (`createBond()` returns `BOND_NONE` with reason `AUTH_REJECTED (2)`). This is by design — the device does not implement standard pairing. **GATT writes and notifications work without bonding**, so a client should connect, discover services, enable notifications, and start writing without attempting a bond.

---

## 2. Device discovery

Devices are matched by **advertised name prefix**. Source: `com/jaxjox/mobile/config/connect/DeviceManager.java:316-395`.

| Product | Prefix |
|---------|--------|
| DumbbellConnect | `DB200` |
| KettlebellConnect 2.0 | `KB200` |
| KettlebellConnect (legacy) | `KB42` |
| PushUpConnect | `PB220` |
| FoamRollerConnect | `FR100` |
| Heart-rate monitors | `JJ HRM`, `CL800`, `CL803`, `CL813`, `CL820`, `CL830`, `CL831`, `CL880` |
| Smart Scale | `JJ Scale` |

Names ending in `U` are filtered out (DFU/firmware-update mode). Scan settings (`ConnectManager.java:68-78`): mode = BALANCED, report delay = 1000 ms, legacy = false.

---

## 3. Packet format

Built in `FitnessManager.f1(byte opcode, byte... payload)` at `FitnessManager.java:536-539`:

```
┌──────┬────────┬────────┬─────────────────┬──────────┐
│ 0xFF │ length │ opcode │ payload (0..N)  │ checksum │
└──────┴────────┴────────┴─────────────────┴──────────┘
```

- `length` = `payload.length + 4` (i.e. the total transmitted byte count; covers all five sections of the frame)
- `checksum` is the algorithm in §6, computed over `[0xFF, length, opcode, ...payload]` (everything before the checksum byte).
- Multi-byte integers in the payload are **big-endian** (`HexUtil.n(long)` produces 4-byte BE).

---

## 4. Commands (app → device)

| Opcode | Hex | Name | Payload | Source |
|--------|-----|------|---------|--------|
| 0x08 | 8 | Sync timestamp | 4-byte BE epoch-millis (local-as-UTC) | `FitnessManager.java:572-574` |
| 0xC0 | -64 | Set user account | length-prefixed ASCII username (`[len, ...bytes]`) | `FitnessManager.java:432-438` |
| 0xD1 | -47 | Query status | (empty) | `FitnessManager.java:529` |
| 0xD6 | -42 | Set weight | 1 byte: weight **index** 0–7 (NOT lbs) | `device/dumbbell/DumbBellManager.java:159-161` |
| **0x27** | **39** | **⚠️ DANGEROUS — DO NOT SEND** | (empty) — see warning at top of doc | `FitnessManager.java:580-587` (`k1()`, dead code) |

Notes:
- Set-user-account (`0xC0`) requires the username to be length-prefixed in the payload — i.e. payload bytes are `[len, ...username_bytes]`. The original APK builds this via `HexUtil.a((byte) bytes.length, bytes)`.
- The kg/lbs toggle opcode was not located in static analysis — see §7.

### Set-weight specifics

```java
// DumbBellManager.I1(int weight)
f1((byte) -42, (byte) weight);
```

The original Java field name `weight` is misleading — runtime testing on `DB200-0161997` confirmed **the byte is a weight-step index, not a value in pounds**. Valid range is **0–7**, mapping to the eight DumbbellConnect settings:

| Index | Weight (lbs) | Set-weight packet |
|-------|--------------|-------------------|
| 0 | 8 | `FF 05 D6 00 1C` |
| 1 | 14 | `FF 05 D6 01 1F` |
| 2 | 20 | `FF 05 D6 02 1E` |
| 3 | 26 | `FF 05 D6 03 19` |
| 4 | 32 | `FF 05 D6 04 18` |
| 5 | 38 | `FF 05 D6 05 1B` |
| 6 | 44 | `FF 05 D6 06 1A` |
| 7 | 50 | `FF 05 D6 07 25` |

(Lbs values are JaxJox's published weight steps and match observed motion; explicit display readings still TODO.)

#### Response semantics

Immediately after writing a `0xD6` packet, the device sends back a 5-byte status frame on RX:

| Response | Meaning |
|----------|---------|
| `FF 05 D6 00 1C` | Command accepted, motor starting |
| `FF 05 D6 01 1F` | Rejected (index out of range, i.e. ≥ 8) |

The status byte is **not** an echo of the requested index — it is `0x00` (ACK) or `0x01` (NACK). This caused early confusion when we tested `0xD6 00`, since the request and the ACK frame happen to coincide byte-for-byte.

#### Physical motion side-effects (on success)

A successful set-weight produces this notification sequence on RX over ~1.5 s:

1. `FF 05 D6 00 1C` — immediate ACK
2. Two identical `FF 0A D1 00 <idx> 64 0C 64 00 <csum>` packets — motor-start broadcast (`byte 6 = 0x0C`)
3. The `0xD2` 1 Hz broadcast updates: byte 11 changes from old index to new index
4. After motion settles: one `FF 0A D1 00 <idx> 64 04 64 00 <csum>` packet — motor-settle broadcast (`byte 6 = 0x04`)

This means a client **does not need to poll** to know when motion completes — wait for the `0x04`-flavoured `0xD1` push.

---

## 5. Notifications (device → app)

Parsed in `device/dumbbell/DumbBellReceivedDataCallback.java:28-66`. The first 3 bytes are framing; offset 3 onward is payload.

| Opcode (response) | Meaning | Layout |
|-------------------|---------|--------|
| 192 (0xC0) | Reply to set-user-account | Length 19. Echoes back device serial + accepted username. |
| 209 (0xD1) | Two roles: explicit query reply, OR motor-state push | Length 10. 6 single bytes at offsets 3..8. See below. |
| 210 (0xD2) | Periodic state broadcast (~1 Hz, unsolicited) | Length 16. Fields at offsets 3 (1B), 4 (3B), 7 (1B), 8 (3B), 11 (1B), 12 (2B). **Byte 11 = current weight index (0–7).** |
| 211 (0xD3) | History chunk | Buffered; multiple may arrive. (Untested at runtime.) |
| 212 (0xD4) | History complete | Triggers parse of all buffered 211 chunks. Each entry is 12 bytes: type(1) / timestamp(4 BE) / data(3) / data(1) / data(3). Decompression via obfuscated `o1()`. (Untested at runtime.) |
| 214 (0xD6) | Set-weight result (status, not echo) | Length 5. 1-byte payload at offset 3: `0x00` = accepted, `0x01` = rejected. Not parsed by the original app's switch — the app waits for the next `0xD2` broadcast to update its UI. |

### `0xD1` byte semantics

The same opcode is used for two different things — explicit replies to `0xD1` queries, and unsolicited motor-state pushes that fire when the dumbbell physically transitions. Both are parsed by the same handler (six single bytes at offsets 3–8). Field names come from the decompiled `DumbBellReceivedDataCallback.h1(...)` callback signature and the matching `DeviceStatus` (`device/a.java`) fields the original app maps them onto.

| Byte | Field (per APK) | Notes |
|------|-----------------|-------|
| 3 | `person` | Always `0x00` so far — multi-user feature never wired up in the decompiled code path. |
| 4 | **`weight`** — current weight index 0–7 | Authoritative. Matches `0xD2` byte 11. |
| 5 | `battery` (per APK name) | But the value we've seen here (`0x43` in query reply, `0x64` in motor pushes) doesn't match the user-facing %, and may be something else entirely (firmware version? a different cell?). Treat as unknown until on-device verified. |
| 6 | **`flag`** — motion state | `0x0C` = motor active / motion starting; `0x04` = motor idle / settled. Other values seen in query response (`0x07`); we treat anything ≠ `0x0C` as idle. |
| 7 | `subBattery` (per APK name) — but it's the **user-facing battery %** | `0x64` = 100%, matches the Battery Service (`0x2A19`) value. The APK's two-battery naming might be from a different device class — for DumbbellConnect, this is the one to render. |
| 8 | **`unit`** — dock display unit | Single byte. **`0x01` = kg** (confirmed on `DB200-0161997` set to kg via the dock's hidden kg/lbs gesture). **`0x00` = lbs** (inferred — all earlier capture sessions had this dumbbell on lbs and consistently saw byte 8 = `0x00`; needs one explicit on-device verification to make ironclad). The decompiled Java forwards this byte through `ChangedManager.c` to a logger and never compares it to a constant, which is why the mapping had to be recovered on-device. |

### Observed examples

Captured from `DB200-0161997` (FW V1.0, SW V1.1.4db):

```
FF 10 D2 00 00 00 00 00 00 00 00 01 00 00 00 24   ← periodic broadcast, ~1 Hz, idle at index 1 (14 lbs)
FF 0A D1 00 01 43 07 64 00 4D                      ← reply to FF 04 D1 16 (explicit query)
FF 05 D6 00 1C                                     ← ACK to a successful set-weight (any valid index 0–7)
FF 05 D6 01 1F                                     ← NACK to an out-of-range set-weight (index ≥ 8)

After successful FF 05 D6 03 19 (move to 26 lbs):
    FF 05 D6 00 1C                                 ← ACK
    FF 0A D1 00 03 64 0C 64 00 75                  ← motor-start push (×2, identical)
    FF 0A D1 00 03 64 0C 64 00 75
    FF 10 D2 00 00 00 00 00 00 00 00 03 00 00 00 26  ← D2 broadcast updates byte 11 → 03
    FF 0A D1 00 03 64 04 64 00 6D                  ← motor-settle push (~1.5s after start)
```

Moving the weights, by index:

```
  - FF 05 D6 00 1C — index 0  (least weight: 8 lbs)
  - FF 05 D6 01 1F — index 1
  - FF 05 D6 02 1E — index 2             
  - FF 05 D6 03 19 — index 3
  - FF 05 D6 04 18 — index 4
  - FF 05 D6 05 1B — index 5
  - FF 05 D6 06 1A — index 6
  - FF 05 D6 07 25 — index 7
```

Sample response for setting an index, including invalid ones:

```
  sent FF 05 D6 02 1E    received FF 05 D6 00 1C   ← response payload = 0x00 (success)
  sent FF 05 D6 03 19    received FF 05 D6 00 1C   ← response payload = 0x00 (success)
  sent FF 05 D6 07 25    received FF 05 D6 00 1C   ← response payload = 0x00 (success)
  sent FF 05 D6 08 24    received FF 05 D6 01 1F   ← response payload = 0x01 (rejected)
  sent FF 05 D6 0A 26    received FF 05 D6 01 1F   ← response payload = 0x01 (rejected)
  sent FF 05 D6 0F 2D    received FF 05 D6 01 1F   ← response payload = 0x01 (rejected)
```

---

## 6. Checksum algorithm

`libfitness.so` is at `reverse-engineering/decompiled/resources/lib/{arm64-v8a,armeabi-v7a}/libfitness.so`. Three exported native symbols:

```
T Java_com_android_jaxjox_fitness_FitnessManager_checkSum      ← used by f1()
T Java_com_android_jaxjox_fitness_FitnessManager_fetchBeat     ← exported, never called from Java
T Java_com_android_jaxjox_fitness_FitnessManager_fetchPassCode ← exported, never called from Java
T getChecksum                                                   ← internal helper called by checkSum
```

The Java side declares one native method (`FitnessManager.java:430`):
```java
protected native byte checkSum(byte[] bArr);
```

### Algorithm (recovered from arm64 disassembly of `getChecksum` at offset 0x7f8)

```dart
int checksum(List<int> data) {
  if (data.isEmpty) return 0x3A;
  int sum = 0;
  for (final b in data) sum += b;
  return ((-sum) ^ 0x3A) & 0xFF;
}
```

Equivalently: sum all bytes mod 256, two's-complement-negate, XOR with `0x3A`. The "if empty" branch is unreachable in practice — `f1()` always builds a ≥3-byte packet before computing.

### Worked example: set weight to 20 lbs

| step | bytes | value |
|------|-------|-------|
| payload | `[0x14]` | weight = 20 |
| length byte | `payload.length + 4` | `0x05` |
| pre-checksum frame | `[0xFF, 0x05, 0xD6, 0x14]` | |
| sum mod 256 | `0xFF + 0x05 + 0xD6 + 0x14 = 0x1EE` | low byte `0xEE` |
| `(-0xEE) & 0xFF` | `0x12` | |
| `0x12 ^ 0x3A` | `0x28` | checksum |
| **final packet (write to TX char)** | **`FF 05 D6 14 28`** | |

### `fetchPassCode` and `fetchBeat` — not relevant to dumbbells

Both disassembled and confirmed unrelated to DumbbellConnect:

- **`fetchPassCode`** builds a 19-byte BLE packet (`FF 28 13 …`, opcode `0x28`) carrying the XOR-encrypted plaintext `Chileaf_201911…`. **Chileaf** is a third-party Chinese manufacturer of BLE heart-rate monitors that the JaxJox app pairs with under the `CL800` / `CL813` / `CL820` / `CL880` device-name prefixes. The password is the Chileaf HRM unlock string. Uses a different framing and a different checksum formula (`(-58 - sum) ^ 0x3A`) than the JaxJox dumbbell protocol.
- **`fetchBeat`** is a one-liner: `return (float)arg / 60.0f`. HRM-related (BPM unit conversion).

Neither is called from Java. Both are HRM-vendor-specific logic that has nothing to do with DumbbellConnect / KettlebellConnect / etc. **Confirmed: no hidden auth on the JaxJox-native devices.**

---

## 7. Known unknowns (need runtime capture)

1. **kg/lbs unit toggle** — not found via static search. May be: (a) UI-only conversion (device always reports lbs), or (b) a command op we missed. Verify with HCI snoop log while toggling units in the original app.
2. **Status response (0xD1) byte semantics** — six bytes, names obfuscated. Connect, observe values change as weight changes / battery drains / etc.
3. **Set-weight response (0xD2) field semantics** — 11 bytes split into 6 fields, all opaque.
4. **Out-of-range / invalid weight** — what does the device do if you write `0xD6 00` or `0xD6 FF`? Worth a careful experiment.

---

## 8. Connection sequence (DumbBellManager.java:44-69)

After `BluetoothGatt.discoverServices()` succeeds:

1. Register device-info notification callback.
2. Register history notification callback (enables notifications on all custom-service characteristics).
3. Send `0xD1` (query status) — also reads device-info characteristics.
4. Enable all notifications.
5. Read battery level.
6. Enable battery-level notifications.
7. On "device ready", send `0xC0 <username>` to sync user account.

There is **no observed cryptographic handshake**, but see §6 / §7 (PassCode).

---

## 9. Pairing / bonding

Standard Android BLE bonding. No custom pairing code. References: `DeviceManager.java:443-450`.

---

## 10. Recommended Flutter implementation order

1. **Connect to the dumbbells with `flutter_blue_plus`** using service UUID `AAE28F00-...`. Subscribe to RX char (`AAE28F01-...`).
2. **Send a query-status packet** (`FF 04 D1 16` — opcode `0xD1`, no payload, length=4) and verify the device replies on RX with a frame whose opcode byte is 209.
3. **Send `0xD6 <weight>` set-weight commands** (e.g. `FF 05 D6 14 28` for 20 lbs) and confirm the dumbbells physically change weight.
4. **Capture HCI snoop log** of the original app doing a kg/lbs toggle to find that opcode.

The MVP is steps 1–3. History sync, user-account sync, and kg/lbs toggle are nice-to-haves.

### Quick disassembly recipe (for future native-code questions)

Tooling already on the machine (Xcode CLT):
```
xcrun llvm-objdump -d --disassemble-symbols=<symbol> \
  reverse-engineering/decompiled/resources/lib/arm64-v8a/libfitness.so
```
Use `nm -D` on the .so first to list exports.
