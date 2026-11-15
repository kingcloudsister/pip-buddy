#!/bin/bash
# Builds Pip.app (Apple silicon + Intel) into build/ and zips it.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Pip"
APP=build/Pip.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pip"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi
# Sign with a real certificate when there is one: macOS then keeps Pip's Accessibility permission
# across rebuilds. Ad-hoc signing ("-") works too, but every rebuild has to be allowed again.
SIGN_ID="${PIP_SIGN_ID:-$(security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Signed with: ${SIGN_ID:-ad-hoc}"
ditto -c -k --keepParent "$APP" build/Pip.zip
echo "Built $APP and build/Pip.zip"
