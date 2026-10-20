#!/bin/bash
# BrowserCast one-click installer (macOS .command — double-click in Finder).
# Downloads the latest source from GitHub and runs install.sh.
# First run: macOS may block it as an internet download — right-click the
# file → Open → Open, once. After that, double-click works.
set -u
echo "=== BrowserCast installer ==="
TMP="$(mktemp -d)"
echo "Downloading latest source…"
if ! curl -fsSL -o "$TMP/browsercast.zip" "https://github.com/sureshsankaran/browsercast/archive/refs/heads/main.zip"; then
  echo "Download failed — check the network connection and try again."
  echo "Press any key to close."
  read -n 1 -s
  exit 1
fi
ditto -x -k "$TMP/browsercast.zip" "$TMP"
bash "$TMP/browsercast-main/install.sh"
echo ""
echo "Install finished. You can close this window."
echo "Press any key to close."
read -n 1 -s
