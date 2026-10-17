#!/bin/zsh
# Builds Dockless.app. Usage: ./build.sh [--install]   (--install copies to /Applications and relaunches)
set -euo pipefail
cd "${0:A:h}"

# Universal binary (Apple silicon + Intel).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Dockless"
APP=build/Dockless.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Dockless"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity so macOS treats each rebuild as the same app.
IDENTITY=${DOCKLESS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no signing identity found, ad-hoc signing (permissions reset on every build)"
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Dockless || true
  sleep 1
  rm -rf /Applications/Dockless.app
  cp -R "$APP" /Applications/
  open /Applications/Dockless.app
  echo "installed /Applications/Dockless.app"
fi
