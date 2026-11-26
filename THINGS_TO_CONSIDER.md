# NotchDeck — Things to Consider

The running notebook for this project: what exists, how to work it, what to watch out for, and
what's next. Kept up to date as each phase lands. The full product spec is
[`notchdeck_technical_specification.txt`](notchdeck_technical_specification.txt).

_Last updated: 2026-11-25, Phase 3 complete and confirmed by hand, Phase 4 in progress._

---

## 1. Roadmap status

| Phase | Scope | Status |
|---|---|---|
| 1 | Window shell: NotchPanel, NotchGeometry, hover/click animations, Classic Black + Frosted Glass | ✅ Done |
| 2 | SettingsStore, 6-tab Settings, global shortcuts, 7-day trial + license activation, Sparkle wiring | ✅ Done |
| 3 | Now Playing + visualizer, File Tray (drag in/out, AirDrop, zip), Calendar banner + meeting links | ✅ Done (confirmed) |
| 4 | Embedded AI Chat (Claude + Gemini streaming, Markdown, attachments, focus shortcut) | 🚧 In progress |
| 5 | Claude Code agent hooks (127.0.0.1 server, hook installer, Approve/Deny card) | ⏳ Planned |
| 6 | Live Activities (battery, Bluetooth, Downloads), Pomodoro, To-Dos, Clipboard, Camera Mirror | ⏳ Planned |

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

## 3. Things to consider ⚠️

### Signing and the Keychain
- **Keychain prompts after every rebuild.** There's no code-signing certificate on this Mac, so builds
  are signed ad-hoc and each rebuild gets a new signature. macOS then asks once per rebuild to let
  NotchDeck read its Keychain item. **Fix:** in Xcode → target → Signing & Capabilities, choose your
  Apple Development team (a free Apple ID works). For quick UI work, use `-notchdeck.debug.ephemeralSecureStore YES`.
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
  needs a separate helper; it's tracked in §5.
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

## 4. Secrets and configuration

| File | Committed? | Contains |
|---|---|---|
| `.env` | ❌ git-ignored (mode 600) | `MASTER_LICENSE_KEY`, DEV `SIGNING_KEY_JWK`, `MERCHANT`, `PRODUCT_ID` |
| `.env.example` | ✅ | The same keys, blank, as a template |
| `Config/NotchDeck.xcconfig` | ✅ | License API URL, **public** keys, purchase URL, Sparkle feed/key |
| `Config/Info.plist` | ✅ | Pulls the xcconfig values into the app's Info.plist |
| Keychain (`com.notchdeck.NotchDeck`) | — | `license.vault` (trial + receipt), `api.anthropic`, `api.gemini` |

Never commit `.env`. The app binary contains only public keys; the master key and signing private key
exist only in `.env` and Cloudflare secrets.

---

## 5. Features

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
- **Calendar** (Phase 3): EventKit, upcoming events with Join buttons, meeting-link parser
  (Zoom, Meet, Teams, Webex), "In 12m: …" collapsed banner.

### Still needed (from the spec)
- Media fallback for browsers/system audio (`mediaremote-adapter`), real audio-level visualizer (optional).
- Reminders (EventKit) alongside Calendar.
- Multi-item drag-out from the tray.
- Phase 4: AI Chat (SSE streaming, Markdown/code rendering, history, attachments, screen capture).
- Phase 5: local hook server, `~/.claude/settings.json` installer, Approve/Deny card.
- Phase 6: battery/Bluetooth/Downloads Live Activities, Pomodoro, To-Dos, Clipboard history, Camera Mirror.
- Release: Developer ID signing, notarization, DMG, production license keys, deployed proxy, Sparkle appcast.

---

## 6. Project layout

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

## 7. Next steps

1. **Hands-on check of Phase 3** (I couldn't see the screen while building it):
   - Play something in Spotify/Music → collapsed wings show art + visualizer; open the notch → controls, scrub, output picker.
   - ✅ Media (Spotify + Music controls) and ✅ Join on a Zoom event: confirmed by you.
   - ✅ Drag a file onto the notch → it opens into the tray and stores it (confirmed after the AppKit rebuild).
     Still worth trying: drag back out, AirDrop, Zip.
   - ✅ Calendar (selection, refresh, scrolling): confirmed.
   - Quit and reopen NotchDeck → it asks again for Spotify/Music control and Calendars.
   - Calendar: choose calendars in Settings → Modules; check previously missing events now appear; within 15 min
     of a meeting the collapsed banner appears.
2. Phase 4: embedded AI Chat (Claude + Gemini streaming).
3. Pick a Development Team in Xcode, which ends the Keychain and Automation re-prompts.
4. Before beta: production license keypair, deploy the proxy, set the master key secret, Sparkle keys + appcast.

---

## 8. Log

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
- **2026-11-25 — Phase 3 confirmed.** Media (Spotify + Music, incl. per-session Automation prompt), File Tray
  drop, and Calendar all confirmed working by the user. Committed.
- **2026-11-25 — Drop rebuild + per-session permissions.** User: drop still not working; wants permissions
  only while NotchDeck runs. Drop moved to a native AppKit destination + polled drag detection + lower
  expanded level. Per-session permissions via `tccutil reset` at launch/quit (setting, default on).
  Found and fixed the Automation auto-deny (3 s script timeout expiring during the consent prompt).
  79 tests (pasteboard-driven drops).
