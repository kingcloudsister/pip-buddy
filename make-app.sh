#!/bin/bash
# Builds Pip.app (Apple silicon + Intel) into build/ and zips it.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
# Builds record source paths for debugging; map this folder to "." so the app never names the builder's folders.
FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
swift build -c release "${ARCHS[@]}" "${FLAGS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" "${FLAGS[@]}" --show-bin-path)/Pip"
APP=build/Pip.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pip"
# Drop debug symbols: they list the object files' full paths on the build machine.
strip -S -x "$APP/Contents/MacOS/Pip"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi
# Version: VERSION=1.2.0 ./make-app.sh stamps it into the app (release.sh does this).
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
# Signing: the self-signed "Pip Buddy" key when this Mac has it (see RELEASING.md), so macOS keeps Pip's
# Accessibility permission across updates and Pip can check that an update really came from that key.
# Personal certificates (Apple Development) are never used: they carry their owner's name and email.
# Without the key, the app is signed ad-hoc, which works but needs Accessibility re-allowed per build.
SIGN_ID="${PIP_SIGN_ID:-$(security find-identity -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Pip Buddy".*/\1/p' | head -1)}"
codesign --force --timestamp=none --sign "${SIGN_ID:--}" "$APP"
if [ -n "$SIGN_ID" ]; then echo "Signed with: Pip Buddy key"; else echo "Signed with: ad-hoc"; fi
if codesign -dvv "$APP" 2>&1 | /usr/bin/grep -qi '@'; then echo "Refusing: the signature contains an email address" >&2; exit 1; fi
if LC_ALL=C /usr/bin/grep -a -q -E "/Users/[A-Za-z0-9]|$(whoami)" "$APP/Contents/MacOS/Pip"; then
  echo "Refusing: the app contains a path or user name from this Mac" >&2; exit 1
fi
ditto -c -k --keepParent "$APP" build/Pip.zip
echo "Built $APP and build/Pip.zip"
