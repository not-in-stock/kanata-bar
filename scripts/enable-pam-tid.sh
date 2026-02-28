#!/bin/bash
# Enable TouchID for sudo via /etc/pam.d/sudo_local.
# This file survives macOS updates (unlike /etc/pam.d/sudo).
#
# USE AT YOUR OWN RISK. The script modifies a system PAM configuration file.
# A backup is created before any changes. If anything goes wrong, restore it:
#   sudo cp /etc/pam.d/sudo_local.bak /etc/pam.d/sudo_local

set -euo pipefail

PAM_FILE="/etc/pam.d/sudo_local"
PAM_LINE="auth       sufficient     pam_tid.so"

# Check that pam_tid.so module exists on this system
if [ ! -f /usr/lib/pam/pam_tid.so ] && [ ! -f /usr/lib/pam/pam_tid.so.2 ]; then
    echo "Error: pam_tid.so not found. TouchID for sudo is not supported on this system."
    exit 1
fi

# Already enabled — nothing to do
if [ -f "$PAM_FILE" ] && grep -q "pam_tid.so" "$PAM_FILE"; then
    echo "TouchID for sudo is already enabled in $PAM_FILE"
    exit 0
fi

echo "This will add pam_tid.so to $PAM_FILE (requires sudo)."
echo ""

# Show what will happen
if [ -f "$PAM_FILE" ]; then
    echo "Existing $PAM_FILE will be backed up and the following line appended:"
else
    echo "A new file $PAM_FILE will be created with:"
fi
echo "  $PAM_LINE"
echo ""
read -r -p "Continue? [y/N] " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Backup existing file before any modification
if [ -f "$PAM_FILE" ]; then
    sudo cp "$PAM_FILE" "${PAM_FILE}.bak"
    echo "Backup saved to ${PAM_FILE}.bak"
    sudo sh -c "echo '$PAM_LINE' >> '$PAM_FILE'"
else
    sudo sh -c "echo '$PAM_LINE' > '$PAM_FILE'"
fi

# Verify the result is a valid PAM file (non-empty, contains our line)
if [ ! -s "$PAM_FILE" ] || ! grep -q "pam_tid.so" "$PAM_FILE"; then
    echo "Error: verification failed. Restoring backup..."
    if [ -f "${PAM_FILE}.bak" ]; then
        sudo cp "${PAM_FILE}.bak" "$PAM_FILE"
    else
        sudo rm -f "$PAM_FILE"
    fi
    echo "Restored. No changes were made."
    exit 1
fi

echo ""
echo "Done. TouchID for sudo is now enabled."
echo "Set pam_tid = \"auto\" in ~/.config/kanata-bar/config.toml to use it."
