#!/bin/bash
# Builds an optimized (Release) NotchDeck for your own daily use and installs it in /Applications.
#
#   ./Scripts/install-local.sh
#
# Local builds are ad-hoc signed (no Developer ID), so this build turns the hardened runtime off;
# otherwise macOS refuses to load the bundled Sparkle framework ("different Team IDs") and the app
# won't open. Public releases are signed with a Developer ID instead (see distribution.md, local only).
#
# After each install, macOS may ask once more for Keychain access (choose "Always Allow") and for
# permissions like Calendar or Spotify control, because every ad-hoc build looks like a new app to it.
# Settings, the license and saved API keys carry over (they belong to the bundle ID).
#
# License: your own Mac is activated (master key) with a receipt signed by the DEVELOPMENT signing key,
# which only Debug builds trust. This personal build trusts the same public DEV key (from
# Config/NotchDeck.xcconfig; public, not a secret), so it shows "Master (unlimited)" instead of falling
# back to the trial. It also uses the local development license server (http://127.0.0.1:8787), so you
# can (re)activate with your master key: run `node Server/license-proxy/dev-server.mjs`, then
# Settings → License. Once activated it works offline; the server isn't needed afterwards.
# Tester builds (package-for-testers.sh) don't get any of this.

set -euo pipefail
# Note: variables are always written as ${NAME}. macOS's bash 3.2 reads non-ASCII text right after a bare
# $NAME (like "…") as part of the variable name, which failed under `set -u`.
cd "$(dirname "$0")/.."

APP="NotchDeck"
BUILT="build/PerfRelease/Build/Products/Release/${APP}.app"
DEST="/Applications/${APP}.app"
# The DEV public key, so the receipt from your master-key activation verifies in this build.
DEV_PUBLIC_KEY="$(sed -n 's/^LICENSE_PUBLIC_KEY\[config=Debug\][[:space:]]*=[[:space:]]*//p' Config/NotchDeck.xcconfig | tr -d '[:space:]')"
if [ -z "${DEV_PUBLIC_KEY}" ]; then
  echo "Couldn't read the DEV LICENSE_PUBLIC_KEY from Config/NotchDeck.xcconfig." >&2
  exit 1
fi

echo "==> Building optimized ${APP} (Release)..."
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/PerfRelease ENABLE_HARDENED_RUNTIME=NO \
  LICENSE_PUBLIC_KEY="${DEV_PUBLIC_KEY}" LICENSE_API_BASE_URL="http://127.0.0.1:8787" -quiet build

if [ ! -d "${BUILT}" ]; then
  echo "Build finished but ${BUILT} is missing." >&2
  exit 1
fi

# Quit the running copy only after a successful build, so NotchDeck is gone for a moment at most.
# (A plain quit signal, not AppleScript: scripting NotchDeck from Terminal would trigger a macOS
# Automation permission prompt. NotchDeck re-applies its per-session permission reset at launch.)
if pgrep -x "${APP}" >/dev/null; then
  echo "==> Quitting the running ${APP}..."
  killall "${APP}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x "${APP}" >/dev/null || break
    sleep 0.25
  done
  pkill -9 -x "${APP}" 2>/dev/null || true
fi

echo "==> Installing to ${DEST}..."
rm -rf "${DEST}"
cp -R "${BUILT}" "${DEST}"

echo "==> Opening ${APP}..."
open "${DEST}"
echo "Done. ${APP} is installed in /Applications (Launch at Login: toggle it off and on once in Settings → General)."
