# Pip

<img src="Tools/icon-preview.png" width="128" alt="Pip's icon: a smiling square face with an antenna">

A tiny strip on the edge of your Mac screen that keeps an eye on your AI chats (Claude, Amp, Grok, ChatGPT, or any app you add). When one finishes while you're somewhere else, Pip pops out a card, and one click takes you straight back to that chat.

- **The face** at the top sleeps when nothing runs, watches while something works, and smiles and hops when something is done. Click it for the panel with every chat that's running or waiting on you.
- **Tiles** show every agent app that's open, with its status, until you quit it: three hopping dots mean working, a small number means several chats at once, a pink dot means ready, a dashed outline means it's your turn. Quiet apps just sit there.
- **Hover** a tile to see each chat's name and what it's doing now ("Now: Running the tests · 4 min"). **Click** to jump to that chat; for Claude, Pip opens the chat itself.
- **Drag** the strip to the left, right, or top edge of the screen. The chevron at the end folds it down to just the face. Right-click for settings.

## Download and install

1. Download **Pip.zip** from the [latest release](../../releases/latest) and unzip it.
2. Move **Pip.app** into your **Applications** folder.
3. Open it. Pip isn't from the App Store, so macOS stops it the first time:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Pip.
   - Or run this once in Terminal: `xattr -dr com.apple.quarantine /Applications/Pip.app`
4. Allow Pip in **System Settings → Privacy & Security → Accessibility**. That's how it sees whether a chat is still working. See [Privacy](#privacy) for exactly what it reads.

Needs macOS 14 or later, on Apple silicon or Intel.

### Updates

Pip checks this repo for a new release when it starts and every few hours. When there is one, an **↓** tile appears on the strip. Click it, and Pip downloads the update, checks it's signed with Pip's release key, installs it, and restarts. Your settings and Accessibility permission stay as they are.

Right-click Pip for **Check for Updates…**, or to turn automatic checks off.

## Ready, then your turn

A finished chat stays on the strip until you pick it back up, so a quick glance doesn't make it vanish:

- **Ready** (pink dot): it finished and you haven't looked yet.
- **Your turn** (dashed tile, hollow ring): you looked for at least 15 seconds, then left. The card keeps the chat's name, the last thing it did, and how long it has waited.
- After 10 minutes away, Pip nudges once: "Still waiting on you".
- It goes away when that chat runs again, when you right-click → **Done with This**, or after 8 hours.

## Finding agents on its own

You don't have to add apps. Every few seconds Pip glances at one or two running apps it doesn't watch yet, taking turns, and looks for an agent at work:

- **Apps and browsers:** a short **Stop** / **Stop generating** / **Interrupt** button, or a chat marked **Running**.
- **Terminals** (Terminal, iTerm2, Ghostty, Warp, kitty and others): an agent's busy line such as **"esc to interrupt"** or **"esc to cancel"** (Claude Code, Codex, Gemini CLI). Each terminal window with a working agent gets its own card, named after the task in the window title, and clicking it brings that window forward.

When it finds one, that app joins the strip and shows up whenever something is working. Pip sees windows on every desktop, including full-screen apps. Music, video, system apps and Xcode are skipped, since their "Stop" means something else. Right-click an app → **Don't Watch This App** to keep it out for good, or turn off **Find Agents Automatically** in the menu.

## How it knows a chat is done

Every 1.5 seconds Pip looks at the apps you track. Chat apps show a **Stop** button while they generate; when it disappears, the chat is done. A new number on an app's Dock badge counts too. Apps that list their chats with a status, like the Claude app's sidebar ("Fix the login bug · Running"), are followed chat by chat.

**Grok Bot** runs its bots remotely, so Pip follows them through Grok Bot's own local list of bots, even with its window closed: a bot is working while your newest message has no reply yet, and it's ready when a reply arrives. If a bot replies more than once to one task, each reply pops a card.

If an app never shows as working, right-click Pip → **Copy Detection Report** while it generates, or write the report to a file:

```sh
open -n -W /Applications/Pip.app --args --report ~/Desktop/pip-report.txt --tree
```

## Hooks for scripts and CLI agents

Anything on your Mac can report to Pip:

```sh
curl -s "http://127.0.0.1:47321/working?app=My%20Agent&open=com.apple.Terminal"
curl -s "http://127.0.0.1:47321/done?app=My%20Agent&note=Tests%20pass&open=com.apple.Terminal"
```

`app` names the tile, `open` is the app to bring forward on click, `note` shows on the card. `/idle` clears it.

## Privacy

Everything Pip knows stays on your Mac.

- **What it reads:** with the Accessibility permission, the window titles, button labels and chat names of the apps you track, plus Dock badges. To find agents it also glances at other running apps' buttons, and at the text on screen in terminal windows, only to look for a busy line like "esc to interrupt"; nothing from it is kept. To see windows on other desktops it uses the same window lookup as window-switcher apps. For Grok Bot, the bot names, unread counts and message IDs in Grok Bot's local list (never the messages, and never its saved secrets). Not the messages themselves, in any app.
- **What it presses:** only a chat's row in an app's sidebar (and Claude's Chat/Code switch), and only when you click that chat in Pip. It never types.
- **What it stores:** your app list, its position and settings (in its preferences), and a log of state changes at `~/Library/Logs/Pip.log` (app and chat names, no message text). None of it is ever uploaded.
- **What goes over the internet:** only the update check, a plain request to GitHub for this repo's latest release, and the download when you install one. No account, no tracking. Turn it off in the right-click menu.
- **The hook** listens on 127.0.0.1 only and refuses requests from web browsers, so websites can't fake a "done".

## Build it yourself

Needs Xcode or the Command Line Tools:

```sh
./make-app.sh
cp -R build/Pip.app /Applications/
```

A copy you build yourself is signed ad-hoc, so it can't install release updates (they're checked against Pip's release key), and macOS asks for Accessibility again after each rebuild. To publish releases, see [RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE). The name "Pip" and its icon are not part of the license grant.
