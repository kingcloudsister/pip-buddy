# Pip

A tiny floating pill for the edge of your Mac screen. It watches your AI chat apps (Claude, Amp, Grok, ChatGPT, or anything you add), pops a bubble when one finishes while you are somewhere else, and lets you jump back with one click.

- **Pip (the face)** is a little square face at the top of the strip: eyes closed when nothing runs, watching with a waving antenna while an app is thinking, and smiling with a hop when something is done. Click it and the monitor panel slides out from behind the strip: one card per app with its chat title and a Working or Ready badge. The arrow in the panel hops to the newest finished chat and the gear opens settings. Click a card to switch to it; click anywhere else to tuck the panel away. When a chat finishes while the panel is closed, only that chat's card slides out next to its icon, with Tap back. Drag it by any part of the strip; it snaps to the nearest edge: left, right, or the top of the screen, where it lies flat and cards drop down from it. The small chevron at the end folds it down to just the face (a pink dot on the face means something finished). Right-click for settings, Minimize to Face, and Move To.
- **Rows** are only the apps in the middle of something, or that just finished and you haven't looked yet; open but quiet apps stay hidden, so most of the time the strip is just the face. Three hopping dots mean working; a small number means several chats are running in that app at once; a pink dot means finished and not seen yet. Hover for each chat's title and what it is doing now ("Now: Running the tests · 4 min"); click to jump straight to that chat (for Claude, Pip opens the chat itself, switching between Chat and Code if needed).
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

## Ready, then your turn

A finished chat stays on the strip until you pick it back up, so a quick look doesn't make it vanish:

- **Ready** (pink dot, READY card): it finished and you haven't looked yet.
- **Your turn** (dashed tile, hollow ring): you spent at least 15 seconds in that app (for Claude, on that chat), then left. The card keeps the chat's name, the last thing it did, and how long it has waited.
- After 10 minutes away, Pip nudges once: "Still waiting on you".
- It leaves when that chat runs again (you replied), when you right-click → **Done with This**, or after 8 hours.

Every change is logged to `~/Library/Logs/Pip.log` (names and states only) so a missed finish can be traced.

## How it knows an app is done

Every 1.5 seconds Pip looks for a **Stop** button in each tracked app's window (chat apps show one while they generate). When it disappears, the app is done. A new number on the app's Dock badge also counts.

Apps that list conversations with a status, like the Claude app's sidebar ("Fix the login bug · Running"), are tracked per conversation: the panel shows one card per running chat, with the step Claude is on for the chat that is open on screen, and when one finishes Pip says "<that conversation> is ready!" even while others keep going.

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
- With the Accessibility permission it reads the window titles and button labels of the apps you track, and the Dock badges. The one thing it ever presses in another app is a chat's row in the sidebar (and Claude's Chat/Code switch), and only when you click that chat in Pip. It never types. macOS grants this permission broadly, so only run a build you trust: building from this source with `./make-app.sh` is the safest.
- The hook listens on 127.0.0.1 only, so other computers cannot reach it. It refuses requests from web browsers, so websites you visit cannot fake a "done".
