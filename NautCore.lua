
-- declare colour codes for console messages
local RED     = "|cffff0000"
local GREEN   = "|cff00ff00"
local YELLOW  = "|cffffff00"
local WHITE   = "|cffffffff"
local GREY    = "|cffbababa"

-- constants
local NONE = -1
local ARTWORK_PATH = "Interface\\AddOns\\NauticusClassicResurrected\\Artwork\\"
local ARTWORK_ZONING = ARTWORK_PATH.."MapIcon_Zoning"
local ARTWORK_DEPARTING = ARTWORK_PATH.."Departing"
local ARTWORK_IN_TRANSIT = ARTWORK_PATH.."Transit"
local ARTWORK_DOCKED = ARTWORK_PATH.."Docked"
-- ShowTooltip's "Arrival" branch (NautUI.lua) can legitimately produce a
-- plat_time anywhere up to just under the FULL rtts value, not rtts-60 --
-- its modular wraparound (plat_time += rtts[transit] when negative) means
-- it's bounded by the whole cycle length, not a fixed margin. This must
-- cover the largest rtts across BOTH clients (self.rtts and
-- self.rtts_forever, see data.lua) or GetFormattedTime silently returns nil
-- for any Arrival prediction past the cap, rendering as a blank tooltip
-- line -- confirmed happening for [5]/Auberdine once rtts_forever[5]
-- (484.007, Forever's new 3-stop route) exceeded the old 297 cap sized off
-- the previous longest route (356.288 - 60).
local MAX_FORMATTED_TIME = 485
local ICON_DEFAULT_SIZE = 18
local MINI_ICON_SIZE_FOREVER_PRESETS = { small = 1, medium = 1.5, large = 2 } -- see iconminisizeforever below
local ARRIVAL_SOUND_DISTANCE = 20.0 -- game yards; matches the platform-proximity threshold used elsewhere

NauticusClassic = LibStub("AceAddon-3.0"):NewAddon("NauticusClassic", "AceEvent-3.0", "AceComm-3.0", "AceTimer-3.0")
local NauticusClassic = NauticusClassic
local L = LibStub("AceLocale-3.0"):GetLocale("NauticusClassic")
local HBD = LibStub("HereBeDragons-2.0")
local Pins = LibStub("HereBeDragons-Pins-2.0")
local ldbicon = LibStub("LibDBIcon-1.0")

-- Fixed replacement for HBD:GetWorldCoordinatesFromAzerothWorldMap /
-- GetAzerothWorldMapCoordinatesFromWorld, calibrated to the same constants
-- HereBeDragons itself used for WOW_PROJECT_CLASSIC (see the WoWClassic
-- branch of fixupZones() in HereBeDragons-2.0.lua) at the time the
-- coordsType<0 routes in data.lua were recorded via the world map.
--
-- HBD re-derives its own worldMapData rect at load time from WOW_PROJECT_ID,
-- and picks a *different* (retail-scale) rect when it doesn't recognize the
-- client's project ID as one of its known Classic flavours. Confirmed via
-- /nautcoords on "WoW: Forever" (Interface 16001): that client reports
-- WOW_PROJECT_ID = 1 (WOW_PROJECT_MAINLINE), which none of HBD's
-- WoWClassic/WoWBC/WoWWrath/WoWCata/WoWMists checks match, so HBD silently
-- uses its retail rect ({76153.14, 50748.62, 65008.24, 23827.51} for
-- instance 0 vs Classic's {44688.53, 29795.11, 32601.04, 9894.93}) — a ~13
-- point swing in the resulting 0-1 fraction for the same physical spot,
-- which is why every coordsType<0 trigger/dock proximity check (20-yard
-- radius) missed entirely, and (below) why DrawMapIcons_Unsafe placed the
-- minimap icon in the wrong spot and suppressed the world map icon outright
-- (its in-viewport bounds check never landed in 0-1). The underlying
-- per-continent raw world coordinates HBD:GetPlayerWorldPosition returns
-- are NOT affected by this (verified against instance 0's known Classic-era
-- range) — only the fractional AzerothWorldMap encoding used to
-- store/replay routes is, so pinning these constants here (independent of
-- whatever HBD decides at runtime) fixes it without needing to re-record
-- any route data. Declared up here (not next to its first use) so it's in
-- scope for both DrawMapIcons_Unsafe (above CheckTriggers_OnUpdate_Unsafe in
-- this file) and the trigger/arrival checks below it.
local CLASSIC_AZEROTH_WORLDMAP_RECT = {
	[0] = { 44688.53, 29795.11, 32601.04,  9894.93 }, -- Eastern Kingdoms
	[1] = { 44878.66, 29916.10,  8723.96, 14824.53 }, -- Kalimdor
}

local function WorldFromClassicAzerothMap(x, y, instance)
	local data = CLASSIC_AZEROTH_WORLDMAP_RECT[instance]
	if not data or not x or not y then return nil, nil end
	local width, height, left, top = data[1], data[2], data[3], data[4]
	return left - width * x, top - height * y
end

local function ClassicAzerothMapFromWorld(x, y, instance)
	local data = CLASSIC_AZEROTH_WORLDMAP_RECT[instance]
	if not data or not x or not y then return nil, nil end
	local width, height, left, top = data[1], data[2], data[3], data[4]
	return (left - x) / width, (top - y) / height
end

-- Interface number of the client actually running us (not the .toc's declared
-- list of supported ones) — see CLAUDE.md "A fix made for Forever must not
-- change Era's behavior". Re-derive FOREVER_INTERFACE the same way as the
-- .toc's Interface line if it moves on; >= (not ==) so a later Forever patch
-- doesn't fall back to being treated as Era.
local FOREVER_INTERFACE = 16001
local IS_FOREVER = select(4, GetBuildInfo()) >= FOREVER_INTERFACE

-- HBD's own GetAzerothWorldMapCoordinatesFromWorld / GetWorldCoordinatesFromAzerothWorldMap
-- (HereBeDragons-2.0.lua) have the exact same WOW_PROJECT_ID-keyed worldMapData
-- problem as the trigger-detection bug WorldFromClassicAzerothMap/
-- ClassicAzerothMapFromWorld above already work around -- but this pair backs
-- HBD's *own* internal World Map (uiMapID 947) handling, a code path neither of
-- those two local replacements reaches: HereBeDragons-Pins-2.0.lua calls
-- GetAzerothWorldMapCoordinatesFromWorld directly whenever the displayed map is
-- the World view (its own ~line 413), and HBD:TranslateZoneCoordinates routes
-- through the same pair whenever either side of a translation is the World map.
-- Confirmed in-game: the [11] boat (Stormwind Harbor<->Auberdine) rendered
-- correctly on the zone map, the continent map, and the minimap, but landed in
-- the wrong spot specifically on the World map -- exactly the code path above.
-- Since HBD is a shared vendored library (update-libs.sh would overwrite an
-- in-place edit anyway), patch these two functions at runtime instead, only on
-- Forever, so every caller -- ours and HBD-Pins' own internal one -- gets the
-- correct Classic-scale conversion transparently. This is strictly a
-- correctness fix (replacing a wrong retail-scale fallback with the verified
-- Classic-scale rect), so it's safe for any other addon sharing this HBD
-- instance too. Lua method calls (self:Method(...)) resolve the function on
-- the table at each call, so this reaches HBD's own internal self-calls too,
-- not just external ones.
if IS_FOREVER then
	function HBD:GetAzerothWorldMapCoordinatesFromWorld(x, y, instance, allowOutOfBounds)
		local ax, ay = ClassicAzerothMapFromWorld(x, y, instance)
		if not ax then return nil, nil; end
		if not allowOutOfBounds and (ax < 0 or ax > 1 or ay < 0 or ay > 1) then return nil, nil; end
		return ax, ay
	end

	function HBD:GetWorldCoordinatesFromAzerothWorldMap(x, y, instance)
		local wx, wy = WorldFromClassicAzerothMap(x, y, instance)
		if not wx then return nil, nil, nil; end
		return wx, wy, instance
	end
end

-- read our own version from the .toc so it can never drift out of sync with
-- what's actually shipped; versionNum packs "MAJOR.MINOR.PATCH" into digits
-- (e.g. 1.4.1 -> 141) for the numeric comparisons in NautComms.lua, so each
-- version segment must stay a single digit (0-9) for the encoding to be lossless
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

-- object variables
NauticusClassic.DEFAULT_PREFIX = "NauticSync" -- do not change!
NauticusClassic.version = GetAddOnMetadata("NauticusClassicResurrected", "Version")
local versionDigits = (NauticusClassic.version):gsub("%.", "") -- discard gsub's 2nd return (match count)
NauticusClassic.versionNum = tonumber(versionDigits)
NauticusClassic.MAX_VERSION_NUM = 999 -- highest value 3 single-digit segments (9.9.9) can pack to; see comment above
NauticusClassic.lowestNameTime = "--"
NauticusClassic.tempText = ""
NauticusClassic.tempTextCount = 0
NauticusClassic.debug = false
NauticusClassic.iconRenderTimer = nil

NauticusClassic.broadcastChannels = {
	["SAY"] = format("|cFFFFFFFF%s|r", L["Say"]),
	["YELL"] = format("|cFFFF3F40%s|r", L["Yell"]),
	["PARTY"] = format("|cFFAAAAFF%s|r", L["Party"]),
	["RAID"] = format("|cFFFF7F00%s|r", L["Raid"]),
	["GUILD"] = format("|cFF40FF40%s|r", L["Guild"]),
}

local alarmSet = false
local alarmDinged = false
local alarmCountdown = 0

local transports
local transitData = {}
local triggers = {}
local zonings = {}
local jumps = {} -- indices tagged ":jump" in packedData (continent-instance teleport
                 -- artifacts, e.g. the [11] Stormwind<->Auberdine boat's two
                 -- coordinate-space jumps) -- see DrawMapIcons_Unsafe, which hides
                 -- the icon entirely while interpolating through one of these instead
                 -- of visibly gliding across the map over the segment's dt
local rawPoints = {} -- indices tagged ":rawp" in packedData -- points recorded as
                 -- literal per-instance world coordinates rather than an Azeroth-
                 -- composite-map fraction, for a continent instance that has no
                 -- reliable composite-map placement at all (e.g. [12]'s Zephras
                 -- Isle leg -- confirmed via /nautcoords's parent-map-chain walk
                 -- returning nil at every level). The instance they're pinned to
                 -- is NauticusClassic.rawInstance[id] (data.lua). See
                 -- PointWorldCoords below, which every render/trigger/arrival call
                 -- site now goes through instead of calling
                 -- WorldFromClassicAzerothMap directly, so this new per-point
                 -- override is honored everywhere uniformly.
local dockedAtPlatform = {}

-- Resolves point `index` of `transit`'s route to WORLD coordinates, checking
-- rawPoints[transit][index] first (see its comment above) before falling
-- back to the existing composite-fraction/Tram-style self.coordsType branch
-- every other route already uses unchanged. Every render/trigger/arrival
-- call site that used to call WorldFromClassicAzerothMap directly now goes
-- through this instead, so the new raw-point override applies uniformly
-- without duplicating the three-way branch at every call site.
--
-- When the point is raw-pinned but `instanceID` (the caller's own current
-- context -- usually the player's) doesn't match NauticusClassic.rawInstance[transit],
-- returns a sentinel far outside any real coordinate range rather than nil:
-- every caller feeds this straight into HBD:GetWorldDistance or a 0-1 bounds
-- check, and a nil operand there is a hard Lua error (see the [5]/plat3
-- nil-.index incident earlier this session), not a graceful "too far away".
local RAW_POINT_MISMATCH_SENTINEL = 1e7
local function PointWorldCoords(transit, index, instanceID)
	if rawPoints[transit] and rawPoints[transit][index] then
		if instanceID == NauticusClassic.rawInstance[transit] then
			return transitData[transit].x[index], transitData[transit].y[index]
		else
			return RAW_POINT_MISMATCH_SENTINEL, RAW_POINT_MISMATCH_SENTINEL
		end
	elseif NauticusClassic.coordsType[transit] < 0 then
		return WorldFromClassicAzerothMap(transitData[transit].x[index], transitData[transit].y[index], instanceID)
	else
		return transitData[transit].x[index], transitData[transit].y[index]
	end
end

local defaults = {
	profile = {
		factionSpecific = true,
		zoneSpecific = false,
		broadcastChannel = "SAY",
		alarmOffset = 20,
		arrivalDing = true,
		miniIconSize = 1,
		worldIconSize = 1.25,
		miniIconSizeForeverPreset = "small", -- Forever-only preset, see iconminisizeforever below -- kept separate from miniIconSize since it's a different kind of value (discrete preset vs. continuous slider), not shared storage
		iconFramerate = 30,
		showMiniIcons = true,
		showWorldIcons = true,
		minimap = {
			hide = false,
		},
	},
	global = {
		knownCycles = {},
		debug = false,
	},
	char = {
		activeTransit = NONE,
		autoSelect = true,
	},
}

local _options = {
	showminimapicon = {
		type = 'toggle',
		name = L["Show on Mini-Map"],
		desc = L["Toggle display of icons on the Mini-Map."],
		order = 600,
		get = function()
			return NauticusClassic.db.profile.showMiniIcons
		end,
		set = function(info, val)
			NauticusClassic.db.profile.showMiniIcons = val
			if not val then
				for _, t in pairs(transports) do
					Pins:RemoveMinimapIcon(NauticusClassic, t.minimap_icon)
					t.minimap_icon:Hide()
				end
			else
				NauticusClassic:DrawMapIcons(false, true)
			end
		end,
	},
	showworldmapicon = {
		type = 'toggle',
		name = L["Show on World Map"],
		desc = L["Toggle display of icons on the World Map."],
		order = 650,
		get = function()
			return NauticusClassic.db.profile.showWorldIcons
		end,
		set = function(info, val)
			NauticusClassic.db.profile.showWorldIcons = val
			if not val then
				for _, t in pairs(transports) do
					Pins:RemoveWorldMapIcon(NauticusClassic, t.worldmap_icon)
					t.worldmap_icon:Hide()
				end
			else
				NauticusClassic:DrawMapIcons(true, false)
			end
		end,
	},
	iconminisize = {
		type = 'range',
		name = L["Mini-Map icon size"],
		desc = L["Change the size of the Mini-Map icons."],
		order = 400,
		hidden = function() return IS_FOREVER end, -- Forever gets the small/medium/large preset below instead
		get = function()
			return NauticusClassic.db.profile.miniIconSize
		end,
		set = function(info, val)
			NauticusClassic.db.profile.miniIconSize = val
			val = val * ICON_DEFAULT_SIZE
			for _, t in pairs(transports) do
				t.minimap_icon:SetSize(val, val)
				t.minimap_icon.texture:SetSize(val * math.sqrt(2), val * math.sqrt(2))
			end
		end,
		isPercent = true,
		min = .5, max = 2, step = .01,
	},
	-- Forever-only preset version of the above -- a separate profile field
	-- (miniIconSizeForeverPreset) rather than reusing miniIconSize, since
	-- Forever uses discrete small/medium/large presets while Era uses a
	-- continuous slider -- different value shapes need different storage
	-- regardless of profile scope. Small (1x) matches the slider's
	-- existing default/current size, Large (2x) is double that, Medium
	-- (1.5x) is halfway between -- see MINI_ICON_SIZE_FOREVER_PRESETS near
	-- ICON_DEFAULT_SIZE.
	iconminisizeforever = {
		type = 'select',
		name = L["Mini-Map icon size"],
		desc = L["Change the size of the Mini-Map icons. Small is the default/current size, Large is double that, Medium is halfway between."],
		order = 400,
		hidden = function() return not IS_FOREVER end,
		values = { small = L["Small"], medium = L["Medium"], large = L["Large"] },
		get = function()
			return NauticusClassic.db.profile.miniIconSizeForeverPreset
		end,
		set = function(info, key)
			NauticusClassic.db.profile.miniIconSizeForeverPreset = key
			local val = MINI_ICON_SIZE_FOREVER_PRESETS[key] * ICON_DEFAULT_SIZE
			for _, t in pairs(transports) do
				t.minimap_icon:SetSize(val, val)
				t.minimap_icon.texture:SetSize(val * math.sqrt(2), val * math.sqrt(2))
			end
		end,
	},
	iconworldsize = {
		type = 'range',
		name = L["World Map icon size"],
		desc = L["Change the size of the World Map icons."],
		order = 500,
		get = function()
			return NauticusClassic.db.profile.worldIconSize
		end,
		set = function(info, val)
			NauticusClassic.db.profile.worldIconSize = val
			val = val * ICON_DEFAULT_SIZE
			for _, t in pairs(transports) do
				t.worldmap_icon:SetSize(val, val)
				t.worldmap_icon.texture:SetHeight(val * math.sqrt(2), val * math.sqrt(2))
			end
		end,
		isPercent = true,
		min = .5, max = 2, step = .01,
	},
	iconframerate = {
		type = 'range',
		name = L["Icon framerate"],
		desc = L["Change the framerate of the World Map/Mini-Map icons (lower this value if you are seeing performance issues with the map open)."],
		order = 600,
		get = function()
			return NauticusClassic.db.profile.iconFramerate
		end,
		set = function(info, val)
			NauticusClassic.db.profile.iconFramerate = val
			if NauticusClassic.iconRenderTimer then
				NauticusClassic:CancelTimer(NauticusClassic.iconRenderTimer)
			end
			NauticusClassic.iconRenderTimer = NauticusClassic:ScheduleRepeatingTimer("DrawMapIcons", 1.0 / val, true, true)
		end,
		min = 1, max = 60, step = 1,
	},
	factiononly = {
		type = 'toggle',
		name = L["Faction only"],
		desc = L["Hide transports of opposite faction from the map, showing only neutral and those of your faction."],
		order = 675,
		get = function()
			return NauticusClassic.db.profile.factionSpecific
		end,
		set = function(info, val)
			NauticusClassic.db.profile.factionSpecific = val
			NauticusClassic:DrawMapIcons(true, true)
		end,
	},
	autoselect = {
		type = 'toggle',
		name = L["Auto select transport"],
		desc = L["Automatically select nearest transport when standing at platform."],
		order = 150,
		get = function()
			return NauticusClassic.db.char.autoSelect
		end,
		set = function(info, val)
			NauticusClassic.db.char.autoSelect = val
		end,
	},
	alarm = {
		type = 'range',
		name = L["Alarm delay"],
		desc = L["Change the alarm delay (in seconds)."],
		order = 300,
		get = function()
			return NauticusClassic.db.profile.alarmOffset
		end,
		set = function(info, val)
			NauticusClassic.db.profile.alarmOffset = val
		end,
		min = 0, max = 90, step = 5,
	},
	arrivalding = {
		type = 'toggle',
		name = L["Arrival sound"],
		desc = L["Play a sound when a tracked transport arrives at a platform you're standing near."],
		order = 320,
		hidden = function() return IS_FOREVER end, -- Forever's client already plays its own docking sound
		get = function()
			return NauticusClassic.db.profile.arrivalDing
		end,
		set = function(info, val)
			NauticusClassic.db.profile.arrivalDing = val
		end,
	},
	minibutton = {
		type = 'toggle',
		name = L["Mini-Map button"],
		desc = L["Toggle the Mini-Map button."],
		order = 100,
		get = function()
			return not NauticusClassic.db.profile.minimap.hide
		end,
		set = function(info, val)
			NauticusClassic.db.profile.minimap.hide = not val
			if val then
				ldbicon:Show("NauticusClassic")
			else
				ldbicon:Hide("NauticusClassic")
			end
		end,
	},
	broadcastchannel = {
		type = 'select',
		name = L["Broadcast channel"],
		desc = format(L["Channel to broadcast your currently tracked transport (will broadcast to \"%s\" if the selected channel is unavailable)."], NauticusClassic.broadcastChannels["SAY"]),
		order = 350,
		values = NauticusClassic.broadcastChannels,
		get = function()
			return NauticusClassic.db.profile.broadcastChannel
		end,
		set = function(info, val)
			NauticusClassic.db.profile.broadcastChannel = val
			NauticusClassic:RefreshMenu()
		end,
	},
}
local options = { type = "group", args = {
	GUI = {
		type = 'group',
		name = "NauticusClassic",
		args = {
			nautdesc = {
				type = 'description',
				name = L["Tracks the precise arrival & departure schedules of boats and Zeppelins around Azeroth and displays them on the Mini-Map and World Map in real-time."].."\n",
				order = 1,
			},
			header1 = {
				type = 'header',
				name = L["General Settings"],
				order = 99,
			},
			minibutton = _options.minibutton,
			autoselect = _options.autoselect,
			alarm = _options.alarm,
			arrivalding = _options.arrivalding,
			broadcastchannel = _options.broadcastchannel,
			header2 = {
				type = 'header',
				name = L["Map Icons"],
				order = 398,
			},
			iconsdesc = {
				type = 'description',
				name = L["Options for displaying transports as icons on the Mini-Map and World Map."].."\n",
				order = 399,
			},
			iconminisize = _options.iconminisize,
			iconminisizeforever = _options.iconminisizeforever,
			iconworldsize = _options.iconworldsize,
			iconframerate = _options.iconframerate,
			showminimapicon = _options.showminimapicon,
			showworldmapicon = _options.showworldmapicon,
			factiononly = _options.factiononly,
		},
	},
} }
local optionsSlash = { type = 'group', name = "NauticusClassic", args = {
	[ L["icons"] ] = {
		type = 'group',
		name = L["Map Icons"],
		desc = L["Options for displaying transports as icons on the Mini-Map and World Map."],
		order = 399,
		args = {
			[ L["minishow"] ] = _options.showminimapicon,
			[ L["worldshow"] ] = _options.showworldmapicon,
			[ L["minisize"] ] = _options.iconminisize,
			[ L["minisizeforever"] ] = _options.iconminisizeforever,
			[ L["worldsize"] ] = _options.iconworldsize,
			[ L["framerate"] ] = _options.iconframerate,
			[ L["faction"] ] = _options.factiononly,
		},
	},
	[ L["minibutton"] ] = _options.minibutton,
	[ L["autoselect"] ] = _options.autoselect,
	[ L["alarm"] ] = _options.alarm,
	[ L["arrivalding"] ] = _options.arrivalding,
	[ L["channel"] ] = _options.broadcastchannel,
} }
NauticusClassic.optionsSlash = optionsSlash

function NauticusClassic:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("NauticusClassic5DB", defaults)
	LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable("NauticusClassic", options)
	LibStub("AceConfig-3.0"):RegisterOptionsTable("NauticusClassicSlashCommand", optionsSlash, { "nauticus", "naut" })
	self.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("NauticusClassic", nil, nil, "GUI")
	ldbicon:Register("NauticusClassic", self.dataobj, self.db.profile.minimap)

	local f = CreateFrame("Frame", "Naut_TransportSelectFrame", nil, "UIDropDownMenuTemplate")
	UIDropDownMenu_Initialize(f, function(frame, level) NauticusClassic:TransportSelectInitialise(frame, level); end, "MENU")

	self:InitialiseConfig()
end

local onUpdateTimer = nil

local function GetCurrentMapOrInstanceID()
	local id = C_Map.GetBestMapForUnit("player")
	if id == 1414 or id == 1415 then -- block returning continents
		return nil
	end
	if id == nil or id == 0 then
		_, _, _, _, _, _, _, id = GetInstanceInfo()
	end
	return id
end

function NauticusClassic:GetBroadcastChannel()
	local channel = NauticusClassic.db.profile.broadcastChannel
	if (channel == "GUILD" and not IsInGuild()) or (channel == "PARTY" and not IsInGroup()) or (channel == "RAID" and not IsInRaid()) then
		channel = "SAY"
	end
	return channel, NauticusClassic.broadcastChannels[channel]
end

function NauticusClassic:OnEnable()
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	self:RegisterEvent("ZONE_CHANGED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	-- listener for the new Zephras Isle boats' dock NPC arrival
	-- announcements ([12] Mulgore, [13] Dalaran City) -- see
	-- ANNOUNCE_WATCHERS/ChatArrivalWatcher_OnMsg below. Forever-only
	-- content (new starting zone), gated behind IS_FOREVER so this is
	-- fully inert on Era (the events just never fire there, but
	-- registering is skipped outright for clarity/consistency with how
	-- other Forever-only content is gated elsewhere).
	if IS_FOREVER then
		self:RegisterEvent("CHAT_MSG_MONSTER_SAY", "ChatArrivalWatcher_OnMsg")
		self:RegisterEvent("CHAT_MSG_MONSTER_YELL", "ChatArrivalWatcher_OnMsg")
		self:RegisterEvent("CHAT_MSG_MONSTER_EMOTE", "ChatArrivalWatcher_OnMsg")
		self:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE", "ChatArrivalWatcher_OnMsg")
	end
	self:RegisterComm(self.DEFAULT_PREFIX)
	-- the client auto-rejoins our hidden channel from a prior session on its own, often
	-- grabbing a low slot (e.g. 1) before Blizzard's default channels (General/Trade/etc.)
	-- load; drop that early auto-rejoin immediately, then rejoin ourselves right away --
	-- JoinWideChannel() no longer needs to wait for those default channels first, since it
	-- deterministically shuffles us to the end of the channel list after joining regardless
	-- of what order things joined in (see moveWideChannelToEnd in NautComms.lua)
	self:LeaveWideChannel()
	self:JoinWideChannel()

	NauticusClassic.iconRenderTimer = self:ScheduleRepeatingTimer("DrawMapIcons", 1 / self.db.profile.iconFramerate, true, true)
	self:ScheduleRepeatingTimer("Clock_OnUpdate", 1) -- every second (clock tick)
	onUpdateTimer = self:ScheduleRepeatingTimer("CheckTriggers_OnUpdate", 0.8) -- every 4/5th of a second
	self:ScheduleRepeatingTimer("CheckArrivals_OnUpdate", 1) -- every second, dings when a nearby transport docks
	--self:ScheduleRepeatingTimer("UpdateChannel", 60)

	--local frameEvent = CreateFrame('Frame')
	--frameEvent:SetScript("OnUpdate", self.OnUpdate)

	hooksecurefunc(WorldMapFrame, "OnMapChanged", function(self)
		NauticusClassic:DrawMapIcons(true, false)
	end)

	self:UpdateChannel(10) -- wait 10 seconds before sending to any comms channels
	self.currentZoneId = GetCurrentMapOrInstanceID()
	if self.currentZoneId then
		self.currentZoneTransports = self.transitZones[self.currentZoneId]
	end

	self:SetTransport()
end

local prevx = 0
local prevy = 0
local prevdx = 0
local prevdy = 0
local lastNonZeroDxDyTime = 0

function NauticusClassic:OnUpdate()
	local x, y, instanceID = HBD:GetPlayerWorldPosition()

	local ddx = abs(x - prevx)
	local ddy = abs(y - prevy)
	if prevx ~= 0 and prevy ~= 0 and prevdx == 0 and prevdy == 0 and (ddx > 0 or ddy > 0) and GetTime() - lastNonZeroDxDyTime > 10 then
		-- if onUpdateTimer then
		-- 	NauticusClassic:CancelTimer(onUpdateTimer)
		-- end
		-- onUpdateTimer = NauticusClassic:ScheduleRepeatingTimer("CheckTriggers_OnUpdate", 1.0)
		-- NauticusClassic:CheckTriggers_OnUpdate()
		NauticusClassic:DebugMessage(format("MOVED: %.3f %d %d", GetTime(), time(), GetServerTime()))
	end
	--if prevx ~= 0 and prevy ~= 0 and (prevdx ~= 0 or prevdy ~= 0) and ddx == 0 and ddy == 0 then
	--	NauticusClassic:DebugMessage(format("STOPPED: %.3f", GetTime()))
	--end
	if ddx > 0 or ddy > 0 then
		lastNonZeroDxDyTime = GetTime()
	end
	prevdx = ddx
	prevdy = ddy
	prevx = x
	prevy = y
end

local isDrawing

function NauticusClassic:DrawMapIcons_Unsafe(renderWorldMapIcons, renderMinimapIcons)
	local liveData, cycle, index, offsets, x, y, wzone, xw, yw, xm, ym, angle, transit_data, fraction,
		isZoning, isZoneInteresting, isFactionInteresting, buttonMini, buttonWorld

	local WorldMapVisible = WorldMapFrame:IsVisible()
	local px, py, instanceID = HBD:GetPlayerWorldPosition()

	for id, transport in pairs(transports) do
		if self:HasKnownCycle(id) then
			transit_data = transitData[id]
			liveData = self.liveData[id]
			cycle = math.fmod(self:GetKnownCycle(id), self.rtts[id])
			offsets = transit_data.offset
			index = liveData.index

			if index > #(offsets) or (index > 1 and offsets[index-1] > cycle) then
				index = 1
			end

			for i = index, #(offsets) do
				if offsets[i] > cycle then
					index = i
					break
				end
			end

			liveData.cycle, liveData.index = cycle, index

			if self.db.profile.showMiniIcons or self.db.profile.showWorldIcons then
				isZoneInteresting = (self.currentZoneTransports) and self.currentZoneTransports[id]
				isFactionInteresting = (not self.db.profile.factionSpecific) or transport.faction == UnitFactionGroup("player") or transport.faction == "Neutral"
				buttonMini, buttonWorld = transport.minimap_icon, transport.worldmap_icon

				-- while interpolating through a ":jump"-tagged index (a
				-- continent-instance coordinate teleport, not real movement --
				-- see the [11] boat's comment in data.lua), fall through to the
				-- existing "hide both icons" branch below instead of visibly
				-- gliding/spinning across the map over that segment's dt
				if (isZoneInteresting or WorldMapVisible) and not jumps[id][index] then
					if index == 1 then
						x, y, angle, isZoning =
							transit_data.x[index], transit_data.y[index], transit_data.dir[index], false
					else
						fraction = (cycle - transit_data.offset[index-1]) / transit_data.dt[index]

						x, y, angle, isZoning =
							transit_data.x[index-1] + transit_data.dx[index] * fraction,
							transit_data.y[index-1] + transit_data.dy[index] * fraction,
							transit_data.dir[index-1] + transit_data.d_dir[index] * fraction,
							zonings[id][index] == true
					end

					local worldMapIconInView = false

					if rawPoints[id][index] then
						-- x,y are already raw per-instance world coordinates (see
						-- rawPoints' comment above) -- same handling as the
						-- coordsType>=0 (Tram) branch below, just pinned to
						-- NauticusClassic.rawInstance[id] instead of coordsType[id]
						-- itself. worldMapIconInView deliberately stays false here
						-- too: this instance has no placement on the World
						-- composite map at all (confirmed via /nautcoords), so
						-- there's nowhere sensible to show a World Map icon --
						-- minimap-only, same as the Tram.
						xw, yw = x, y
						wzone = NauticusClassic.rawInstance[id]
						xm, ym = x, y
					elseif self.coordsType[id] < 0 then
						local wcont
						if x < 0.5 then
							wzone = 1
							wcont = 1414
						else
							wzone = 0
							wcont = 1415
						end
						xw, yw = WorldFromClassicAzerothMap(x, y, wzone)
						if wzone == instanceID then
							xm, ym = xw, yw
						else
							xm, ym = nil, nil
						end

						-- only render world map icon if it is visible in current viewport
						if WorldMapVisible and WorldMapFrame:GetMapID() then
							local xz, yz = HBD:GetZoneCoordinatesFromWorld(xw, yw, wcont)
							xz, yz = HBD:TranslateZoneCoordinates(xz, yz, wcont, WorldMapFrame:GetMapID(), true)
							if xz and yz and xz >= 0 and xz <= 1 and yz >=0 and yz <= 1 then
								worldMapIconInView = true
							end
						end
					else
						xw, yw = x, y
						wzone = self.coordsType[id]
						xm, ym = x, y
					end

					if xw and yw then
						if WorldMapVisible and self.db.profile.showWorldIcons and isFactionInteresting and worldMapIconInView then
							if renderWorldMapIcons then
								if isZoning ~= transport.status then
									buttonWorld.texture:SetTexture(isZoning and ARTWORK_ZONING or transport.texture_name)
									transport.status = isZoning
								end
								Pins:RemoveWorldMapIcon(self, buttonWorld)
								Pins:AddWorldMapIconWorld(self, buttonWorld, wzone, xw, yw, HBD_PINS_WORLDMAP_SHOW_WORLD)
								buttonWorld.texture:SetRotation(angle)
								-- stashed for /nautrotcheck -- a live comparison against the
								-- player's own GetPlayerFacing() while standing still on the
								-- boat, since repeated attempts to fix rotation by reprocessing
								-- recorded data haven't converged (see comment above [11] in
								-- data.lua) -- this bypasses recording/interpolation entirely
								self.lastRenderedAngle = self.lastRenderedAngle or {}
								self.lastRenderedAngle[id] = angle
								buttonWorld:Show()
							end
						elseif buttonWorld:IsVisible() then
							Pins:RemoveWorldMapIcon(self, buttonWorld)
							buttonWorld:Hide()
						end

						if xm and ym and isZoneInteresting and self.db.profile.showMiniIcons and isFactionInteresting then
							if renderMinimapIcons then
								Pins:RemoveMinimapIcon(self, buttonMini)
								Pins:AddMinimapIconWorld(self, buttonMini, instanceID, xm, ym, true)
								buttonMini.texture:SetRotation(angle - (GetCVar("rotateMinimap") == "1" and GetPlayerFacing() or 0))
								buttonMini:SetAlpha(Pins:IsMinimapIconOnEdge(buttonMini) and 0.6 or 0.9)
								buttonMini:Show()
							end
						elseif buttonMini:IsVisible() then
							Pins:RemoveMinimapIcon(self, buttonMini)
							buttonMini:Hide()
						end
					end
				else
					if buttonMini:IsVisible() then
						Pins:RemoveMinimapIcon(self, buttonMini)
						buttonMini:Hide()
					end
					if buttonWorld:IsVisible() then
						Pins:RemoveWorldMapIcon(self, buttonWorld)
						buttonWorld:Hide()
					end
				end
			end
		end
	end

end

-- DrawMapIcons_Unsafe touches many external APIs (HereBeDragons, WorldMapFrame,
-- Pins, CVars) that another addon's map/minimap hooks can disturb; if it errors
-- mid-loop, isDrawing must still be released or every future call (including the
-- repeating timer and the WorldMapFrame OnMapChanged hook) silently no-ops forever.
function NauticusClassic:DrawMapIcons(renderWorldMapIcons, renderMinimapIcons)
	if isDrawing then return; end
	isDrawing = true

	local ok, err = pcall(self.DrawMapIcons_Unsafe, self, renderWorldMapIcons, renderMinimapIcons)
	if not ok then
		self:DebugMessage("DrawMapIcons error: "..tostring(err))
	end

	isDrawing = false
end

function NauticusClassic:Clock_OnUpdate_Unsafe()
	if alarmDinged then
		alarmCountdown = alarmCountdown - 1

		if 0 > alarmCountdown then
			alarmSet, alarmDinged = false, false
			PlaySound(SOUNDKIT.AUCTION_WINDOW_CLOSE)
		end
	end

	local transit = self.activeTransit

	if self:HasKnownCycle(transit) then
		local liveData = self.liveData[transit]
		local cycle, index = liveData.cycle, liveData.index
		local lowestTime = math.huge
		local plat_time, colour

		for _, data in pairs(self.platforms[transit]) do
			if data.index == index then
				-- we're at a platform and waiting to depart
				plat_time = self:GetCycleByIndex(transit, index) - cycle

				if alarmSet and not alarmDinged and plat_time < self.db.profile.alarmOffset then
					alarmDinged = true
					alarmCountdown = plat_time
					PlaySound(8212) -- PVPFlagTakenHorde
				end

				if 30 < plat_time then
					colour = YELLOW
					self.icon = ARTWORK_DOCKED
				else
					colour = RED
					self.icon = ARTWORK_DEPARTING
				end

				lowestTime = -math.huge
				self.lowestNameTime = data.ebv.." "..colour..self:GetFormattedTime(plat_time)
			else
				plat_time = self:GetCycleByIndex(transit, data.index-1) - cycle

				if 0 > plat_time then
					plat_time = plat_time + self.rtts[transit]
				end

				if plat_time < lowestTime then
					lowestTime = plat_time
					self.lowestNameTime = data.ebv.." "..GREEN..self:GetFormattedTime(plat_time)
					self.icon = ARTWORK_IN_TRANSIT
				end
			end
		end
	end

	if self.tempTextCount > 0 then
		self.tempTextCount = self.tempTextCount - 1
	end

	self:UpdateDisplay()
end

-- AceTimer-3.0 (bundled) does not pcall repeating-timer callbacks: its reschedule
-- call sits after the callback invocation in the same function, so an uncaught
-- error here would silently and permanently stop this timer from ever firing again.
function NauticusClassic:Clock_OnUpdate()
	local ok, err = pcall(self.Clock_OnUpdate_Unsafe, self)
	if not ok then
		self:DebugMessage("Clock_OnUpdate error: "..tostring(err))
	end
end

local x, y, dx, dy, ax, ay, dax, day, tx, ty, txp, typ, instanceID, dist, post, last_trig, keep_time
local old_x, old_y, old_ax, old_ay -- old player coords
local prev_time = 0
local prev_rot = 0

function NauticusClassic:CheckTriggers_OnUpdate_Unsafe()
	self:UpdateZone(true)

	-- remember if we've already triggered a set of coords within the last 30 secs
	if last_trig and GetTime() > 30.0 + last_trig then last_trig = nil; end
	if not self.currentZoneTransports or self.currentZoneTransports.virtual then return; end

	old_x, old_y = x, y
	old_ax, old_ay = ax, ay
	x, y, instanceID = HBD:GetPlayerWorldPosition()
	ax, ay = ClassicAzerothMapFromWorld(x, y, instanceID)

	if not x or not old_x or not y or not old_y then return; end

	dx = x - old_x
	dy = y - old_y

	-- start calculate data
	-- local now = GetTime()
	-- dt = now - prev_time
	-- prev_time = now
	-- local rot = GetPlayerFacing()
	-- local drot = deg(rot - prev_rot)
	-- if drot < -180 then
	-- 	drot = 360 + drot
	-- end
	-- if drot > 180 then
	-- 	drot = drot - 360
	-- end
	-- self:DebugMessage(format("%.14f:%.14f:%.14f:%.14f:%.3f:0:%.4f:%.4f", x, y, dx, dy, dt, drot, deg(rot)))
	-- prev_rot = rot
	-- end calculate data

	-- start calculate data
	-- dax = ax - old_ax
	-- day = ay - old_ay
	-- local now = GetTime()
	-- local dt = now - prev_time
	-- prev_time = now
	-- local rot = GetPlayerFacing()
	-- local drot = deg(rot - prev_rot)
	-- if drot < -180 then
	-- 	drot = 360 + drot
	-- end
	-- if drot > 180 then
	-- 	drot = drot - 360
	-- end
	-- self:DebugMessage(format("%.14f:%.14f:%.14f:%.14f:%.3f:0:%.4f:%.4f", ax, ay, dax, day, dt, drot, deg(rot)))
	-- prev_rot = rot
	-- end calculate data

	dist = HBD:GetWorldDistance(instanceID, x, y, old_x, old_y)
	-- have we moved by at least 6.16 game yards since the last check? this equates to >~110% movement speed
	if 6.16 < dist then
		-- diagnostic for the [11] registration issue: if this ever prints
		-- swim=true or taxi=true while riding the new boat, that's the whole
		-- story -- the very next line would return before triggers[11] is
		-- ever looked at, on every tick, for the entire ride
		if self.debug and self.currentZoneTransports and self.currentZoneTransports[11] then
			self:DebugMessage(format("id11 dist=%.3f swim=%s taxi=%s", dist, tostring(IsSwimming()), tostring(UnitOnTaxi("player"))))
		end
		if IsSwimming() or UnitOnTaxi("player") then return; end
		--check X/Y coords against all triggers for all transports in current zone
		for transit in pairs(self.currentZoneTransports) do
			for _, index in pairs(triggers[transit]) do
				post = 0 > index; if post then index = -index; end
				txp, typ = PointWorldCoords(transit, index-1, instanceID)
				tx, ty = PointWorldCoords(transit, index, instanceID)
				local tdist = HBD:GetWorldDistance(instanceID, x, y, tx, ty)
				-- (a per-trigger-index tdist print used to live here -- removed now that
				-- placement/speed are confirmed working; it produced a line per tagged
				-- index per tick, which blew through DEBUG_LOG_CAP well before a capture
				-- could span a full round trip, let alone two)
				-- within 20 game yards of trigger coords?
				if tdist and 20.0 > tdist then
					if (not (self.checkTriggerDirection[transit] and self.checkTriggerDirection[transit].x and not self:sameSign(dx, tx - txp))) and
						(not (self.checkTriggerDirection[transit] and self.checkTriggerDirection[transit].y and not self:sameSign(dy, ty - typ))) then
						if post then
							if last_trig and keep_time then
								self:SetKnownCycle(transit, GetTime() - last_trig + keep_time, 0, 0)
								self:RequestTransport(transit, "ALL")
								self:DoRequest(10 + math.random() * 10, "ALL")
								self:RequestTransport(transit, "WIDE")
								self:DoRequest(10 + math.random() * 10, "WIDE")
								keep_time = nil
								last_trig = GetTime()
							end
						else
							if not last_trig then
								-- BUG (found via live debug data on [11], see data.lua's
								-- comment above packedData[11] for the trail): this used
								-- to set last_trig unconditionally, even when
								-- `17.0 < dist` was false and SetKnownTime's result got
								-- discarded. That silently burns the whole 30s cooldown
								-- (last_trig is shared across every transport in the
								-- zone) on a no-op, blocking every later -- possibly
								-- much better -- candidate for the rest of that pass.
								-- Invisible on every other route because they only ever
								-- have one trig point each, so there was never a second,
								-- better candidate for an early bad hit to block. Only
								-- consume the cooldown on an actual commit.
								local willCommit = 17.0 < dist
								if self.debug and transit == 11 then
									self:DebugMessage(format("id11 %s idx=%d tdist=%.3f dist=%.3f",
										willCommit and "COMMITTING" or "SKIPPING (dist<17, not consuming cooldown)", index, tdist, dist))
								end
								self:SetKnownTime(instanceID, transit, index, x, y, willCommit)
								if willCommit then last_trig = GetTime(); end
							elseif self.debug and transit == 11 then
								self:DebugMessage(format("id11 BLOCKED idx=%d tdist=%.3f -- last_trig already set %.3fs ago (30s cooldown, shared across all transports)", index, tdist, GetTime()-last_trig))
							end
						end
						return
					end
				end
			end
		end
	elseif self.db.char.autoSelect and 0 == dist and not IsSwimming() then
		--check X/Y coords against all platforms in current zone
		for transit in pairs(self.currentZoneTransports) do
			if transit ~= self.activeTransit then
				for _, data in pairs(self.platforms[transit]) do
					tx, ty = PointWorldCoords(transit, data.index, instanceID)
					local tdist = HBD:GetWorldDistance(instanceID, x, y, tx, ty)
					-- within 20 game yards of platform coords?
					if tdist and 20.0 > tdist then
						self:DebugMessage("near: "..transit)
						self:SetTransport(transit)
						return
					end
				end
			end
		end
	end
end

-- see Clock_OnUpdate: guards against one bad tick permanently killing this repeating timer
function NauticusClassic:CheckTriggers_OnUpdate()
	local ok, err = pcall(self.CheckTriggers_OnUpdate_Unsafe, self)
	if not ok then
		self:DebugMessage("CheckTriggers_OnUpdate error: "..tostring(err))
	end
end

-- dings when a transport in the player's current zone newly arrives (docks) at a
-- platform the player is standing near; edge-triggered on dockedAtPlatform so it
-- fires once per arrival rather than every tick while docked
function NauticusClassic:CheckArrivals_OnUpdate_Unsafe()
	-- Forever's own client already plays a docking sound; ignore whatever
	-- arrivalDing is set to (even a stale true from before switching clients)
	-- rather than double up on it. Era has no such built-in sound.
	if IS_FOREVER then return; end
	if not self.db.profile.arrivalDing then return; end
	if not self.currentZoneTransports or self.currentZoneTransports.virtual then return; end

	local px, py, instanceID = HBD:GetPlayerWorldPosition()
	if not px then return; end

	for transit in pairs(self.currentZoneTransports) do
		if self:HasKnownCycle(transit) and
			((not self.db.profile.factionSpecific) or transports[transit].faction == UnitFactionGroup("player") or transports[transit].faction == "Neutral") then

			local dockedIndex
			local liveIndex = self.liveData[transit].index
			for _, data in pairs(self.platforms[transit]) do
				if data.index == liveIndex then
					dockedIndex = data.index
					break
				end
			end

			if dockedIndex and dockedIndex ~= dockedAtPlatform[transit] then
				local tx, ty = PointWorldCoords(transit, dockedIndex, instanceID)
				local pdist = tx and ty and HBD:GetWorldDistance(instanceID, px, py, tx, ty)
				if pdist and ARRIVAL_SOUND_DISTANCE > pdist then
					PlaySound(5495) -- BoatDockingWarning
				end
			end
			dockedAtPlatform[transit] = dockedIndex
		end
	end
end

-- see Clock_OnUpdate: guards against one bad tick permanently killing this repeating timer
function NauticusClassic:CheckArrivals_OnUpdate()
	local ok, err = pcall(self.CheckArrivals_OnUpdate_Unsafe, self)
	if not ok then
		self:DebugMessage("CheckArrivals_OnUpdate error: "..tostring(err))
	end
end

function NauticusClassic:SetKnownTime(instanceID, transit, index, x, y, set)
	local transitData = transitData[transit]
	local ix, iy, ix2, iy2
	ix, iy = PointWorldCoords(transit, index-1, instanceID)
	ix2, iy2 = PointWorldCoords(transit, index, instanceID)
	--local extrapolate = -transitData.dt[index] + transitData.dt[index] *
	--	(Astrolabe:ComputeDistance(0, 0, x, y, 0, 0, ix, iy) /
	--	Astrolabe:ComputeDistance(0, 0, transitData.x[index], transitData.y[index], 0, 0, ix, iy) )
	local extrapolate = -transitData.dt[index] + transitData.dt[index] *
		(HBD:GetWorldDistance(instanceID, x, y, ix, iy) /
		HBD:GetWorldDistance(instanceID, ix2, iy2, ix, iy) )

	--self:DebugMessage("extrapolate: "..extrapolate)
	local sum_time = self:GetCycleByIndex(transit, index) + extrapolate

	--[===[@debug@
	if self.debug then
		if self:HasKnownCycle(transit) then
			local old_time = self:GetKnownCycle(transit)
			local oldCycle = math.fmod(old_time, self.rtts[transit])
			local diff = oldCycle-sum_time
			local drift = format("%0.6f", diff / ((old_time-sum_time) / self.rtts[transit]))
			self.db.global.knownCycles[transit].drift = drift
			self:DebugMessage(transit..", cycle time: "..sum_time
				.." ; old: "..format("%0.3f", oldCycle)
				.." ; diff: "..format("%0.3f", diff)
				.." ; drift: "..drift)
		else
			self:DebugMessage(transit..", cycle time: "..sum_time)
		end
	end
	--@end-debug@]===]

	if set then
		self:SetKnownCycle(transit, sum_time, 0, 0)
		self:RequestTransport(transit, "ALL")
		self:DoRequest(10 + math.random() * 10, "ALL")
		self:RequestTransport(transit, "WIDE")
		self:DoRequest(10 + math.random() * 10, "WIDE")
		-- unlike the "cycle time" print a few lines up, this one is a live
		-- call, not dead code inside a --[===[@debug@...]===] long comment
		-- (see CLAUDE.md-style history above) -- this is the only
		-- unambiguous confirmation that a known cycle actually committed
		if self.debug then self:DebugMessage(transit..": known cycle COMMITTED, sum_time="..sum_time); end
	else
		-- "set" was false (player's own per-tick movement was <17 yards at
		-- the moment of the trigger crossing) -- this value is only ever
		-- consumed by a "post"/trig0-tagged point, which nothing in this
		-- addon's data uses, so in practice this is a dead end: the
		-- transport will NOT register from this crossing
		if self.debug then self:DebugMessage(transit..": trigger crossed but NOT committed (dist<17), sum_time="..sum_time.." discarded"); end
		keep_time = sum_time
	end
end

function NauticusClassic:GetCycleByIndex(transit, index)
	return transitData[transit].offset[index]
end

-- strips any transport flagged forever_only (data.lua) when not IS_FOREVER, e.g.
-- the new Stormwind Harbor<->Darkshore boat, which doesn't exist on Era. Every
-- id-keyed table below is consulted independently of self.transports elsewhere
-- (e.g. CheckTriggers_OnUpdate_Unsafe indexes transitData/coordsType/platforms
-- straight off whatever id turns up in self.currentZoneTransports, without ever
-- checking self.transports first), so all of them need pruning together, not
-- just self.transports itself -- otherwise an Era client would index a nil
-- entry the moment it wandered near that transport's zone. Must run before
-- anything below (InitialiseConfig and everything downstream of it) reads any
-- of these tables; ids are always appended at the end in data.lua, so deleting
-- one here never leaves a hole for the #(transports)-style numeric loops
-- elsewhere (NextTransportInList, etc.) to trip over.
function NauticusClassic:PruneForeverOnlyTransports()
	if IS_FOREVER then return; end
	for id, transport in pairs(self.transports) do
		if transport.forever_only then
			self.transports[id] = nil
			self.rtts[id] = nil
			self.platforms[id] = nil
			self.coordsType[id] = nil
			self.packedData[id] = nil
			self.checkTriggerDirection[id] = nil
			if self.rawInstance then self.rawInstance[id] = nil; end
			for _, zone in pairs(self.transitZones) do
				zone[id] = nil
			end
		end
	end
end

-- Swaps in Forever-specific route data for EXISTING transports whose
-- real-world path differs between clients (data.lua's *_forever tables --
-- see the comment above transportOverrides_forever for why this is a
-- separate mechanism from PruneForeverOnlyTransports/forever_only rather
-- than reusing it: that one only ever prunes an appended id, so reusing it
-- for a mid-range id like [5] would leave a gap in self.transports on
-- Forever, breaking #(transports)-based code elsewhere). A no-op on Era --
-- every override table is only ever read here, gated behind IS_FOREVER, so
-- Era's own data for these ids is never touched.
function NauticusClassic:ApplyForeverRouteOverrides()
	if not IS_FOREVER then return; end

	for id, override in pairs(self.transportOverrides_forever or {}) do
		if self.transports[id] then
			for k, v in pairs(override) do
				self.transports[id][k] = v
			end
		end
	end

	-- rtt 0 and an empty packed table are the placeholder state before a
	-- route is actually recorded (see the TODOs in data.lua) -- applying
	-- either would wipe out the existing, working Era-recorded data for the
	-- id on Forever too (rtt 0 -> math.fmod(x, 0) is NaN; empty packedData
	-- -> the decode loop below runs zero times, leaving transitData/triggers
	-- empty and the known cycle unable to ever register), so both are
	-- skipped until real data replaces the placeholder.
	for id, rtt in pairs(self.rtts_forever or {}) do
		if rtt ~= 0 then
			self.rtts[id] = rtt
		end
	end

	-- Gated on the SAME "packedData actually recorded" condition as the
	-- packedData swap below, not applied unconditionally: a platform with no
	-- corresponding plat-tag in packedData never gets its .index set (that
	-- only happens in the decode loop's "plat"-tag branch further down), and
	-- CheckTriggers_OnUpdate_Unsafe's autoSelect proximity scan indexes
	-- transitData[transit].x[data.index] for every platform of a zoned
	-- transit unconditionally -- a nil .index there means
	-- HBD:GetWorldDistance(..., nil, nil), which errors every tick while
	-- standing in one of [5]'s zones (silently swallowed by
	-- CheckTriggers_OnUpdate's pcall, so it'd just silently kill autoSelect
	-- for the route). Keeping platforms and packedData in lockstep avoids
	-- ever having a platform whose index can't be set.
	for id, packed in pairs(self.packedData_forever or {}) do
		if #packed > 0 then
			self.packedData[id] = packed
			if self.platforms_forever[id] then
				self.platforms[id] = self.platforms_forever[id]
			end
		end
	end

	for zoneId, ids in pairs(self.transitZones_forever or {}) do
		self.transitZones[zoneId] = self.transitZones[zoneId] or {}
		for id, flag in pairs(ids) do
			self.transitZones[zoneId][id] = flag
		end
	end
end

-- initialise saved variables and data
function NauticusClassic:InitialiseConfig()
	--self:DebugMessage("init config...")
	self:PruneForeverOnlyTransports()
	self:ApplyForeverRouteOverrides()
	transports = self.transports
	self.debug = self.db.global.debug

	self.title = "NauticusClassic "..self.version

	if self.db.global.newerVersion then
		--self:DebugMessage("new version: "..self.db.global.newerVersion.." vs our "..self.versionNum)
		if self.db.global.newerVersion <= 0 or self.db.global.newerVersion > self.MAX_VERSION_NUM then
			-- a peer once broadcast an implausible version (e.g. a two-digit segment like
			-- a "1.4.10"-style build, which breaks the single-digit packing) before the
			-- ReceiveMessage_version guard existed to reject it outright; self-heal here
			-- so an already-poisoned SavedVariables value doesn't show "update available" forever
			self.db.global.newerVersion = nil
			self.db.global.newerVerAge = nil
		elseif self.db.global.newerVersion > self.versionNum then
			-- major update released
			if math.floor(self.db.global.newerVersion/10) > math.floor(self.versionNum/10) then
				self.comm_disable = true
				self.update_available = true
			else
				self.update_available = 30
			end
		else
			self.db.global.newerVersion = nil
			self.db.global.newerVerAge = nil
		end
	end

	self.activeTransit = self.db.char.activeTransit
	-- make sure our saved active transport is still valid...
	if self.activeTransit ~= NONE and not transports[self.activeTransit] then
		self.activeTransit = NONE
		self.db.char.activeTransit = NONE
	end

	local now = GetTime()
	local the_time = time()
	if self.db.global.uptime then
		-- calculate potential drift time in ms between sessions
		local drift = (the_time - now) - (self.db.global.timestamp - self.db.global.uptime)
		self:DebugMessage(format("boot drift: %0.3f", drift))
		-- if more than 3 mins drift, that means reboot occured. we need to adjust ms timers
		if 180 < math.abs(drift) then
			local since
			-- adjust all available transport times by drift
			for transport, data in pairs(self.db.global.knownCycles) do
				since = data.since
				if since then
					since = since - drift
					if 0 > now-since then
						self.db.global.knownCycles[transport] = nil
					else
						data.since = since
						data.boots = data.boots + 1
					end
				end
			end
			self:DebugMessage("reboot must have occured")
		end
	end
	-- record uptime and 'when' (relative to local system clock) this was made
	self.db.global.uptime = now
	self.db.global.timestamp = the_time

	--local worldMapOverlay = CreateFrame("Frame", "NauticusClassicWorldMapOverlay", WorldMapButton)
	--tinsert(WorldMapDisplayFrames, worldMapOverlay)

	-- unpack transport data
	local packedData = self.packedData
	local args = {}
	local j, oldX, oldY, oldOffset, oldDir, d_dir, transit_data, texture_name, frame, texture
	-- see iconminisizeforever in _options above -- Forever uses its own
	-- separate preset field, never miniIconSize (shared/account-wide
	-- profile, so writing through the same field would affect Era too)
	local miniIconSize = (IS_FOREVER and MINI_ICON_SIZE_FOREVER_PRESETS[self.db.profile.miniIconSizeForeverPreset] or self.db.profile.miniIconSize) * ICON_DEFAULT_SIZE
	local worldIconSize = self.db.profile.worldIconSize * ICON_DEFAULT_SIZE
	local liveData = {}
	self.liveData = liveData

	for id, data in pairs(transports) do
		oldX, oldY, oldOffset, oldDir = 0, 0, 0, 0

		transitData[id] = { ['x'] = {}, ['y'] = {}, ['offset'] = {},
			['dx'] = {}, ['dy'] = {}, ['dt'] = {}, ['dir'] = {}, ['d_dir'] = {}, }

		zonings[id] = {}
		jumps[id] = {}
		triggers[id] = {}
		rawPoints[id] = {}
		transit_data = transitData[id]

		for i = 1, #(packedData[id]) do
			j = 0; args[6] = nil
			-- search for seperators in the string and return the separated data
			for value in string.gmatch(packedData[id][i], "[^:]+") do
				j = j + 1; args[j] = value
			end

			transit_data.x[i] = args[1]+oldX
			transit_data.y[i] = args[2]+oldY
			transit_data.offset[i] = args[3]+oldOffset
			transit_data.dx[i] = tonumber(args[1])
			transit_data.dy[i] = tonumber(args[2])
			transit_data.dt[i] = tonumber(args[3])
			d_dir = rad(args[5])
			transit_data.dir[i] = d_dir+oldDir
			transit_data.d_dir[i] = d_dir

			-- a point can carry more than one tag (e.g. a dock that's both
			-- plat2 AND rawp -- see rawPoints above), so every colon-field
			-- from 6 onward is processed as its own independent tag, not
			-- just args[6]
			for k = 6, j do
				local comment = strsub(args[k], 1, 4)
				if comment == "plat" then
					local index = tonumber(strsub(args[k], 5))
					self.platforms[id][index].index = i
				elseif comment == "trig" then
					local index = tonumber(strsub(args[k], 5)) == 0 and -i or i
					tinsert(triggers[id], index)
				elseif comment == "zone" then
					zonings[id][i] = true
				elseif comment == "jump" then
					jumps[id][i] = true
				elseif comment == "rawp" then
					rawPoints[id][i] = true
				end
			end

			oldX, oldY = transit_data.x[i], transit_data.y[i]
			oldOffset = transit_data.offset[i]
			oldDir = transit_data.dir[i]
		end

		transit_data.offset[0] = 0
		transit_data.offset[#(packedData[id])] = self.rtts[id]

		liveData[id] = { cycle = 0, index = 1, }

		texture_name = ARTWORK_PATH.."MapIcon_"..data.ship_type
		data.texture_name = texture_name

		frame = CreateFrame("Button", "NauticusClassicMiniIcon", Minimap)
		data.minimap_icon = frame
		frame:SetSize(miniIconSize, miniIconSize)
		texture = frame:CreateTexture(nil, "ARTWORK")
		frame.texture = texture
		texture:SetTexture(texture_name)
		texture:SetPoint("CENTER")
		texture:SetSize(miniIconSize * math.sqrt(2), miniIconSize * math.sqrt(2))
		frame:SetScript("OnEnter", function(self) NauticusClassic:MapIcon_OnEnter(self) end)
		frame:SetScript("OnLeave", function(self) NauticusClassic:MapIcon_OnLeave(self) end)
		frame:SetID(id)
		frame:Hide()

		frame = CreateFrame("Button", "NauticusClassicWorldIcon", WorldMapFrame)
		data.worldmap_icon = frame
		frame:SetSize(worldIconSize, worldIconSize)
		texture = frame:CreateTexture(nil, "ARTWORK")
		frame.texture = texture
		texture:SetTexture(texture_name)
		texture:SetPoint("CENTER")
		texture:SetSize(worldIconSize * math.sqrt(2), worldIconSize * math.sqrt(2))
		frame:SetScript("OnEnter", function(self) NauticusClassic:MapIcon_OnEnter(self) end)
		frame:SetScript("OnLeave", function(self) NauticusClassic:MapIcon_OnLeave(self) end)
		frame:SetScript("OnMouseDown", function(self) NauticusClassic:MapIcon_OnClick(self) end)
		frame:SetID(id)
		frame:Hide()
	end

	self.packedData = nil -- free some memory (too many indexes to recycle)
end

function NauticusClassic:PLAYER_ENTERING_WORLD()
	-- stays registered for the whole session (not just the first load): a
	-- zeppelin/boat continent crossing is itself a zone transition, and the
	-- hidden WIDE channel can silently drop membership across one, so it
	-- needs to be re-verified/rejoined every time, not just once at login.
	self:JoinWideChannel()
	self:UpdateChannel(10)

	self.currentZoneId = GetCurrentMapOrInstanceID()
	if self.currentZoneId then
		self.currentZoneTransports = self.transitZones[self.currentZoneId]
	end
end

local updateZoneTimer
function NauticusClassic:UpdateZone(loopback)
	if updateZoneTimer then self:CancelTimer(updateZoneTimer, true); updateZoneTimer = nil; end

	local newZoneId = GetCurrentMapOrInstanceID()
	if not loopback and self.currentZoneId == newZoneId then
		updateZoneTimer = self:ScheduleTimer("UpdateZone", 1, true)
		return
	end

	self:SetZone(newZoneId)
end

function NauticusClassic:ZONE_CHANGED()
	self:UpdateZone(false)
end

function NauticusClassic:ZONE_CHANGED_NEW_AREA()
	self:UpdateZone(false)
end

function NauticusClassic:SetZone(zoneId)
	-- special case; don't acknowledge zone change when brushing certain zones, keeping map icons
	if zoneId == nil or self.currentZoneId == zoneId or (self.currentZoneId == 1413 and zoneId == 1411) then return; end

	self.currentZoneId = zoneId
	self.currentZoneTransports = self.transitZones[zoneId]
	-- diagnostic for the [11] (Stormwind Harbor<->Darkshore) registration
	-- issue: confirms/rules out whether GetCurrentMapOrInstanceID ever
	-- reports something other than 1453/1439 while out on open water,
	-- which would explain triggers never being checked for that transport
	if self.debug then
		self:DebugMessage(format("zone -> %s (currentZoneTransports has 11: %s)",
			tostring(zoneId), tostring(self.currentZoneTransports and self.currentZoneTransports[11] ~= nil)))
	end
	if self.db.profile.zoneSpecific then self:RefreshMenu(); end
	self:DrawMapIcons(false, true)
end

function NauticusClassic:ToggleAlarm()
	alarmSet = not alarmSet
	if not alarmSet then alarmDinged = false end
	print(YELLOW.."NauticusClassic|r - "..WHITE..L["Alarm is now: "]..(alarmSet and RED..L["ON"] or GREEN..L["OFF"]).."|r")
	PlaySound(SOUNDKIT.AUCTION_WINDOW_OPEN)
end

function NauticusClassic:IsAlarmSet()
	return alarmSet or alarmDinged
end

function NauticusClassic:GetKnownCycle(transport)
	local knownCycle = self.db.global.knownCycles[transport]
	if knownCycle and knownCycle.since then
		return GetTime()-knownCycle.since, knownCycle.boots, knownCycle.swaps
	end
end

function NauticusClassic:SetKnownCycle(transport, since, boots, swaps)
	if self.db.global.freeze then return; end
	local knownCycle = self.db.global.knownCycles[transport]
	if not knownCycle then
		knownCycle = {}
		self.db.global.knownCycles[transport] = knownCycle
	end
	knownCycle.since, knownCycle.boots, knownCycle.swaps = GetTime()-since, boots, swaps
	self.db.global.uptime = GetTime()
	self.db.global.timestamp = time()
end

function NauticusClassic:HasKnownCycle(transport)
	local knownCycle = self.db.global.knownCycles[transport]
	if transport ~= NONE then
		return knownCycle ~= nil and knownCycle.since ~= nil
	end
end

local formattedTimeCache = {}

-- build cache of formatted times
do
	for i = 0, 59 do
		formattedTimeCache[i] = format("%ds", i)
	end
	for i = 60, MAX_FORMATTED_TIME do
		formattedTimeCache[i] = format("%dm %02ds", i/60, math.fmod(i, 60))
	end
end

function NauticusClassic:GetFormattedTime(t)
	return formattedTimeCache[floor(t)]
end

function NauticusClassic:IsTransportListed(transportIndex)
	local addtrans = false
	local transport = transports[transportIndex]
	if self.db.profile.factionSpecific then
		if transport.faction == UnitFactionGroup("player") or
			transport.faction == "Neutral" then

			addtrans = true
		end
	else
		addtrans = true
	end
	if addtrans and self.db.profile.zoneSpecific then
		if not self.currentZoneTransports or not self.currentZoneTransports[transportIndex] then
			addtrans = false
		end
	end
	return addtrans
end

function NauticusClassic:NextTransportInList()
	local isNotEmpty, isFound, addtrans, first
	for i = 1, #(transports), 1 do
		addtrans = self:IsTransportListed(i)
		isNotEmpty = isNotEmpty or addtrans
		if not first and addtrans then first = i; end
		if not isFound then
			if self.activeTransit == i then
				isFound = true
			end
		else
			if addtrans then
				addtrans = i
				break
			end
		end
	end
	if not isNotEmpty then
		addtrans = NONE
	elseif type(addtrans) ~= "number" then
		addtrans = first
	end
	return addtrans
end

function NauticusClassic:SetTransport(transport)
	if transport then
		self.activeTransit = transport
		self.db.char.activeTransit = self.activeTransit
	end

	local has = self:HasKnownCycle(self.activeTransit)

	if has then
		self.tempText = GREEN..transports[self.activeTransit].short_name
		self.tempTextCount = 3
	else
		self.lowestNameTime = (has == false) and L["N/A"] or "--"
		self.tempTextCount = 0
		self.icon = nil
	end

	self:UpdateDisplay()
end

local lastDebug = GetTime()

-- capped so a long diagnostic session (e.g. the [11] trigger-registration
-- debugging, which logs every ~0.8s tick) can't grow SavedVariables without
-- bound; oldest entries drop off once the cap is hit
local DEBUG_LOG_CAP = 3000

function NauticusClassic:DebugMessage(msg)
	if self.debug then
		local now = GetTime()
		print(format("[Naut] ["..YELLOW.."%0.3f|r]: %s", now-lastDebug, msg))
		--ChatFrame3:AddMessage(format("[Naut] ["..YELLOW.."%0.3f|r]: %s", now-lastDebug, msg))

		-- chat has a copy-length limit that a multi-minute debug session
		-- blows through easily; mirror everything into SavedVariables too
		-- (see /nautdebuglog below) so it can be pulled from the .lua file
		-- on disk instead of copy-pasted out of the chat frame
		if self.db and self.db.global then
			self.db.global.debugLog = self.db.global.debugLog or {}
			local log = self.db.global.debugLog
			tinsert(log, format("[%s] [%0.3f]: %s", date("%H:%M:%S"), now-lastDebug, msg))
			if #(log) > DEBUG_LOG_CAP then tremove(log, 1); end
		end

		lastDebug = now
	end
end

-- companion to /nautrecord: DebugMessage mirrors every debug line into
-- self.db.global.debugLog as it's logged (see above), so this just manages
-- that log -- clear it right before a fresh test run so the SavedVariables
-- file only has to be re-opened for the lines that matter, and /reload (or
-- log out) afterward to flush it to disk before reading the .lua file
SLASH_NAUTDEBUGLOG1 = "/nautdebuglog"
SlashCmdList["NAUTDEBUGLOG"] = function(msg)
	local cmd = strlower(strtrim(msg or ""))
	if cmd == "clear" then
		NauticusClassic.db.global.debugLog = {}
		print("|cff33ff99[NautDebugLog]|r cleared")
	elseif cmd == "count" then
		local n = NauticusClassic.db.global.debugLog and #(NauticusClassic.db.global.debugLog) or 0
		print(format("|cff33ff99[NautDebugLog]|r %d line(s) buffered -- /reload (or log out), then read [\"debugLog\"] under global in the SavedVariables file", n))
	else
		print("|cff33ff99[NautDebugLog]|r usage: /nautdebuglog clear | /nautdebuglog count")
	end
end

-- Collector AND active re-sync anchor for dock NPCs' boat-arrival
-- announcements, generalized to support more than one route/NPC pair --
-- originally built just for [12]'s Windshapers Dockmaster, but adding
-- [13] (Alliance Zephras Isle <-> Dalaran City) surfaced two real
-- precision problems with matching on a single sender-or-keyword pair:
--
-- 1. "Skycutter" turned out to be a generic VESSEL TYPE, not specific to
--    one route -- [13]'s dockmasters use it too ("The skycutter bound for
--    Dalaran City...", "The skycutter to Zephras Isle...", screenshots
--    2026-09-21), so a bare keyword match would cross-collide between
--    routes.
-- 2. A single sender can say more than one line -- Dalaran City's
--    Arcanist Laurain follows the real arrival line with an unrelated
--    flavor line ("The ride can sometimes be bumpy...") 5s later, which a
--    sender-only match would also catch.
--
-- So each watcher now requires BOTH sender AND a keyword unique to its
-- specific arrival line, tied to a specific transit+platform to re-sync.
-- Meant to run unattended across normal play, not a toggled debug session
-- like /nautrecord -- always registered when IS_FOREVER (see OnEnable),
-- logs quietly (no chat spam) unless self.debug is on.
--
-- Range-gated like any other SAY/YELL message (confirmed by the user for
-- [12] -- NOT a zone-wide broadcast the way the on-screen banner might
-- suggest), so each one only re-syncs for whichever player happens to be
-- within earshot of that specific dock at that exact moment -- same
-- character as a normal trigger point, just proximity-by-audio instead of
-- proximity-by-distance -- and like any trigger commit, it propagates to
-- other players via the existing RequestTransport/DoRequest broadcast.
local CHAT_ARRIVAL_LOG_CAP = 200 -- generous relative to how rarely these actually fire
local ANNOUNCE_WATCHERS = {
	{ sender = "Windshapers Dockmaster", keyword = "Skycutter",    transit = 12, platIndex = 1 }, -- Zephras Isle (Horde)
	{ sender = "High Order Dockmaster",  keyword = "just arrived", transit = 13, platIndex = 1 }, -- Zephras Isle (Alliance)
	{ sender = "Arcanist Laurain",       keyword = "just arrived", transit = 13, platIndex = 2 }, -- Dalaran City
}

-- see Clock_OnUpdate/CheckArrivals_OnUpdate for the established "wrap in
-- pcall" pattern this follows -- added after a live error confirmed
-- `sender == w.sender` throws "attempt to compare local 'sender' (a secret
-- string value, while execution tainted by ...)" on Forever: a newer
-- client-side protection marks CHAT_MSG_* sender/message arguments as
-- "secret" (likely anti-automation, ironically exactly what this handler
-- does), and raw Lua comparison operators can't touch them directly.
-- strcmputf8i (a standard Blizzard global, the established idiom for this
-- exact class of taint-safe string comparison) is used instead of `==`.
-- This error fired on EVERY CHAT_MSG_MONSTER_YELL/SAY/EMOTE in the game,
-- not just the ones this addon cares about, since the comparison itself
-- threw before any relevance check could run -- the pcall wrapper is a
-- second layer of safety in case string.find(msg, ...) below has the same
-- issue (unconfirmed -- the error trace never reached it, since `and`
-- short-circuited on the first failure).
function NauticusClassic:ChatArrivalWatcher_OnMsg_Unsafe(event, msg, sender)
	local matched
	for _, w in ipairs(ANNOUNCE_WATCHERS) do
		if strcmputf8i(sender or "", w.sender) == 0 and string.find(msg or "", w.keyword, 1, true) then
			matched = w
			break
		end
	end
	if not matched then return; end

	self.db.global.chatArrivalLog = self.db.global.chatArrivalLog or {}
	local log = self.db.global.chatArrivalLog
	tinsert(log, format("[%s] [%s] transit=%d %s: %s", date("%Y-%m-%d %H:%M:%S"), event, matched.transit, tostring(sender), msg))
	if #(log) > CHAT_ARRIVAL_LOG_CAP then tremove(log, 1); end

	if self.debug then
		self:DebugMessage(format("ChatArrivalWatcher matched transit=%d (%s) %s: %s", matched.transit, event, tostring(sender), msg))
	end

	-- active re-sync: the announcement firing IS the confirmed arrival
	-- instant, so anchor the cycle directly to offset[plat.index - 1] --
	-- the same "arrival" reference ShowTooltip itself uses (NautUI.lua:
	-- GetCycleByIndex(transit, data.index-1)) -- rather than going through
	-- SetKnownTime. SetKnownTime's distance-ratio extrapolation is built
	-- for a trigger point mid-flight (approaching a point) and anchors to
	-- offset[index] itself; for a platform tag, that index's own dt
	-- already includes the ENTIRE dwell, so calling it with the
	-- platform's own index sets the cycle to the DEPARTURE moment (end of
	-- dwell) instead of arrival every single time -- confirmed live on
	-- [12]: made the gap worse, not better. Here there's no fractional
	-- position to extrapolate anyway -- the announcement gives exact
	-- knowledge of the arrival instant, not an approximate mid-route
	-- position -- so this sets the cycle directly.
	local plat = self.platforms[matched.transit] and self.platforms[matched.transit][matched.platIndex]
	if plat and plat.index then
		local x, y, instanceID = HBD:GetPlayerWorldPosition()
		-- raw-pinning is PER-POINT, not per-transit -- [13]'s Zephras Isle
		-- dock (plat1) is raw-pinned but its Dalaran City dock (plat2) is a
		-- plain composite point (confirmed: no :rawp tag on that row).
		-- Checking rawInstance[transit] alone (a transit-wide value) would
		-- wrongly require instanceID==2991 even for the Dalaran
		-- announcement, which can never be true there -- silently blocking
		-- that dock's re-sync forever. rawPoints[transit][index] is the
		-- same per-point flag PointWorldCoords itself reads, so checking
		-- it here keeps the two consistent.
		local isRawPoint = rawPoints[matched.transit] and rawPoints[matched.transit][plat.index]
		local instanceOK = not isRawPoint or instanceID == self.rawInstance[matched.transit]
		if x and instanceOK then
			local sum_time = self:GetCycleByIndex(matched.transit, plat.index - 1)
			self:SetKnownCycle(matched.transit, sum_time, 0, 0)
			self:RequestTransport(matched.transit, "ALL")
			self:DoRequest(10 + math.random() * 10, "ALL")
			self:RequestTransport(matched.transit, "WIDE")
			self:DoRequest(10 + math.random() * 10, "WIDE")
			if self.debug then
				self:DebugMessage(format("ChatArrivalWatcher: active re-sync committed for [%d] via platIndex %d, sum_time=%s", matched.transit, matched.platIndex, tostring(sum_time)))
			end
		end
	end

	-- flag consumed by NautRecord_Sample below, which marks the very next
	-- recorded sample :announce -- see its comment for why this goes
	-- through a field rather than a direct call
	self.pendingRecordAnnounceMark = true
	if self.debug then
		print(format("|cff33ff99[NautChatLog]|r %s heard (transit %d) -- if /nautrecord is running, the next sample will be marked :announce", tostring(sender), matched.transit))
	end
end

function NauticusClassic:ChatArrivalWatcher_OnMsg(event, msg, sender)
	local ok, err = pcall(self.ChatArrivalWatcher_OnMsg_Unsafe, self, event, msg, sender)
	if not ok then
		self:DebugMessage("ChatArrivalWatcher_OnMsg error: "..tostring(err))
	end
end

-- companion to ChatArrivalWatcher_OnMsg above -- same clear/count pattern as
-- /nautdebuglog
SLASH_NAUTCHATLOG1 = "/nautchatlog"
SlashCmdList["NAUTCHATLOG"] = function(msg)
	local cmd = strlower(strtrim(msg or ""))
	if cmd == "clear" then
		NauticusClassic.db.global.chatArrivalLog = {}
		print("|cff33ff99[NautChatLog]|r cleared")
	elseif cmd == "count" then
		local n = NauticusClassic.db.global.chatArrivalLog and #(NauticusClassic.db.global.chatArrivalLog) or 0
		print(format("|cff33ff99[NautChatLog]|r %d entr%s buffered -- /reload (or log out), then read [\"chatArrivalLog\"] under global in the SavedVariables file", n, n == 1 and "y" or "ies"))
	else
		print("|cff33ff99[NautChatLog]|r usage: /nautchatlog clear | /nautchatlog count")
	end
end

-- Diagnostic that confirmed, then verifies, the "WoW: Forever" (Interface
-- 16001) transit-detection breakage: on that client WOW_PROJECT_ID = 1
-- (WOW_PROJECT_MAINLINE), which none of HereBeDragons' WoWClassic/WoWBC/
-- WoWWrath/WoWCata/WoWMists checks match (see fixupZones() in
-- HereBeDragons-2.0.lua) — an old-style global, not a C_ API, so it isn't
-- in the WowApiExplorer dumps and this had to be confirmed live in-game
-- instead. HBD falls into its retail/mainline branch as a result and uses a
-- much larger Azeroth-world-map scale ({76153.14,50748.62,...} vs Classic's
-- {44688.53,29795.11,...}), so every route recorded via that fraction
-- encoding (coordsType<0 in data.lua) landed nowhere near where the client
-- now says it is. WorldFromClassicAzerothMap/ClassicAzerothMapFromWorld
-- above pin the Classic constants directly, independent of HBD's runtime
-- guess, which is the actual fix; this command's "HBD's live" line should
-- now visibly disagree with "fixed classic-calibrated", confirming why the
-- old code broke and that the new path is being used instead. Not gated
-- behind self.debug: meant to be run ad-hoc and the output pasted back,
-- like /nautwide.
SLASH_NAUTCOORDS1 = "/nautcoords"
SlashCmdList["NAUTCOORDS"] = function()
	local x, y, instanceID = HBD:GetPlayerWorldPosition()
	local hbdAx, hbdAy
	if x then hbdAx, hbdAy = HBD:GetAzerothWorldMapCoordinatesFromWorld(x, y, instanceID) end
	local fixedAx, fixedAy = ClassicAzerothMapFromWorld(x, y, instanceID)
	local uiMapID = C_Map.GetBestMapForUnit("player")
	local mapInfo = uiMapID and C_Map.GetMapInfo(uiMapID)
	local wm0, wm1 = HBD.worldMapData[0], HBD.worldMapData[1]

	-- ground truth for CLASSIC_AZEROTH_WORLDMAP_RECT entries that don't exist
	-- yet (e.g. a brand-new Forever-only continent instance with no Classic
	-- equivalent to copy a constant from, unlike Eastern Kingdoms/Kalimdor --
	-- see the comment above that table). C_Map.GetPlayerMapPosition(947, ...)
	-- reports the player's fraction on the World composite map independent of
	-- HBD entirely, same ground-truth source /nautworldmap already uses. Two
	-- samples at different world x/y within the same instance are enough to
	-- solve the rect's 4 unknowns (width/left from the x pair, height/top
	-- from the y pair) since x and y transform independently in this model.
	--
	-- 947 came back nil for Zephras Isle (confirmed live) despite its map
	-- breadcrumb showing "World > Zephras Isle" -- 947 is the Classic-era
	-- World map id, which was likely never extended to include Forever's new
	-- content, so the real composite parent is probably a different uiMapID.
	-- Walk the actual parent chain (C_Map.GetMapInfo().parentMapID) and try
	-- GetPlayerMapPosition at every level to find whichever one actually
	-- returns a position, instead of assuming 947 is still correct.
	local blizzPos = C_Map.GetPlayerMapPosition(947, "player")
	local blizzX, blizzY = blizzPos and blizzPos:GetXY()

	local parentChain = {}
	do
		local walkID = uiMapID
		local seen = {}
		while walkID and not seen[walkID] do
			seen[walkID] = true
			local info = C_Map.GetMapInfo(walkID)
			if not info then break; end
			local pos = C_Map.GetPlayerMapPosition(walkID, "player")
			local px, py = pos and pos:GetXY()
			tinsert(parentChain, format("uiMapID=%s (%s) mapType=%s pos=%s,%s",
				tostring(walkID), tostring(info.name), tostring(info.mapType), tostring(px), tostring(py)))
			walkID = info.parentMapID
			if not walkID or walkID == 0 then break; end
		end
	end

	local function fmtRect(wm)
		return wm and format("{%.2f, %.2f, %.2f, %.2f}", wm[1], wm[2], wm[3], wm[4]) or "nil"
	end

	print("|cff33ff99[NautCoords]|r WOW_PROJECT_ID = "..tostring(WOW_PROJECT_ID))
	print(format("  player world pos: x=%s y=%s instanceID=%s", tostring(x), tostring(y), tostring(instanceID)))
	print(format("  HBD's live azeroth worldmap pos: ax=%s ay=%s", tostring(hbdAx), tostring(hbdAy)))
	print(format("  fixed classic-calibrated pos (what transitData is now compared against): ax=%s ay=%s", tostring(fixedAx), tostring(fixedAy)))
	print(format("  Blizzard's own World Map (947) ground-truth fraction: x=%s y=%s", tostring(blizzX), tostring(blizzY)))
	print(format("  uiMapID=%s (%s)", tostring(uiMapID), mapInfo and mapInfo.name or "?"))
	print("  parent map chain (looking for one with a non-nil pos):")
	for _, line in ipairs(parentChain) do
		print("    "..line)
	end
	print("  HBD.worldMapData[0] = "..fmtRect(wm0))
	print("  HBD.worldMapData[1] = "..fmtRect(wm1))
	print("  reference: Classic Era = {44688.53, 29795.11, 32601.04, 9894.93} / {44878.66, 29916.10, 8723.96, 14824.53}")
	print("             HBD retail-branch fallback = {76153.14, 50748.62, 65008.24, 23827.51} / {77621.12, 51854.98, 12444.4, 28030.61}")
end

-- Ground-truth check for the [11] World Map placement issue: Stormwind
-- (instance 0) looked right after the GetAzerothWorldMapCoordinatesFromWorld
-- patch above, but Auberdine (instance 1) still didn't -- surprising, since
-- that patch treats both instances symmetrically through the same
-- CLASSIC_AZEROTH_WORLDMAP_RECT already proven correct for trigger/dock
-- detection at Auberdine. Rather than guess at a second correction, compare
-- against C_Map.GetPlayerMapPosition(947, "player") -- a modern Blizzard API
-- that reports the player's own position on ANY uiMapID (including the
-- World composite) independent of HBD entirely, so it's ground truth. Run
-- this while standing at the point in question with the World Map open.
SLASH_NAUTWORLDMAP1 = "/nautworldmap"
SlashCmdList["NAUTWORLDMAP"] = function()
	local x, y, instanceID = HBD:GetPlayerWorldPosition()
	local ourX, ourY = x and HBD:GetAzerothWorldMapCoordinatesFromWorld(x, y, instanceID)
	local blizzPos = C_Map.GetPlayerMapPosition(947, "player")
	local blizzX, blizzY = blizzPos and blizzPos:GetXY()

	print("|cff33ff99[NautWorldMap]|r instanceID="..tostring(instanceID))
	print(format("  our computed World Map fraction:      x=%s y=%s", tostring(ourX), tostring(ourY)))
	print(format("  Blizzard's own World Map fraction:    x=%s y=%s", tostring(blizzX), tostring(blizzY)))
	if ourX and blizzX then
		print(format("  delta: dx=%.5f dy=%.5f", ourX-blizzX, ourY-blizzY))
	end
end

-- Live rotation comparison for the [11] boat, bypassing the whole recording/
-- interpolation pipeline: reads back the angle actually applied via
-- SetRotation (stashed by DrawMapIcons_Unsafe into self.lastRenderedAngle,
-- only updated while the World Map is open) and compares it directly to the
-- player's OWN live GetPlayerFacing(). Run this while standing still on the
-- boat with the World Map open -- if there's a genuinely wrong transform
-- (not just noisy recorded data), the delta here will be constant and
-- obvious, telling us exactly what correction is needed instead of guessing
-- from reprocessed data again.
SLASH_NAUTROTCHECK1 = "/nautrotcheck"
SlashCmdList["NAUTROTCHECK"] = function()
	local rendered = NauticusClassic.lastRenderedAngle and NauticusClassic.lastRenderedAngle[11]
	local facing = GetPlayerFacing()

	if not rendered then
		print("|cffff0000[NautRotCheck]|r no rendered angle yet for id 11 -- open the World Map while on/near the boat first")
		return
	end

	local renderedDeg = deg(rendered) % 360
	local facingDeg = facing and deg(facing) % 360

	local liveData = NauticusClassic.liveData and NauticusClassic.liveData[11]

	print("|cff33ff99[NautRotCheck]|r rendered angle (SetRotation, deg) = "..format("%.2f", renderedDeg))
	print("  player GetPlayerFacing() (deg) = "..format("%s", facingDeg and format("%.2f", facingDeg) or "nil"))
	if facingDeg then
		local delta = (renderedDeg - facingDeg + 180) % 360 - 180
		print(format("  delta (rendered - facing): %.2f degrees", delta))
	end
	-- added after two clean but inconsistent /nautrotcheck plateaus (~+90 and
	-- ~-60, 16s apart) pointed at a real, isolated discontinuity somewhere in
	-- the [11] array rather than noise -- logging the live interpolation
	-- index/cycle alongside the delta lets us pinpoint exactly which segment
	-- boundary it happens at, instead of guessing from elapsed time
	if liveData then
		print(format("  liveData: index=%s cycle=%s", tostring(liveData.index), tostring(liveData.cycle)))
	end
end

-- Ad-hoc live diagnostic for [12]'s Zephras Isle approach/dwell timing --
-- built after three rounds of guessing at dt corrections from vague
-- end-of-flight reports ("still N seconds left"/"icon looks ahead")
-- oscillated (too slow -> overcorrected -> dwell fix helped but approach
-- pacing still off). Logs the model's own predicted seconds-until-arrival
-- at Windshapers Dock (plat1) -- same formula ShowTooltip's "Arrival"
-- branch uses (NautUI.lua: GetCycleByIndex(transit, data.index-1) - cycle)
-- -- alongside the player's LIVE distance to that same dock, once a
-- second, for the whole flight. The over-time curve reveals whether the
-- mismatch is a uniform pacing error or concentrated in one stretch (e.g.
-- the noisy low-speed final approach), instead of guessing from a single
-- end-of-flight snapshot. Mirrors into self.db.global.paceLog
-- (SavedVariables) the same way debugLog/chatArrivalLog do, capped the
-- same way. Hardcoded to transit 12 -- this is a targeted diagnostic for
-- the one route currently being tuned, not a general-purpose tool.
local paceLogging = false
local paceTimer
local PACE_LOG_CAP = 500

local function NautPace_Tick()
	local liveData = NauticusClassic.liveData and NauticusClassic.liveData[12]
	local plat1 = NauticusClassic.platforms[12] and NauticusClassic.platforms[12][1]
	if not liveData or not plat1 or not plat1.index then return; end

	local rtts = NauticusClassic.rtts[12]
	local offsets = transitData[12].offset
	local plat_time = offsets[plat1.index - 1] - liveData.cycle
	if 0 > plat_time then plat_time = plat_time + rtts; end

	local x, y, instanceID = HBD:GetPlayerWorldPosition()
	local distStr = "n/a"
	if x then
		local tx, ty = PointWorldCoords(12, plat1.index, instanceID)
		local d = HBD:GetWorldDistance(instanceID, x, y, tx, ty)
		if d then distStr = format("%.1f", d); end
	end

	-- index/cycle logged alongside the prediction -- a backward jump in
	-- predicted_arrival_in (should only ever count down) needs the exact
	-- array row to pinpoint the discontinuity, not just the timestamp
	local line = format("[%s] predicted_arrival_in=%.1fs live_dist_to_dock=%s index=%s cycle=%s",
		date("%H:%M:%S"), plat_time, distStr, tostring(liveData.index), tostring(liveData.cycle))
	print("|cff33ff99[NautPace]|r "..line)
	NauticusClassic.db.global.paceLog = NauticusClassic.db.global.paceLog or {}
	local log = NauticusClassic.db.global.paceLog
	tinsert(log, line)
	if #(log) > PACE_LOG_CAP then tremove(log, 1); end
end

SLASH_NAUTPACE1 = "/nautpace"
SlashCmdList["NAUTPACE"] = function()
	paceLogging = not paceLogging
	if paceLogging then
		if paceTimer then NauticusClassic:CancelTimer(paceTimer); end
		paceTimer = NauticusClassic:ScheduleRepeatingTimer(NautPace_Tick, 1.0)
		print("|cff33ff99[NautPace]|r logging ON -- ride from Skywatch Plateau all the way to docking at Zephras Isle, then /nautpace again to stop.")
	else
		if paceTimer then NauticusClassic:CancelTimer(paceTimer); paceTimer = nil; end
		print("|cff33ff99[NautPace]|r logging OFF")
	end
end

-- Visual debug aid for diagnosing trigger/registration problems (built
-- after [5]'s Southshore route repeatedly failed to register live and
-- reprocessing the data from text reports alone wasn't converging -- see
-- data.lua's comment above packedData_forever[5]) instead of guessing from
-- another round of "still didn't register". Places a small dot on the
-- World Map for every point in a transit's current packedData[id]
-- (colour-coded by tag), plus a bright cyan marker that tracks the
-- player's own live position on a timer, so a registration failure can be
-- diagnosed by directly watching how close the live marker actually gets
-- to each trig point/cluster while riding the route, instead of
-- re-guessing from another text report.
--
-- Deliberately does NOT reuse PointWorldCoords for the static per-point
-- placement below: that helper resolves a coordsType<0 point's hemisphere
-- from the CALLER's own current instanceID (correct for a live proximity
-- check, where the point being tested is guaranteed to be on whichever
-- continent the player is currently standing on) -- but this overlay needs
-- to place EVERY point correctly regardless of which continent the player
-- happens to be on when they open the map, so RouteDebug_PointWzone below
-- mirrors DrawMapIcons_Unsafe's own hemisphere split instead (picked from
-- the point's own x<0.5 fraction, see its comment on the [11] World Map
-- placement bug). PointWorldCoords is still used for the actual
-- fraction->world conversion once the correct wzone is known.
local routeDebugIcons = {}
local routeDebugMiniIcons = {}
local routeDebugWzones = {}
local routeDebugPlayerIcon
local routeDebugPlayerMiniIcon
local routeDebugTimer
local routeDebugTransit

local function RouteDebug_ColorFor(i, id)
	if triggers[id] then
		for _, idx in pairs(triggers[id]) do
			if (0 > idx and -idx or idx) == i then return 1, 0.2, 0.2, 1; end -- trig: red
		end
	end
	for _, plat in pairs(NauticusClassic.platforms[id] or {}) do
		if plat.index == i then return 0.15, 0.9, 0.15, 1; end -- plat: green
	end
	if jumps[id] and jumps[id][i] then return 1, 0.6, 0, 1; end -- jump: orange
	return 1, 0.85, 0.1, 0.75 -- plain: yellow (was dim grey -- too washed
	-- out/white-looking against the map to actually see; plat moved to
	-- green above so the dock still stands out distinctly from the route)
end

local function RouteDebug_GetIcon(n)
	local icon = routeDebugIcons[n]
	if not icon then
		icon = CreateFrame("Frame", nil, WorldMapFrame)
		icon:SetSize(6, 6)
		icon.texture = icon:CreateTexture(nil, "OVERLAY")
		icon.texture:SetAllPoints()
		icon:Hide()
		routeDebugIcons[n] = icon
	end
	return icon
end

local function RouteDebug_GetMiniIcon(n)
	local icon = routeDebugMiniIcons[n]
	if not icon then
		icon = CreateFrame("Frame", nil, Minimap)
		icon:SetSize(5, 5)
		icon.texture = icon:CreateTexture(nil, "OVERLAY")
		icon.texture:SetAllPoints()
		icon:Hide()
		routeDebugMiniIcons[n] = icon
	end
	return icon
end

local function RouteDebug_Clear()
	for _, icon in pairs(routeDebugIcons) do
		Pins:RemoveWorldMapIcon(NauticusClassic, icon)
		icon:Hide()
	end
	for _, icon in pairs(routeDebugMiniIcons) do
		Pins:RemoveMinimapIcon(NauticusClassic, icon)
		icon:Hide()
	end
	if routeDebugPlayerIcon then
		Pins:RemoveWorldMapIcon(NauticusClassic, routeDebugPlayerIcon)
		routeDebugPlayerIcon:Hide()
	end
	if routeDebugPlayerMiniIcon then
		Pins:RemoveMinimapIcon(NauticusClassic, routeDebugPlayerMiniIcon)
		routeDebugPlayerMiniIcon:Hide()
	end
end

-- mirrors DrawMapIcons_Unsafe's own wzone selection -- see comment above
local function RouteDebug_PointWzone(id, index)
	if rawPoints[id] and rawPoints[id][index] then
		return nil -- no sensible World Map placement, see DrawMapIcons_Unsafe
	elseif NauticusClassic.coordsType[id] < 0 then
		local x = transitData[id].x[index]
		return x < 0.5 and 1 or 0
	else
		return NauticusClassic.coordsType[id]
	end
end

-- Minimap icons only make sense for points in the player's CURRENT
-- zone/instance (unlike the World Map, which can show the whole route
-- across continents at once) -- so which points get a minimap icon is
-- re-evaluated every tick against the player's live instanceID, using the
-- wzone cached per point at toggle-on time (RouteDebug_PointWzone is
-- static per point, no need to recompute it every 0.5s).
local function RouteDebug_Tick()
	if not routeDebugTransit then return; end
	local x, y, instanceID = HBD:GetPlayerWorldPosition()
	if not x then return; end
	if not routeDebugPlayerIcon then
		routeDebugPlayerIcon = CreateFrame("Frame", nil, WorldMapFrame)
		routeDebugPlayerIcon:SetSize(10, 10)
		routeDebugPlayerIcon.texture = routeDebugPlayerIcon:CreateTexture(nil, "OVERLAY")
		routeDebugPlayerIcon.texture:SetAllPoints()
		routeDebugPlayerIcon.texture:SetColorTexture(0, 1, 1, 1)
	end
	Pins:RemoveWorldMapIcon(NauticusClassic, routeDebugPlayerIcon)
	Pins:AddWorldMapIconWorld(NauticusClassic, routeDebugPlayerIcon, instanceID, x, y, HBD_PINS_WORLDMAP_SHOW_WORLD)
	routeDebugPlayerIcon:Show()

	if not routeDebugPlayerMiniIcon then
		routeDebugPlayerMiniIcon = CreateFrame("Frame", nil, Minimap)
		routeDebugPlayerMiniIcon:SetSize(8, 8)
		routeDebugPlayerMiniIcon.texture = routeDebugPlayerMiniIcon:CreateTexture(nil, "OVERLAY")
		routeDebugPlayerMiniIcon.texture:SetAllPoints()
		routeDebugPlayerMiniIcon.texture:SetColorTexture(0, 1, 1, 1)
	end
	Pins:RemoveMinimapIcon(NauticusClassic, routeDebugPlayerMiniIcon)
	Pins:AddMinimapIconWorld(NauticusClassic, routeDebugPlayerMiniIcon, instanceID, x, y, true)
	routeDebugPlayerMiniIcon:Show()

	for i, wzone in pairs(routeDebugWzones) do
		local icon = RouteDebug_GetMiniIcon(i)
		if wzone == instanceID then
			local xw, yw = PointWorldCoords(routeDebugTransit, i, wzone)
			if xw and xw ~= RAW_POINT_MISMATCH_SENTINEL then
				local r, g, b, a = RouteDebug_ColorFor(i, routeDebugTransit)
				icon.texture:SetColorTexture(r, g, b, a)
				Pins:RemoveMinimapIcon(NauticusClassic, icon)
				Pins:AddMinimapIconWorld(NauticusClassic, icon, wzone, xw, yw, true)
				icon:Show()
			end
		elseif icon:IsShown() then
			Pins:RemoveMinimapIcon(NauticusClassic, icon)
			icon:Hide()
		end
	end
end

SLASH_NAUTROUTEDBG1 = "/nautroutedbg"
SlashCmdList["NAUTROUTEDBG"] = function(msg)
	local id = tonumber(msg)
	if routeDebugTransit then
		RouteDebug_Clear()
		if routeDebugTimer then NauticusClassic:CancelTimer(routeDebugTimer); routeDebugTimer = nil; end
		routeDebugTransit = nil
		for k in pairs(routeDebugWzones) do routeDebugWzones[k] = nil; end
		print("|cff33ff99[NautRouteDbg]|r OFF")
		if not id then return; end
	end
	if not id or not transitData[id] then
		print("|cffff0000[NautRouteDbg]|r usage: /nautroutedbg <transit id> -- e.g. /nautroutedbg 5")
		return
	end
	routeDebugTransit = id
	local n = #(transitData[id].x)
	local placed = 0
	for i = 1, n do
		local wzone = RouteDebug_PointWzone(id, i)
		routeDebugWzones[i] = wzone
		if wzone then
			local xw, yw = PointWorldCoords(id, i, wzone)
			if xw and xw ~= RAW_POINT_MISMATCH_SENTINEL then
				local icon = RouteDebug_GetIcon(i)
				local r, g, b, a = RouteDebug_ColorFor(i, id)
				icon.texture:SetColorTexture(r, g, b, a)
				Pins:AddWorldMapIconWorld(NauticusClassic, icon, wzone, xw, yw, HBD_PINS_WORLDMAP_SHOW_WORLD)
				icon:Show()
				placed = placed + 1
			end
		end
	end
	routeDebugTimer = NauticusClassic:ScheduleRepeatingTimer(RouteDebug_Tick, 0.5)
	print(format("|cff33ff99[NautRouteDbg]|r ON for transit %d (%d/%d points placed) -- open the World Map AND/OR minimap. Red=trig, green=plat, orange=jump, yellow=plain, cyan=your live position (minimap only shows points in your current zone). /nautroutedbg again to turn off.", id, placed, n))
end

-- Ad-hoc recorder for producing new packedData[id] entries (data.lua's
-- "X:Y:t:(s):a:[c]" format -- see PruneForeverOnlyTransports above and the
-- [11] entry in data.lua for why this is needed for the new Stormwind
-- Harbor<->Darkshore boat). Reconstructs the exact sampling
-- CheckTriggers_OnUpdate_Unsafe used to record every existing coordsType<0
-- route: the commented-out block still sitting in that function computes
-- fractional ClassicAzerothMap deltas (dx/dy) the same way, a time delta
-- (dt), and a GetPlayerFacing()-based rotation delta ("a") -- confirmed
-- cosmetic-only (used purely to interpolate the map icon's rotation while
-- in transit, see DrawMapIcons_Unsafe; never consulted by trigger/dock
-- detection), so an imprecise "a" here can't break anything functional.
-- Samples on its own timer rather than hooking the live CheckTriggers path
-- so recording never interferes with real trigger detection. Not gated
-- behind self.debug: meant to be run ad-hoc while riding the boat being
-- recorded, like /nautcoords. Writes into self.db.global.recordedRoute so
-- the data survives to the SavedVariables file on /reload or logout --
-- addon Lua has no OS clipboard access, so that's the only reliable way to
-- get a few hundred lines of text out of the client to paste back.
--
-- IMPORTANT, learned the hard way on the [11] route: "mark trig1"/"trig2"
-- are NOT optional cosmetic markers -- self.triggers[id] (built from
-- "trig"-tagged points, see InitialiseConfig's packedData decode loop) is
-- the ONLY thing that populates it, and CheckTriggers_OnUpdate_Unsafe's
-- SetKnownTime call (the thing that actually establishes a known cycle,
-- i.e. makes the transport "register") only ever fires off a triggers[id]
-- hit. plat1/plat2 alone are enough for auto-select-at-dock, but with no
-- trig marks a transport will silently never register at all, no matter
-- how many round trips are ridden. Always mark at least one trig point
-- somewhere near each end while the boat is actively moving (not docked/
-- idle) and still within that dock's zone bounds.
local recording = false
local recTimer, recLastAx, recLastAy, recLastRot, recLastTime

local function NautRecord_Sample()
	local x, y, instanceID = HBD:GetPlayerWorldPosition()
	if not x then return; end
	local ax, ay = ClassicAzerothMapFromWorld(x, y, instanceID)
	local isRaw = false
	if not ax then
		-- no known Azeroth-composite-map calibration for this instance (see
		-- CLASSIC_AZEROTH_WORLDMAP_RECT) -- rather than failing outright,
		-- fall back to recording literal per-instance world coordinates,
		-- tagged :rawp so the decoder/renderer treat this point's x/y as
		-- already-raw world coords instead of a composite fraction (see
		-- rawPoints/PointWorldCoords above and NauticusClassic.rawInstance
		-- in data.lua). First needed for [12]'s Zephras Isle leg -- confirmed
		-- via /nautcoords's parent-map-chain walk that no map level (947 or
		-- otherwise) has valid position data for that instance at all.
		ax, ay, isRaw = x, y, true
	end
	local now = GetTime()
	local rot = GetPlayerFacing() or 0
	local dx, dy, dt, drot

	if recLastAx then
		dx, dy, dt = ax - recLastAx, ay - recLastAy, now - recLastTime
		drot = deg(rot - recLastRot)
		if drot < -180 then drot = drot + 360; end
		if drot > 180 then drot = drot - 360; end
	else
		-- first point: the decoder's oldX/oldY/oldDir all start at 0, so the
		-- first line must be the absolute starting position/heading, not a delta
		dx, dy, dt, drot = ax, ay, 0, deg(rot)
	end

	recLastAx, recLastAy, recLastRot, recLastTime = ax, ay, rot, now
	local line = format("%.14f:%.14f:%.3f:0:%.4f", dx, dy, dt, drot)
	if isRaw then line = line..":rawp"; end
	tinsert(NauticusClassic.db.global.recordedRoute, line)
	local i = #(NauticusClassic.db.global.recordedRoute)

	-- consumed here (not appended directly from ChatArrivalWatcher_OnMsg)
	-- because that function is defined earlier in the file and can't
	-- lexically see the recording-session locals in this section -- a
	-- plain NauticusClassic field sidesteps that scoping issue and reads
	-- naturally regardless of definition order, since method/field access
	-- resolves at call time, not upvalue-capture time. Marks the very next
	-- sample after the announcement fires with an :announce tag -- at most
	-- 0.8s of slop (this timer's own period), a huge precision improvement
	-- over inferring the real arrival instant from idle-run boundaries.
	if NauticusClassic.pendingRecordAnnounceMark then
		local route = NauticusClassic.db.global.recordedRoute
		route[i] = route[i]..":announce"
		NauticusClassic.pendingRecordAnnounceMark = false
		print(format("|cff33ff99[NautRecord]|r marked point [%d] as :announce (from Windshapers Dockmaster)", i))
	end

	return i
end

SLASH_NAUTRECORD1 = "/nautrecord"
SlashCmdList["NAUTRECORD"] = function(msg)
	local cmd, rest = strsplit(" ", strtrim(msg or ""), 2)
	cmd = strlower(cmd or "")

	if cmd == "start" then
		NauticusClassic.db.global.recordedRoute = {}
		recLastAx, recLastAy, recLastRot, recLastTime = nil, nil, nil, nil
		recording = true
		NauticusClassic.pendingRecordAnnounceMark = false -- clear any stale flag from a prior session
		if recTimer then NauticusClassic:CancelTimer(recTimer); end
		NautRecord_Sample()
		recTimer = NauticusClassic:ScheduleRepeatingTimer(NautRecord_Sample, 0.8)
		print("|cff33ff99[NautRecord]|r started -- ride the transport now. Use /nautrecord mark plat1 the instant you depart, plat2 the instant you dock at the far end, then /nautrecord stop once you're back where you started (a full round trip, matching how every other route in data.lua is recorded). Points recorded right after the Windshapers Dockmaster's announcement are auto-tagged :announce.")
	elseif cmd == "mark" then
		if not recording then print("|cffff0000[NautRecord]|r not recording -- /nautrecord start first"); return; end
		local tag = strlower(strtrim(rest or ""))
		-- generalized from a hardcoded plat1/plat2/trig1/trig2/zone1/zone2
		-- list: that only ever fit a 2-stop route and silently rejected
		-- plat3 the moment [5] gained a 3rd (Southshore) stop on Forever
		if not string.match(tag, "^plat%d+$") and not string.match(tag, "^trig%d+$") and not string.match(tag, "^zone%d+$") then
			print("|cffff0000[NautRecord]|r usage: /nautrecord mark platN|trigN|zoneN (e.g. plat1, plat3, trig2)")
			return
		end
		local i = NautRecord_Sample()
		if not i then return; end
		local route = NauticusClassic.db.global.recordedRoute
		route[i] = route[i]..":"..tag
		print(format("|cff33ff99[NautRecord]|r marked point [%d] as %s", i, tag))
	elseif cmd == "stop" then
		if recTimer then NauticusClassic:CancelTimer(recTimer); recTimer = nil; end
		recording = false
		local route = NauticusClassic.db.global.recordedRoute or {}
		print(format("|cff33ff99[NautRecord]|r stopped -- %d points captured into SavedVariables.", #(route)))
		print("|cff33ff99[NautRecord]|r /reload (or log out), then open WTF/Account/<account>/SavedVariables/NauticusClassicResurrected.lua, find [\"recordedRoute\"] under global, and paste its contents back so it can be turned into data.lua's packedData[11].")
	else
		print("|cff33ff99[NautRecord]|r usage: /nautrecord start | /nautrecord mark plat1|plat2|trig1|trig2|zone1|zone2 | /nautrecord stop")
	end
end

function NauticusClassic:sameSign(num1, num2)
    return num1 >= 0 and num2 >= 0 or num1 < 0 and num2 < 0
end
