<p align="center">
  <img src="assets/zombiejox-logo-bg.svg" alt="ZombieJox logo" width="160">
</p>

# ZombieJox

> Your JaxJox dumbbells aren't dead. They just need a new brain.

Open-source Flutter replacement for the discontinued JaxJox Connect app.
For owners of DumbbellConnect, KettlebellConnect, and friends whose
weights went silent when JaxJox went into administration.

---

## The story

In early 2025 JaxJox went into administration. The app vanished from
both stores. The dumbbells you paid $300 for were, overnight, not smart anymore —
weight stuck wherever it last landed, no way to change it without the
app, no app to install.

**ZombieJox is a new brain attached to  the corpse.**
Same hardware. New app. No cloud, no subscription,
no telemetry, no account.

## Status

| Product                     | Code   | Status                                              |
|-----------------------------|--------|-----------------------------------------------------|
| DumbbellConnect             | DB200  | 🟢 Feature-complete; verified on Android + iOS      |
| KettlebellConnect 2.0       | KB200  | 🟡 Protocol known, untested                         |
| KettlebellConnect (legacy)  | KB42   | 🟡 Protocol known, untested                         |
| FoamRollerConnect           | FR100  | ⚪ Not yet                                          |
| PushUpConnect               | PB220  | ⚪ Not yet                                          |
| Chileaf-branded HRMs        | CL8xx  | ⚪ Not yet                                          |

For DumbbellConnect: the implementation  is complete (reverse-engineering, MVP, polish + hardening), and the app has been verified on real Android + iOS hardware. If you have one of the untested devices and want to help, open an issue.

## What it does

- Scans for and connects to one or more DumbbellConnect (`DB200`) devices over BLE
- Single Home screen — tap any scanned dumbbell to promote it to the selected set; one weight tile tap sets every connected dumbbell in parallel
- All eight weight settings (8 / 14 / 20 / 26 / 32 / 38 / 44 / 50 lbs)
- Live per-dumbbell status: current weight, battery, motion state, connection state
- Reflects manual weight changes (set via the dock's own buttons) in the UI
- Auto-reconnect after a mid-session drop, with exponential backoff and a fast-forward kick when the app comes back to the foreground or Bluetooth is toggled back on
- Warm-start: relaunching the app reconnects to last session's dumbbells with no scan-and-pick round-trip
- Tap the status pill on any card for a centered toast spelling out the connection state in full
- Tap-to-rename — give your dumbbells real names; the rename persists across launches and removal
- Pull down to refresh — re-query state from the dumbbells and restart the scan
- lbs / kg toggle in Settings; flipping it re-labels every weight tile live. On first connect, if you haven't picked a unit, the app silently matches whatever your docks are physically set to.
- Edge-case screens for Bluetooth off (with one-tap Enable on Android), all devices out of range, mid-session disconnect, and permission revoked while backgrounded
- Pre-permission rationale on first launch — a plain "this is what we need Bluetooth for, here's why" before the OS prompt fires
- Dark theme seeded from aubergine; tablet + landscape + large-font safe
- Custom launcher icon and splash on both platforms
- About screen with credits, license, and a pointer to the protocol docs
- No cloud, no account, no telemetry — everything stays on your phone

## What it doesn't do (yet)

- Per-device weight override — useful for asymmetric warm-up sets, where you want one dumbbell heavier than the other. Deferred to post-release (§4a).
- Connect to KettlebellConnect, FoamRollerConnect, or Chileaf HRMs — the protocols are catalogued in [`docs/ble_protocol.md`](docs/ble_protocol.md) but the scan filter and device classes for them aren't wired up
- Light theme — dark only for now
- Sync workout history off the dock (`0xD3` / `0xD4` opcodes are documented but unparsed)

## What it will never do

- Workout tracking, exercise library, social features, "Fitness IQ"
  scores, training plans — none of it. The original app's cloud is
  gone anyway. ZombieJox is a weight controller, nothing more.

## Install

**Android:** Download the APK from [Releases](#) and sideload.
Google Play won't host an unofficial app for orphaned hardware.

**iOS:** TestFlight link in [Releases](#).

Or build from source:

First time setting up Flutter for this project on macOS? See [FLUTTER.md](FLUTTER.md) for the Android toolchain walkthrough (JDK, command-line Android SDK, license acceptance, common gotchas).

## Build from source

```bash
git clone https://github.com/rbp/zombiejox
cd zombiejox
flutter pub get
flutter run
```

## Contributing

PRs are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions —
short version: AI-assisted contributions are fine if you understand and
verify them, hardware-touching changes need an on-device test, and `main`
always works.

## How it works

The original app talked to the dumbbells over a custom BLE protocol
on service UUID `AAE28F00-71B5-42A1-8C3C-F9CF6AC969D0`. We
reverse-engineered the protocol from the decompiled APK and recovered
the native checksum algorithm by disassembling `libfitness.so` with
`llvm-objdump`. Full protocol spec is in [`docs/ble_protocol.md`](docs/ble_protocol.md).

There's no auth on the dumbbells — they'll talk to anyone who can
frame a packet correctly.

## FAQ

**Q: Is this affiliated with JaxJox?**
No. JaxJox the company is in administration. ZombieJox is an
independent community project for people who'd rather not throw $300
of hardware in a landfill.

**Q: Why the zombie name?**
Because the dumbbells were dead and now they aren't.

**Q: Will this brick my dumbbells?**
Highly unlikely — we only send commands the official app already
sent. But: this is hobbyist software with no warranty. Don't expect
support.

**Q: I have a Chileaf heart rate monitor that worked with the
original JaxJox app. Will it work here?**
Not yet. The Chileaf protocol is in scope but not implemented; PRs
welcome.

## Credits

- **Eamon Tuhami / X8IQ LTD** — proved the protocol was workable
  with the iOS-only "JaxJox Connect" app, before this project existed
- The original JaxJox engineering team — the hardware is solid, sorry
  the company didn't make it
- Everyone who's owned bricked smart-fitness equipment and wondered
  if it had to be that way
- Rodrigo Pimentel started this project. See [CREDITS](CREDITS) for more details.

## License

[GPLv3](COPYING)

## Disclaimer

ZombieJox is not affiliated with JaxJox, its administrators, or any
successor entity. Provided as-is, no warranty. Don't drop your dumbbells.
