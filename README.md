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

kanata requires root privileges for keyboard access on macOS. kanata-bar starts it via `sudo` in the user session (so the macOS Input Monitoring permission dialog appears correctly) and stops it via a privileged XPC helper that sends SIGTERM.

The app connects to kanata's TCP API to receive layer change events and updates the menu bar in real time.

## Acknowledgements

Inspired by [kanata-tray](https://github.com/rszyma/kanata-tray) — a cross-platform system tray app for kanata.
