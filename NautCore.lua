
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
local MAX_FORMATTED_TIME = 297 -- the longest route minus 60
local ICON_DEFAULT_SIZE = 18
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
local dockedAtPlatform = {}

local defaults = {
	profile = {
		factionSpecific = true,
		zoneSpecific = false,
		broadcastChannel = "SAY",
		alarmOffset = 20,
		arrivalDing = true,
		miniIconSize = 1,
		worldIconSize = 1.25,
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

				if isZoneInteresting or WorldMapVisible then
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

					if self.coordsType[id] < 0 then
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
		if IsSwimming() or UnitOnTaxi("player") then return; end
		--check X/Y coords against all triggers for all transports in current zone
		for transit in pairs(self.currentZoneTransports) do
			for _, index in pairs(triggers[transit]) do
				post = 0 > index; if post then index = -index; end
				if self.coordsType[transit] < 0 then
					txp, typ = WorldFromClassicAzerothMap(transitData[transit].x[index-1], transitData[transit].y[index-1], instanceID)
					tx, ty = WorldFromClassicAzerothMap(transitData[transit].x[index], transitData[transit].y[index], instanceID)
				else
					txp, typ = transitData[transit].x[index-1], transitData[transit].y[index-1]
					tx, ty = transitData[transit].x[index], transitData[transit].y[index]
				end
				local tdist = HBD:GetWorldDistance(instanceID, x, y, tx, ty)
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
								self:SetKnownTime(instanceID, transit, index, x, y, 17.0 < dist)
								last_trig = GetTime()
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
					if self.coordsType[transit] < 0 then
						tx, ty = WorldFromClassicAzerothMap(transitData[transit].x[data.index], transitData[transit].y[data.index], instanceID)
					else
						tx, ty = transitData[transit].x[data.index], transitData[transit].y[data.index]
					end
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
				local tx, ty
				if self.coordsType[transit] < 0 then
					tx, ty = WorldFromClassicAzerothMap(transitData[transit].x[dockedIndex], transitData[transit].y[dockedIndex], instanceID)
				else
					tx, ty = transitData[transit].x[dockedIndex], transitData[transit].y[dockedIndex]
				end
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
	if self.coordsType[transit] < 0 then
		ix, iy = WorldFromClassicAzerothMap(transitData.x[index-1], transitData.y[index-1], instanceID)
		ix2, iy2 = WorldFromClassicAzerothMap(transitData.x[index], transitData.y[index], instanceID)
	else
		ix, iy = transitData.x[index-1], transitData.y[index-1]
		ix2, iy2 = transitData.x[index], transitData.y[index]
	end
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
	else
		keep_time = sum_time
	end
end

function NauticusClassic:GetCycleByIndex(transit, index)
	return transitData[transit].offset[index]
end

-- initialise saved variables and data
function NauticusClassic:InitialiseConfig()
	--self:DebugMessage("init config...")
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
	local miniIconSize = self.db.profile.miniIconSize * ICON_DEFAULT_SIZE
	local worldIconSize = self.db.profile.worldIconSize * ICON_DEFAULT_SIZE
	local liveData = {}
	self.liveData = liveData

	for id, data in pairs(transports) do
		oldX, oldY, oldOffset, oldDir = 0, 0, 0, 0

		transitData[id] = { ['x'] = {}, ['y'] = {}, ['offset'] = {},
			['dx'] = {}, ['dy'] = {}, ['dt'] = {}, ['dir'] = {}, ['d_dir'] = {}, }

		zonings[id] = {}
		triggers[id] = {}
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

			if args[6] then
				local comment = strsub(args[6], 1, 4)
				if comment == "plat" then
					local index = tonumber(strsub(args[6], 5))
					self.platforms[id][index].index = i
				elseif comment == "trig" then
					local index = tonumber(strsub(args[6], 5)) == 0 and -i or i
					tinsert(triggers[id], index)
				elseif comment == "zone" then
					zonings[id][i] = true
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

function NauticusClassic:DebugMessage(msg)
	if self.debug then
		local now = GetTime()
		print(format("[Naut] ["..YELLOW.."%0.3f|r]: %s", now-lastDebug, msg))
		--ChatFrame3:AddMessage(format("[Naut] ["..YELLOW.."%0.3f|r]: %s", now-lastDebug, msg))
		lastDebug = now
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

	local function fmtRect(wm)
		return wm and format("{%.2f, %.2f, %.2f, %.2f}", wm[1], wm[2], wm[3], wm[4]) or "nil"
	end

	print("|cff33ff99[NautCoords]|r WOW_PROJECT_ID = "..tostring(WOW_PROJECT_ID))
	print(format("  player world pos: x=%s y=%s instanceID=%s", tostring(x), tostring(y), tostring(instanceID)))
	print(format("  HBD's live azeroth worldmap pos: ax=%s ay=%s", tostring(hbdAx), tostring(hbdAy)))
	print(format("  fixed classic-calibrated pos (what transitData is now compared against): ax=%s ay=%s", tostring(fixedAx), tostring(fixedAy)))
	print(format("  uiMapID=%s (%s)", tostring(uiMapID), mapInfo and mapInfo.name or "?"))
	print("  HBD.worldMapData[0] = "..fmtRect(wm0))
	print("  HBD.worldMapData[1] = "..fmtRect(wm1))
	print("  reference: Classic Era = {44688.53, 29795.11, 32601.04, 9894.93} / {44878.66, 29916.10, 8723.96, 14824.53}")
	print("             HBD retail-branch fallback = {76153.14, 50748.62, 65008.24, 23827.51} / {77621.12, 51854.98, 12444.4, 28030.61}")
end

function NauticusClassic:sameSign(num1, num2)
    return num1 >= 0 and num2 >= 0 or num1 < 0 and num2 < 0
end
