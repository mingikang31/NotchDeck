# NotchDeck — Things to Consider

The running notebook for this project: what exists, how to work it, what to watch out for, and
what's next. Kept up to date as each phase lands. The full product spec is
[`notchdeck_technical_specification.txt`](notchdeck_technical_specification.txt).

_Last updated: 2026-11-26, Phase 6 committed; Phase 7 (post-spec modules) built, needs hands-on check._

---

## 1. Roadmap status

| Phase | Scope | Status |
|---|---|---|
| 1 | Window shell: NotchPanel, NotchGeometry, hover/click animations, Classic Black + Frosted Glass | ✅ Done |
| 2 | SettingsStore, 6-tab Settings, global shortcuts, 7-day trial + license activation, Sparkle wiring | ✅ Done |
| 3 | Now Playing + visualizer, File Tray (drag in/out, AirDrop, zip), Calendar banner + meeting links | ✅ Done (confirmed) |
| 4 | Embedded AI Chat (Claude + Gemini streaming, Markdown, attachments, focus shortcut) | ✅ Done (Claude chat confirmed) |
| 5 | Claude Code & Codex agent hooks (127.0.0.1 server, hook installer, Approve/Deny card) | ✅ Done (Claude Code confirmed; Codex believed working) |
| 6 | Live Activities (battery, Bluetooth, Downloads), Pomodoro, To-Dos, Clipboard, Camera Mirror | ✅ Done (initial review OK; tweaks to come) |
| 7 | Post-spec: World Clock, Usage / token-cost tracker (AI Chat + Claude Code + Codex, MCP servers), Terminal, synced lyrics | ✅ Built (needs hands-on check) |
| ✗ | Menu bar overflow drawer | Not built: macOS 27 already has it (see §4) |
| + | System Monitor tab (CPU / GPU / memory, asitop/macmon-style), requested 2026-11-26 | ✅ Done (styles approved) |

---

## 2. How to work the app

### Build, run, test

```sh
# Build (Debug)
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -derivedDataPath build/DerivedData build

# Run
open build/DerivedData/Build/Products/Debug/NotchDeck.app

# Unit tests
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -derivedDataPath build/DerivedData test
```

Or open `NotchDeck.xcodeproj` in Xcode and press ⌘R / ⌘U. New `.swift` files dropped into
`NotchDeck/` or `NotchDeckTests/` are picked up automatically (synchronized folders); no project edits needed.

### Using it

- **No Dock icon.** NotchDeck is a menu bar agent app (`LSUIElement`). Look for the ▭ icon in the menu bar.
- **Open the notch:** hover the notch (it swells after ~150 ms, then opens), click it, or press **⌃⌥N**.
- **Close it:** move the pointer away (default), click outside, or press ⌃⌥N again. Escape only works
  once a text field in the notch has focus.
  - **Hover close delay** (Settings → General → Behavior, 0–500 ms like the open delay, default 200 ms): how long the pointer can
    be outside the open notch before it closes; coming back within that time keeps it open. Greyed out when
    *Collapse automatically* is "When clicking outside". (The hover *open* delay, 0–500 ms, default 150 ms,
    sits right above it.)
  - **When pointer-exit doesn't close it (on purpose):** opened by a *shortcut* (⌃⌥N, Open AI Chat, Open File
    Tray, Toggle Camera Mirror) or an approval card. It stays until you press the shortcut again or click
    outside. A *module* shortcut's hold ends as soon as you click a different tab; ⌃⌥N's hold covers every tab.
  - It also stays open while a text field holds **unsent text** (a chat draft, a to-do being typed). Once the
    field is empty (sent / cleared), moving away closes it again.
- **Shortcut hints follow your settings:** the chat's "… opens this chat from anywhere" names whatever key
  you recorded in Settings → Shortcuts (or says to set one), and updates immediately when you change it.
- **Quit / reopen:** right-click the notch → *Quit NotchDeck*, or Settings → General → *Quit NotchDeck*,
  or the menu bar icon → *Quit NotchDeck*. **The menu bar icon can be invisible:** when the menu bar has
  more icons than fit, macOS hides the overflow behind the notch. That's why Quit also lives on the notch
  and in Settings. Reopen with
  `open build/DerivedData/Build/Products/Debug/NotchDeck.app`, by double-clicking that app in Finder, or ⌘R in Xcode.
  Add `--args -notchdeck.debug.ephemeralSecureStore YES` to skip the Keychain prompt on rebuilt Debug builds.
- **Settings:** menu bar icon → Settings… (⌘,), or the gear in the expanded notch. If you hide the
  menu bar icon, open NotchDeck again from Finder/Spotlight to get Settings back.
- **Themes:** switch Classic Black / Frosted Glass live from the notch header, the menu, or Settings → Appearance.
- **Alignment check:** menu → *Show Geometry Outline* draws a 1 pt red line that should trace the physical notch edge.
- **Module tabs:** the icons across the top of the expanded notch switch modules. Order and on/off live in
  Settings → Modules. Modules from later phases show a "coming in Phase N" card.
- **Live activities (collapsed):** while music plays, the collapsed notch grows small "wings": album art on
  the left, visualizer on the right. A meeting within 15 minutes takes over with a countdown ("In 12m")
  and title. Priority: ongoing/imminent meeting (≤15 min, and the first 10 min of an ongoing one) →
  playing music → meeting within the hour.
- **Media:** play/pause/next/previous, drag the bar to scrub, speaker icon to switch the Mac's output device.
  Works with **Music** and **Spotify**. The first time, macOS asks to let NotchDeck control each player: click Allow.
- **File Tray:** drag files, images or text **anywhere onto the notch** (collapsed or open). It opens into the
  tray and shows "Release to add". Drag items back out to Finder/Slack/Mail; double-click opens; click selects; actions
  (AirDrop / Zip / Clear) apply to the selection, or everything if nothing is selected.
- **AI Chat:** press **⌥Space** anywhere: the notch opens tall with the cursor in the message field (your
  current app stays in front). Or click the ✨ tab. First add a key: Settings → AI & Agents → API Keys.
  - **Model pill** (top-left): every model your keys can use, fetched live from each provider (Claude Models
    API, Gemini model list, custom endpoint `/models`), grouped by provider. Default: Claude Opus 5.5.
    Your pick becomes the default for new chats. *Refresh Model Lists* is at the bottom of the menu.
  - **Other model IDs:** Settings → AI & Agents → Models → pick the provider, type the ID, **Add**.
  - **Shortcut:** ⌥Space by default; change it in Settings → AI & Agents (or Shortcuts). Pressing it again
    while the chat is open tucks it back into the notch.
  - **Return** sends, **Shift-Return** adds a line. **Esc** or clicking outside closes the notch (typing keeps
    it open even if the pointer leaves).
  - **Attach** (📎): capture a screen selection, paste from clipboard, choose files, or pick items from the
    File Tray. **⌘V** in the message field attaches copied images/files. Dropping files on the open chat
    attaches them.
  - Replies stream with Markdown, syntax-highlighted code (**Copy Code**), **Copy Response** on hover, a
    collapsible "Thought process" summary, **Retry** on errors, **History** (🕘) and **New Chat** (✎).
- **Claude Code & Codex approvals (Agent Hooks):** Settings → AI & Agents → **Install Claude Code Hook**
  and/or **Install Codex Hook** (once each). **Codex extra step:** open Codex, run `/hooks`, and trust both
  NotchDeck hooks (Codex skips new or changed hooks until you do; repeat after an *Update Hook*).
  From then on, in **new** sessions, whenever the agent would ask permission (run a command,
  edit or write a file, use an MCP tool…), the notch opens with an approval card showing the exact command,
  a red/green diff, or the file content:
  - **Approve** (⌘↩), **Deny** (Esc), or **Always Allow** (⌘⇧↩, when Claude Code offers a "don't ask again"
    rule). The keys work as soon as the card appears, with no click needed.
  - Several requests queue up ("+2 waiting"). If you close the notch, the collapsed pill says **Approve?**;
    hover or click it to get the card back.
  - Not answered within **2 minutes** → handed back; Claude Code asks in the terminal as usual.
  - Answering in the terminal instead also works; the card disappears.
  - When Claude Code finishes a task: a **chime** and a green **Done · project** pulse beside the notch
    (chime can be turned off).
  - **Send Test Request** (per agent, same Settings section) shows a sample card through the real server; nothing runs.
  - Shortcut **Approve Pending Agent Request** (Settings → Shortcuts) approves without touching the mouse.
