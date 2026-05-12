# AGENTS.md

Guidance for AI agents (and humans) working in this repository. Read this before editing.

## 1. Project context

ZombieJox is a Flutter replacement for the discontinued JaxJox Connect app — it controls JaxJox DumbbellConnect (`DB200`) hardware over a reverse-engineered BLE protocol. It runs on Android and iOS, no cloud, no auth, no telemetry. See more on [README.md](README.md).

## 2. Code style preferences

- **Dart `^3.6.0`, Flutter stable.** Null-safety on, sound flow analysis assumed.
- **Lints:** `flutter_lints` (`analysis_options.yaml`). No new warnings.
- **Formatting:** `dart format .` — 2-space indent, 80-col soft limit, trailing commas on multi-line literals to keep `dart format` stable.
- **Strings:** single quotes (`'foo'`) unless the string contains a `'`.
- **Imports:** `dart:` first, then `package:`, then relative — separated by blank lines. Prefer relative imports within `lib/`.
- **Naming:** `lowerCamelCase` for members, `UpperCamelCase` for types, `snake_case.dart` for files. Private members get a leading `_`.
- **Async:** prefer `async`/`await` over raw `.then()`. Always `await` futures or document why you intentionally fire-and-forget.
- **Comments:** dartdoc (`///`) on public APIs that aren't self-evident. Inline comments only for the *why* (a constraint, an invariant, a hardware quirk) — never the *what*.
- **Logging:** `debugPrint` only - and even then, to be avoided - behind a check or category prefix. No `print()`.

## 3. Commands

Run these from the repo root.

| Task                                 | Command                                        |
|--------------------------------------|------------------------------------------------|
| Install deps                         | `flutter pub get`                              |
| Run on attached device               | `flutter run`                                  |
| Run on a specific device             | `flutter run -d <device-id>`                   |
| Static analysis (must be clean)      | `flutter analyze`                              |
| Run all tests                        | `flutter test`                                 |
| Run one test file                    | `flutter test test/protocol/frame_test.dart`   |
| Format code                          | `dart format .`                                |
| Build Android release APK            | `flutter build apk --release`                  |
| Build iOS                            | `flutter build ios --release`                  |
| Regenerate launcher icons            | `dart run flutter_launcher_icons`              |
| Regenerate splash screen             | `dart run flutter_native_splash:create`        |
| List connected devices               | `flutter devices`                              |

**Pre-PR checklist (must pass):** `dart format .` → `flutter analyze` → `flutter test`.

## 4. Architecture decisions

```
lib/
  protocol/   ← pure Dart, NO Flutter imports. Frame, checksum, opcodes, DumbbellState. Unit-tested.
  state/      ← pure Dart, NO Flutter imports (except `package:flutter/foundation.dart` for ValueNotifier). Preferences, weights, UnitAutoMatcher.
  ble/        ← flutter_blue_plus wrapper, UUIDs, device-display helpers.
  devices/    ← Dumbbell (one device) + WeightGroup (a connected set). The model layer.
  widgets/    ← Reusable UI atoms (WeightButton, DumbbellCard, FailedDeviceCard).
  screens/    ← Top-level screens (Permission, Scan, Control, Settings, About).
  main.dart   ← Entrypoint: load Preferences → check BT permissions → route.
test/         ← Mirrors lib/. Pure-Dart layers get unit tests; widgets get widget tests.
docs/ble_protocol.md  ← Canonical BLE spec. Dart transcribes from it, not the other way around.
```

- **`protocol/` and `state/` are deliberately Flutter-free** so they can be unit-tested without a widget binding. Don't add `package:flutter/material.dart` imports there.
- **`docs/ble_protocol.md` is the source of truth for the BLE protocol.** If you discover something new about the hardware, update the doc first, then transcribe to Dart.
- **One `Dumbbell` per device, one `WeightGroup` per connected set.** Screens observe the model; they don't own BLE state.
- **Preferences are reactive.** Expose preferences as `ValueListenable`s so widgets can rebuild without navigation round-trips.
- **Scan filter** uses device-name prefixes (`DB200`, `KB200`, etc.) — see `docs/ble_protocol.md`.

