# Dew

A small, fast macOS + iOS browser built directly on the system WebKit (WKWebView), with a Dia-style UI
and **Spaces**: separate browsing identities (e.g. Personal and Work) in one window, each with its own
cookies, logins, history and tabs.

Release build of the Mac app: ~1.4 MB (vs. ~1.3 GB for Dia), no third-party dependencies.

## Build and run

```sh
xcodegen generate        # after adding/removing files
open Dew.xcodeproj       # schemes: Dew-macOS, Dew-iOS
```

Both targets use Xcode-managed signing (team UTJ8CD785K, needed for iCloud); from the command line add `-allowProvisioningUpdates`. For iOS on a device pick your Team under Signing & Capabilities.

## Settings

Mac: Dew → Settings (⌘,): General, Appearance, Spaces, Passwords, Privacy, AI Chat, Shortcuts. iOS: ⋯ → Settings…
(or the cog side button on iPhone Duo): General, Appearance & Layout, then Spaces, Passwords, Privacy & Ad Blocking,
then AI Chat. General is behaviour (default browser, search, tab suspension, import, iCloud); Appearance is how Dew
looks and where things sit (website colour, bookmarks bar, address bar position, Duo side buttons). The space
(profile) menu only has space things; its **Manage Spaces…** opens Settings at Spaces.

## How spaces work

Each `Space` has a UUID, and every tab in it uses `WKWebsiteDataStore(forIdentifier: space.id)`, a
persistent, fully separate store for cookies, local storage, IndexedDB and cache. Signing in to Google in
"Work" doesn't affect "Personal". Deleting a space removes its data store from disk.
"Open in Space" on a tab reopens its URL in another space (cookies are never shared).

## iPhone, iPhone Duo and iPad

- **iPhone Duo (folded and open):** the browser's buttons (back, forward, reload, tabs with count, new tab, space,
  menu) are a glass capsule inside the Duo's right-edge status strip, anchored to the bottom and growing upward
  (iOS's own toolbar placement starts at the top). No tab bar or tab strip: the tabs button opens the tab view (an
  overlapping deck of cards, with + and ✓ in the right-edge column); Settings is in the space menu. The address bar
  is a floating capsule over the page (which scrolls underneath; `obscuredContentInsets` keeps fixed page elements
  clear of it), top or bottom, so moving it never moves the buttons.
- **Side Buttons** (Settings → Appearance & Layout → Side Buttons): choose which buttons the Duo's side column shows and their
  order (Back, Forward, Reload, Tabs, New Tab, Chat, Bookmark, Share, Space, Settings, More). Drag to reorder, − to
  remove, + to add; More or Settings always stays so Settings is reachable. `iOS/SideButtonsSettings.swift`.
- **Chat on the open Duo** sits beside the page like split view (two panes and a drag handle; width remembered);
  folded, it's a full-height sheet.
- **Page under the side status bar** (Settings → General, off by default): the page fills the right edge too,
  with iOS's status pill and the button capsule floating over it.
  Recognised by the Duo's side status strip. Checked on the device (open).
- **Address bar position** (Settings → General): Automatic, Top or Bottom. Automatic: top on iPhone Duo and iPad,
  bottom bar on other iPhones.
- **Other iPhones / iPad:** toolbar layout (address centred on wide screens, its own row on narrow ones, tab strip
  under it) or the bottom bar with a tab grid.
- **Split view** shows side by side at regular width (Duo open, iPad); narrow screens show the focused pane.
- Only size classes, safe areas and standard containers; tabs own their web views, so folding/unfolding keeps
  the page, scroll position and form input.
- Debug: `-DewOpenURL <url>`, `-DewOpenSplitURL <url>`, `-DewForceDuoLayout YES`.

## iCloud: tabs from other devices, and Handoff

