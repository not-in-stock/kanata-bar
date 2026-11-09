#!/usr/bin/env bash
#
# dev-doctor.sh — a read-only snapshot of this machine's kanata-bar dev setup.
#
# Installs and changes NOTHING; needs no sudo. Prints the facts a session needs
# before building/testing/developing here — toolchain, nix, repos, kanata config
# and device-name match, SIP — and ends with a build/test/lint readiness verdict
# plus the fix for anything red. Written because the setup differs per machine
# (M1/Sequoia baseline vs M5/macOS 27); see wiki reference/dev-machine-m5.
#
# Usage: scripts/dev-doctor.sh
#
set -uo pipefail

# ---- presentation -----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; Z=$'\033[0m'
else
  B=''; DIM=''; G=''; Y=''; R=''; Z=''
fi
section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn() { printf '  %s▲%s %s\n' "$Y" "$Z" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$Z" "$1"; }
kv()   { printf '    %s%-22s%s %s\n' "$DIM" "$1" "$Z" "$2"; }

# Track readiness; each flag is "ok"/"no"/"?" with a hint.
build_ok=no; test_ok=no; lint_ok=no
build_hint=''; test_hint=''; lint_hint=''

# ---- system -----------------------------------------------------------------
section "System"
kv "macOS" "$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
kv "Darwin / arch" "$(uname -r) / $(uname -m)"
kv "host / user" "$(scutil --get LocalHostName 2>/dev/null || hostname) / $(whoami)"

# ---- toolchain --------------------------------------------------------------
section "Toolchain (build with system /usr/bin/swiftc, never nix swiftc)"
active="$(xcode-select -p 2>/dev/null)"
kv "xcode-select -p" "${active:-<none>}"
swiftc_v="$(/usr/bin/swiftc --version 2>/dev/null | grep -oiE 'swift version [0-9.]+' | head -1)"
if [ -n "$swiftc_v" ]; then ok "/usr/bin/swiftc — $swiftc_v"; build_ok=ok
else bad "/usr/bin/swiftc not working"; build_hint="install Command Line Tools or Xcode"; fi

xcodeapp="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
if [ -n "$xcodeapp" ]; then
  kv "Xcode.app" "$xcodeapp ($(defaults read "$xcodeapp/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null))"
fi

# XCTest is the test gate; CommandLineTools ships none. `xcrun --find xctest`
# resolves only when a full Xcode toolchain is active (a bare `swiftc -typecheck`
# can't see XCTest.framework even with Xcode, so don't probe that way).
if xcrun --find xctest >/dev/null 2>&1; then
  ok "XCTest available — swift test will run"; test_ok=ok
else
  bad "XCTest missing (Command Line Tools active, not Xcode)"
  test_hint="sudo xcode-select -s ${xcodeapp:-/Applications/Xcode.app} && sudo xcodebuild -license accept"
fi

# swiftlint (nix) needs sourcekitd from an ACTIVE Xcode toolchain, else it crashes.
case "$active" in
  *Xcode*) ok "Xcode toolchain active — nix swiftlint can load sourcekitd"; lint_ok=ok ;;
  *) bad "swiftlint will crash (needs Xcode active for sourcekitd)"
     lint_hint="same xcode-select -s fix as above" ;;
esac

# ---- nix --------------------------------------------------------------------
section "Nix"
if command -v nix >/dev/null 2>&1; then ok "nix $(nix --version 2>/dev/null | grep -oE '[0-9.]+' | head -1)"; else bad "nix not found"; fi
command -v darwin-rebuild >/dev/null 2>&1 && ok "darwin-rebuild present" || warn "darwin-rebuild not found"
command -v swiftlint >/dev/null 2>&1 || kv "swiftlint" "not global — run via: nix-shell -p swiftlint --run 'swiftlint ...'"

# ---- repos ------------------------------------------------------------------
section "Repos"
ws="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # workspace holding kanata-bar
for d in "$ws/kanata-bar" "$ws/kanata-darwin" "$ws/kanata-bar-wiki" "$HOME/.nix-config"; do
  name="${d/#$HOME/~}"
  if [ -d "$d/.git" ]; then
    br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    dirty="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [ "$dirty" = 0 ] && ok "$name ($br, clean)" || warn "$name ($br, $dirty uncommitted)"
  else bad "$name MISSING"; fi