- **System (CPU / GPU / memory):** the **System** tab (chip icon). Live, once per second while it's open:
  - **CPU** % with efficiency- and performance-cluster frequencies, and a bar per core grouped by cluster;
  - **GPU** % with frequency and watts; **Memory** used / total, swap;
  - a 2-minute trend for each; power (CPU / GPU / Neural Engine); memory-pressure and thermal status.
  No admin password, no helper. It samples only while the tab is visible, so it costs nothing otherwise.
  - **Refresh rate:** 250 ms / 500 ms / 1 s (default) / 2 s / 5 s, in **Settings → Modules → System Monitor**
    only (it was taken off the notch to reduce clutter). Applies immediately. The sparklines always span the last 2 minutes (samples are
    placed by time, so changing the rate mid-way doesn't distort them).
  - **CPU / GPU / memory style** (same settings group): *Cards* (the original tiles with sparklines),
    *Meter rows* (one aligned row each: meter, value, details, mini trend), *Area graphs* (tiles with a filled
    2-minute graph), *Minimal* (big numbers and slim meters, no boxes). Only those three top components change;
    the per-core bars and the power/status row are the same in every style.
  - **The notch fits the tab exactly:** no empty space below the last row, whichever style is picked.
- **Calendar:** open the Calendar tab and click *Connect Calendar* (macOS asks for access). Shows upcoming
  events grouped by day (Today / Tomorrow / …). With more than three, **scroll** (trackpad/wheel) through them;
  a fade at the bottom and "scroll for more" in the header show there's more. Green **Join** button for Zoom, Google Meet,
  Teams and Webex links. The ↻ button re-syncs now; the sliders button opens the calendar settings.
- **Choosing calendars:** Settings → Modules → Calendar → *Choose Calendars…* (grouped by account). Same place:
  range (next 24 h / 3 days / 7 days, default 3 days) and *Include all-day events* (default on).
- **Live Activities** (bolt tab): battery card (percent, charging state, time left / to full, live watts in or
  out, adapter rating, health and cycle count), connected Bluetooth devices with battery levels (AirPods L / R /
  case, Magic Keyboard / Mouse / Trackpad), and the last downloads.
  - **Pills beside the notch** for a few seconds: plugged in / unplugged / charged, low battery at 20 %, 10 %
    and 5 %, a device connecting (with its battery), a new download. Hover or click the notch while one shows
    and it opens on the matching tab.
  - **Downloads:** each row can be dragged straight into any app, AirDropped, added to the File Tray, or shown
    in Finder; double-click opens it. Only files that *finished* downloading count (browser temp names like
    `.crdownload` / `.download` / `.part` are ignored until they're renamed).
  - Turn each one on or off in Settings → Modules → Live Activities. The tab's height fits its content.
- **Pomodoro** (timer tab): ring countdown, Start / Pause / Resume, Skip, Reset, sessions today, dots for the
  cycle. While it runs (or is paused) the countdown sits beside the notch; urgent meetings and agent requests
  still take priority over it, and it takes priority over music. When a phase ends: a chime and a pill.
  Durations (focus 25, break 5, long break 15 min, long break every 4) and auto-start in Settings → Modules →
  Pomodoro. Shortcut: *Start / Pause Pomodoro* (record one in Settings → Shortcuts). A running timer survives
  a relaunch.
- **To-Dos** (checklist tab): type and press Return to add; click the circle to tick; double-click a title to
  edit (empty title deletes); hover → ✕ to delete; *Clear Done*. Finished items sink to the bottom. Saved to
  `~/Library/Application Support/NotchDeck/todos.json`.
- **Clipboard** (clipboard tab): the last 25 clips (text, images, copied files). Click one to put it back on
  the clipboard, then ⌘V. Memory only, never written to disk, cleared when NotchDeck quits. Password-manager
  copies are skipped. **Needs one macOS setting** to record by itself (see §4 Clipboard).
- **World Clock** (globe tab): an analog face per city (light by day, dark by night), "Today, +3HRS" style offset
  and the digital time; right-click a clock to move or remove it. Add cities in Settings → Modules → World
  Clock (search: "seoul", "san fran", …). Defaults: here, New York, London, Tokyo.
- **Usage** (chart tab): Today / 7 days / 30 days. Cards per source (AI Chat, Claude Code, Codex) with cost,
  tokens and in / cache / out split; a by-model breakdown; plan limits (Codex plan % and reset; Claude Code
  only when a limit is close or hit); configured MCP servers (green dot = used in the active session).
  The **Agent Hooks** tab shows a one-line version under the approval queue (active session tokens and cost,
  MCP servers used, today's totals).
  - **Plan limits — Claude Code.** Live source: **Settings → AI & Agents → Usage → Live Claude Code plan
    usage → Connect.** Claude Code passes its status line command a JSON snapshot after every reply, and for
    Pro / Max / Ultra it includes `rate_limits.five_hour` / `seven_day` (`used_percentage` 0–100, `resets_at`
    epoch s); hooks don't get this. Connect installs `~/Library/Application Support/NotchDeck/claude-statusline.sh`
    (0700, holds the local token) as `statusLine` in `~/.claude/settings.json` (backed up first). It forwards the
    snapshot to `POST 127.0.0.1:<port>/notchdeck/statusline` in the background and prints
    "Session 85% · Week 38%" (or runs and prints your previous status line, which Disconnect restores).
    Needs the Agent Hooks module on (its server). Claude Code may need a new session to pick it up.
  - Without Connect, the fallback is `~/.claude.json` → `cachedUsageUtilization`, a copy Claude Code saves only
    now and then. **That's why the first version showed 19 % when the real numbers were ~85 % / ~38 %**: the
    copy was ~9 hours old. The tab says which source it's showing; live data is never replaced by an older copy.
  - **Customize** in Settings → AI & Agents → Usage: which sources (AI Chat / Claude Code / Codex), which
    sections (by model, plan limits, MCP servers, note), the range it opens on, and whether / what the
    one-line strip under the Agent Hooks queue shows. Prices moved there too (Usage · Prices).
  - AI Chat cost is real (your API keys); Claude Code / Codex cost is "≈" an estimate at API list prices.
  - No price for a model → cost "—" (or "+" when partly priced). Add prices in Settings → Modules → Usage ·
    Prices (e.g. `gpt-5*` for Codex).
- **Terminal** (terminal tab): a real terminal (xterm emulation in a PTY, via SwiftTerm) running your login
  shell, like Terminal.app: prompts, colors, tab completion, `cd`, vim / top / ssh / sudo, Ctrl-C all work.
  Clicking the Terminal tab puts the cursor in it (or click the terminal); it keeps focus between commands.
  While it has keyboard focus the notch stays open (moving the pointer away doesn't close it); click outside or
  press ⌃⌥N to close. The session keeps running when the notch closes. **New Session** (top right) ends the
  shell and everything in it and starts a fresh one (also offered after `exit`). ⌘C / ⌘V / ⌘A, ⌘K clears,
  ⌘+ / ⌘− text size. Option types special characters (not Meta). Same look as the AI Chat: 12.5 pt system font
  in its monospaced design (SF Mono; a terminal needs fixed-width columns) on the chat composer's background.
- **Lyrics** (off by default): Media tab → speech-bubble button, or Settings → Modules → Media · Lyrics. While
  music plays the collapsed notch grows one line (same width as the collapsed notch; long lines are
  truncated) and shows the current lyric in time with the song.
- **Mirror** (camera tab): mirrored camera preview; pick another camera (Continuity Camera, external) from the
  top-right button. The camera runs only while the tab is open. Shortcut: *Toggle Camera Mirror*.

### Default shortcuts (change in Settings → Shortcuts)

| Action | Default |
|---|---|
| Toggle notch | ⌃⌥N |
| Open AI Chat | ⌥Space (opens the notch until Phase 4 adds the chat) |
| Play / Pause media, Open File Tray | unset; works once you record one |
| Pomodoro (start / pause), Camera Mirror (open / close), Approve Agent | unset; work once you record one |

### Debug launch flags

Pass after `--args` with `open`, or as launch arguments in the Xcode scheme:

| Flag | Effect |
|---|---|
| `-notchdeck.debug.startExpanded YES` | Opens the notch (pinned) right after launch |
| `-notchdeck.debug.showsGeometryOutline YES` | Shows the red alignment outline |
| `-notchdeck.debug.ephemeralSecureStore YES` | Debug only: keeps license/API keys in memory, so no Keychain prompts. The trial restarts every launch. |
| `-notchdeck.theme frostedGlass` | Any setting key can be overridden this way |

### Licensing in development

```sh
node Server/license-proxy/dev-server.mjs     # local license server on http://127.0.0.1:8787
```

Debug builds talk to that server. With it running, in Settings → License:
- any key starting with `TEST-` activates (mock merchant), and
- the **master key** from `.env` activates as "Master (unlimited)".

---

## 3. Keychain permission prompt: development builds only

> **Users of released NotchDeck will never see this prompt.** The "NotchDeck wants to use your confidential
> information stored in … in your keychain" dialog is a side effect of how *development* builds are signed
> on this Mac. It is not part of the product, and released builds are designed so it can't appear.

### What the prompt is
macOS shows this dialog whenever an app reads a Keychain item **and macOS can't confirm the app is the same
one that created the item**. The wording ("confidential information") is fixed by macOS and is the same no
matter what the item holds, which is why it looks alarming.

### What NotchDeck stores in the Keychain (and what it never touches)
- **Only NotchDeck's own secrets:** the 7-day trial / license record and the AI API keys you enter
  (Claude, Gemini, custom endpoint).
- They live in **one** Keychain item named **"NotchDeck"** (service `com.notchdeck.NotchDeck`,
  account `secrets`).
- NotchDeck **never reads any other Keychain item**: not your passwords, not other apps' data. It only asks
  for that one item, by name.
- The item is **read once per launch** and kept in memory. Using the chat, refreshing model lists or the
  hourly license check never re-reads it.

### Why development builds show it
- There's no Apple code-signing certificate on this Mac, so every build is signed **ad-hoc**.
- An ad-hoc signature is derived from the app's exact binary, so **every rebuild gets a new signature**.
- A classic Keychain item remembers which app created it **by signature**. After a rebuild the signature no
  longer matches, so macOS asks once: "is this new build allowed?"
- Choosing **Always Allow** adds the current build to the item's allowed list; the next rebuild asks again.

### Why released versions don't show it
Release builds are signed with your **Developer ID** (required anyway for notarization and distribution),
which gives the app a **stable identity across every version and update**.
- **Data protection keychain (preferred):** signed builds use macOS's newer, app-scoped keychain (the same
  model as iOS). Items belong to the app's signing identity, and macOS never shows a permission dialog for
  them. This needs the build to carry an application identifier / keychain access group (part of the
  signing setup); NotchDeck detects whether it's available at launch.
- **Fallback, also prompt-free:** if a build can't use the data protection keychain, NotchDeck uses the
  classic login keychain. Because the Developer ID signature is stable, every version is recognized as the
  app that created the item, so there's still no prompt, including after updates.
- **First launch:** NotchDeck creates the item itself, so there's nothing to ask about.

### What was changed (2026-11-25)
- **Before:** Phases 2–4 kept one Keychain item **per secret** (license, Claude key, Gemini key) and re-read
  them **every time they were used** (each chat message, each model refresh, the hourly license check).
  On a development build that meant *several* prompts per launch, and repeated prompts after "Allow"
  (instead of "Always Allow").
- **Now:**
  - all secrets are in a single item, read once per launch (at most **one** prompt per rebuild in
    development, zero in release);
  - the existing separate items were merged into it automatically and then deleted;
  - signed builds use the data protection keychain;
  - the item is labelled plainly "NotchDeck" ("NotchDeck license and API keys" in Keychain Access).
  - Code: `SecretsVault` and `SystemKeychain` in `NotchDeck/Core/Licensing/KeychainHelper.swift`; tests in
    `SecretsVaultTests`.

### Bug fixed 2026-11-26: saved keys disappearing on every other launch
- **Symptom:** API keys (and the license record, same item) were "sometimes saved, sometimes not" across rebuilds.
- **Cause:** at launch the vault first looks in the data protection keychain. Development builds can *read*
  it (they get "not found") but can't *write* to it. The one-time "move from the login keychain" step then
  wrote the item back to the login keychain (the fallback) and **deleted that same item**. That launch still
  worked from memory; the next launch found nothing. Re-entering a key saved it again, and the launch after
  that deleted it again.
- **Fix:** the login copy is deleted only after a copy really lands in the data protection keychain.
  `KeychainRealTests` reproduces it against the real keychain under a throwaway service name (3 relaunches
  in a row), and cleans up after itself.
- Keys lost before the fix need entering once more; after that they persist across rebuilds. The
  once-per-rebuild "confidential information" prompt below is unchanged (development builds only).

### What to do while developing
- **When the prompt appears after a rebuild:** enter your Mac password and choose **Always Allow**. It won't
  ask again until the next rebuild.
- **To remove the prompt from development entirely (recommended):** Xcode → Settings → Accounts → add your
  Apple ID; then target **NotchDeck** → Signing & Capabilities → **Team** → choose it (a free personal team
  works). Builds then have a stable signature and stop prompting.
- **For quick UI work without the Keychain at all:** launch with
  `-notchdeck.debug.ephemeralSecureStore YES`. Secrets stay in memory only, so API keys and the trial
  record are forgotten when the app quits.

### Before shipping: confirm users won't see it
1. Build the release with your **Developer ID** signing.
2. Install it on a test Mac or a fresh macOS user account and run it: enter an API key, quit, relaunch,
   send a chat message. **No Keychain dialog should appear at any point.**
3. Check the log: `log show --last 5m --predicate 'subsystem == "com.notchdeck.NotchDeck" AND category == "Keychain"'`.
   The line "Data protection keychain unavailable" means that build fell back to the login keychain:
   still prompt-free with a stable signature, but worth fixing in the signing setup.
4. Install an update over it (same Developer ID) and repeat step 2.
- **Only exception to watch for:** if pre-release builds were ever given to people **unsigned/ad-hoc**,
  those people could see the prompt once when a signed build first takes over the item. Distribute
  betas signed with Developer ID to avoid it.

---

## 4. Things to consider ⚠️

### Signing and distribution
- **Keychain permission prompts are development-only:** see §3 for the full explanation.
- **Hardened runtime isn't applied to ad-hoc builds** (`codesign -dv` shows only `adhoc`). Notarization
  requires it, so check your Developer ID release build shows the `runtime` flag.
- **Distribution needs a Developer ID certificate + notarization** for the `.dmg`/`.zip` (spec §1). Not set up yet.

### Licensing
- **Release builds can't activate licenses yet.** `LICENSE_PUBLIC_KEY` (Release) is empty until you run
  `swift Scripts/license-keygen.swift` and paste the public key into `Config/NotchDeck.xcconfig`.
  The License pane says "activation isn't configured" until then.
- **The license proxy must be deployed** (Cloudflare Worker) and `LICENSE_API_BASE_URL` (Release) set to it.
  Steps: [`Server/license-proxy/README.md`](Server/license-proxy/README.md).
- **Debug uses a throwaway DEV keypair.** Its private half is only in `.env`; never ship it, and never
  reuse it for production.
- **Master key revocation is partial.** Changing `MASTER_LICENSE_KEY` stops *new* activations, but Macs
  already activated keep working (their receipts are signed and verified offline). Fully revoking them
  means rotating the signing key, which also invalidates every customer. Share it only with people you trust.
- **Production needs the master key set as a Worker secret:** `npx wrangler secret put MASTER_LICENSE_KEY`.
- **LemonSqueezy seats:** each activation creates a new instance, so a reinstall without
  "Deactivate This Mac" uses another seat. Refunds don't revoke offline receipts automatically.
- **Trial tamper resistance is deliberately moderate.** The trial record is HMAC-signed with a secret
  embedded in the app and stored in the Keychain. It defeats deleting preferences, editing the record,
  copying it to another Mac, and rolling the clock back. Deleting the Keychain item itself resets the
  trial; that's accepted.
- If the Keychain can't be read at all, NotchDeck stays **unlocked** (it never punishes a user for a storage error).

### Permissions
- **Per-session permissions (default ON):** Settings → General → Privacy → *Ask for permissions every time
  NotchDeck opens*. macOS has no "allow until quit" option, so NotchDeck resets **its own** approvals
  (Automation, Calendars, Reminders, Camera, Screen Recording, Bluetooth, Downloads folder) with
  `tccutil reset <service> com.notchdeck.NotchDeck` at
  launch and at quit. Grants last while it runs; the next launch asks again. No admin rights needed.
  Turn it off to have macOS remember approvals normally.
  - Expect prompts at **every launch** (including launch at login): "control Spotify/Music" when a player
    is running, Calendars if you had connected it before, and, with Live Activities on, **Bluetooth** and
    **Downloads folder**. Camera asks when you first open Mirror. If that's too many, turn off the Bluetooth
    or Downloads watcher in Settings → Modules, or turn off per-session permissions.
  - A force quit / crash skips the quit-time reset; the launch-time reset covers that.
- **Automation (Music / Spotify):** NotchDeck triggers the prompt by sending the player a harmless
  "get player state" Apple event with a **10-minute timeout** on its own queue, and runs no player scripts
  until you answer. History:
  1. First media script triggered the prompt, but its 3 s timeout expired while the prompt was open, and
     macOS recorded **denied**.
  2. Switched to `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)`: on this macOS it
     **blocked forever and never showed a prompt** (logs: requests never returned; Spotify never
     received a TCC request). "Ask Again" therefore did nothing.
  3. Now: a real Apple event (which makes the player raise the TCC request; confirmed in Spotify's log:
     `TCCAccessRequestIndirect … requesting access`) with a long timeout. The silent API is still used
     only with `askUserIfNeeded: false`, behind a 2 s deadline.
  While a prompt is open, `tccutil list` shows the entry as "denied"; that's normal.
  If you click *Don't Allow*, the Media tab shows a button to System Settings → Privacy & Security → Automation.
- **Automation prompt may not appear (open issue):** macOS can hold back Automation prompts for background
  agent apps like NotchDeck (Calendar prompts appear fine). When NotchDeck can't control a running player,
  the Media tab shows **"Allow NotchDeck to control Spotify"** with:
  - **Ask Again:** brings NotchDeck to the front, then re-asks (best chance for the prompt to show);
  - **Open Automation Settings:** switch on *NotchDeck → Spotify/Music* directly (guaranteed path).
- **Permission re-check every 15 s:** while Media or Calendar lacks permission, NotchDeck silently re-checks
  (`SessionPermissions.recheckInterval`) and starts working within ~15 s of you allowing it, with no relaunch.
- **Calendars:** first time, requested when you click *Connect Calendar*. With per-session permissions on,
  later launches ask again automatically.
- NotchDeck logs permission activity under subsystem `com.notchdeck.NotchDeck`, category `Permissions` / `Media`:
  `log show --last 5m --predicate 'subsystem == "com.notchdeck.NotchDeck"'`.
- Both are declared in `Config/NotchDeck.entitlements` (hardened-runtime Apple Events + Calendars) and
  have usage strings in `Config/Info.plist`. Without the entitlements, a hardened build fails silently.

### Media module
- **Only Music and Spotify for now.** The spec's fallback for browser/system audio (`mediaremote-adapter`)
  is **not implemented** yet. Apple locked down the private MediaRemote framework in macOS 15.4+, so that
  needs a separate helper; it's tracked in §6.
- **The visualizer is procedural**, not real audio levels (that needs a system audio tap + extra permission).
  It animates only while playing.
- **Event-driven, not polling.** Music/Spotify post a notification on every change; NotchDeck re-reads then,
  resyncs every 10 s while playing, and interpolates the position in between.
- AppleScript runs on one background serial queue with a 3 s timeout, so a hung player can't freeze the notch.
  Scripts check that the player is running first and never launch it.
- The output picker changes the **system** default output device (same as the Sound menu).

### File Tray
- **Dropped files are referenced, not copied** (bookmarks that survive moves/renames). Removing them from the
  tray never touches the originals. Dropped text/images and created zips are **staged copies** in
  `~/Library/Application Support/NotchDeck/Tray/`; removing those deletes the copy.
- Zip uses `/usr/bin/ditto` (what Finder's Compress uses). One file → `name.zip` with the file at the root;
  several → `NotchDeck Archive <date>.zip` with a folder inside.
- Drag-out is one item per drag.
- **How drops work now (third design, after two failed attempts):**
  - A native AppKit drag destination (`NotchContainerView`, the panel's content view) reads the drag
    pasteboard directly: file URLs → referenced items; PNG/JPEG/TIFF → staged image (TIFF saved as PNG);
    web links and text → staged `.txt`. SwiftUI's `onDrop` is no longer used.
  - The drop zone is the whole notch silhouette (+ slop), including the strip over the hardware notch.
  - **Drag detection polls** the mouse button + drag pasteboard (20×/s, pasteboard only while the button is
    held) because global event monitors aren't guaranteed to see events during another app's drag.
    While a drag is in flight the panel stops being click-through so it can receive it even when collapsed;
    it reverts on release.
  - The expanded notch now sits at `popUpMenu + 1` instead of `.screenSaver`: at 1000 it was **above** the
    system drag-image layer (500), hiding the dragged file and making drops unreliable. (Spec §2.2 said
    `.screenSaver`; this is a deliberate deviation.)
  - Not supported yet: **file promises** (e.g. some Mail attachments / Photos items that aren't real files yet).
- History: attempt 1 only accepted drops below the top strip; attempt 2 used SwiftUI `onDrop` on the whole
  shape but still didn't receive drops in real use.

### Calendar
- **Freshness:** local changes arrive instantly (`EKEventStoreChanged`). Remote accounts (iCloud, Google,
  Exchange) are asked to re-sync every 5 minutes, on wake, and when you press ↻. The list re-reads every
  minute so countdowns roll over.
- **What's hidden:** canceled events, events you declined, calendars you turned off, and all-day events if that
  toggle is off. All-day events never drive the collapsed banner. At most 60 events are listed.
- Calendar choices are stored as an *exclusion* list, so newly added calendars show up automatically.
- Fixed after first use: recurring events share one EventKit identifier across occurrences, which made SwiftUI drop
  rows; occurrences now get unique IDs. The first build also capped the notch list at 3 rows and 36 hours.
- **Reminders aren't integrated yet** (spec §3.6 mentions them; Phase 3 scope was the Calendar banner).

### AI Chat
- **API calls are BYOK** (your keys, your bill). Keys live only in the Keychain. With the
  `-notchdeck.debug.ephemeralSecureStore YES` launch flag they're kept **in memory only** and vanish on
  relaunch, so launch without it when testing chat.
- **Claude:** raw HTTPS to `https://api.anthropic.com/v1/messages` (Swift has no official Anthropic SDK),
  `anthropic-version: 2026-10-21`, streaming SSE. **Per-model request shaping** from the Models API
  capabilities: adaptive thinking (summarized) only where `capabilities.thinking.types.adaptive.supported`
  (older models such as Haiku 4.5 would 400); `max_tokens` = min(32000, the model's limit). Hand-added IDs
  are guessed by family, and if one rejects thinking NotchDeck retries without it.
- **Model lists:** fetched at launch and when you save a key; cached in
  `~/Library/Application Support/NotchDeck/model-catalog.json`. Gemini's list is filtered to text-chat models
  (image "Nano Banana", Lyria music, TTS, transcription, embeddings, computer-use / Antigravity /
  Deep Research agents are hidden) and sorted newest first.
- **Refusal fallbacks are ON for Opus 5.5, Sonnet 5.5, Opus 5, Fable 5.2 and Fable 5.1** (`anthropic-beta: server-side-fallback-2026-07-01`,
  `fallbacks: "default"`): if Claude's safety classifiers decline, the API re-runs the request on a suitable
  model in the same stream, and the reply shows "Continued with …". If your account doesn't have that beta,
  NotchDeck retries once without it and stops sending it for the session. A refusal the whole chain declines
  shows "Claude declined this request" and discards the partial text. Haiku 5.5 has no server-side fallback.
- **History sends assistant text only** (no thinking blocks), which keeps every request valid across model
  switches and fallbacks; the model doesn't see its earlier private reasoning.
- **Gemini:** `streamGenerateContent?alt=sse`.
- **Custom endpoint:** any OpenAI-compatible `/chat/completions` streaming server (local LLMs, proxies); PDFs
  aren't sent to it.
- **Attachments:** images downscaled to 1568 px long edge (PNG, JPEG if >4.5 MB); PDFs ≤ 20 MB; UTF-8 text
  ≤ 400 KB. Anything bigger or binary is refused with a message, never silently truncated.
- **Screen selection** uses macOS `screencapture -i`; the first use asks for **Screen Recording** permission
  (also reset per session; `tccutil` may not be allowed to reset that one, and that's logged).
- **Chats are saved** as JSON in `~/Library/Application Support/NotchDeck/Chats/` (attachments included).
- **Tall layout:** the AI Chat tab expands the notch taller (Compact 300 / Medium 360 / Large 440 pt of content,
  capped at 70% of screen height). The window grows immediately and shrinks after the close animation, so no
  invisible strip blocks clicks.

### Agent Hooks (Claude Code & Codex)
- **Claude Code:** its `http` hook type. The installer adds two entries to `~/.claude/settings.json`:
  a `PermissionRequest` hook (matcher `*`) POSTing to `http://127.0.0.1:47823/notchdeck/permission-request`,
  and a `Stop` hook POSTing to `…/notchdeck/stop`. No script is installed.
- **Codex:** Codex's hooks (same event names and decision schema as Claude Code: `PermissionRequest` with
  `hookSpecificOutput.decision.behavior`, and `Stop`) support only `command` handlers, not HTTP. So the
  installer writes `~/.codex/hooks.json` with one command per hook:
  `/usr/bin/curl -sf --max-time 590 -H 'Expect:' -H 'Content-Type: application/json' -H 'X-NotchDeck-Token: …'
  --data-binary @- http://127.0.0.1:47823/notchdeck/codex/permission-request || true`.
  Codex pipes the hook JSON to curl's stdin; NotchDeck's decision comes back on stdout. If NotchDeck is away,
  curl prints nothing and `|| true` exits 0, so Codex shows its normal prompt (a test runs this exact command).
  - **Trust:** Codex only runs non-managed hooks you've reviewed (`/hooks` in Codex, trust is per hook
    hash), so after installing or updating, trust both NotchDeck hooks once.
  - Codex needs a version with hooks (they're on by default; `[features] hooks = false` turns them off).
    NotchDeck only edits `hooks.json`, never `config.toml`.
  - Codex sends no "don't ask again" suggestions, so its cards have no **Always Allow**.
  - Codex runs `Bash` (commands may arrive as an argv array, which the card joins) and `apply_patch` (shown as a
    per-file +/− diff).
- **Both:** everything else in the files is preserved; a backup (`….notchdeck-backup`) is written first; a file
  that isn't valid JSON is never touched. **Remove Hook** takes exactly NotchDeck's entries out again
  (recognized by `/notchdeck/` in the URL or command).
- **Fail-safe, never fail-open:** NotchDeck doesn't set `onFailure: "block"`, and it never approves anything
  on its own. If NotchDeck is quit, the module is off, the request times out, or you don't answer within
  2 minutes, Claude Code just shows its normal terminal prompt. A denial or approval only ever comes from
  you clicking a button (or the approve shortcut).
- **Security:** the server binds to **127.0.0.1 only** (verified: unreachable from the Mac's LAN address) and
  requires a per-install token header (`X-NotchDeck-Token`, stored in NotchDeck's preferences and in the
  hook entry). Requests without it get 403. The token keeps other local software from injecting fake
  approval cards; it isn't a credential for anything else.
- **Port 47823, not 49152:** the spec's example port is the first port of macOS's ephemeral range, and on
  this Mac Cisco AnyConnect's `vpnagentd` already listens on 127.0.0.1:49152 (`lsof` can't see it without
  admin rights; `netstat -anv` can). Changing the port in Settings restarts the server and marks the hook
  **Needs update**; click it to rewrite the URL.
- **Takes effect in new sessions** (the agents read hooks at session start). It applies to **every** session of
  that agent on this Mac, including Claude Code inside VS Code.
- **Approval card keyboard:** when a card appears, the notch **takes keyboard focus** (without switching apps:
  your terminal or editor stays the frontmost app) so Esc / ⌘↩ / ⌘⇧↩ work immediately. Keystrokes typed
  meanwhile go to the card, not your terminal; focus returns where it was once the last request is answered.
  Plain Return does nothing, so a stray Return can't approve. The keys are handled by NotchDeck directly
  (a key monitor), because SwiftUI shortcuts and Escape didn't reliably reach the non-activating panel: the
  first build's keys didn't work at all (reported 2026-11-26). The global *Approve Pending Agent Request*
  shortcut works any time.
- **"Always Allow"** sends back Claude Code's own suggestion (`permission_suggestions` → `updatedPermissions`),
  so the rule lands where Claude Code proposed (usually the project's local settings).
- **Diff preview** shows the changed lines between `old_string` and `new_string` with 2 lines of context;
  it's a preview, not a full diff of the file.

### System monitor
- **Sources (all without admin rights):** CPU usage per core from `host_processor_info`; which cores are
  efficiency vs performance from the device tree (`cluster-type`, on this M4: CPUs 0–5 E, 6–9 P); memory from
  `host_statistics64` ("Memory Used" = app + wired + compressed, like Activity Monitor), swap from `vm.swapusage`,
  pressure from `kern.memorystatus_vm_pressure_level`; GPU % from IOKit `PerformanceStatistics`; power and
  cluster/GPU frequency from **IOReport** (the same counters macmon reads; asitop needs `sudo powermetrics`
  instead), combined with the `pmgr` frequency tables (`voltage-states1-sram` E, `5-sram` P, `9` GPU).
- **IOReport is a private Apple interface**, loaded at runtime with every symbol checked. If a macOS update
  removes or changes it, power and frequencies show "—" and everything else keeps working. (Private APIs are
  fine for a notarized direct download; they'd be a problem only for the Mac App Store.)
- **CPU watts show "—" on this M4 / macOS 27:** IOReport's CPU energy channels read 0 even under load (probed
  2026-11-26); GPU energy works. "—" means *unavailable*, never zero; it gets a tooltip saying why.
- **Color** is selectable (Settings → Modules → System Monitor → Color: rose / violet / blue / teal / amber /
  graphite, the visualizer's palette without "Match Album Art"); default blue. Passed down as the
  `monitorAccent` environment value.
- **Colors** follow the bundled data-visualization guidance: one accent color for magnitude (usage fills,
  sparkline "now"), a same-hue track behind meters, status colors only for memory pressure and thermal state,
  always with an icon and label. Contrast checked on the black surface (all pass) and the dark glass surface
  (critical red is 2.6:1 there, covered by its visible label).
- **Overview styles** share one metric model (`OverviewMetric`: label, value, detail, 0–1 fraction, history).
  A nil fraction (GPU unavailable) draws an empty track and a grey "—", never a 0% bar. Styles are trial
  options while the user picks a favourite; the unpicked ones can be deleted later.
- 250 ms sampling is noticeably busier than 1 s (four IOReport reads a second) but still only runs while the
  tab is open. 1 s stays the default.
- High CPU is not shown as an error (it's usage, not a fault), so cores stay blue at any load.
- **Content-fitted height:** the System tab measures its own natural height and the notch (and its window)
  sizes to it (`ExpandedLayout.fitted`), clamped between a small minimum and the tall layout. On this Mac:
  window 355 pt (notch 319 + shadow) instead of 428 with the old tall layout. Before the first measurement it
  briefly uses the tall layout, then glides to the fitted size. Other modules can opt in by adding themselves
  to `ExpandedLayout.contentFittedModules`.
- Debug flag to open a given tab at launch: `-notchdeck.debug.startExpanded YES -notchdeck.debug.startModule systemMonitor`
  (any module's raw name).

### Live Activities
- **Battery:** IOPowerSources run-loop notification (no polling, no permission) plus the `AppleSmartBattery`
  driver for watts (voltage × instant current; signed value can arrive as an unsigned 64-bit number), cycle
  count and health (raw max ÷ design capacity). Watts refresh every 3 s only while the tab is open. Desktops
  have no battery: the card and toggle are disabled.
- **Bluetooth battery levels use undocumented properties** (`batteryPercentLeft/Right/Case/Single` on
  `IOBluetoothDevice`), each checked with `responds(to:)` before reading, so a macOS change just hides the
  levels. Magic accessories come from their HID service's `BatteryPercent`. Devices already connected at
  launch are listed but don't toast (3 s quiet period). The toast waits 1.5 s so AirPods levels arrive first.
- **Downloads:** kqueue DispatchSource on the folder (write / rename / link), 0.6 s debounce, then a file is
  reported once its size is stable for 1 s. The first read runs off the main thread because it blocks while
  macOS shows the Files & Folders prompt. If access is denied, the card says where to allow it.
- Toasts are one at a time; a newer one replaces the current one (`NotchToastCenter`).
- **Not hands-on tested yet** (need real events): plugging/unplugging, AirPods connecting, a real browser
  download. The logic is unit-tested, including a simulated `.crdownload` → final-name rename.

### Pomodoro, To-Dos, Mirror
- Pomodoro state is stored in UserDefaults (`notchdeck.pomodoro.state`) so a running timer survives a quit; a
  phase that ended while NotchDeck was closed advances quietly on launch (no chime). Turning the module off
  pauses a running timer. Skipped focus sessions don't count.
- To-Dos are plain JSON (dates as exact Doubles). An unreadable file is copied to `todos.unreadable.json`
  instead of being overwritten.
- Mirror: `AVCaptureSession` on its own serial queue; started on tab appear, stopped on disappear (closing the
  notch turns the green light off). Needs the hardened-runtime camera entitlement (added) and
  `NSCameraUsageDescription`; Continuity Camera is allowed via `NSCameraUseContinuityCameraDeviceType`.

### Phase 7 modules
- **Menu bar drawer not built.** On this Mac (macOS 27) the system already hides overflowing menu bar
  items behind its own **"Show Hidden Menu Bar Items"** button right of the notch, and only Apple's visible
  items (Battery, Wi-Fi, Control Center, Clock) are exposed to other apps through Accessibility; hidden
  third-party items (NotchDeck's own icon included) can't be listed or opened individually. The old
  per-item status windows are gone too (the whole bar is one `MenuBarAgent` window). A drawer could only
  press Apple's button, so it was skipped. Checked 2026-11-26 with CGWindowList and AX probes.
- **Usage sources:** Claude Code `~/.claude/projects/**/*.jsonl` (assistant lines' `message.usage`, de-duplicated
  by message ID + request ID, since one message is logged once per content block; `quotaLimits` for plan
  limits; `mcp__<server>__` tool calls for MCP use). Codex `~/.codex/sessions/**/rollout-*.jsonl`
  (`token_count` events: `last_token_usage` counted when the running total grows; cached tokens are inside
  OpenAI's input count and are split out; `rate_limits` for plan %). MCP config from `~/.claude.json`,
  `<project>/.mcp.json`, `~/.codex/config.toml`. Only usage fields are read; nothing leaves the Mac.
  Files are read incrementally (byte offsets); a cheap substring pre-filter skips the huge request lines.
  First scan of this Mac's logs: 0.24 s; refreshes ~2 ms. Polls every 15 s only while Usage or Agent Hooks
  is open, plus once when an agent task finishes.
- **AI Chat usage** comes from the API responses (Anthropic `message_start` / `message_delta` usage, Gemini
  `usageMetadata`, OpenAI-compatible `stream_options.include_usage`) and is saved to
  `Application Support/NotchDeck/usage-chat.json` (90 days).
- **Prices:** built-in table = Anthropic's pricing page fetched 2026-11-26 (incl. 5 m / 1 h cache writes,
  per-model cache-read rates, Haiku 5.5's 5× above 100K-token prompts, fast mode 2×, US-only 1.1×). No OpenAI or
  Gemini prices are built in (not verified); add them as custom rows. Update the table when prices change.
- **Lyrics** come from lrclib.net (free, no key). When on, each new track's title / artist / album / length is
  sent there (said in Settings). Exact match first, then search by title + artist within ±4 s of the length.
  Results cached per track for the session.
- **Lyric timing (fixed 2026-11-26, user saw lyrics lagging on Bluetooth):** three causes, all fixed:
  1. My "redraw only at line changes" optimization scheduled redraws at exactly a line's start; rounding could
     land a hair before it and keep showing the *previous* line until the next redraw (a whole line late).
     Redraws now land 20 ms after, with 1 ms tolerance when picking the line.
  2. Positions were timestamped when the AppleScript reply arrived (100–200 ms after the position was taken;
     later still with Music and Spotify both open). Now stamped at the round trip's midpoint (`readAt`).
  3. Bluetooth / AirPlay output delay: the position is the player's, but you hear it later (this Mac's
     "gusher 3.0" headphones report ~171 ms). `OutputLatency` reads the default output device's latency +
     safety offset + buffer + stream latency from CoreAudio and subtracts it.
  Lines show 0.1 s early. Settings → Modules → Media · Lyrics → *Timing* nudges ±1 s in 0.1 s steps.
  Verified against Spotify on Bluetooth: three captures each showed the line being sung at that moment. Hover / clicks pass through the lyric
  strip (it's below the hover zone).
- **Terminal** uses SwiftTerm **pinned to exactly 1.10.1** (Feb 2026). Releases from 1.11.0 on apply a
  package *build plugin* to the macOS library, which Xcode makes you trust separately (and `xcodebuild`
  needs `-skipPackagePluginValidation`); 1.10.1 is the last without it. Revisit when upgrading.
  The shell starts as a login shell (`-zsh` argv[0]) with `TERM=xterm-256color`, in your home folder, the
  first time the tab opens. One `NotchTerminalView` is kept by `TerminalSession` and re-attached each time
  the tab is shown. `needsPanelToBecomeKey` is overridden so a click gives the non-activating panel keyboard
  focus. SwiftTerm sometimes reports the raw `waitpid` status as the exit code; it's decoded.
  (Replaced the one-shot Command Runner, which the user found unreliable.)
  - **Typing stopped after the first Return (reported 2026-11-26):** most likely SwiftUI taking keyboard focus
    back from the embedded AppKit terminal when the tab redrew (the shell retitles the window on every command).
    Fix: the hosting container watches the window's first responder and hands focus back to the terminal when
    anything other than a text field takes it (only while the panel is key and you'd been typing there); title
    updates no longer cause redraws. Not reproducible in unit tests (test windows can't become key), so
    confirm by hand.
  - New Session builds a new terminal view; the old one's delegate is detached first, because its exit report
    can arrive after the new shell starts.
- **Camera light after leaving Mirror:** the camera used to stop only when the Mirror view was removed (after
  the tab-switch fade) and the stop then queued behind any start in progress. Now the panel controller turns it
  off the moment Mirror stops being the visible tab (tab switch or collapse) and cancels a pending start.
- Tab strip now scrolls sideways when the enabled modules don't fit (14 modules).

### Performance and the glass / black notch (fixed 2026-11-26)
- **Glass ↔ black flipping:** the collapsed notch on a real notch display was always pure black (to vanish into
  the camera housing), even with wings / lyrics showing, while hover (peek) used the theme. So on the desktop
  it flipped black ↔ glass as the pointer came and went (invisible on a black full-screen menu bar). Now black
  only when the collapsed notch is exactly the housing (nothing beside / below it), fading over 0.25 s, and no
  blur view is kept behind it then (an invisible live blur still costs the window server).
- **Pulsing background (likely cause, not confirmed visually):** `NotchMaterialView.updateNSView` re-assigned
  `material` on every SwiftUI update; re-setting it can rebuild the blur. Now only changed properties are set.
- **CPU:** the Usage scanner was the main CPU consumer while Claude Code was busy: its pre-filter let
  user / request lines through (they contain "assistant" and "usage"), each was JSON-decoded, and timestamps
  went through ISO8601DateFormatter. Now: exact `"type":"assistant"` + `"output_tokens"` pre-filter, a manual
  timestamp parser, regex-free model-name normalization, a price cache, cached summaries (recomputed only
  when records or prices change), and no republish when a refresh finds nothing new.
- **Visualizer runs in the render server (2026-11-26):** the bars / wave were a SwiftUI `TimelineView` at 30 fps,
  and every frame re-laid-out the whole notch window. They aren't audio-driven (macOS doesn't share other apps'
  levels), so they're now looping Core Animation keyframes (`VisualizerLayerView`): bars loop every 6 s (each
  bar's frequencies rounded to whole cycles per loop, so the loop is seamless), the wave every 2π/6 s. NotchDeck
  does no per-frame work, and the motion is smoother (display refresh rate).
  Measured, Release build, collapsed, Spotify playing, glass + wave + lyrics (30 s CPU-time averages):
  **CPU 10–13 % → 4–6 %, wakeups ~1,000/s → ~340/s, main thread ~98 % idle.** (Debug builds use ~2× the
  CPU of Release.) Most remaining wakeups are system threads, chiefly the global mouse-move monitor that
  hover detection needs (only while the mouse moves).
- Lyric line redraws are scheduled at each line's start time (re-planned on pause / seek / track change)
  instead of polling 5×/s.
- Measured on this Mac (collapsed, Spotify playing, glass): NotchDeck ≈ 9.5 % CPU averaged over 10 s (from
  `ps` CPU time; `top` / `sample` readings overstate it). WindowServer ≈ 37 % without NotchDeck vs ≈ 45 % with
  it: the glass blur behind the 30 fps visualizer.

### Release builds and library validation
- A **Release** build that's ad-hoc signed with the hardened runtime **won't launch**: library validation
  rejects the embedded Sparkle framework ("mapping process and mapped file have different Team IDs").
  Debug builds aren't affected. Signing with a Developer ID team (already a release step) fixes it, since
  everything gets re-signed with one team. For local performance measurements:
  `xcodebuild … -configuration Release -derivedDataPath build/PerfRelease ENABLE_HARDENED_RUNTIME=NO build`.

### Clipboard
- **macOS asks before an app reads what other apps copied** (`NSPasteboard.accessBehavior`, macOS 15.4+).
  Polling `changeCount` never asks, but reading the contents would show a prompt *on every copy* unless the
  app is set to **Allow** in System Settings → Privacy & Security → **Paste from Other Apps**. So:
  - set to Allow → the history records by itself;
  - not set yet (`default` / `ask`) → nothing is read automatically; the tab explains the setting and offers
    *Grab Current Clip* (one read, which may show macOS's prompt; that first prompt is also what makes
    NotchDeck appear in that settings list);
  - set to Deny → the tab says so.
  The setting is re-checked every 3 s, so switching it on takes effect without a relaunch. It is **not** reset
  by per-session permissions (it isn't a `tccutil` service).
- Skips clips marked `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` and 1Password's
  marker. Copying a clip back is not re-recorded. Images over 12 MB are skipped.
- Kept in memory only, on purpose: clipboard history often contains secrets.

### Hover / collapse state machine
- **Bug fixed 2026-11-26 ("sometimes it doesn't collapse when the pointer leaves"):** pointer-exit collapse
  was skipped whenever the panel had keyboard focus. The panel gets focus from a text field click (AI Chat,
  To-Dos), the chat shortcut or an approval card, and **keeps it until the notch closes**, even after
  switching to a tab with no text field. So after using any text field the notch only closed on a click
  outside. Plain button clicks don't give focus (checked experimentally), which is why it looked random.
  Now only *unsent text in the focused field* holds it open.
- Shortcut holds (`isPinnedOpen`) are tied to the module they opened (`pinnedModule`); a tab click on another
  module ends them (and collapses right away if the pointer has already left). The whole-notch toggle has no
  module and keeps its hold.
- `CollapseBehaviorTests` drive the real `NotchPanelController` with a simulated pointer
  (`pointerLocation` is injectable). Their panels are **ordered out and transparent**: an earlier version
  showed real panels on the screen, which opened and closed the notch by itself while the tests ran.
  They can't give the panel real keyboard focus without stealing it from your app, so the "focus left over
  from a text field" case is covered by an empty focused text field instead.
- The close delay used to be a fixed 220 ms; it's now the *Hover close delay* setting (default 200 ms).
- Under the full parallel test run the main thread is busy, and the 200 ms collapse can take ~0.6 s; tests
  wait for the state (up to 3 s) instead of sleeping a fixed time.
- Known flaky (pre-existing): `requestIsWithdrawnWhenClaudeCodeHangsUp` failed once under load.

### Updates (Sparkle)
- **Sparkle stays dormant** until `SPARKLE_FEED_URL` (https) and `SPARKLE_PUBLIC_ED_KEY` are set in
  `Config/NotchDeck.xcconfig`. Generate the EdDSA key with Sparkle's `generate_keys` tool (it stores the
  private key in your login Keychain), and host an `appcast.xml`.

### Architecture decisions that differ from the spec
- **Settings uses its own window** (`SettingsWindowController`: toolbar tabs + SwiftUI panes) instead of
  SwiftUI's `Settings` scene, because a Dock-less agent app can't open that scene reliably. ⌘, is routed to it.
- **The notch's shadow is drawn in SwiftUI**, not by the window (`hasShadow`), because window-server
  shadows lag behind the animated shape.
- **Fixed-size panel.** The window never resizes; only the drawn silhouette animates (smooth at 120 Hz).
  Transparent, click-through regions make this invisible to the user.
- **Collapsed state is click-through** (`ignoresMouseEvents`), so menu bar items beside the notch keep working.
- **Frosted Glass stays black while collapsed over a real notch**, so it stays invisible against the camera housing.
- **The chat model picker stores a tier** (Claude Sonnet/Haiku, Gemini Flash/Pro); concrete model IDs are
  chosen when the chat client is built (Phase 4).

### Verification gaps
- **Screen capture was blocked** in the environment that built Phases 1–2, so the visual look (notch
  alignment, glass rendering, Settings panes) was verified by geometry/window inspection and tests,
  not by eye. Check visually on your Mac.

---

## 5. Secrets and configuration

| File | Committed? | Contains |
|---|---|---|
| `.env` | ❌ git-ignored (mode 600) | `MASTER_LICENSE_KEY`, DEV `SIGNING_KEY_JWK`, `MERCHANT`, `PRODUCT_ID` |
| `.env.example` | ✅ | The same keys, blank, as a template |
| `Config/NotchDeck.xcconfig` | ✅ | License API URL, **public** keys, purchase URL, Sparkle feed/key |
| `Config/Info.plist` | ✅ | Pulls the xcconfig values into the app's Info.plist |
| Keychain (`com.notchdeck.NotchDeck` / `secrets`) | — | One item holding the trial/license record and API keys |

Never commit `.env`. The app binary contains only public keys; the master key and signing private key
exist only in `.env` and Cloudflare secrets.

---

## 6. Features

### Done
- **Notch window** (Phase 1): borderless non-activating panel aligned from `NSScreen.auxiliaryTopLeftArea/RightArea`;
  fallback top-center pill on displays without a notch; peek → expand spring animations; continuous-curvature
  silhouette with flared "ears"; Classic Black and Frosted Glass (HUD material, 1 pt specular border, ambient glow).
- **Displays:** notch display only / follow active screen / all displays; rebuilds on display changes.
- **Settings** (Phase 2): General (launch at login, menu bar icon, displays, hover delay 0–500 ms, auto-collapse),
  Appearance (theme, size preset, visualizer style, accent color, hide idle pill), Modules (enable + drag to reorder),
  Shortcuts (7 global recorders), AI & Agents (Keychain API keys, model tier, system prompt, hook port),
  License & Updates (trial status, activate/deactivate, Sparkle, version).
- **Licensing:** 7-day trial, activation gate in the notch, license proxy with master key, offline Ed25519 receipts.
- **Live Activities** (Phase 6): battery / charging pills and card, Bluetooth device toasts with battery levels,
  Downloads watcher with drag-out, AirDrop and add-to-tray.
- **Quick utilities** (Phase 6): Pomodoro with countdown pill and chime, To-Dos (JSON), Clipboard history
  (memory only, respects macOS paste privacy), Camera Mirror (AVCaptureSession, camera picker).
- **Media** (Phase 3): Music + Spotify Now Playing, artwork with dynamic color extraction and ambient glow,
  scrub bar, transport controls, output device picker, bars/wave visualizer, collapsed live pill.
- **File Tray** (Phase 3): drop zone (files, images, text, links), thumbnails + size badges, drag out,
  AirDrop, zip, remove/clear, persistence across launches, drag-a-file-to-open-the-notch.
- **AI Chat** (Phase 4): Claude (Opus/Sonnet/Haiku 5.5), Gemini, custom OpenAI-compatible endpoint; streaming
  Markdown with highlighted code + copy buttons; thinking summaries; history + new chat; attachments (files,
  ⌘V, screen selection, File Tray); ⌥Space focused-input shortcut; refusal fallbacks.
- **System monitor** (added 2026-11-26): CPU (per core, E/P clusters, frequencies), GPU (%, MHz, W), memory
  (used, swap, pressure), power, thermal, 2-minute sparklines; IOReport without root.
- **Agent Hooks** (Phase 5): 127.0.0.1 hook server (Network.framework), one-click Claude Code **and Codex** hook
  installer / remover / updater, approval cards (command, diff, file, MCP JSON) with Approve / Deny / Always Allow and a
  queue, 2-minute hand-back, terminal-answer detection, collapsed "Approve?" pill, finished chime + pulse,
  approve shortcut, test request.
- **Calendar** (Phase 3): EventKit, upcoming events with Join buttons, meeting-link parser
  (Zoom, Meet, Teams, Webex), "In 12m: …" collapsed banner.

### Still needed (from the spec)
- Media fallback for browsers/system audio (`mediaremote-adapter`), real audio-level visualizer (optional).
- Reminders (EventKit) alongside Calendar.
- Multi-item drag-out from the tray.
- Release: Developer ID signing, notarization, DMG, production license keys, deployed proxy, Sparkle appcast.

---

## 7. Project layout

```
NotchDeck/                     app sources (synchronized folder)
  App/                         entry point, AppDelegate (menu bar), DependencyContainer
  Core/Windowing/              NotchPanel, NotchGeometry, panel + multi-screen controllers
  Core/Theme/                  ThemeEngine, NotchMaskShape, Frosted Glass bridge
  Core/Licensing/              LicenseManager, receipts, API client, Keychain, hardware ID
  Core/Persistence/            SettingsStore, preference types, API keys, launch at login
  Core/Shortcuts/              global shortcuts
  Core/Updates/                Sparkle wrapper
  Core/Windowing/LiveActivity…  which live activity owns the collapsed pill
  Modules/MediaPlayer/         AppleScript bridge, Music/Spotify providers, NowPlayingStore, views
  Modules/FileTray/            FileTrayStore (bookmarks, staging, zip, AirDrop), views
  Modules/CalendarReminders/   CalendarStore (EventKit), MeetingLinkParser, views
  Modules/AIChat/              chat clients (Claude, Gemini, OpenAI-compatible), ModelCatalog, views
  Modules/AgentHooks/          loopback HTTP server, hook installer, approval card
  Modules/SystemMonitor/       sampler (host stats, IOKit, IOReport), store, views (4 overview styles)
  Modules/LiveActivities/      toast center, battery / Bluetooth / Downloads monitors, store, view
  Modules/QuickUtilities/      Pomodoro, To-Dos, Clipboard, Camera Mirror (store + view each)
  UI/                          notch root view, components, Settings panes
NotchDeckTests/                Swift Testing suites + fixtures
Config/                        xcconfig, Info.plist template, entitlements
Server/license-proxy/          Cloudflare Worker + local dev server
Scripts/                       license-keygen.swift
```

---

## 8. Next steps

1. **Phase 7 hands-on checks:** Usage tab (compare Claude Code numbers with `ccusage` if you have it; add a
   `gpt-5*` price for Codex), Agent Hooks strip during a Claude Code session, World Clock (add a city),
   Terminal (vim, top, ssh, Ctrl-C, ⌘V), Lyrics on with Spotify / Music, glass notch while switching apps /
   spaces, System tab background (pulse gone?).
2. **Phase 6 hands-on checks:**
   - Live Activities: unplug / plug in the charger (pill + card), connect AirPods (pill with battery), download a
     file in a browser (pill, then drag it out of the tab / AirDrop / add to tray).
   - Pomodoro: set focus to 5 min, start, watch the countdown beside the notch, let it end (chime + pill).
   - To-Dos: add, tick, edit, quit and reopen (items persist).
   - Clipboard: set *Paste from Other Apps* → NotchDeck → Allow, copy a few things, click one, ⌘V.
   - Mirror: allow the camera; close the notch and check the green light goes off.
2. **System tab:** ✅ styles approved (all four kept). Still worth comparing with Activity Monitor under load.
2. **Phase 5 (Claude Code approvals):**
   - Settings → AI & Agents → **Send Test Request**: a card appears; try Approve and Deny.
   - ✅ **Claude Code:** hook installed; real requests reach the notch; card keys confirmed working.
   - ✅ **Codex:** believed working by the user (2026-11-26); revisit if anything misbehaves.
   - Let a task finish → chime + "Done" pulse. Quit NotchDeck and confirm Claude Code still asks in the terminal.
3. **Phase 4 (AI Chat):** ✅ Claude chat confirmed. Still worth trying: the new model menu (Gemini models),
   adding a model ID by hand, the open/close shortcut.
4. **Phase 3 checks:**
   - Play something in Spotify/Music → collapsed wings show art + visualizer; open the notch → controls, scrub, output picker.
   - ✅ Media (Spotify + Music controls) and ✅ Join on a Zoom event: confirmed by you.
   - ✅ Drag a file onto the notch → it opens into the tray and stores it (confirmed after the AppKit rebuild).
     Still worth trying: drag back out, AirDrop, Zip.
   - ✅ Calendar (selection, refresh, scrolling): confirmed.
   - Quit and reopen NotchDeck → it asks again for Spotify/Music control and Calendars.
   - Calendar: choose calendars in Settings → Modules; check previously missing events now appear; within 15 min
     of a meeting the collapsed banner appears.
5. Phase 6: Live Activities (battery, Bluetooth/AirPods, Downloads), Pomodoro, To-Dos, Clipboard, Camera Mirror.
6. Pick a Development Team in Xcode, which ends the Keychain and Automation re-prompts.
7. Before beta: production license keypair, deploy the proxy, set the master key secret, Sparkle keys + appcast.

---

## 9. Log

- **2026-11-26 — CPU pass.** Visualizer moved to Core Animation keyframes (Release, collapsed with music:
  CPU 10–13 % → 4–6 %, wakeups ~1,000/s → ~340/s). Found that ad-hoc Release builds don't launch (Sparkle
  library validation). Agent-hook server tests wait longer / retry ports (were flaky under load). 229 tests.

- **2026-11-26 — Live Claude Code plan usage; System Monitor color.** The plan % was wrong (19 % vs ~85 % / ~38 %):
  it came from Claude Code's occasionally-refreshed cache. Added the documented live source (status line
  snapshot → NotchDeck, opt-in Connect button, wraps / restores an existing status line). System Monitor color
  picker using the visualizer palette. 226 tests.

- **2026-11-26 — Usage: Claude Code plan limits + customization; settings reorganized.** Claude Code 5-hour /
  weekly plan usage from Claude Code's own cache; Usage display preferences; Usage settings and prices moved
  to AI & Agents (all AI / API / agent settings now live there). API key rows: provider name on the left, the
  "saved / paste to replace" hint inside the field (a Form turned the field's title into a stray label), green
  check when a key is saved. Compact Agent Hooks usage line. 220 tests.

- **2026-11-26 — Visualizer accent color.** The accent color was only used when the track had no album art,
  i.e. never while music played (the artwork palette always won). The chosen accent now always colors the
  visualizer (wings and Media tab); a new first option, **Match Album Art**, keeps the artwork-palette look.
  217 tests.

- **2026-11-26 — Crash with AirPods connected + lyric timing.** IOBluetooth posts connect / disconnect on a
  background queue; the main-actor `@objc` handlers tripped Swift 6's executor check and NotchDeck crashed on
  every launch while a Bluetooth device was connected. Handlers are now `nonisolated` and hop to main.
  Lyric timing: off-by-one-line redraw rounding, late position timestamps, and Bluetooth output delay fixed;
  Timing nudge setting. 216 tests.

- **2026-11-26 — Terminal focus, New Session, look; camera stop.** Terminal keeps keyboard focus between commands
  (focus restoration) and gets it when its tab is clicked; New Session button; chat-matching font and
  background. Camera stops immediately when leaving Mirror. 212 tests.

- **2026-11-26 — Lag / glass / lyrics / terminal fixes.** User reported lag, a pulsing background, glass ↔ black
  flipping when switching apps, wide lyrics, and an unreliable command runner. Fixed: black only for the bare
  idle notch (fade, no hidden blur), material set only on change, lyrics keep the notch width, usage scanning
  made cheap (pre-filter, timestamp parser, caches), lyric redraws scheduled. Command Runner replaced by a real
  terminal (SwiftTerm 1.10.1, login shell in a PTY). 210 tests. Collapsed CPU ≈ 9.5 %.

- **2026-11-26 — Phase 7 built.** World Clock, Usage tracker (AI Chat usage from API responses; Claude Code and
  Codex from local logs; plan limits; MCP servers; strip in Agent Hooks), Command Runner (one-shot login
  shell, cd / clear built-ins, Stop), synced lyrics (LRCLIB, off by default; collapsed notch grows one line),
  scrollable tab strip. Pricing table from Anthropic's pricing page. Menu bar drawer dropped (macOS 27 has its own
  hidden-items button; hidden items aren't exposed). 210 tests.

- **2026-11-26 — Hover close delay.** New Settings → General slider (0–500 ms, default 200 ms; max lowered from 1000 ms at the user’s request) replacing the
  fixed 220 ms pointer-exit grace. 183 tests.

- **2026-11-26 — Keychain fix.** Saved API keys / license record no longer vanish every other launch (the
  data-protection migration deleted the login item after falling back to it). Real-keychain regression
  tests added. 180 tests.

- **2026-11-26 — Collapse + shortcut-hint fixes.** Pointer-exit collapse no longer blocked by leftover keyboard
  focus (only unsent text holds it open); module-shortcut holds end when another tab is clicked; the chat's
  shortcut hint shows the recorded shortcut live. New controller-level collapse tests, run off screen. 177 tests.

- **2026-11-26 — Phase 6 committed** after the user's initial review; minor adjustments to follow.
- **2026-11-26 — Phase 6 built.** Live Activities (IOPowerSources battery pills + card with watts / health,
  IOBluetooth connection toasts with AirPods / HID battery levels, kqueue Downloads watcher with drag-out,
  AirDrop, add-to-tray), Pomodoro (persisted state, countdown pill, chime, auto-start options), To-Dos (JSON),
  Clipboard (memory-only, `accessBehavior`-aware, concealed types skipped), Camera Mirror (AVCaptureSession,
  camera picker). New toast system for short pills; Pomodoro sits between urgent meetings and music. Camera
  entitlement + usage strings; Bluetooth and Downloads added to per-session resets. Settings → Modules is now
  scrollable with Live Activities / Pomodoro / Clipboard groups. 167 tests.
- **2026-11-26 — System monitor committed.** User kept all four overview styles.

- **2026-11-25 — Phase 1.** Xcode project (hand-written, objectVersion 77), notch window shell, both themes,
  geometry unit tests using real 14" MacBook Pro values (notch 185×32 pt at x 663.5–848.5).
- **2026-11-25 — Phase 2.** Settings window + 6 panes, KeyboardShortcuts 3.1.0, Sparkle 2.10.1, trial +
  licensing, license proxy (LemonSqueezy + mock) with master key, 43 tests including a live proxy round trip.
- **2026-11-25 — Phase 3.** Media (Music/Spotify via AppleScript, artwork palette, scrub, output devices,
  visualizer), File Tray (bookmarks + staging, drag in/out, AirDrop, ditto zip, drag-to-open), Calendar
  (EventKit, meeting links, banner), collapsed live-activity wings, interactive module tabs, hardened-runtime
  entitlements. 69 tests. Tests caught two real tray bugs before shipping (duplicate drops in one gesture;
  single-file zips not actually zipped / nested in their parent folder).
- **2026-11-25 — Phase 3 fixes from hands-on testing.** Media + Join confirmed working by the user (Spotify,
  Music, Zoom). Fixed: drops onto the notch weren't received (target moved to the whole silhouette; panel
  accepts drags while collapsed; more reliable file-URL loading). Calendar: per-calendar selection, range
  picker, all-day events, day-grouped scrolling list, 5-minute remote re-sync + wake + manual refresh,
  unique IDs for recurring occurrences. 77 tests (incl. real NSItemProvider drops).
- **2026-11-26 — System monitor styles.** User liked the fitted height and the E/P core bars, not the
  CPU/GPU/memory tiles. Refresh picker moved off the notch into Settings only; added 250 ms (1 s default);
  added four switchable styles for the top three components (Cards, Meter rows, Area graphs, Minimal) in
  Settings → Modules → System Monitor. Core bars and power row untouched. 143 tests.
- **2026-11-26 — System monitor feedback.** User asked for a configurable refresh rate and no empty space below
  the monitor. Added the 500 ms / 1 s / 2 s / 5 s setting (time-based sparkline history) and a content-fitted
  layout that measures the tab (window 428 → 355 pt on this Mac). 143 tests.
- **2026-11-26 — System monitor.** New System tab requested by the user (asitop / macmon style). Probed this M4
  first: device-tree core layout, IOKit GPU stats, IOReport channels and `pmgr` frequency tables all readable
  without root; CPU energy reads 0 here, so CPU watts show "—". Live readings matched the machine's state.
  139 tests, including a live sampling test. Phase 5 committed (`c73158e`).
- **2026-11-26 — Codex support.** User asked for Codex alongside Claude Code. Codex hooks (checked against
  OpenAI's current Codex hooks docs) mirror Claude Code's events and decision schema but only run commands, so
  NotchDeck installs a `curl` command hook in `~/.codex/hooks.json`. Generalized installer (`HookAgent`), per-agent
  status/rows, agent names on cards, Codex previews (argv commands, `apply_patch`). 134 tests, including running
  the installed curl command end to end and with NotchDeck away. Keys confirmed working by the user.
- **2026-11-26 — Phase 5 fix.** Card keys didn't work (the panel never had keyboard focus). The card now takes
  focus on appearing (non-activating) and NotchDeck routes Esc / ⌘↩ / ⌘⇧↩ itself. Confirmed in the log:
  "keyboard focus: notch" with VS Code still frontmost. The hook is installed and live: real Claude Code
  requests are reaching the notch.
- **2026-11-26 — Phase 5 built.** Claude Code agent hooks via the `http` hook type (checked against the
  current Claude Code hooks reference: PermissionRequest decision schema, Stop input, HTTP response semantics).
  Local loopback HTTP server, installer, approval cards, queue, hand-back, chime/pulse. Default port moved to
  47823 after finding Cisco AnyConnect on 49152. 128 tests incl. end-to-end runs through the real server;
  live checks: 403 without token, unreachable from LAN, Stop → chime.
- **2026-11-25 — Phase 4 feedback round.** User confirmed Claude chat works. Added live model lists per
  provider (14 Claude / 25 Gemini models on this account) + hand-added IDs, per-model request shaping,
  shortcut recorder in the AI pane with press-again-to-close. Keychain reworked after the user reported
  repeated "confidential information" prompts: one cached item, data protection keychain when signed.
  112 tests.
- **2026-11-25 — Phase 4 built.** AI Chat module (Claude/Gemini/custom clients over raw HTTP SSE, Markdown +
  highlighter, attachments incl. screen capture, history, tall layout, keyboard focus in the non-activating
  panel, ⌥Space). Claude API details checked against the bundled Claude API reference (model IDs, version
  header, streaming events, refusal fallbacks). 103 tests incl. a mock-client streaming loop.
- **2026-11-25 — Phase 3 confirmed.** Media (Spotify + Music, incl. per-session Automation prompt), File Tray
  drop, and Calendar all confirmed working by the user. Committed.
- **2026-11-25 — Drop rebuild + per-session permissions.** User: drop still not working; wants permissions
  only while NotchDeck runs. Drop moved to a native AppKit destination + polled drag detection + lower
  expanded level. Per-session permissions via `tccutil reset` at launch/quit (setting, default on).
  Found and fixed the Automation auto-deny (3 s script timeout expiring during the consent prompt).
  79 tests (pasteboard-driven drops).
