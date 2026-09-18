# NauticusClassicResurrected

A World of Warcraft addon that tracks boat/zeppelin arrival & departure
schedules and shows them on the world map/minimap. See `README.md` for the
user-facing feature description.

## Target platform

Two official Blizzard clients, both targeted from the one `.toc` via
`## Interface: 11509, 16001` — a comma-separated list, which the Forever
client is known to accept (WowApiExplorer loads there with
`## Interface: 11509, 16001, 110200`). Era's tolerance of the comma list is
*not* confirmed; if Era ever flags the addon out-of-date, that's the cause,
and the fix is per-flavour `.toc` files rather than a single shared one.

The two builds:

- **WoW Classic Era** — `11509` = client patch 1.15.9.
- **"WoW: Forever"** — `16001` = client patch 1.60.1, in beta as of
  2026-09-18.

Both are Blizzard's own clients — not a private server, not Turtle WoW, not
any other custom server. If an `Interface` value has moved on, re-derive the
patch version the same way (`1.MINOR.PATCH` -> `1MINORPATCH`, each segment
zero-padded to 2 digits) rather than assuming.

Anything used unconditionally has to exist on **both** clients. Forever's
`C_` surface is close to a superset of Era's (407 systems vs 337), so Era is
the binding constraint in practice; where a Forever-only API is worth taking
advantage of, guard it at runtime the way the vendored HereBeDragons already
guards `C_Map.GetMapWorldSize` / `C_Minimap.GetViewRadius` (present on
Forever, absent on Era).

