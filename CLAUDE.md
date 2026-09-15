# NauticusClassicResurrected

A World of Warcraft addon that tracks boat/zeppelin arrival & departure
schedules and shows them on the world map/minimap. See `README.md` for the
user-facing feature description.

## Target platform

**Official WoW Classic Era** (Blizzard's own Classic client — not a private
server, not Turtle WoW, not any other custom server). `## Interface: 11509`
in the `.toc` corresponds to Classic Era client patch 1.15.9. If the
`Interface` line has moved on, re-derive the patch version the same way
(`1.MINOR.PATCH` -> `1MINORPATCH`, each segment zero-padded to 2 digits)
rather than assuming.

Do not assume an API is available just because it shows up in a generic WoW
API reference — check the ground-truth dump in the
[WowApiExplorer](https://github.com/sam-k-taylor/WowApiExplorer) repo first,
at `_classic_era_/<interface>.json` (currently
`_classic_era_/11509.json` for `## Interface: 11509` — re-derive the
filename the same way as the patch version above if `Interface` has moved
on). It's a structured dump of every `C_`-namespaced function/event/table
actually reported by **this Classic Era client's own** `/api` command (see
that project's README for how it was generated) — i.e. it's Era-verified,
not a retail guess, and can be trusted as ground truth for whether a `C_`
API exists here. Caveat: it only captures `C_`-namespaced tables (what
`/api system list` reflects) — old-style global FrameXML functions (e.g.
`JoinChannelByName`, `GetChannelList`, most UI/frame code) aren't in it at
all, so its silence on those means nothing either way. When in doubt about
one of those, prefer reusing a call already made elsewhere in this codebase
(grep for it first) over introducing a new one on faith.

There is no local WoW client to test against in this dev environment —
changes here can't be run/verified in-game by Claude; say so explicitly
rather than claiming a fix works, and ask the user to confirm in-game.

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
