# Testing ZombieJox

How to verify ZombieJox is working — both the automated test suites and the on-device manual passes that the automated tests can't cover.

## Automated tests

Run from the repo root:

```sh
flutter pub get
dart format --output=none --set-exit-if-changed .   # format check
flutter analyze                                     # must be clean — no warnings
flutter test                                        # full suite
```

To run a single file:

```sh
flutter test test/protocol/frame_test.dart
```

What's covered:

- `protocol/` — checksum algorithm, frame builder/parser round-trip, `0xD1` byte-8 unit parse.
- `state/` — weights table, reactive `Preferences`, `UnitAutoMatcher`, `PermissionRequestFlow`, `SelectionModel` (incl. rename + `customNameFor`).
- `devices/` — `Dumbbell`, `WeightGroup` (`GroupSnapshot` derivations, `remove()` race guard, §2a reconnect supervisor with `fake_async`, cancellation paths, `kickReconnectsForResume`, `setWeightIndex` skips reconnecting members).
- `widgets/` — `WeightButton`, `DumbbellCard`, `FailedDeviceCard`, `StatusToast` (incl. `TextScaler` 1.6× large-font safety, mid-session-drop state, §2a "Reconnecting…" state, §2h chip-tap + toast lifecycle).
- `screens/` — `HomeScreen` (warm-start, promote-on-tap, ×-remove, auto-match-from-dock, unit-toggle live re-label, BT-off banner, permission-revoked-on-resume, scan-empty + Scan again, §2a drop + resume kick, §2g pull-to-refresh, §2h chip-tap), `PermissionScreen`, `SettingsScreen`, `AboutScreen`.

What's **not** covered, and why: the BLE platform channels, the OS permission prompts, and real motor motion. None of these are exercisable from `flutter test` — they require a real `DB200` and a real phone. The iOS Simulator has no BLE stack at all.

**Pre-PR checklist:** `dart format .` → `flutter analyze` → `flutter test` all clean.

---

## Manual testing

### Prerequisites

- At least one JaxJox DumbbellConnect (`DB200-*`), powered on. Two is better — fan-out, consensus, and partial-drop scenarios need ≥ 2.
- An Android phone (primary dev platform) and an iPhone (verification platform).
- Android: Developer Options + USB debugging on; Bluetooth on; Location services on (some Android builds require Location for BLE scanning even with `neverForLocation`).
- iOS: a paired developer Mac with a provisioning profile.
- `flutter devices` lists the target. See `FLUTTER.md` if Android setup isn't done yet.

Install on the connected device with `flutter run -d <device-id>`. To start from a clean slate, uninstall the app first so `SharedPreferences` resets — this is what triggers the first-launch rationale and the auto-match-from-dock probe.

### Android

#### Permission flow

1. **First launch, grant.** Cold install → Continue on the rationale → OS Bluetooth permission prompt → Allow. Lands on the Home screen.
2. **First launch, deny.** Cold install → Continue → Deny on the prompt. Lands on the denied-state UI with `Open Settings` and `Try again` buttons.
3. **Try again.** Tap `Try again` → reverts to the rationale; Continue re-issues the prompt.
4. **Revoke between launches.** Revoke "Nearby devices" in Settings → relaunch the app. The rationale appears again (routing reads `Permission.bluetoothScan.isGranted`, no first-launch flag).
5. **Revoke mid-session.** With Home visible, background the app → revoke "Nearby devices" → foreground. App re-routes to `PermissionScreen` automatically.

#### Core flow

6. **Cold launch, no remembered devices.** Top region shows "Tap a dumbbell below to connect"; bottom region scans and lists at least one `DB200-*` when in range.
7. **Promote-on-tap.** Tap a scan card → it moves to the top region in `connecting` state; the connect starts immediately.
8. **×-remove.** Tap × on a top card → device disconnects, slot drops, scanner keeps running. Doing it while still `connecting` doesn't resurrect the slot when the racing connect resolves.
9. **Weight write.** Tap weight tiles → the dumbbell(s) physically move. Verify both extremes (8 lbs / 50 lbs).
10. **Battery.** Battery % on each card matches what nRF Connect reads for the same device.
11. **Manual dock change.** Press the dock's own +/− buttons → the active weight on the card updates (via `0xD2` byte 11).

#### Settings + About

12. **Live unit toggle.** Open Settings → flip lbs ↔ kg. Every weight tile re-labels live, no navigation round-trip.
13. **Rename a dumbbell** (§2e). Tap the name region on any card → rename dialog opens → OK commits, Cancel discards. The new name appears on the card and in the scan list. Restart the app — the name persists. Remove the device with × — the name is preserved if the device reappears later.
14. **About screen.** Logo at the top (crisp on a high-DPR device), app name + tagline, "What it is", a tappable GitHub row, a "Created by Rodrigo Pimentel \<rbp@isnomore.net\>" line where **only the email span is tappable** (icon + surrounding text inert). Tap GitHub → browser opens to the repo. Tap email → mail composer pre-filled to `rbp@isnomore.net`. Credits / Protocol / License / Disclaimer all readable.

