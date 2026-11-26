# NotchDeck — Things to Consider

The running notebook for this project: what exists, how to work it, what to watch out for, and
what's next. Kept up to date as each phase lands. The full product spec is
[`notchdeck_technical_specification.txt`](notchdeck_technical_specification.txt).

_Last updated: 2026-11-25, Phase 2 complete, Phase 3 in progress._

---

## 1. Roadmap status

| Phase | Scope | Status |
|---|---|---|
| 1 | Window shell: NotchPanel, NotchGeometry, hover/click animations, Classic Black + Frosted Glass | ✅ Done |
| 2 | SettingsStore, 6-tab Settings, global shortcuts, 7-day trial + license activation, Sparkle wiring | ✅ Done |
| 3 | Now Playing + visualizer, File Tray (drag in/out, AirDrop, zip), Calendar banner + meeting links | 🚧 In progress |
| 4 | Embedded AI Chat (Claude + Gemini streaming, Markdown, attachments, focus shortcut) | ⏳ Planned |
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
- **Settings:** menu bar icon → Settings… (⌘,), or the gear in the expanded notch. If you hide the
  menu bar icon, open NotchDeck again from Finder/Spotlight to get Settings back.
- **Themes:** switch Classic Black / Frosted Glass live from the notch header, the menu, or Settings → Appearance.
- **Alignment check:** menu → *Show Geometry Outline* draws a 1 pt red line that should trace the physical notch edge.

### Default shortcuts (change in Settings → Shortcuts)

| Action | Default |
|---|---|
| Toggle notch | ⌃⌥N |
| Open AI Chat | ⌥Space (opens the notch until Phase 4 adds the chat) |
| Play/Pause, File Tray, Pomodoro, Camera Mirror, Approve Agent | unset (record your own) |

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

### Still needed (from the spec)
- Phase 3: Now Playing, visualizer, File Tray, AirDrop, Calendar banner, drag-a-file-to-open-the-notch.
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
  Modules/                     feature modules (Phase 3+)
  UI/                          notch root view, components, Settings panes
NotchDeckTests/                Swift Testing suites + fixtures
Config/                        xcconfig + Info.plist template
Server/license-proxy/          Cloudflare Worker + local dev server
Scripts/                       license-keygen.swift
```

---

## 7. Next steps

1. Finish Phase 3 (see §1).
2. Pick a Development Team in Xcode, which ends the Keychain prompts.
3. Before beta: production license keypair, deploy the proxy, set the master key secret, Sparkle keys + appcast.

---

## 8. Log

- **2026-11-25 — Phase 1.** Xcode project (hand-written, objectVersion 77), notch window shell, both themes,
  geometry unit tests using real 14" MacBook Pro values (notch 185×32 pt at x 663.5–848.5).
- **2026-11-25 — Phase 2.** Settings window + 6 panes, KeyboardShortcuts 3.1.0, Sparkle 2.10.1, trial +
  licensing, license proxy (LemonSqueezy + mock) with master key, 43 tests including a live proxy round trip.
