#!/bin/bash
# Publishes a new version of Pip as a GitHub release that everyone's Pip will offer as an update.
#   ./release.sh 1.1.0 "Cards now show the last step"
# Needs: the "Pip Buddy" signing key in this Mac's keychain, and `gh` signed in to the repo's owner account.
set -euo pipefail
cd "$(dirname "$0")"

V="${1:?usage: ./release.sh <version like 1.2.0> [\"what changed\"]}"
NOTES="${2:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.0" >&2; exit 1; }
REPO=$(/usr/libexec/PlistBuddy -c "Print :PipUpdateRepo" Info.plist)
OWNER="${REPO%%/*}"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token -u "$OWNER" 2>/dev/null || true)}"
[ -n "$GH_TOKEN" ] || { echo "Sign in to GitHub as $OWNER first: gh auth login" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
security find-identity -p codesigning | grep -q '"Pip Buddy"' || {
  echo "The Pip Buddy signing key isn't in this Mac's keychain; see RELEASING.md." >&2; exit 1; }
CUR=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if git rev-parse -q --verify "refs/tags/v$V" >/dev/null; then echo "v$V is already released." >&2; exit 1; fi
if [ "$V" != "$CUR" ] && [ "$(printf '%s\n%s\n' "$CUR" "$V" | sort -V | tail -1)" != "$V" ]; then
  echo "$V is older than the current $CUR." >&2; exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $V" Info.plist
VERSION="$V" ./make-app.sh

# What ships must carry nothing about the person building it.
SIG=$(codesign -dvv build/Pip.app 2>&1)
echo "$SIG" | grep -q 'Authority=Pip Buddy' || { echo "Not signed with the Pip Buddy key." >&2; exit 1; }
if echo "$SIG" | grep -qi '@' || strings -a build/Pip.app/Contents/MacOS/Pip | grep -q -i -E "/Users/|$(whoami)"; then
  echo "The build contains a path, user name or email; not publishing." >&2; exit 1
fi

git add Info.plist
git diff --cached --quiet || git commit -qm "Release $V"
git tag "v$V"
git push -q origin HEAD "v$V"
gh release create "v$V" build/Pip.zip --repo "$REPO" --title "Pip $V" --notes "${NOTES:-Pip $V}"
echo "Published Pip $V. Everyone's Pip will offer it within 6 hours (or now, via Check for Updates)."