#### Warm-start

15. **Verified connect → kill → relaunch.** After at least one ready connect, force-stop the app and reopen. The Home screen seeds the top region with the previously-connected devices in `connecting` state on the first frame, and the scanner also starts immediately. No flash of an empty top region.
16. **Out-of-range warm-start.** If a remembered dumbbell is offline at relaunch, a `FailedDeviceCard` appears with a refresh icon (retry) and an × (dismiss).

#### Auto-match dock unit

17. **No prior Settings choice, docks agree.** Clear app data. Set both docks to kg via the dock's hidden physical gesture. Connect → SnackBar "Unit set to kg to match your dumbbells.", weight tiles re-label to `3.6 kg` … `22.7 kg`.
18. **No prior Settings choice, docks disagree.** Flip one dock to lbs, reconnect → SnackBar "Dumbbells are set to different units — pick one in Settings". App display unit unchanged.
19. **Explicit pick wins.** Open Settings, tap the lbs/kg toggle (either side counts as explicit). Reconnect with any combination → no SnackBar, no preference change.
20. **Post-connect race.** Clear app data and connect. The auto-match SnackBar should arrive within ~1.5 s of "Connecting…" clearing — *not* instantly. (The bare battery-read state shouldn't trigger the match; the `0xD1` reply with the unit byte should.)

#### Pull-to-refresh (§2g)

21. **Populated top region.** Pull down on the selected-devices region → `WeightGroup.refresh()` re-queries every ready dumbbell and the scanner restarts. State on the cards updates from the fresh `0xD1` reply; the indicator stays until both finish.
22. **Empty top region.** With no devices selected, pull-down still activates (top region is wrapped in a scroll view with `AlwaysScrollableScrollPhysics`) and restarts the scan.

#### Edge cases (§1h)

23. **Bluetooth off mid-session.** Toggle BT off in the quick-settings panel. Error-coloured "Bluetooth is off" banner appears at the top of the body; scan area copy switches to "Turn Bluetooth on to scan."; the banner CTA reads **"Enable Bluetooth"** and pops the OS's in-app "Allow Bluetooth?" dialog. Accept → BT on → banner + copy disappear; scan resumes; any waiting reconnects fast-forward (no 60 s wait).
24. **All out of range.** After the 30 s scan timeout, the bottom region shows "No JaxJox dumbbells found. Make sure they're powered on and in range." with a tonal `Scan again` button. Tap → scan restarts.
25. **Mid-session drop.** Power off a connected dumbbell. Its card flips to a "Reconnecting…" chip + body line within ~2 s. Power it back on within a couple of minutes → card returns to "Connected" without user intervention. Tap × on the card → gives up reconnecting, drops the slot.

#### Reconnect supervisor (§2a)

26. **Drop on one of N.** Two dumbbells connected and ready. Power one off → its card flips to "Reconnecting…". The weight grid stays enabled (the other member is still ready); a weight tap fans out only to the still-ready peer. Power the dropped one back on → its card cycles back through "Connecting…" to "Connected" / "Idle".
27. **Drop on the only connected dumbbell.** Weight grid disables (no ready member). On reconnect → grid re-enables.
28. **Long drop.** Power a connected dumbbell off and leave it off. Card stays on "Reconnecting…" indefinitely (retry repeats at the 60 s cap). Tap × → slot disappears, no further retries, device removed from `rememberedDeviceIds`.
29. **Resume kick.** Connect → power off → background the app for ≥ 60 s → power back on → foreground. The dumbbell reconnects within seconds of the resume, not after the next 60 s backoff tick.
30. **BT-adapter toggle (in-foreground).** Connect → toggle BT off in quick-settings (banner + cards flip to "Reconnecting…" as supervisor retries fail). Toggle BT back on → cards reconnect within seconds, not after a 60 s wait.
31. **Half-responsive device.** A nearly-dead dumbbell may briefly wake its BLE radio but never reply to `queryStatus`. Card stays on "Connecting…" with a "—" weight; grid stays disabled; × is the only recovery. (The supervisor doesn't kick in here — the device never reached `isReady`, so this is initial-connect territory.)
32. **Resume with revoked permissions.** Connect → power off so the card is "Reconnecting…" → background → revoke "Nearby devices" → foreground. Home routes to `PermissionScreen` and no reconnect attempt fires during the resume window.

#### Status-pill toast (§2h)

33. **Renamed connected.** Tap the chip on a renamed connected card → centered toast reads `Device <real id> (<your name>) is Connected`. Fades in, holds ~1.6 s, fades out. While visible, tapping a weight tile still fires the BLE write; tapping × still removes the card (toast is non-blocking via `IgnorePointer`).
34. **No rename.** Same tap without a rename: `Device <real id> is Connected` — no parenthesised name, no advertised-name fallback.
35. **Failed connect.** On a `FailedDeviceCard`, tap the "Failed" chip → `Device <real id> [(<your name>)] is Failed`. Refresh on the same card still retries.
36. **Truncated chip.** On a narrow phone width where the chip truncates to "Conne…", the toast still reads the full word ("Connected") — the message uses `statusLabel`, not the visible chip text.

---

### iOS

The entire Android list above applies on iOS. BLE does not work in the iOS Simulator — run on a real iPhone.

#### One-time setup: code signing

Unlike Android, you can't `flutter run` straight onto a physical iPhone without Apple code signing first. If you skip this you'll see `No valid code signing certificates were found` and the build will refuse to install. The CLI can't fix this itself — Xcode owns provisioning.

1. **Sign in to Xcode.** Xcode → Settings → Accounts → `+` → Apple ID. A personal (free) Apple ID is enough for testing; a paid Apple Developer Program account lasts a year vs. the free 7 days.
2. **Open the iOS workspace in Xcode** (not the bare `.xcodeproj`):
   ```sh
   open ios/Runner.xcworkspace
   ```
3. **Set a Development Team.** Select the `Runner` *project* in the navigator → the `Runner` *target* → **Signing & Capabilities**. Tick "Automatically manage signing" and pick your Apple ID under "Team".
4. **Bundle identifier.** The default is `net.isnomore.zombiejox`. Apple requires globally unique bundle IDs per Apple ID — if Xcode complains "Failed to register bundle identifier", change it to something like `net.isnomore.zombiejox.<yourname>` in the same Signing pane. The change is local; don't commit it.
5. **Register the device.** Plug the iPhone in, accept "Trust This Computer" on the phone, and select the device in Xcode's target dropdown. First-time registration downloads a symbol bundle ("Preparing debugger support…") — wait it out, it can be several minutes.
6. **Run once from Xcode** (the play button). This provisions the device, installs the app, and creates the certificate. **After this completes**, `flutter run -d <device-id>` from the CLI will work.
7. **Trust the dev certificate on the iPhone.** Settings → General → VPN & Device Management → tap the cert under "Developer App" → Trust. Without this the app installs but refuses to launch.
8. **Free-cert expiry.** A free Apple ID's provisioning profile expires after 7 days. Re-run from Xcode (or `flutter run` after Xcode has re-provisioned) to refresh.

If `flutter devices` doesn't list the iPhone after step 5, see the error above — it's almost always the signing chain, not the cable. Once a working `flutter run` lands once, subsequent runs are fast.

If you're having trouble building the app, try

```sh
# from repo root
flutter clean
flutter pub get
(cd ios && pod install)

# Then delete ZombieJox from the iPhone home screen so iOS resets its persisted CB authorization, and:

flutter run -d <iphone-device-id>
```

#### iOS-specific points to confirm

37. **First-launch rationale.** This is the riskiest unverified assumption in the project. `permission_handler` reports `denied` for `Permission.bluetoothScan` / `bluetoothConnect` on iOS *until the OS has prompted at least once*, **but the OS prompt itself is triggered by `flutter_blue_plus`'s first BLE op** (controlled by `NSBluetoothAlwaysUsageDescription` in `ios/Runner/Info.plist`), not by our `permission_handler.request()` call. Expected: rationale appears → Continue → OS prompt → grant → Home. If the rationale screen doesn't show, or Continue feels like a no-op (iOS reports "granted" so we navigate to Home and the OS prompt fires from Home's first BLE call), the routing logic needs to be revisited — possibly a "rationale shown" flag specifically for iOS.
38. **Live unit toggle.** lbs ↔ kg in Settings re-labels the weight tiles live (verifies `ValueListenable` works through the iOS Flutter render path).
39. **Mid-session drop timing.** `flutter_blue_plus` may emit `disconnected` with different latency than Android, and CoreBluetooth's "system kills the connection when the peripheral goes out of range" semantics differ. The supervisor logic doesn't care about latency (any `disconnected` for an ever-ready member triggers a retry), but pin down the user-visible "card flips to Reconnecting…" delay on real hardware.
40. **No "Enable Bluetooth" CTA.** iOS doesn't expose a programmatic toggle. The BT-off banner shows without a CTA; the copy instructs the user to flip BT in Settings or Control Center.
41. **TestFlight build is producible.** `flutter build ios --release` succeeds with the current scaffold.

---

## When something fails

- **`flutter analyze` not clean.** Fix before continuing — green analysis is the floor for everything else.
- **`flutter test` fails.** Re-run the single failing file with `flutter test test/<path>` for a faster loop. Don't disable a test to make CI green; investigate.
- **No motor motion on weight tap.** Confirm the dumbbell index in `0xD6` actually went out — pair an `adb logcat` or Xcode console to the run, or sanity-check via nRF Connect that the dock itself responds to a hand-crafted `0xD6 <idx>` frame on the JaxJox custom service. See `docs/ble_protocol.md`.
- **Unexpected dumbbell behaviour.** Stop testing. Confirm you have not somehow sent opcode `0x27` — it knocks the dock temporarily offline (see `docs/ble_protocol.md` and `AGENTS.md` §5). Power-cycle the dock to recover.