done

# nix-config host whose flake entry owns the current user (best-effort).
nc="$HOME/.nix-config"
if [ -f "$nc/flake.nix" ]; then
  host="$(grep -nE "home-manager.users.$(whoami)\b" "$nc/flake.nix" 2>/dev/null | head -1)"
  [ -n "$host" ] && kv "flake host (this user)" "$(grep -B20 "home-manager.users.$(whoami)" "$nc/flake.nix" | grep -oE 'darwinConfigurations\."[^"]+"' | tail -1)"
fi

# ---- kanata -----------------------------------------------------------------
section "kanata"
command -v kanata >/dev/null 2>&1 && ok "kanata — $(command -v kanata)" || warn "kanata not in PATH"
if [ -d "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice" ]; then
  ok "Karabiner VHID daemon present"; else warn "Karabiner VHID daemon absent (kanata output needs it)"; fi
if pgrep -x kanata >/dev/null 2>&1; then ok "kanata is running (pid $(pgrep -x kanata | head -1))"; else kv "kanata process" "not running"; fi

cfg="$HOME/.config/kanata/kanata.kbd"
if [ -e "$cfg" ]; then
  real="$(readlink -f "$cfg" 2>/dev/null || echo "$cfg")"
  kv "config" "$real"
  # device-name match: every name in macos-dev-names-include should match a
  # connected keyboard (kanata emits its own WARN for misses at startup).
  incl="$(awk '/macos-dev-names-include/{f=1} f{print} /\)/{if(f)exit}' "$real" 2>/dev/null \
          | grep -oE '"[^"]+"' | tr -d '"')"
  # Match by substring against the raw keyboard listing — hidutil's Product
  # column has spaces, so column-splitting is unreliable; the names are distinct.
  connected="$(hidutil list --matching '{"PrimaryUsagePage":1,"PrimaryUsage":6}' 2>/dev/null)"
  if [ -n "$incl" ]; then
    while IFS= read -r nm; do
      [ -z "$nm" ] && continue
      if printf '%s' "$connected" | grep -qF "$nm"; then ok "device matches: \"$nm\""
      else warn "in config but not connected now: \"$nm\" (won't remap until plugged in / name fixed)"; fi
    done <<< "$incl"
  fi
else warn "no $cfg (kanata config not linked)"; fi

# kanata-bar enable state (local-testing wants enable=false)
kbnix="$(grep -rl 'kanata-bar' "$nc"/hosts/*/kanata.nix 2>/dev/null | head -1)"
if [ -n "$kbnix" ]; then
  en="$(grep -A1 'kanata-bar' "$kbnix" | grep -oE 'enable = (true|false)' | head -1)"
  kv "nix kanata-bar" "${en:-?}  ($([ "${en##* }" = false ] && echo 'local testing: hand-build into /Applications' || echo 'nix installs the app'))"
fi

# ---- SIP --------------------------------------------------------------------
section "SIP"
sip="$(csrutil status 2>/dev/null)"
if printf '%s' "$sip" | grep -qi 'enabled\.'; then ok "SIP fully enabled"
elif printf '%s' "$sip" | grep -qi 'Custom Configuration'; then
  warn "SIP partially disabled (Custom Configuration — yabai profile)"
  printf '%s\n' "$sip" | grep -iE 'Protections|Restrictions|Signing|Root' | sed 's/^/      /'
  kv "caveat" "helper/supervise privilege+signing checks here can be false positives — verify on full SIP"
else kv "SIP" "$(printf '%s' "$sip" | head -1)"; fi

# ---- verdict ----------------------------------------------------------------
section "Readiness"
v() { if [ "$2" = ok ]; then ok "$1: ready"; else bad "$1: NOT ready — $3"; fi; }
v "build  (swift build -c release, strict + warnings-as-errors)" "$build_ok" "$build_hint"
v "test   (swift test / XCTest)" "$test_ok" "$test_hint"
v "lint   (swiftlint --strict via nix-shell)" "$lint_ok" "$lint_hint"
if [ "$build_ok" = ok ] && [ "$test_ok" = ok ] && [ "$lint_ok" = ok ]; then
  printf '\n%s%sAll three CI gates can run locally.%s\n' "$B" "$G" "$Z"
fi
