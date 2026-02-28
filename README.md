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

- Menu bar icon with current layer name (or custom per-layer PNG icons)
- Start / Stop / Reload kanata from the menu
- Crash notifications via macOS Notification Center
- Launch at Login via LaunchAgent
- TOML config file with CLI override support
- Extra arguments passthrough to kanata

## Requirements

| Dependency | Note |
| :--------- | :--- |
| macOS 13+  | Uses SMAppService for XPC helper registration |
| [kanata](https://github.com/jtroo/kanata) | Installed via Homebrew, Nix, or manually |
| sudo access | kanata requires root for keyboard input on macOS |
| Xcode CLT | Only for building from source (`xcode-select --install`) |

## Install

### Homebrew

```bash
brew install not-in-stock/tap/kanata-bar
```

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
# Path to kanata binary (empty = search $PATH)
kanata = ""

# Path to kanata keyboard config
config = "~/.config/kanata/kanata.kbd"

# TCP port for layer tracking
port = 5829

# Directory with per-layer PNG icons (e.g. nav.png, base.png)
icons_dir = "~/.config/kanata-bar/icons"

# Start kanata automatically when app launches
autostart = true

# Restart kanata automatically if it crashes
autorestart = false

# Extra arguments passed to kanata
extra_args = ["--log-layer-changes"]

# Privilege escalation mode:
#   "auto"  — use sudo with PAM (TouchID if configured, recommended)
#   "false" — use AuthorizationExecuteWithPrivileges (deprecated API)
pam_tid = "auto"
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
--install-agent        Install LaunchAgent for login autostart
--uninstall-agent      Remove LaunchAgent
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
| **sudo + PAM** | `pam_tid = "auto"` | TouchID / password (system PAM dialog) | `sudo -S` with stdin EOF — fast, clean |
| **AuthExec** | `pam_tid = "false"` (default) | macOS password dialog | `AuthorizationExecuteWithPrivileges` via dlsym |

Both modes start kanata in the user session (so the macOS Input Monitoring permission dialog appears correctly). The app stops kanata via a privileged XPC helper (SIGTERM) or `sudo -n kill` as fallback, and connects to kanata's TCP API to receive layer change events in real time.

### Recommended: enable sudo TouchID

The AuthExec mode relies on `AuthorizationExecuteWithPrivileges`, a macOS API **deprecated since OS X 10.7** (2011). Apple may remove it in a future macOS release without notice. When that happens, the AuthExec mode will stop working.

If you have a Mac with TouchID (built-in or via Magic Keyboard), you can enable TouchID for sudo and use the more reliable PAM-based mode instead. A helper script is included:

```bash
./scripts/enable-pam-tid.sh
```

The script creates `/etc/pam.d/sudo_local` with the `pam_tid.so` module (this file survives macOS updates). It will ask for confirmation, back up any existing file, and verify the result. **Use at your own risk** — the script modifies a system PAM configuration file. If anything goes wrong, restore the backup:

```bash
sudo cp /etc/pam.d/sudo_local.bak /etc/pam.d/sudo_local
```

Then set in `~/.config/kanata-bar/config.toml`:

```toml
pam_tid = "auto"
```

This gives you native TouchID prompts for sudo and doesn't depend on any deprecated APIs.

## Acknowledgements

Inspired by [kanata-tray](https://github.com/rszyma/kanata-tray) — a cross-platform system tray app for kanata.
