# Contributing to ZombieJox

Welcome. ZombieJox is an open-source Flutter replacement for the discontinued JaxJox Connect app — see the [README](README.md) for what the project does and why.

## TL;DR

Three rules govern every change:

1. **Accountability** — the human opening the PR owns it.
2. **No degradation** — don't ship something that breaks what already works.
3. **`main` always works** — tests pass, app builds, dumbbells respond.

## AI-assisted contributions

AI assistants (Claude, ChatGPT, Cursor, etc.) are welcome. Most of the BLE protocol decoding and the initial Flutter scaffold in this repo were AI-collaborated, and that's expected to continue.

The conditions:

- **The human author is responsible.** "I asked an LLM and merged its output" is not a defense for a regression. Read every line before you push it; understand it; verify it works.
- **Disclose AI involvement in the PR description.** A line like *"Drafted with Claude Sonnet 4.6, reviewed and tested by me on a DB200 dumbbell"* helps reviewers calibrate effort. Add a co-author to you commits when relevant (e.g., `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`)
- **No pure-AI commits.** Don't push code you didn't actually read.

## Quality bar

- **Add tests for pure-Dart logic.** The `protocol/` and `state/` layers are deliberately Flutter-free so they can be unit-tested. New code in those layers needs tests; new code that touches BLE or UI is harder to test automatically — see the next bullet.
- **Hardware-touching changes need on-device verification.** GitHub can't run a BLE-controlled dumbbell. If your change affects BLE behaviour or motion, test it against a real device (DumbbellConnect, KettlebellConnect, etc.) and describe in the PR what you tested and what happened.
- **`flutter analyze` and `flutter test` must pass before opening the PR.** No new warnings.
- **`dart format .` your changes** before pushing.
- **Documentation is part of the change, not a follow-up.** If your PR changes:
  - the BLE protocol → update [`docs/ble_protocol.md`](docs/ble_protocol.md). This doc is the canonical reference. The Dart code transcribes from it, not the other way around. New BLE findings update the doc first.
  - the implementation status / phase plan → update [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).
  - user-visible behaviour or supported devices → update the [README](README.md).

## Hardware safety

ZombieJox controls a physical motor. Some opcodes are hazardous.

- **Never send opcode `0x27`.** It knocks the dumbbell offline temporarily. See the warning at the top of [`docs/ble_protocol.md`](docs/ble_protocol.md).
- **Read `docs/ble_protocol.md` before touching `lib/protocol/` or `lib/ble/`** — especially the "DO NOT SEND" section.
- **Document new BLE behaviour before relying on it.** Future contributors (and future you) will need it.

## Workflow

- Branch off `main`. Don't push to `main` directly — open a PR even for solo work; PRs are the audit trail.
- One logical change per PR. If you ended up doing two things, split them.
- Commit messages: short, imperative, area-prefixed where it helps (e.g. `protocol: fix off-by-one in checksum`, `ui: add settings screen`).
- Mention the issue / phase the PR addresses in the description when relevant (e.g. *"Closes Phase 1.1h item 4"*).

## License

By contributing, you agree your code is licensed under the project licence (see [COPYING](COPYING)).

## Thanks

If you got this far you're already the audience this project was made for. Welcome!