- **Tabs from your other devices:** each device writes one CloudKit record (private database, your own iCloud,
  zone `DewSync`, container `iCloud.com.local.dew`; the container, keychain group and Handoff type keep the
  original `com.local.dew` names from before the bundle ID became `com.automate.dew`) listing its open tabs per space; private tabs are never
  included. Others appear under **From Your Other Devices** in the Mac's ⌄ popover and under the iOS tab grid,
  with **Open All** per space. Tabs open in the space with the same name, else the current one. Syncs a few seconds
  after tabs change, on launch/activation and every 2 minutes. Toggle in Settings → General → iCloud.
  Code: `Shared/Model/CloudSync.swift`.
- **Bookmarks and spaces:** one CloudKit record per bookmark, keyed by space name + URL (space IDs differ per
  device), carrying the space's colour and icon so a missing space is created. Adds, renames (newest edit wins)
  and deletions sync. A bookmark missing on one side only counts as deleted if this device had already confirmed
  syncing it (keys are remembered only after iCloud accepts the upload), so a failed save never wipes anything.
  Toggle: Settings → General → iCloud → Sync bookmarks and spaces.
- **Handoff:** the page you're viewing is offered to your other devices (Dock / app switcher); falls back to
  Safari where Dew isn't installed. Never in private browsing.
- Signing is Xcode-managed (team UTJ8CD785K) because iCloud needs a provisioning profile; build from the command
  line with `-allowProvisioningUpdates`. The CloudKit schema is in the Development environment; deploy it to
  Production in the CloudKit Console before TestFlight/App Store builds.

## iOS address editor

Tapping the address bar (iOS) opens the address in place (above the keyboard when the bar is at the bottom) with a
round ✕ to cancel; suggestions fill the screen: open tabs, bookmarks and history, then live suggestions from the
search engine (Google and DuckDuckGo have open endpoints; toggle under Settings → General). In private browsing the
field is grey with an eye. Debug: `-DewEditAddress <text>`, `-DewPrivate YES`.

## Cookie banners

Settings → Privacy → Cookie banners: **Reject automatically** (default), Accept automatically, or Leave them. A script
in Dew's own JS world (all frames) clicks the right button for OneTrust, Cookiebot, Didomi, Quantcast, Usercentrics,
TrustArc, Complianz, CookieYes, Osano, iubenda, Google Funding Choices and others, falling back to a "Reject all" /
"Accept all"-style button (several languages) inside an element that is clearly a cookie banner. Reject mode never
accepts. Sites using Sourcepoint in a cross-origin frame (e.g. spiegel.de) aren't handled yet.
`Shared/Model/CookieBanners.swift`.

## Default browser

Mac: **Set Dew as Default Browser…** appears in the Dew menu (and Settings → General) when it isn't the default;
macOS asks to confirm. iOS: ⋯ → Set as Default Browser… opens Settings; iOS only lists Dew there once Apple grants the
managed `com.apple.developer.web-browser` entitlement. The iOS app already meets Apple's requirements (declares `http`
and `https`, uses WKWebView, opens with an address field, opens links directly, no Universal Links or restricted
privacy keys). To finish: request the entitlement at https://developer.apple.com/contact/request/default-browser-entitlement/
(team UTJ8CD785K, bundle ID com.automate.dew); once approved, enable it for the App ID in Certificates, Identifiers & Profiles,
add `com.apple.developer.web-browser: true` to the iOS entitlements in `project.yml`, and rebuild. Adding it before approval
breaks signing.

## Private browsing

⇧⌘N (File → New Private Tab), or the space menu / ⋯ on iOS. Private tabs use an in-memory WebKit store, record no
history or recently closed tabs, aren't saved with the session, don't offer to save passwords and can't be
bookmarked. The chrome turns dark. Closing the last private tab wipes its cookies and returns to your space.

## Split view

Like Dia: 2–4 tabs side by side (Mac, and iOS at regular width). Right-click a tab → **Show Beside Current Tab**,
or **New Split Tab** (⌥⌘T) for a blank pane; **Separate Split View** or a pane's header buttons undo it. Drag the
handles between panes to resize. Click/tap a pane to focus it; the address bar and navigation act on the focused
pane. A split shows as one joined tab in the strip. Splits are saved with the session.

