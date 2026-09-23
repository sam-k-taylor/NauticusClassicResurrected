# Debugging NauticusClassicResurrected

Ad-hoc diagnostic tooling built into `NautCore.lua`. All of it is meant to be
run live in-game and the output pasted/copied back for analysis — there's no
local WoW client or Lua interpreter in this dev environment, so nothing here
can be verified without you running it.

## Enabling debug mode

Most of this is gated behind `self.debug`, which is not exposed via any
options panel:

```
/run NauticusClassic.db.global.debug = true; NauticusClassic.debug = true
```

`self.db.global.debug` is what persists across sessions (SavedVariables);
`self.debug` is the in-memory copy `InitialiseConfig` reads it into at
load. Setting only one of them will not reliably enable debug output until
the next reload re-syncs them — set both, as above.

To turn it back off: same command with `false` instead of `true`.

## Where debug output goes

`DebugMessage(msg)` (only prints/logs when `self.debug` is true) does two
things at once:

1. Prints to chat, prefixed `[Naut] [<seconds since last message>]:`.
2. Mirrors a plain-text copy into `self.db.global.debugLog` (a flat array),
   capped at 3000 entries (`DEBUG_LOG_CAP`) — oldest lines drop off once the
   cap is hit, so it's a rolling window, not unbounded growth.

Chat has a copy-length limit that a multi-minute debug session blows
through easily, which is why the SavedVariables mirror exists — see
`/nautdebuglog` below for pulling it out.

**Reading the SavedVariables file**: after `/reload` or logging out, open
`WTF/Account/<account>/SavedVariables/NauticusClassicResurrected.lua` (the
addon is account-wide, not per-character/per-realm) and look under
`["global"]["debugLog"]`.

## Slash commands

### `/nautdebuglog clear|count`

Manages the `debugLog` SavedVariables buffer described above.

- `/nautdebuglog clear` — wipes it. Run this right before a fresh test so
  the SavedVariables file only has to be re-opened for lines that matter.
- `/nautdebuglog count` — prints how many lines are currently buffered.

Not gated behind `self.debug` itself (the buffering inside `DebugMessage`
is, but managing the buffer isn't).

### `/nautchatlog clear|count`

Companion to `ChatArrivalWatcher_OnMsg` (`NautCore.lua`), an always-on
(when `IS_FOREVER`) listener for dock NPCs' boat-arrival announcements.
Driven by a table, `ANNOUNCE_WATCHERS`, listing every known
`{sender, keyword, transit, platIndex}` combination -- currently:

| Sender | Keyword | Transit | Dock |
|---|---|---|---|
| Windshapers Dockmaster | `Skycutter` | 12 | Zephras Isle (Horde) |
| High Order Dockmaster | `just arrived` | 13 | Zephras Isle (Alliance) |
| Arcanist Laurain | `just arrived` | 13 | Dalaran City |

Both sender **and** keyword must match (not either/or) -- two real
precision problems forced this: `"Skycutter"` turned out to be a generic
vessel type both [12] and [13]'s dockmasters use, so keyword-only matching
would cross-collide between routes; and Arcanist Laurain sends a *second*,
unrelated flavor line 5s after the real arrival line, so sender-only
matching would also catch that. Adding a new route's announcement is just
a new table entry, not new code.

Unlike `/nautrecord`/`/nautsound`, this isn't something you toggle for one
session -- it's registered unconditionally in `OnEnable` on Forever.

**"Secret string" taint fix (2026-09-22).** A live error confirmed
`sender == w.sender` throws `attempt to compare local 'sender' (a secret
string value, while execution tainted by ...)` on Forever -- a newer
client-side protection (likely anti-automation, ironically exactly what
this handler does) marks `CHAT_MSG_*` sender/message arguments as
"secret", and raw Lua comparison operators can't touch them directly. This
fired on **every** `CHAT_MSG_MONSTER_YELL`/`SAY`/`EMOTE` in the game, not
just the ones this addon cares about, since the comparison threw before
any relevance check could run. Fixed by using `strcmputf8i` (a standard
Blizzard global, the established idiom for taint-safe string comparison)
instead of `==`, and the actual matching logic was also split into
`ChatArrivalWatcher_OnMsg_Unsafe` behind a `pcall` wrapper -- the same
"can't let one bad tick kill the whole handler" pattern
`CheckTriggers_OnUpdate`/`CheckArrivals_OnUpdate` already use -- as a
second layer of safety, since `string.find(msg, ...)` might have the same
issue and this hasn't been confirmed either way (the error trace never
reached it, short-circuited by the first failure).

