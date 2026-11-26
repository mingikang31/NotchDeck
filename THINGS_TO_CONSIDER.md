# NotchDeck — Things to Consider

The running notebook for this project: what exists, how to work it, what to watch out for, and
what's next. Kept up to date as each phase lands. The full product spec is
[`notchdeck_technical_specification.txt`](notchdeck_technical_specification.txt).

_Last updated: 2026-11-26, Phase 5 committed; System Monitor + Phase 6 in progress._

---

## 1. Roadmap status

| Phase | Scope | Status |
|---|---|---|
| 1 | Window shell: NotchPanel, NotchGeometry, hover/click animations, Classic Black + Frosted Glass | ✅ Done |
| 2 | SettingsStore, 6-tab Settings, global shortcuts, 7-day trial + license activation, Sparkle wiring | ✅ Done |
| 3 | Now Playing + visualizer, File Tray (drag in/out, AirDrop, zip), Calendar banner + meeting links | ✅ Done (confirmed) |
| 4 | Embedded AI Chat (Claude + Gemini streaming, Markdown, attachments, focus shortcut) | ✅ Done (Claude chat confirmed) |
| 5 | Claude Code & Codex agent hooks (127.0.0.1 server, hook installer, Approve/Deny card) | ✅ Done (Claude Code confirmed; Codex believed working) |
| 6 | Live Activities (battery, Bluetooth, Downloads), Pomodoro, To-Dos, Clipboard, Camera Mirror | 🚧 In progress |
| + | System Monitor tab (CPU / GPU / memory, asitop/macmon-style), requested 2026-11-26 | 🚧 In progress |

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
  once a text field in the notch has focus (arrives with AI Chat, Phase 4).
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
- **Calendar:** open the Calendar tab and click *Connect Calendar* (macOS asks for access). Shows upcoming
  events grouped by day (Today / Tomorrow / …). With more than three, **scroll** (trackpad/wheel) through them;
  a fade at the bottom and "scroll for more" in the header show there's more. Green **Join** button for Zoom, Google Meet,
  Teams and Webex links. The ↻ button re-syncs now; the sliders button opens the calendar settings.
- **Choosing calendars:** Settings → Modules → Calendar → *Choose Calendars…* (grouped by account). Same place:
  range (next 24 h / 3 days / 7 days, default 3 days) and *Include all-day events* (default on).

### Default shortcuts (change in Settings → Shortcuts)

| Action | Default |
|---|---|
| Toggle notch | ⌃⌥N |
| Open AI Chat | ⌥Space (opens the notch until Phase 4 adds the chat) |
| Play / Pause media, Open File Tray | unset; works once you record one |
| Pomodoro, Camera Mirror, Approve Agent | unset; take effect in later phases |

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
  (Automation, Calendars, Reminders, Camera) with `tccutil reset <service> com.notchdeck.NotchDeck` at
  launch and at quit. Grants last while it runs; the next launch asks again. No admin rights needed.
  Turn it off to have macOS remember approvals normally.
  - Expect prompts at **every launch** (including launch at login): "control Spotify/Music" when a player
    is running, and Calendars if you had connected it before.
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
- **Media** (Phase 3): Music + Spotify Now Playing, artwork with dynamic color extraction and ambient glow,
  scrub bar, transport controls, output device picker, bars/wave visualizer, collapsed live pill.
- **File Tray** (Phase 3): drop zone (files, images, text, links), thumbnails + size badges, drag out,
  AirDrop, zip, remove/clear, persistence across launches, drag-a-file-to-open-the-notch.
- **AI Chat** (Phase 4): Claude (Opus/Sonnet/Haiku 5.5), Gemini, custom OpenAI-compatible endpoint; streaming
  Markdown with highlighted code + copy buttons; thinking summaries; history + new chat; attachments (files,
  ⌘V, screen selection, File Tray); ⌥Space focused-input shortcut; refusal fallbacks.
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
- Phase 6: battery/Bluetooth/Downloads Live Activities, Pomodoro, To-Dos, Clipboard history, Camera Mirror.
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
  UI/                          notch root view, components, Settings panes
NotchDeckTests/                Swift Testing suites + fixtures
Config/                        xcconfig, Info.plist template, entitlements
Server/license-proxy/          Cloudflare Worker + local dev server
Scripts/                       license-keygen.swift
```

---

## 8. Next steps

1. **Hands-on check of Phase 5 (Claude Code approvals):**
   - Settings → AI & Agents → **Send Test Request**: a card appears; try Approve and Deny.
   - ✅ **Claude Code:** hook installed; real requests reach the notch; card keys confirmed working.
   - ✅ **Codex:** believed working by the user (2026-11-26); revisit if anything misbehaves.
   - Let a task finish → chime + "Done" pulse. Quit NotchDeck and confirm Claude Code still asks in the terminal.
2. **Phase 4 (AI Chat):** ✅ Claude chat confirmed. Still worth trying: the new model menu (Gemini models),
   adding a model ID by hand, the open/close shortcut.
3. **Phase 3 checks:**
   - Play something in Spotify/Music → collapsed wings show art + visualizer; open the notch → controls, scrub, output picker.
   - ✅ Media (Spotify + Music controls) and ✅ Join on a Zoom event: confirmed by you.
   - ✅ Drag a file onto the notch → it opens into the tray and stores it (confirmed after the AppKit rebuild).
     Still worth trying: drag back out, AirDrop, Zip.
   - ✅ Calendar (selection, refresh, scrolling): confirmed.
   - Quit and reopen NotchDeck → it asks again for Spotify/Music control and Calendars.
   - Calendar: choose calendars in Settings → Modules; check previously missing events now appear; within 15 min
     of a meeting the collapsed banner appears.
4. Phase 6: Live Activities (battery, Bluetooth/AirPods, Downloads), Pomodoro, To-Dos, Clipboard, Camera Mirror.
5. Pick a Development Team in Xcode, which ends the Keychain and Automation re-prompts.
6. Before beta: production license keypair, deploy the proxy, set the master key secret, Sparkle keys + appcast.

---

## 9. Log

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
