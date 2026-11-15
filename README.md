# Pip

A tiny floating pill for the edge of your Mac screen. It watches your AI chat apps (Claude, Amp, Grok, ChatGPT, or anything you add), pops a bubble when one finishes while you are somewhere else, and lets you jump back with one click.

- **Pip (the face)** is a little square face at the top of the strip: eyes closed when nothing runs, watching with a waving antenna while an app is thinking, and smiling with a hop when something is done. Click it and the monitor panel slides out from behind the strip: one card per app with its chat title and a Working or Ready badge. The arrow in the panel hops to the newest finished chat and the gear opens settings. Click a card to switch to it; click anywhere else to tuck the panel away. When a chat finishes while the panel is closed, only that chat's card slides out next to its icon, with Tap back. Drag it to either screen edge. Right-click for settings.
- **Rows** are your apps, softly faded while quiet. Three hopping dots mean working; a pink dot means finished and not seen yet. Hover for status and the chat title; click to switch.
- **+** adds any open app, or any app from /Applications.

## Install

Build on your Mac (needs Xcode or the Command Line Tools):

```sh
./make-app.sh
cp -R build/Pip.app /Applications/
open /Applications/Pip.app
```

Or unzip a prebuilt `Pip.zip`, move `Pip.app` to /Applications, and clear the download flag once, because it is not notarized:

```sh
xattr -dr com.apple.quarantine /Applications/Pip.app
```

On first launch, allow Pip in **System Settings → Privacy & Security → Accessibility**. Pip reads other apps' buttons through it; nothing leaves your Mac.

`make-app.sh` signs with your **Apple Development** certificate when the keychain has one (or `PIP_SIGN_ID`), so the permission survives rebuilds. With ad-hoc signing every rebuild counts as a new app: remove the old Pip entry in Accessibility and add the new one.

## How it knows an app is done

Every 1.5 seconds Pip looks for a **Stop** button in each tracked app's window (chat apps show one while they generate). When it disappears, the app is done. A new number on the app's Dock badge also counts.

Apps that list conversations with a status, like the Claude app's sidebar ("Fix the login bug · Running"), are tracked per conversation: the card shows which ones are running, and when one finishes Pip says "<that conversation> is ready!" even while others keep going.

If an app never shows as working, right-click Pip → **Copy Detection Report** while it is generating to see the buttons Pip can see. Or write the report to a file:

```sh
open -n -W /Applications/Pip.app --args --report ~/Desktop/pip-report.txt --tree
```

`--tree` adds each app's accessibility tree (roles, labels, and short status texts; message bodies are left out).

## Hooks for CLI agents

Anything on your Mac can report to Pip:

```sh
curl -s "http://127.0.0.1:47321/working?app=Claude%20Code&open=com.apple.Terminal"
curl -s "http://127.0.0.1:47321/done?app=Claude%20Code&note=Tests%20pass&open=com.apple.Terminal"
```

`app` names the row (new names get their own row), `open` is the app to bring forward on click, `note` shows in the bubble. `/idle` clears a row.

## Privacy and security

- Pip sends nothing anywhere and stores only your app list, position, and settings.
- With the Accessibility permission it reads the window titles and button labels of the apps you track, and the Dock badges. It never clicks or types in other apps, but macOS grants that permission broadly, so only run a build you trust: building from this source with `./make-app.sh` is the safest.
- The hook listens on 127.0.0.1 only, so other computers cannot reach it. It refuses requests from web browsers, so websites you visit cannot fake a "done".
