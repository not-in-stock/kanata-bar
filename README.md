<p align="center">
  <img src="doc/images/icon.png" width="128" alt="kanata-bar icon">
</p>

<h1 align="center">kanata-bar</h1>

<p align="center">
  Native macOS menu bar app for the <a href="https://github.com/jtroo/kanata">kanata</a> keyboard remapper
</p>

<p align="center">
  <a href="https://github.com/not-in-stock/kanata-bar/releases/latest"><img src="https://img.shields.io/github/v/release/not-in-stock/kanata-bar" alt="Release"></a>
  <a href="https://github.com/not-in-stock/kanata-bar/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/not-in-stock/kanata-bar/ci.yml?branch=main&label=build" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/not-in-stock/kanata-bar" alt="License"></a>
</p>

Shows the current keyboard layer in the menu bar and manages the kanata process lifecycle.

## Features

- Menu bar icon with current layer name (or custom per-layer PNG icons with animated transitions)
- Start / Stop / Reload kanata from the menu
- Auto-restart on crash (with rate limiting)
- Connects to an already running kanata automatically
- Crash notifications via macOS Notification Center
- Launch at Login (integrates with System Settings)
- Guided first-run permission: requests Accessibility; Start shows a "Permission needed" badge until it's granted
- Auto-reset the permission when the install source changes
- TOML config file with CLI override support

## Requirements

