#!/bin/bash
# Packages NotchDeck for friends to try: a universal (Apple silicon + Intel) Release build with a longer
# free trial, zipped with a short "how to open it" note. Output goes to TestTrial/ (git-ignored).
#
#   ./Scripts/package-for-testers.sh                 # 90-day trial
#   ./Scripts/package-for-testers.sh --trial-days 30
#
# Not for public release: the app is ad-hoc signed (no Developer ID, not notarized), so testers have to
# allow it once in System Settings (the included note explains how). License activation isn't configured
# in this build; the long trial is what gives testers time. Your API keys, license and settings are not
# included (they live in your own Keychain and preferences).

set -euo pipefail
# Variables are always written as ${NAME}: macOS's bash 3.2 reads non-ASCII text right after a bare
# $NAME as part of the variable name.
cd "$(dirname "$0")/.."

TRIAL_DAYS=90
while [ $# -gt 0 ]; do
  case "$1" in
    --trial-days)
      TRIAL_DAYS="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (use --trial-days N)" >&2
      exit 1
      ;;
  esac
done
if ! [[ "${TRIAL_DAYS}" =~ ^[0-9]+$ ]] || [ "${TRIAL_DAYS}" -lt 1 ] || [ "${TRIAL_DAYS}" -gt 365 ]; then
  echo "--trial-days must be a whole number from 1 to 365." >&2
  exit 1
fi

DERIVED="build/Testers"
BUILT="${DERIVED}/Build/Products/Release/NotchDeck.app"
OUT_DIR="TestTrial"

echo "==> Building NotchDeck for testers (universal, ${TRIAL_DAYS}-day trial)..."
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${DERIVED}" \
  ENABLE_HARDENED_RUNTIME=NO TRIAL_DAYS="${TRIAL_DAYS}" -quiet build

[ -d "${BUILT}" ] || { echo "Build finished but ${BUILT} is missing." >&2; exit 1; }

echo "==> Checking the build..."
ARCHS="$(lipo -archs "${BUILT}/Contents/MacOS/NotchDeck")"
PLIST_DAYS="$(/usr/libexec/PlistBuddy -c 'Print :NDTrialDays' "${BUILT}/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${BUILT}/Contents/Info.plist")"
codesign --verify --deep --strict "${BUILT}"
[ "${PLIST_DAYS}" = "${TRIAL_DAYS}" ] || { echo "Trial length in the app is ${PLIST_DAYS}, expected ${TRIAL_DAYS}." >&2; exit 1; }
echo "    architectures: ${ARCHS} | trial: ${PLIST_DAYS} days | version: ${VERSION} | signature: OK"

NAME="NotchDeck-${VERSION}-${TRIAL_DAYS}day-trial"
STAGE="${OUT_DIR}/${NAME}"
ZIP="${OUT_DIR}/${NAME}.zip"
rm -rf "${STAGE}" "${ZIP}"
mkdir -p "${STAGE}"
# ditto keeps the embedded Sparkle framework's symlinks (plain `zip` can break them, and the signature).
ditto "${BUILT}" "${STAGE}/NotchDeck.app"

cat > "${STAGE}/How to open NotchDeck.txt" <<EOF
NotchDeck ${VERSION} (test build, free for ${TRIAL_DAYS} days)
==================================================

Thanks for trying NotchDeck! It lives in your MacBook's notch: music, files, calendar,
AI chat, a system monitor and more. Hover over the notch (or click it) to open it.

You need: macOS 14 (Sonoma) or newer. It works best on a MacBook with a notch;
on other Macs it shows a small pill at the top of the screen.


INSTALL (about a minute, one time)
----------------------------------
1. Drag NotchDeck.app into your Applications folder.
2. Open it. macOS will say it can't verify the app ("NotchDeck Not Opened").
   That's because this is a test build that isn't registered with Apple yet.
   Click "Done".
3. Open System Settings > Privacy & Security, scroll down to
   "NotchDeck was blocked to protect your Mac", click "Open Anyway",
   and enter your Mac password. NotchDeck opens.

If step 3 doesn't show the button, open Terminal and run:
   xattr -dr com.apple.quarantine /Applications/NotchDeck.app
then open NotchDeck again.


GOOD TO KNOW
------------
- Permissions: NotchDeck asks before using Calendar, controlling Spotify / Music,
  Bluetooth, your Downloads folder or the camera. By default it asks again every
  time it starts; turn that off in Settings > General if it's too much.
- macOS may ask NotchDeck to use your "Keychain" (that's where it keeps API keys
  and the trial record). Choose "Always Allow".
- AI Chat needs your own API key (Claude, Gemini or another provider):
  Settings > AI & Agents.
- Settings: right-click the notch > Settings, or use the menu bar icon.
- Quit: right-click the notch > Quit NotchDeck.
- Updates: this test build doesn't update itself. I'll send you new versions.
- Remove it: quit NotchDeck and drag it from Applications to the Trash.

Please tell me what works, what breaks and what you'd change. Thank you!
EOF

ditto -c -k --keepParent "${STAGE}" "${ZIP}"
rm -rf "${STAGE}"

echo "Done: ${ZIP} ($(du -h "${ZIP}" | cut -f1 | xargs))"
echo "Send that zip (AirDrop, Messages, Google Drive, ...). It contains NotchDeck.app and 'How to open NotchDeck.txt'."
