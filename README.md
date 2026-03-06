<p align="center">
  <img src="icon.png" width="128" alt="kanata-bar icon">
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
- Auto-reset Input Monitoring permission when install source changes
- TOML config file with CLI override support

## Requirements

| Dependency | Note |
| :--------- | :--- |
| macOS 13+  | Uses SMAppService for login items and XPC helper |
| [kanata](https://github.com/jtroo/kanata) | Installed via Homebrew, Nix, or manually |
| sudo access | kanata requires root for keyboard input on macOS |
| Xcode CLT | Only for building from source (`xcode-select --install`) |

## Install

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

# Privilege escalation mode:
#   "auto"  — use sudo with PAM (TouchID if configured, recommended)
#   "false" — use AuthorizationExecuteWithPrivileges (deprecated API)
pam_tid = "auto"

[kanata_bar]
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

## How it works

kanata requires root privileges for keyboard access on macOS. kanata-bar supports two privilege escalation methods:

| Mode | Config | Auth prompt | How it works |
| :--- | :----- | :---------- | :----------- |
| **sudo + PAM** | `pam_tid = "auto"` | TouchID / password | `sudo -S` with stdin EOF |
| **AuthExec** | `pam_tid = "false"` (default) | macOS password dialog | `AuthorizationExecuteWithPrivileges` (deprecated since 10.7) |

Both modes start kanata in the user session so the macOS Input Monitoring permission dialog appears correctly. The app stops kanata via a privileged XPC helper (SIGTERM) or `sudo -n kill` as fallback, and connects to kanata's TCP API for real-time layer change events.

If kanata is already running when kanata-bar launches, the app detects it automatically and connects without starting a new instance.

### Recommended: enable sudo TouchID

The AuthExec mode uses a deprecated macOS API that Apple may remove in a future release. If you have a Mac with TouchID, enable TouchID for sudo with the included helper script:

```bash
./scripts/enable-pam-tid.sh
```

The script creates `/etc/pam.d/sudo_local` with `pam_tid.so` (survives macOS updates). Then set `pam_tid = "auto"` in your config.

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
