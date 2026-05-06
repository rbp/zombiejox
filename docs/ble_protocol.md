# JaxJox BLE Protocol

Reverse-engineered from decompiled `com.jaxjox.mobile` v3.1.0 APK. All paths below are relative to `reverse-engineering/decompiled/sources/`.

> **Status**: derived from static analysis only. A few items (checksum algorithm, exact meaning of status response bytes, kg/lbs toggle command) require runtime verification before the replacement client will work.

---

## 1. UUIDs

All confirmed in `com/android/jaxjox/fitness/FitnessManager.java:143-155`.

### Custom JaxJox service
| Role | UUID |
|------|------|
| Service | `AAE28F00-71B5-42A1-8C3C-F9CF6AC969D0` |
| RX (notify, device → app) | `AAE28F01-71B5-42A1-8C3C-F9CF6AC969D0` |
| TX (write, app → device) | `AAE28F02-71B5-42A1-8C3C-F9CF6AC969D0` |

### Standard services also used
- Battery Service `0000180F-...` / Battery Level `00002A19-...`
- Device Information Service `0000180A-...` with Serial / Model / Firmware / Hardware / Software / Manufacturer characteristics

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
| 0x08 | 8 | Sync timestamp | 4-byte BE epoch-millis | `FitnessManager.java:572-574` |
| 0xC0 | -64 | Set user account | ASCII username | `FitnessManager.java:432-438` |
| 0xD1 | -47 | Query status | (empty) | `FitnessManager.java:529` |
| 0xD6 | -42 | Set weight | 1 byte (lbs, 8–50 for DumbbellConnect) | `device/dumbbell/DumbBellManager.java:159-161` |
| 0xFF | -1  | Query device info | hard-coded `[-1, 4, 39, csum]` | `FitnessManager.java:580-587` |

The kg/lbs toggle opcode was not located in static analysis — see §7.

### Set-weight specifics

```java
// DumbBellManager.I1(int weight)
f1((byte) -42, (byte) weight);
```

Weight is encoded as a single unsigned byte in the device's display unit (lbs). Range based on product specs: 8–50 lbs. The device fires response opcode `0xD2` (210) once weight is reached.

---

## 5. Notifications (device → app)

Parsed in `device/dumbbell/DumbBellReceivedDataCallback.java:28-66`. The first 3 bytes are framing; offset 3 onward is payload.

| Opcode (response) | Meaning | Layout |
|-------------------|---------|--------|
| 209 (0xD1) | Status update | 6 single bytes at offsets 3..8. Individual byte semantics (current weight, unit, battery, motor state…) unknown; verify by experiment. |
| 210 (0xD2) | Set-weight ack | bytes at offsets 3 (1B), 4 (3B), 7 (1B), 8 (3B), 11 (1B), 12 (2B). |
| 211 (0xD3) | History chunk | Buffered; multiple may arrive. |
| 212 (0xD4) | History complete | Triggers parse of all buffered 211 chunks. Each entry is 12 bytes: type(1) / timestamp(4 BE) / data(3) / data(1) / data(3). Decompression via obfuscated `o1()`. |

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