## 5. Hardware safety (non-negotiable)

ZombieJox drives a physical motor. The hardware has no auth.

- **Never send opcode `0x27`.** It knocks the dumbbell temporarily offline. See `docs/ble_protocol.md` and `lib/protocol/opcodes.dart`.
- **Hardware-touching changes need on-device verification.** A green test suite does not prove a motor command works. Test against a real `DB200` and describe what you tested in the PR.
- **Read `docs/ble_protocol.md` before editing `lib/protocol/` or `lib/ble/`** — especially the "DO NOT SEND" section.

## 6. Testing conventions

- **Add tests for new pure-Dart logic** in `protocol/` and `state/`. New BLE/UI code is harder to test automatically — compensate with on-device verification.
- **Don't write tests that test themselves.** If the only caller of a public method is its own test, the method is the dead code, not the test. See §7.
- **Widget tests** live under `test/screens/` and `test/widgets/` and use `flutter_test`.
- **Tests must not depend on real BLE.** Stub at the `BleConnection` / `Dumbbell` boundary.

## 7. Lessons from code review — read before you refactor

These are recurring traps that a recent thorough review surfaced. They are the difference between a passing test suite and code that actually works.

### 7.1 Beware test-only public APIs

`Preferences.getUnit()`, the nullable `FailedDeviceCard.error`/`onRetry`, and the now-deleted `weightLbs` getter were all kept alive purely by tests testing themselves. Before adding or keeping a public method, ask: **"what production code calls this?"** If the only answer is "the tests for it," the method itself is the dead code, not its tests. Test ergonomics is not a load-bearing reason to expose a method — expose a seam, fold the rest back into the caller, or test through the real entry point.

### 7.2 Use real exceptions for input bounds, not `assert`

`Dumbbell.setWeightIndex` once had a debug-only `assert(index < 8)` standing between user input and a motor. **`assert` is stripped in `--release` builds.** An out-of-range index would have sent a malformed `0xD6 N` frame straight to the hardware. Rule of thumb: anything that crosses a trust boundary — user input → hardware, user input → network, untrusted data → parser — needs a check that survives `--release`. Throw `ArgumentError`/`RangeError`, or clamp explicitly with a comment.

### 7.3 Derived state belongs on the model, not the view

`_consensusIndex` / `_anyMoving` / `_anyReady` / `_failedDevices` are currently split between `WeightGroup` (live membership) and `ControlScreen` (failures + derivations). The view recomputes them on every rebuild, and the group doesn't know things about itself the screen knows. **The next refactor:** `WeightGroup` exposes a single `GroupSnapshot { connecting, ready, failed, consensusIndex, anyMoving }` as its public surface, and the screen becomes a projection of that snapshot. The screen can't drift from the model if it computes nothing.

### 7.4 Extract repeated lifecycle patterns

The `_disposed` flag pattern is being hand-rolled in `Dumbbell`, `WeightGroup`, and `BleConnection` — three repetitions is enough to justify a named primitive (a `Disposable` mixin, or `package:async`'s `CancelableOperation`). Relatedly: `flutter_blue_plus`'s `connectionState` stream of `BluetoothConnectionState` currently leaks the plugin type into `DumbbellCard`. That coupling closes off cleanly once §7.3 lands and the screen consumes a `GroupSnapshot` instead of plugin types directly.

## 8. Working efficiently in this repo

- The `protocol/` layer transcribes `docs/ble_protocol.md`. When something doesn't match, the doc is right and the code is wrong — until you've proven otherwise on hardware. If so, update the doc.
- Reverse-engineering artifacts (decompiled APK, `libfitness.so` notes) live under `reverse-engineering/` and are reference material, not buildable code.
- `IMPLEMENTATION_PLAN.md` is the phase plan; check it when you're unsure whether a piece of behaviour is in scope.
- `CONTRIBUTING.md` covers the PR workflow, AI-assistance disclosure, and the merge rules.
- One logical change per PR. Branch off `main`. Don't push to `main` directly.