## Chat

Like Dia's Chat: ⌘E or the ✨ button in the address bar (Mac) opens a panel beside the page; on iOS it's ⋯ → Chat
(a sheet). The tab you're on is shared with your question automatically (all panes, in split view); **+** adds
other open tabs from any space, and ✕ on a chip stops sharing one. Anything selected on a page goes along too.
Tabs that are suspended or haven't been opened are loaded in the background so they can be read.

- **Providers** (Settings → AI Chat → Answer with; the model menu in the panel header switches too):
  - **Claude:** an Anthropic API key (Keychain, service "Dew AI"); model (Opus 5.5 default, Sonnet 5.5, Haiku 5.5,
    Fable 5.2) and depth (`effort`). Anthropic doesn't allow other apps to use Claude subscriptions, so it's key-only.
    Server-side refusal fallbacks (`fallbacks: "default"`) are on, except for Haiku.
  - **ChatGPT plan:** "Continue with ChatGPT" (OpenAI's Sign in with ChatGPT for open-source/local apps). OAuth with
    PKCE in the system sign-in sheet, redirected to a one-off server on `127.0.0.1` (port 1455, else any free port;
    the Mac app has the `network.server` entitlement for this). First sign-in registers with `dynamic_agent_client` and
    OpenAI issues a client ID that's reused; tokens are in the Keychain, refreshed one at a time (they rotate), and
    revoked on sign-out. Requests go to `/v1/responses` with `store: false, stream: true`, the full history each time.
    Shows "Using ChatGPT plan · Manage usage" and OpenAI's one-time welcome. Debug: `-ChatGPTSendHostID YES` sends
    `ext_agent_host_id` (OpenAI's devkit leaves it off unless the deployment supports it).
  - **Other (OpenAI-compatible):** OpenRouter, the OpenAI API, Ollama, LM Studio or a custom `/v1` server, via
    streaming Chat Completions. The model list comes from `/models`, or type any model ID.
- **How it works:** `Shared/Model/Chat.swift` (session, page reading), `ChatProviders.swift` (streaming clients),
  `ChatGPTAuth.swift` (sign-in). Page text is read with `innerText` in Dew's own JS world and sent inside `<tab>` tags;
  the system prompt says that text is web content, not instructions. Pages over 400,000 characters are cut, and both
  the model and the chip's tooltip say so. A page already sent and unchanged isn't sent again. The conversation is kept
  provider-neutral, so you can switch provider mid-chat (Claude's own replies are replayed exactly, thinking included).
- **Actions** (Settings → AI Chat → "Let Chat open, close and switch tabs", on by default): the model can list, read,
  open (or search), close and switch tabs, search history and bookmarks, and show tabs side by side
  (`Shared/Model/ChatTools.swift`). Tabs are named to it by the first 8 characters of their ID. Each action appears in
  the answer as a row (click to show the tab); closing has **Undo**, and the model is told about undos with the next
  question. Up to 10 tool rounds per question. Private tabs are only visible to it in private browsing. The system
  prompt tells it to act only on the user's own words, never on instructions in page text, and not to put page text
  into addresses. Works with all three providers (Anthropic tool use with eager input streaming, Responses
  function calls, Chat Completions `tool_calls`); local models without tool support answer without them.
- **Look:** your messages are bubbles in the space's colour; answers are soft bubbles with full Markdown (headings,
  lists, code blocks with Copy, quotes, tables) via `Shared/Views/MarkdownView.swift`. It's a general assistant too,
  not only for tabs. Debug: `-DewOpenChat YES` opens the panel, `-DewChatSample YES` loads a sample conversation
  (nothing is sent), `-DewChatAttachTabs YES` shares six tabs. iOS: `-DewOpenSettings YES -DewSettingsPage ai`.
- Nothing is sent until you ask, and conversations aren't saved (the pencil button starts a new chat).

## Mac shortcuts

| | |
|---|---|
| ⌘T | New tab (Dew's new tab page: search, URL, open tabs, history) |
| ⌘L | Edit the address of the current tab |
| ⌘W / ⌘⇧T | Close tab / reopen closed tab |
| ⌘1…⌘9, ⌃Tab | Switch tabs |
| ⌃1, ⌃2… | Switch to space 1, 2… (order set in Settings → Spaces) |
| ⌃⌥→ / ⌃⌥← | Next / previous space |
| ⇧⌘N | New private tab |
| ⌥⌘N | New space |
| ⌘E | Show / hide Chat |
| ⌘, | Settings: manage spaces (rename, colour, icon, reorder, delete), appearance |
| ⌘D | Bookmark / un-bookmark the page |
| ⌘⇧B | Show / hide bookmarks bar |
| ⌥⌘P | Pin / unpin tab |
| ⌥⌘T | New split tab (blank pane beside the current tab) |
| ⌘[ ⌘] ⌘R | Back, forward, reload |
| ⌘+ ⌘- ⌘0 | Page zoom |
| ⌘-click / middle-click | Open link or bookmark in background tab |
| Middle-click a tab | Close it |
| Right-click a link | Open Link in New Tab / in Background Tab / Chat About Link (iOS: press and hold) |
| Mouse side buttons over the tab strip | Previous / next space (elsewhere: back / forward) |

On iPhone, swipe sideways along the bottom bar to switch space; the space button menu has Rename and Manage Spaces.

## New tab page

⌘T or + opens a blank tab with Dew's new tab page: the Dew mark (the drop and its reflection, static), a large
search box, and the space's bookmarks as tiles. `Shared/Views/DewMark.swift`.

## Favicons

Icons are fetched for the exact scheme, host and port (local devices like `192.168.1.20:7878` matter). If an icon
address fails (missing, or redirected to a login page), Dew reads the page for the icons it declares, then tries
`/favicon.ico`, `/favicon.png` and `/apple-touch-icon.png`. Visiting a site teaches its bookmarks the real icon.
Local devices with self-signed certificates are allowed for icon fetches only; plain-HTTP icons are allowed
(`NSAllowsArbitraryLoads`, as a browser needs).

## Bookmarks

Bookmarks belong to a space. They appear in the bookmarks bar (under the address bar, tinted with the site colour),
the Bookmarks menu, the command bar and the start page. Click opens in the current tab, ⌘-click in a background tab. Icons only by default (names in tooltips), like Dia;
turn names on with Bookmarks → Show Bookmark Names, right-clicking the bar, or Settings → General.
Drag to reorder; drop a tab onto the bar to bookmark it; right-click to rename or delete.

## Import from Dia

File → Import from Dia… (or Settings → General). Choose Dia's `User Data` folder (the sandbox needs your
permission; the panel opens there), then map each Dia profile to a new or existing space and pick bookmarks
and/or history. Bookmarks come from Dia's bookmarks bar (folders flattened) with Dia's own favicons; history keeps
visit counts and dates (most recent 5,000 per profile). Cookies and passwords can't be imported: Dia encrypts them
with a key in its own Keychain item, which a sandboxed app can't read. Code: `macOS/DiaImporter.swift`.

## Passwords

Settings → Passwords (Touch ID / password to view). Saved per space, in one AES-GCM encrypted file whose key
is in your Keychain (`Shared/Model/PasswordStore.swift`). Clicking into a login field on an HTTPS site shows your saved
usernames for that site in a dropdown (type to narrow, ↑/↓ + Return); Dew also fills automatically when there's exactly
one login, and the 🔑 in the address bar lists them too, and offers to save or update after you sign in.
The autofill script runs in an isolated JS world, so pages can't see or call it.

**Import:** export a CSV from Dia (its password manager → Export passwords), Chrome, Safari, 1Password or Bitwarden,
then Settings → Passwords → Import CSV… and pick the space. Dew offers to move the CSV to the Trash afterwards.

## Privacy

Settings → Privacy, per space:
- **Clear History…** / **Clear Cookies…** (cookies clears logins, storage and cache for that space only).
- **Clear automatically:** Never, When Dew quits, Every day, Every week or Every month, choosing history and/or
  cookies. "When Dew quits" also runs at the next launch, so it still happens after a force-quit (and on iOS,
  where apps don't really quit).

## Ad blocking

On by default; toggle with the shield in the address bar, Dew → Block Ads, or Settings → Privacy. Uses WebKit's
native content blocker (rules compiled once and applied inside WebKit, so it's fast and adds nothing per request).
A small built-in list works immediately; EasyList (ads) and EasyPrivacy (trackers) are downloaded, converted
(`FilterListConverter` in `Shared/Model/ContentBlocker.swift`) and refreshed weekly (~115k rules). Scores 100/100
on adblock-tester.com's contextual-advertising test (40 with blocking off).

## Website colour

Like Dia, the selected tab and address bar take on the colour at the top of the current page (sampled by a
small script in an isolated JS world that re-checks on scroll/resize), with text switching to light or dark
to stay readable. Toggle it under View → Match Toolbar to Website Colour or in Settings → Appearance.
On iPhone it tints the status-bar area when it would stay readable.

The tab strip follows Dia: the space name (in its colour) and pinned tabs share one capsule; click the name to
switch spaces, with each space's shortcut shown. Tabs have no chrome until hovered, titles fade out instead of
"…", the selected tab is taller and flows into the page, and tabs condense toward icon-only as you open more.
The ⌄ at the far right opens a Dia-style popover: search, open tabs, recently closed tabs and recent
history, with **Show All History** (⌘Y) at the bottom: a full, searchable history window grouped by day, per space.

Tabs can be dragged to reorder, including into and out of the pinned group. Right-click a tab for more.

## App icon

A blue drop and its reflection on a white tile. The source is `Tools/AppIcon.svg`;
`Tools/render-icon.swift` renders it with WebKit into the Mac icon (rounded tile on the macOS icon grid, hairline
edge and soft shadow so white reads in the Dock) and a full-bleed, opaque iOS icon (iOS rounds the corners). To regenerate after editing the SVG:

```sh
swiftc -O -o /tmp/render-icon Tools/render-icon.swift && /tmp/render-icon Tools/AppIcon.svg /tmp/dewicon
cp /tmp/dewicon/icon-ios.png iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png
for s in 16 32 128 256 512; do for x in 1 2; do p=$((s*x)); sips -z $p $p /tmp/dewicon/icon-mac.png \
  --out macOS/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@${x}x.png; done; done
```

## Layout

```
Shared/Model   Space, BrowserTab (owns a lazily created WKWebView + delegates), BrowserStore
               (spaces, tabs, history, persistence to Application Support/Dew/state.json), downloads, URL parsing
Shared/Views   WebContainer (swaps the selected tab's web view in), command bar, space editor, favicons
macOS/         Window, Dia-style tab strip + content card, menu commands
iOS/           Bottom address bar, space menu, tab grid with space chips
```

Restored tabs don't create a web view until you open them, so launch is instant with any number of tabs.

**Suspend unused tabs** (Settings → General: Never by default, or after 15 min to 1 day): once a minute, tabs that
haven't been on screen for that long release their web view. Their back/forward history and scroll position are kept
(`WKWebView.interactionState`) and the page reloads when you return. Tabs on screen (including split panes), loading,
playing audio/video or using the camera/microphone are skipped.

## Ideas / not done yet

- Vertical sidebar tab mode, tab groups, split view
- Chat: tab groups (Dew has none yet), actions on bookmarks
- Find in page on macOS (iOS uses the system find bar), content blocking via `WKContentRuleList`
- Per-space search engine, password autofill integration, Safari Web Extensions
- Multiple windows on Mac; iCloud sync of spaces/tabs between Mac and iPhone