Do not assume an API is available just because it shows up in a generic WoW
API reference — check the ground-truth dumps in the
[WowApiExplorer](https://github.com/sam-k-taylor/WowApiExplorer) repo first:
`_classic_era_/11509.json` and `_classic_beta_/16001.json`. Each is named
for the `## Interface` value it was dumped from, so re-derive the filenames
the same way if the `.toc` moves on. They're structured dumps of every
`C_`-namespaced function/event/table actually reported by **that client's
own** `/api` command (see that project's README for how they were
generated) — i.e. client-verified, not a retail guess, and trustworthy as
ground truth for whether a `C_` API exists there. Caveat: they only capture
`C_`-namespaced tables (what `/api system list` reflects) — old-style global
FrameXML functions (e.g. `JoinChannelByName`, `GetChannelList`, most
UI/frame code) aren't in them at all, so their silence on those means
nothing either way. When in doubt about one of those, prefer reusing a call
already made elsewhere in this codebase (grep for it first) over introducing
a new one on faith.

This isn't hypothetical: on Forever, the old-style global `MouseIsOver`
(a FrameXML convenience wrapper around the `Frame:IsMouseOver()` widget
method) turned up nil, crashing `NautUI.lua`'s `MapIcon_OnEnter` tooltip
handler (`attempt to call a nil value`) — confirmed via an in-game Lua error
readout, since neither dump could have shown it either way. Fixed by calling
`data.worldmap_icon:IsMouseOver()` directly instead of going through the
global — the base widget method is a much safer bet than a FrameXML
convenience wrapper on an unfamiliar client. Prefer that pattern (call the
widget/unit method directly) over an old-style global wrapper when adding
new code, even on Era.

There is no local WoW client to test against in this dev environment —
changes here can't be run/verified in-game by Claude, on either client; say
so explicitly rather than claiming a fix works, and ask the user to confirm
in-game. Anything touching the comms workarounds below needs confirming on
both clients separately: each one is a workaround for an empirically
observed Era restriction, and whether Forever still has that restriction is
untested.

**A fix made for Forever must not change Era's behavior.** Since both
clients load the same `.lua` files off the one `.toc`, there's no separate
"Forever build" to change in isolation — every edit lands on Era too. Before
calling a Forever-motivated fix done, either show it's a no-op on Era (e.g.
the `CLASSIC_AZEROTH_WORLDMAP_RECT` fix in `NautCore.lua` reuses the exact
constants HBD's own `WoWClassic` branch already used, so it's byte-for-byte
identical to Era's prior behavior — not a guess, actually traced through)
or, if the two clients genuinely need different behavior, branch on a
runtime client check (e.g. `WOW_PROJECT_ID`, confirmed to read `1`
(`WOW_PROJECT_MAINLINE`) on Forever and presumably the Classic-specific
constant on Era — verify before relying on it) rather than changing the
shared code path outright.

For the latter case, `NautCore.lua` has `IS_FOREVER` (declared right after
the coordinate-fix constants above, so it's in scope everywhere): `select(4,
GetBuildInfo()) >= FOREVER_INTERFACE` — the *running* client's interface
number, not the `.toc`'s declared list, using `>=` so a later Forever patch
doesn't fall back to reading as Era. Re-derive `FOREVER_INTERFACE` the same
way as the `.toc`'s `Interface` line if it moves on. First real use: Forever
plays its own docking sound when a tracked transport arrives, so the
addon's own `arrivalDing` (`PlaySound(5495)` in `CheckArrivals_OnUpdate_Unsafe`)
is unconditionally skipped when `IS_FOREVER`, and its options-panel toggle
is hidden there too — Era keeps both, since Era has no built-in equivalent.

## File layout

- `NautCore.lua` — Ace3 addon lifecycle (`OnEnable`), event handling, transit
  trigger detection, map/minimap icon placement, versioning.
- `NautComms.lua` — all inter-player communication (see below).
- `NautUI.lua` — LDB broker text/tooltip, UI widgets.
- `data.lua` — static transport route data (vessel names, endpoints, faction).
- `Locales/` — AceLocale translation tables.
- `Libs/` — vendored third-party libraries (Ace3, HereBeDragons, LibDBIcon,
  LibDataBroker). Refresh with `./update-libs.sh` (only re-fetches files
  that already exist locally; `LibSimpleFrame-Mod-1.0` is a hand-patched
  fork and is deliberately never touched by it).
- `package.sh` — builds the release zip for a GitHub release from a git ref;
  keeps the zip's internal folder name == the addon name (not
  `<addon>-<version>`), which is required for WoW's addon-update detection.

## Transit detection & coordinate system (NautCore.lua)

Boat/zeppelin routes in `data.lua` (`packedData`, unpacked into `transitData`
in `NautCore.lua`) are recorded as points on the player's own path recorded
while riding the transport, stored as one of two coordinate types per
transit id (`NauticusClassic.coordsType`):

- `coordsType[id] < 0` — the route crosses zones/continents (every boat and
  zeppelin), so points are stored as fractional coordinates on the combined
  "Azeroth world map" (the continent-composite map, not any single zone),
  via what was originally `HBD:GetAzerothWorldMapCoordinatesFromWorld` /
  `HBD:GetWorldCoordinatesFromAzerothWorldMap` (HereBeDragons-2.0.lua).
- `coordsType[id] >= 0` (the Deeprun Tram) — the whole route stays inside
  one zone/instance (that uiMapID), so points are stored as raw per-instance
  world coordinates directly, no continent-composite conversion involved.

**"WoW: Forever" (Interface 16001) broke every `coordsType < 0` route** —
i.e. every boat/zeppelin, but not the Tram — because HereBeDragons picks its
Azeroth-world-map calibration (`HBD.worldMapData[0]`/`[1]`, the
width/height/left/top of the fraction-to-world-coordinate transform) off the
old-style `WOW_PROJECT_ID` global at load time (see `fixupZones()` in
`Libs/HereBeDragons/HereBeDragons-2.0.lua`) — not a `C_` API, so it can't be
checked against the WowApiExplorer dumps; this had to be confirmed live via
the `/nautcoords` slash command (`NautCore.lua`, near `DebugMessage`).
Confirmed: Forever reports `WOW_PROJECT_ID = 1` (`WOW_PROJECT_MAINLINE`),
which none of HBD's `WoWClassic`/`WoWBC`/`WoWWrath`/`WoWCata`/`WoWMists`
checks match, so HBD silently falls into its retail-scale rect
(`{76153.14, 50748.62, 65008.24, 23827.51}` for the Eastern Kingdoms
instance) instead of Classic's (`{44688.53, 29795.11, 32601.04, 9894.93}`) —
a fraction shift large enough that every 20-yard trigger/dock proximity
check misses outright. The underlying raw per-continent world coordinates
(`HBD:GetPlayerWorldPosition`) are *not* affected by this — only the
fractional encoding used to store/replay `coordsType < 0` routes is, which
is why this was fixable purely computationally, without re-recording any
route data: `WorldFromClassicAzerothMap`/`ClassicAzerothMapFromWorld`
(declared near the top of `NautCore.lua`, right after the `HBD`/`Pins`
locals, so they're in scope for every call site) pin the Classic constants
directly and are used in place of the HBD calls wherever `coordsType < 0`
route data is converted — both in the trigger/dock/arrival checks and in
`DrawMapIcons_Unsafe`'s minimap/world-map icon placement (that second call
site was missed in the first pass and confirmed broken separately: the
minimap icon rendered in the wrong spot, and the world map icon rendered
nowhere near the player, or not at all, because its in-viewport bounds
check never landed in 0-1 with the wrong-scale coordinates) — decoupling
all of it from whatever HBD guesses about `WOW_PROJECT_ID` on any future
client. `DrawMapIcons_Unsafe`'s subsequent `HBD:GetZoneCoordinatesFromWorld`
/ `TranslateZoneCoordinates` calls (which place the icon within whatever
uiMapID the world map is currently showing) were left alone deliberately:
those go through HBD's `mapData`, built live from `C_Map.GetMapRectOnMap`
per uiMapID rather than from the `WOW_PROJECT_ID`-keyed `worldMapData`
table, so they aren't subject to this same bug — they only misbehaved
because they were being fed the wrong `xw, yw` upstream.

## Communication architecture (NautComms.lua)

Two independent transports, because Classic's chat/comm APIs are more
restrictive than retail's:

1. **AceComm addon messages** (`DEFAULT_PREFIX = "NauticSync"`) over RAID /
   PARTY / GUILD / YELL distributions — small-group, low-latency sync.
2. **The "WIDE" channel** — a hidden custom chat channel
   (`WIDE_CHANNEL_BASE`, currently `"NauticusSync119"`) that every player
   running the addon auto-joins, used for realm-wide sync. This exists
   because `SendAddonMessage` over `"CHANNEL"` distribution is rejected by
   the Classic client (confirmed empirically, not documented) — so WIDE
   messages are sent as **literal chat text** via `SendChatMessage`/
   `C_ChatInfo.SendChatMessage`, tagged with `WIDE_TAG` to identify/version
   them, and filtered out of the visible chat UI entirely
   (`wideChatFilter`, `hideWideChannelFromChatFrames`).

Classic quirks this code works around (don't "simplify" these away without
re-reading the surrounding comments — they're each working around a real,
tested client restriction, not speculative):

- `SendChatMessage`/`C_ChatInfo.SendChatMessage` require a genuine hardware
  event (mouse click / key press) in the same call stack — a timer or slash
  command callback doesn't qualify and the send is silently dropped. Outbound
  WIDE messages are queued (`wideQueue`) and only flushed from
  `WorldFrame:HookScript("OnMouseDown", ...)` / a key-down hook
  (`drainWideQueue`), piggybacking on the player's ambient input.
- Renaming `WIDE_CHANNEL_BASE` is a wire-protocol-breaking change (every
  client must agree on the channel name to interoperate) — don't do it
  without bumping `WIDE_TAG` too and understanding the compatibility break.
  A password was deliberately never set (see the comment above
  `WIDE_CHANNEL_BASE`): a channel's password is fixed at creation, so a
  later join supplying one against an already-existing unpassworded channel
  could misbehave.

### The chat-channel-slot bug (history — read before touching join logic)

Classic assigns the `/1`, `/2`, ... numeric chat slash-slots by channel join
order. Naively joining the hidden WIDE channel can grab slot 1/2 before
Blizzard's own default channels (General, Trade, etc.) load, silently
hijacking `/1` from the player's real General chat. This took several
iterations to fix properly:

- ~~Fixed delay before joining~~ — guessed wrong under real login timing.
- ~~Poll `GetChannelName` count for N stable ticks~~ — unreliable on a
  freshly-created character: the count can sit at 0 for a couple of seconds
  simply because the server hasn't sent the default-channel joins yet (not
  because none are coming), which got misread as "stable, done loading."
- ~~Listen for `CHAT_MSG_CHANNEL_NOTICE` `YOU_JOINED` and wait for a quiet
  window~~ — closer, but still a timing guess, and there were other call
  sites (`drainWideQueue`'s hardware-event hook, `PLAYER_ENTERING_WORLD`)
  that called `JoinWideChannel()` directly and could bypass any wait guard
  placed only around the initial join.
- **Current approach**: stop guessing when to join and instead correct the
  slot *after* joining. Join whenever, then deterministically walk the WIDE
  channel to the end of the channel list via
  `C_ChatInfo.SwapChatChannelsByChannelIndex` (`moveWideChannelToEnd` in
  `NautComms.lua`), called every time we confirm we're joined. A permanent
  `wideReshuffleWatcher` (`CHAT_MSG_CHANNEL_NOTICE` `YOU_JOINED`) re-runs the
  shuffle any time a *different* channel joins later in the session too
  (e.g. Trade only becomes available on entering a city). Confirmed by the
  user to fix an **existing** character, but initially still reproduced on a
  **freshly-created** one — leading hypothesis (unconfirmed, but the fix
  built on it worked) was that a brand-new character's one-time default
  channel provisioning doesn't fire the same observable `YOU_JOINED` notice a
  normal mid-session channel join does, so `wideReshuffleWatcher` never got
  triggered to correct it. Fixed by adding `startWideReshufflePoll()`, which
  re-runs `moveWideChannelToEnd()` on a plain 3s timer for ~30s after our own
  join, independent of any event — **confirmed working by the user on a
  fresh character too.** `DebugMessage` calls were left in place at the key
  decision points (the swap itself, and the watcher firing) gated behind
  `self.debug` (`self.db.global.debug`, no exposed slash/options toggle —
  set via `/run NauticusClassic.db.global.debug = true; NauticusClassic.debug = true`)
  in case a new variant of this bug shows up; this one burned several rounds
  of unverifiable guessing before landing, so if slot-1 is ever reported
  again, prefer getting real debug output over another hypothesis.

## Versioning

`NauticusClassic.version` is read from the `.toc` at runtime (never
hardcoded in Lua, so it can't drift). `versionNum` packs `MAJOR.MINOR.PATCH`
into a single number (e.g. `1.4.1` -> `141`) for numeric comparison in
`NautComms.lua`'s update-check logic — **each version segment must stay a
single digit (0-9)** for that encoding to stay lossless; watch for this if
`MINOR` or `PATCH` ever needs to reach double digits.

## Style conventions already in use

- Tabs for indentation.
- Comments explain *why* (a client quirk, a prior incident, a non-obvious
  constraint), not *what* — match that; don't add narrative "what this does"
  comments.
- No linter/formatter/CI configured in this repo and no local Lua
  interpreter available in this dev environment — there's no automated way
  to catch a typo or unbalanced `end` before the user tests in-game, so
  proofread edits to `.lua` files carefully (balanced `do`/`then`/`function`
  ... `end`, correct arg order for WoW event callbacks) rather than relying
  on a check step.