It does two things every time a watcher matches:

1. **Logs it.** Quietly accumulates matches (tagged with which transit
   matched) into `self.db.global.chatArrivalLog` over normal play, capped
   at 200 entries. No chat spam unless `self.debug` is on.
2. **Actively re-syncs that transit's known cycle.** Sets the cycle
   directly to `offset[plat.index - 1]` -- the same "arrival" reference
   `ShowTooltip` itself uses -- then commits via `SetKnownCycle` and the
   usual `RequestTransport`/`DoRequest` broadcast. Deliberately does
   **not** go through `SetKnownTime`: that function's distance-ratio
   extrapolation is built for a trigger point mid-flight and anchors to
   `offset[index]` itself, but a platform tag's own `dt` already includes
   the *entire* dwell duration -- calling it with the platform's own index
   set the cycle to the departure moment instead of arrival, confirmed
   live on [12] to make things worse, not better. The announcement gives
   exact knowledge of the arrival instant anyway, so there's no fractional
   position to extrapolate in the first place. Only gated on matching the
   raw-pinned instance when the SPECIFIC platform being re-synced is
   itself raw-pinned (checked via `rawPoints[transit][plat.index]`, the
   same per-point flag `PointWorldCoords` reads) -- not per-transit. Raw
   pinning is per-point, not per-route: [13]'s Zephras Isle dock (`plat1`)
   is raw-pinned but its Dalaran City dock (`plat2`) is a plain composite
   point. An earlier version of this gate checked `rawInstance[transit]`
   directly, which would have required `instanceID==2991` even for the
   Dalaran announcement -- never true there, so it would have silently
   blocked that dock's re-sync forever. This is range-gated like any
   `SAY`/`YELL` (confirmed by the user for [12] -- **not** a zone-wide
   broadcast despite the on-screen banner), so it only corrects for
   whoever happens to be within earshot at that moment -- but like any
   trigger commit, that correction propagates to everyone else via the
   broadcast.

- `/nautchatlog clear` — wipes the buffer.
- `/nautchatlog count` — prints how many entries are buffered.
- Read the actual entries from `["chatArrivalLog"]` under `global` in the
  SavedVariables file, same as `debugLog`/`recordedRoute` -- `/reload` or
  log out first to flush.

The logged timestamps are still useful on their own too -- multiple real
intervals between firings gave a very high-confidence `rtts[12]` (347,
zero variance across 3 measurements) before a single point of route
geometry was even recorded, the same way route 11's `rtts` was averaged
from several manual `/nautdebuglog` measurements, just gathered for free
here instead.

### `/nautcoords`