| Dependency | Note |
| :--------- | :--- |
| macOS 13+  | Uses SMAppService for login items and XPC helper |
| [kanata](https://github.com/jtroo/kanata) | Installed via Homebrew, Nix, or manually |
| [Karabiner VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) | Driver + daemon kanata needs to emit remapped keys on macOS |
| Accessibility | TCC permission kanata-bar requests on first run; covers input capture (see [Permissions](#permissions)) |
| sudo access | kanata requires root for keyboard input on macOS |
| Xcode CLT | Only for building from source (`xcode-select --install`) |

## Install

### Download

Grab the latest `.dmg` or `.zip` from the [Releases page](https://github.com/not-in-stock/kanata-bar/releases/latest) and move **Kanata Bar.app** to `/Applications`.

### Homebrew

```bash
brew install not-in-stock/tap/kanata-bar
```

### Nix (nix-darwin)

The [kanata-darwin](https://github.com/not-in-stock/kanata-darwin) flake includes a kanata-bar module:

```nix
services.kanata.kanata-bar.enable = true;
```

See the kanata-darwin README for full configuration options.

### Build from source

```bash
git clone https://github.com/not-in-stock/kanata-bar.git
cd kanata-bar
./build.sh build
```

The app bundle is at `build/Kanata Bar.app`. Move it to `/Applications` or run directly:

```bash
./build.sh run
```

## Configuration

kanata-bar looks for `~/.config/kanata-bar/config.toml`:

```toml
[kanata]
# Path to kanata binary (empty = search $PATH)
path = ""

# Path to kanata keyboard config
config = "~/.config/kanata/kanata.kbd"

# TCP port for layer tracking
port = 5829

# Extra arguments passed to kanata
extra_args = ["--log-layer-changes"]

[kanata_bar]
# Privilege escalation mode:
#   "auto"  — use sudo with PAM (TouchID if configured, recommended)
#   "false" — use AuthorizationExecuteWithPrivileges (deprecated API)
pam_touchid = "auto"

# Launch mechanism (experimental):
#   "auto"   — sudo/AuthExec per pam_touchid above (default)
#   "helper" — root XPC helper supervises kanata: zero prompts after the
#              one-time Login Items approval, and kanata can't outlive the app.
#              Falls back to "auto" until the helper is approved and TCC was
#              granted to the current binary (a first run still bootstraps
#              through the user session so macOS can show the TCC dialog).
launcher = "auto"

# Start kanata automatically when app launches
autostart_kanata = false

# Restart kanata automatically if it crashes (disabled after 3 crashes in 60s)
autorestart_kanata = false

# Directory with per-layer PNG icons (e.g. nav.png, base.png)
icons_dir = "~/.config/kanata-bar/icons"

# Icon transition animation: "pages" (default), "flow", "cards", "off"
# Automatically set to "off" when Reduce Motion is enabled in System Settings
icon_transition = "pages"
```

All string values support `~` expansion.

### CLI flags

CLI flags override config file values:

```
--config-file <path>   Config file path (default: ~/.config/kanata-bar/config.toml)
--kanata <path>        Path to kanata binary
--config <path>        Path to kanata .kbd config
--port <port>          TCP port (default: 5829)
--icons-dir <path>     Directory with layer icons
--no-autostart         Don't start kanata on launch
```

## Layer icons

Place PNG files named after your layers in the icons directory:

```
~/.config/kanata-bar/icons/
  base.png
  nav.png
  num.png
```

If no icon is found for a layer, the menu bar shows the layer name abbreviation.

## Permissions

kanata needs the **Accessibility** permission; kanata-bar requests it on first run and
holds it so the root-launched kanata inherits it.

Until it's granted, **Start** carries a "Permission needed" badge and, when clicked,
opens the right System Settings pane instead of starting kanata.

When the install source changes (e.g. a rebuild with a new code signature) the old
grant no longer applies, so kanata-bar resets it and re-requests.

## How it works

kanata requires root privileges for keyboard access on macOS. kanata-bar can obtain
it several ways:

| Mode | Config | Auth prompt | How it works |
| :--- | :----- | :---------- | :----------- |
| **sudo + PAM** | `pam_touchid = "auto"` (default) | TouchID / password each start | `sudo -S` with PAM (TouchID if configured) |
| **AuthExec** | `pam_touchid = "false"` | macOS password dialog each start | `AuthorizationExecuteWithPrivileges` (deprecated since 10.7) |
| **XPC helper** | `launcher = "helper"` | one-time Login Items approval, then none | root `SMAppService` daemon supervises kanata (experimental — see note below) |

**Recommended:** **sudo + PAM with TouchID** (`pam_touchid = "auto"` + the
`enable-pam-tid.sh` helper below) — no signing, no standing privilege, a quick tap each
Start. On a Mac **without** Touch ID, use **AuthExec** (`pam_touchid = "false"`). Nix
users can get prompt-free Start via the
[kanata-darwin](https://github.com/not-in-stock/kanata-darwin) module.

The default (sudo / AuthExec) starts kanata in the **user session** so the macOS
permission dialogs appear against kanata-bar. The app stops kanata via a
**stop-sentinel**: a small root wrapper watches a user-owned file and SIGKILLs kanata
the moment it disappears or the app exits — so **Stop needs no second auth prompt**,
and kanata can never outlive the app. kanata-bar connects to kanata's TCP API for
real-time layer-change events.

If kanata is already running when kanata-bar launches, the app detects it
automatically and connects without starting a new instance (Stop is hidden in this
case — the app only manages instances it started).

### Recommended: enable sudo TouchID

The AuthExec mode uses a deprecated macOS API that Apple may remove in a future release. If you have a Mac with TouchID, enable TouchID for sudo with the included helper script:

```bash
./scripts/enable-pam-tid.sh
```

The script creates `/etc/pam.d/sudo_local` with `pam_tid.so` (survives macOS updates). Then set `pam_touchid = "auto"` in your config.

## Notifications

kanata-bar posts macOS notifications for config reloads, crashes, and auto-restarts.
They arrive **off by default** (the app isn't notarized), so enable them to see them:

**System Settings → Notifications → Kanata Bar → Allow Notifications**

<p align="center">
  <img src="doc/images/kanata-bar-notifications-setting.png" width="420" alt="Enable notifications in System Settings">
</p>

## Logs

| Log | Path |
| :-- | :--- |
| kanata-bar | `~/Library/Logs/kanata-bar.log` |
| kanata process | `~/Library/Logs/kanata.log` |

Both are accessible from the menu via "View Logs".

## Localization

Kanata Bar is localized into English, German, French, Japanese, Korean, Simplified Chinese, Dutch, Russian, and Brazilian Portuguese. Translations live in `Resources/<lang>.lproj/Localizable.strings`.

Machine-generated translations may sound unnatural. If you are a native speaker and spot an issue, PRs are welcome — each string has a context comment in the English file (`Resources/en.lproj/Localizable.strings`) explaining where and how it is used.

## Acknowledgements

Inspired by [kanata-tray](https://github.com/rszyma/kanata-tray) — a cross-platform system tray app for kanata.
