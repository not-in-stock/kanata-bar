---
name: dev-doctor
description: >-
  Snapshot this machine's kanata-bar dev environment — toolchain (active Xcode vs
  CommandLineTools, swiftc/XCTest/swiftlint readiness), nix, the four repos and
  their branch/dirty state, the kanata config + keyboard device-name match, SIP
  state, and a build/test/lint readiness verdict with the fix for anything red.
  Use at the start of work on a new or unfamiliar machine; when a build, `swift
  test`, or swiftlint failure smells environmental (missing XCTest, sourcekitd
  crash, wrong toolchain); when onboarding another Mac; or whenever asked "what do
  we need to develop here / is this machine set up / what's the environment".
---

# dev-doctor

Run the project's read-only environment probe and report from its output:

```sh
scripts/dev-doctor.sh
```

It installs nothing and needs no sudo. Prefer it over ad-hoc `xcode-select`,
`sw_vers`, `csrutil`, `hidutil` and repo-status checks — it gathers all of them in
one pass and ends with a **Readiness** verdict (build / test / lint) plus the exact
fix command for anything not ready.

## Reading the result

- **Toolchain** is the usual culprit on a fresh Mac: a machine can have Xcode
  installed but `CommandLineTools` active, which has no XCTest (so `swift test`
  fails `no such module 'XCTest'`) and makes the nix swiftlint crash loading
  sourcekitd. The fix the verdict prints is
  `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept`.
  Build with the system `/usr/bin/swiftc`, never nix's.
- **kanata device match** mirrors kanata's own startup WARN: a name in
  `macos-dev-names-include` that isn't connected won't remap. `macos-dev-names-*`
  changes need a kanata **restart**, not a reload.
- **SIP** on the dev boxes is partially disabled (yabai) — helper/supervise
  privilege+signing checks can be false positives; verify on full SIP before
  shipping.

Background on the two dev machines (M5/macOS 27 current, M1/Sequoia baseline) and
why each check exists: wiki `reference/dev-machine-m5`. The script is
`scripts/dev-doctor.sh`; extend it there when a new environment assumption appears.