Prints a snapshot of the addon's own coordinate-conversion state at the
player's current position: raw world position, HBD's *live* Azeroth
world-map fraction (`HBD:GetAzerothWorldMapCoordinatesFromWorld`, subject to
the `WOW_PROJECT_ID` bug on Forever — see the top of `NautCore.lua`) versus
the addon's own Classic-calibrated fraction (`ClassicAzerothMapFromWorld`),
current `uiMapID`, and `HBD.worldMapData[0]`/`[1]` (the rects HBD itself
picked, for comparing against the known-good Classic values vs the
retail-scale fallback it uses when it doesn't recognize the client).

Not gated behind `self.debug` — meant to be run ad-hoc and the output
pasted back, regardless of debug mode.

Use when: diagnosing whether HBD has picked the wrong world-map scale for
the current client (the original Forever trigger-detection bug), or just
to get a confirmed `uiMapID` for a location (used throughout this session
to pin down `transitZones` entries).

### `/nautworldmap`

Compares the addon's own World Map (uiMapID 947) position fraction against
`C_Map.GetPlayerMapPosition(947, "player")` — a modern Blizzard API that's
independent of HBD entirely, so it's ground truth. Prints both fractions
and the delta between them.

Use when: the icon's position looks wrong specifically on the World Map
(but not the zone map, continent map, or minimap) — that pattern points at
HBD's World Map-specific translation path
(`HBD:TranslateZoneCoordinates`/`GetAzerothWorldMapCoordinatesFromWorld`,
called internally by HereBeDragons-Pins when the displayed map is the
World view), not the addon's own stored data.

### `/nautrotcheck`

Live comparison of the map icon's actual rendered rotation against the
player's own facing, for the Stormwind Harbor↔Auberdine boat (transport id
11 is hardcoded in this command). Reads `self.lastRenderedAngle[11]` —
stashed by `DrawMapIcons_Unsafe` every time it calls
`buttonWorld.texture:SetRotation(angle)`, so **it only updates while the
World Map is open** — and prints it alongside `GetPlayerFacing()`, the
delta between them, and the live `liveData.index`/`cycle` (which
`packedData[11]` array segment is currently being interpolated, and how far
into the round-trip cycle the known-cycle timer thinks we are).

Gotchas learned the hard way:

- **World Map must stay open the whole time you're sampling.** If it's
  closed, `lastRenderedAngle` goes stale and the delta will just reflect
  your facing changing against a frozen number — looks like real drift but
  isn't.
- The rendered angle and your facing are two independent signals; a
  *rock-stable* delta across several samples (even while both numbers are
  changing) means real signal. A *scattered* delta most likely means
  something (camera, or which segment of the route you're in) changed
  between samples, not noise in the underlying data.
- A **calibration taken while the boat is docked is not meaningful** — there's
  no "direction of travel" to auto-face when nothing is moving, so a
  correction derived from a stationary reading is comparing two arbitrary
  numbers. Always sample while genuinely underway.
- A correction derived from one snapshot of this command does **not**
  automatically stay valid if the underlying rotation data is rebuilt
  afterward (e.g. re-deriving the array's rotation base) — always
  re-measure after a structural change, don't reuse an old delta.

Use when: diagnosing map-icon rotation being wrong. This bypasses the
entire recording/merging/array-rotation pipeline and measures the actually
rendered angle directly, which is far more reliable than reasoning about
recorded data or judging rotation by eye from a screenshot.

### `/nautpace`

Toggle. Built after three rounds of guessing at `packedData[12]` `dt`
corrections from vague end-of-flight reports ("still N seconds
left"/"icon looks ahead") oscillated without converging. Once a second
while active, logs the model's own predicted seconds-until-arrival at
Windshapers Dock (`plat1`, transport 12 — same formula `ShowTooltip`'s
"Arrival" display uses) alongside the player's **live** distance to that
dock. Prints to chat and mirrors into `self.db.global.paceLog`
(SavedVariables), capped at 500 entries, same pattern as `debugLog`.

- `/nautpace` once to start, ride the whole Skywatch Plateau → Zephras
  Isle leg, `/nautpace` again to stop.
- The resulting curve (predicted-seconds vs. live-distance, both moving
  together over time) shows *where* any mismatch actually is — a constant
  proportional gap the whole flight means the recorded pacing is still off
  by a uniform factor; a gap that only opens up in the last stretch points
  at the noisy low-speed final-approach data specifically, not the whole
  leg.
- Hardcoded to transport 12 — a targeted diagnostic for the route
  currently being tuned, not a general-purpose tool like the others above.

### `/nautroutedbg <transit id>`

Toggle. Built after `[5]`'s Southshore route repeatedly failed to register
live (see data.lua's comment above `packedData_forever[5]`) and reprocessing
the data from text reports alone stopped converging. Places a small dot on
the World Map (and the minimap, for whichever points are in the player's
current zone) for **every point** in that transit's current
`packedData[id]` — red = `trig`, green = `plat`, orange = `jump`, yellow =
untagged — plus a bright cyan marker that tracks the player's own live
position, updated every 0.5s. (Untagged points were originally dim grey;
changed to yellow since grey at low alpha read as washed-out/white and was
hard to actually see against the map. `plat` is green so the dock still
stands out clearly from the route itself.)

- `/nautroutedbg 5` to start, open the World Map and/or minimap, ride the
  route. `/nautroutedbg` again (no argument) to stop, or
  `/nautroutedbg <other id>` to switch directly to a different transit.
- The minimap only ever shows points in the player's CURRENT zone/instance
  (unlike the World Map, which shows the whole route across continents at
  once) — which points that is gets re-evaluated every 0.5s tick as you
  move, same cadence as the live player marker.
- Prints how many of the transit's points were actually placed
  (`N/total`) — fewer than total usually means some points are
  raw-pinned (`:rawp`, no sensible World Map placement, see
  `DrawMapIcons_Unsafe`) and were skipped, not a bug.
- Lets a registration failure be diagnosed by directly watching how close
  the live cyan marker actually gets to the red trig dots while flying
  past, instead of re-guessing from another "still didn't register"
  report.
- Not gated behind `self.debug` (same as `/nautrecord`) — meant to be run
  ad-hoc. Icons are cleared automatically when toggled off; they do **not**
  persist across `/reload` (matches `/nautpace`'s non-persistent state).

### `/nautrecord start | mark <tag> | stop`

Records a transport's route for building a new `packedData[id]` entry, by
sampling position (`HBD:GetPlayerWorldPosition` → `ClassicAzerothMapFromWorld`)
and heading (`GetPlayerFacing()`) every 0.8s while running.

- `/nautrecord start` — begins sampling, resets the buffer.
- `/nautrecord mark platN|trigN|zoneN` (e.g. `plat1`, `plat3`, `trig2`) —
  tags the *next* sample with that comment (matches `data.lua`'s packedData
  comment convention — see its own header comment for what each tag means
  to the decoder). Generalized to any N — a 2-stop-route-only hardcoded list
  (`plat1`/`plat2`/`trig1`/`trig2`/`zone1`/`zone2`) silently rejected `plat3`
  the moment a route needed a 3rd stop (Southshore on [5], Forever).
- `/nautrecord stop` — stops sampling.

Output goes to `self.db.global.recordedRoute` (a flat array, same
SavedVariables-mirroring rationale as `debugLog`) — `/reload` or log out,
then read it from the SavedVariables file the same way.

**`:announce` auto-marking.** While recording, the very next sample taken
after `ChatArrivalWatcher_OnMsg` fires (the Windshapers Dockmaster's
arrival line) is automatically tagged `:announce` — no manual mark needed.
At most ~0.8s of slop (the sampling timer's own period), a big precision
win over inferring the real arrival instant from idle-run boundaries after
the fact. This makes a much more targeted recording possible: rather than
a full round trip with manual `plat`/`trig` marks throughout, start
recording just before reaching a dock where you can hear its
announcement, let `:announce` mark the true arrival instant, ride the
known dwell through to the next dock (no need to mark departure if the
dwell duration is already known/measured), and stop whenever you hear a
second `:announce` fire (closing the loop). Added specifically to nail
down the Zephras Isle leg's timing precisely instead of another guessed
`dt` correction.

Gotchas learned the hard way (see `data.lua`'s comment history above
`packedData[11]` for the full story of what went wrong applying this data):

- **The recorded heading is only as good as what actually turns your
  character.** `GetPlayerFacing()` reads your character model's own
  orientation, not the camera. If the game auto-turns your character to
  face the direction of travel while on this vehicle (confirmed true for
  at least one route), don't manually turn the camera *or* the character
  during a recording — either will get recorded as a real heading change
  indistinguishable from the boat actually turning.
- Camera-only free-look (orbiting without turning the character) does not
  affect this — only actions that change `GetPlayerFacing()` do. Know
  which one you're doing before assuming a recording is "clean".
- Low-speed segments (right after departure, final approach into dock)
  produce very small position deltas per tick, which makes any
  geometrically-derived heading (`atan2` of the delta) extremely noisy —
  don't try to cross-check rotation against movement direction in these
  stretches.
- A recording that crosses a continent-instance boundary will show one
  huge position "jump" row at the crossing — this is a real coordinate-
  space artifact (each continent has its own fractional coordinate
  system), not a bug, and it should be tagged `:jump` in the final
  `packedData` entry (see below) so the renderer hides the icon instead of
  interpolating across it.
- The *rotation* delta recorded at that same jump row is also real, not
  noise — `GetPlayerFacing()` is apparently relative to the current
  instance's own coordinate frame, and different continents don't
  necessarily share a facing-zero direction. Don't zero it out assuming
  it's a glitch; it's a needed correction between the two sides.

## `packedData` comment tags (not slash commands, but debug-adjacent)

For reference, since several of the tools above exist specifically to get
these right — the recognized comment suffixes on a `packedData[id]` line
(`"dx:dy:dt:0:a[:tag]"`), decoded in `InitialiseConfig`:

| Tag | Effect |
|---|---|
| `plat1` / `plat2` | Sets `platforms[id][N].index` to this row — the "at this platform" reference point used for the Departure/Arrival tooltip and auto-select-at-dock. |
| `trig1` / `trig2` (any non-`0` digit) | Adds this row to `triggers[id]` — a candidate point for `SetKnownTime` to establish/re-sync a known cycle when the player passes within 20 yards while moving fast enough (`17.0 < dist`, see `CheckTriggers_OnUpdate_Unsafe`). |
| `zone1` / `zone2` | Marks this row as "zoning" for the map icon's cosmetic zoning-transition artwork. |
| `jump` | Marks this row as a continent-instance coordinate teleport, not real movement — `DrawMapIcons_Unsafe` hides the icon entirely while interpolating through it instead of showing it glide/spin across the map. |
| `rawp` | Marks this row's `dx`/`dy` as literal per-instance world coordinates rather than an Azeroth-composite-map fraction, for a continent instance with no reliable composite-map placement at all (first needed for [12]'s Zephras Isle leg). Read via `PointWorldCoords`, pinned to `NauticusClassic.rawInstance[id]` (data.lua). `/nautrecord` applies this automatically (see below) — it's not something you mark manually. |

A row can carry more than one tag (e.g. a dock that's both `plat2` and
`rawp`) — every colon-field from position 6 onward is decoded as its own
independent tag, not just the first one.

### `/nautrecord` and instances with no composite-map placement

If `ClassicAzerothMapFromWorld` can't place the player's current instance on
the Azeroth composite map at all (confirmed for Zephras Isle/instance 2991
via `/nautcoords`'s parent-map-chain walk — see below), `/nautrecord` no
longer refuses to sample there. It falls back to recording literal raw
world coordinates and appends `:rawp` to that row automatically — no
manual marking needed, and `/nautrecord mark plat2` etc. still work
normally on top of an auto-tagged row (the two tags just concatenate).

`/nautcoords` also walks the actual parent-map chain (not just `947`) and
tests `C_Map.GetPlayerMapPosition` at every level, printing each one's
result — useful for confirming whether a new continent instance has *any*
usable composite-map ground truth before assuming it needs `:rawp` treatment.

## Known gotcha: `/reload` and the reboot-detection logic

Unrelated to any of the tools above, but worth knowing: `InitialiseConfig`
has pre-existing logic (not something added for the new boat) that compares
wall-clock time (`time()`) against the client's process-uptime counter
(`GetTime()`) on every load, and wipes **every** transport's known cycle if
they disagree by more than 3 minutes — the assumption being that a
mismatch that large only happens after a real client/game restart. If
`/reload` on a given client resets `GetTime()` the same way a full restart
does (unconfirmed as of this writing — see the debug output below to
check), every known cycle would be wiped on every `/reload`, for every
transport uniformly, which would look exactly like "the boat isn't
detected" but isn't specific to any one route.

Diagnostic output already exists for this (gated behind `self.debug`):
watch chat/the debug log right after a `/reload` for:

```
boot drift: <seconds>
reboot must have occured
```

If these appear on every plain `/reload` with a large drift value, that
confirms the client is resetting `GetTime()` on reload.
