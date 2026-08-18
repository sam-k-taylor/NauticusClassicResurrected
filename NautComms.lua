
-- declare colour codes for console messages
local RED     = "|cffff0000"
local GREEN   = "|cff00ff00"
local YELLOW  = "|cffffff00"
local WHITE   = "|cffffffff"
local GREY    = "|cffbababa"

local DATA_VERSION = 4 -- route calibration versioning
local CMD_VERSION = "VER"
local CMD_KNOWN = "KWN4"

local NauticusClassic = NauticusClassic
local L = LibStub("AceLocale-3.0"):GetLocale("NauticusClassic")

local requests = {
	["ALL"] = nil,
	["RAID"] = nil,
	["GUILD"] = nil,
	["YELL"] = nil,
	["WIDE"] = nil
}
local requestLists = {
	["ALL"] = {},
	["RAID"] = {},
	["GUILD"] = {},
	["YELL"] = {},
	["WIDE"] = {}
}
local requestVersions = {
	["ALL"] = false,
	["RAID"] = false,
	["GUILD"] = false,
	["YELL"] = false,
	["WIDE"] = false
}

function NauticusClassic:CancelRequest(distribution)
	if requests[distribution] then
		self:CancelTimer(requests[distribution], true)
		requests[distribution] = nil
	end
end

function NauticusClassic:DoRequest(wait, distribution)
	self:CancelRequest(distribution)

	if wait and wait > 0 then
		requests[distribution] = self:ScheduleTimer("DoRequest", wait, 0, distribution)
		return
	end

	if next(requestLists[distribution]) then
		self:BroadcastTransportData(distribution)

		if requestVersions[distribution] or next(requestLists[distribution]) then
			self:DoRequest(2.5, distribution)
			return
		end
	end

	if requestVersions[distribution] then
		requestVersions[distribution] = false
		local version = self.versionNum
		if self.version then version = version.." "..self.version; end
		self:SendMessage(CMD_VERSION.." "..version, distribution)
	end
end

local function GetLag()
	local _,_,lag = GetNetStats()
	return lag / 1000.0
end

-- printable-only alphabet: safe to send as literal chat text (WIDE distribution).
-- excludes: space, comma, colon, s, S, %, tab (\009) — same reserved set as below
local SAFE_MAP =
	"0123456789ABCDEFGHIJKLMNOPQRTUVWXYZabcdefghijklmnopqrtuvwxyz!\"#$&'()*+-./;<=>?@[\\]^_`{}~"

-- adds non-printable control bytes: fine over SendAddonMessage (raw byte transport),
-- unsafe over literal SendChatMessage text. excludes: nul (\000), line feed (\010), bar (\124), >\127
local FULL_MAP = SAFE_MAP..
	"\001\002\003\004\005\006\007\008\011\012"..
	"\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031\127"

local function buildCodec(map)
	local _base = strlen(map)
	local digits = {}
	local chrmap = {}

	for i = 1, _base do
		local c = strbyte(map, i)
		chrmap[c] = i-1
		digits[i-1] = strchar(c)
	end

	local function crunch(num)
		if 0 > num then error("negative number"); end -- shouldn't happen, but just in case
		local s = ""
		local remain
		repeat
			remain = num % _base -- faster than fmod
			s = s..digits[remain]
			num = (num-remain) / _base -- faster than floor
		until 0 == num
		return s
	end

	local function uncrunch(s)
		local num = 0
		local base = 1
		local c
		for i = 1, strlen(s) do
			c = chrmap[strbyte(s, i)]
			if not c then
				NauticusClassic:DebugMessage("FECK: "..s.." ; i: "..i.." ; strbyte: "..strbyte(s, i))
				return
			end
			num = num + c * base
			base = base * _base -- faster than power (^)
		end
		return num
	end

	return crunch, uncrunch
end

local crunch, uncrunch = buildCodec(FULL_MAP)
local crunchSafe, uncrunchSafe = buildCodec(SAFE_MAP)

-- by Mikk; from http://www.wowwiki.com/StringHash
local function StringHash(text)
	local counter = 1
	local len = strlen(text)
	for i = 1, len, 3 do
		counter = (counter * 8161) % 4294967279 +
		 (strbyte(text, i) * 16776193) +
		((strbyte(text, i+1) or (len-i+256)) * 8372226) +
		((strbyte(text, i+2) or (len-i+256)) * 3932164)
	end
	return counter % 4294967291
end

function NauticusClassic:BroadcastTransportData(distribution)
	local enc = (distribution == "WIDE") and crunchSafe or crunch
	local since, boots, swaps
	local lag = GetLag()
	local trans_str = ""

	for transit in pairs(requestLists[distribution]) do
		since, boots, swaps = self:GetKnownCycle(transit)
		trans_str = trans_str..enc(transit)

		if since ~= nil then
			trans_str = trans_str..":"..enc(math.floor((since+lag)*1000.0+.5))

			if swaps ~= 1 then
				trans_str = trans_str..":"..enc(swaps)
			end

			if boots ~= 0 then
				if swaps == 1 then
					trans_str = trans_str..":"
				end

				trans_str = trans_str..":"..enc(boots)
			end
		end

		trans_str = trans_str..","
		requestLists[distribution][transit] = nil
		if 229 < strlen(trans_str) then break; end
	end

	if trans_str ~= "" then
		trans_str = strsub(trans_str, 1, -2) -- remove the last comma
		self:SendMessage(CMD_KNOWN.." "..DATA_VERSION.." "..trans_str.." "..enc(StringHash(trans_str)), distribution)
		self:DebugMessage("tell our transports ; length: "..strlen(trans_str))
	else
		self:DebugMessage("nothing to tell")
	end
end

--[===[@debug@
function NauticusClassic:RequestAllTransports()
	local trans_str = ""
	for transit in ipairs(self.transports) do
		trans_str = trans_str..crunch(transit)..","
		requestList[transit] = nil
	end
	trans_str = strsub(trans_str, 1, -2) -- remove the last comma
	self:SendMessage(CMD_KNOWN.." "..crunch(DATA_VERSION).." "..trans_str.." "..crunch(StringHash(trans_str)))
end
--@end-debug@]===]

function NauticusClassic:RequestTransport(t, distribution)
	requestLists[distribution][t] = true
end

function NauticusClassic:SendMessage(msg, distribution)
	if not self.comm_disable then
		self:DebugMessage("sending msg dist: "..distribution.." ; length: "..strlen(msg))
		if distribution == "ALL" then
			if IsInRaid() then
				self:SendCommMessage(self.DEFAULT_PREFIX, msg, "RAID")
			elseif IsInGroup() then
				self:SendCommMessage(self.DEFAULT_PREFIX, msg, "PARTY")
			end
			if IsInGuild() then
				self:SendCommMessage(self.DEFAULT_PREFIX, msg, "GUILD")
			end
			self:SendCommMessage(self.DEFAULT_PREFIX, msg, "YELL")
		elseif distribution == "WIDE" then
			self:EnqueueWideMessage(msg)
		else
			self:SendCommMessage(self.DEFAULT_PREFIX, msg, distribution)
		end
	end
end

-- extract key/value from message
local function GetArgs(message, separator)
	local args = { strsplit(separator, message) }
	for t = 1, #(args), 1 do
		if args[t] == "" then
			args[t] = nil
		end
	end
	return args
end

-- shared dispatch for a decoded protocol message, regardless of transport
-- (AceComm addon message vs. literal WIDE chat text)
local function ProcessMessage(msg, distribution, sender)
	if 254 <= strlen(msg) then return; end -- message too big, probably corrupted

	local args = GetArgs(msg, " ")

	if args[1] == CMD_VERSION then -- version, num
		NauticusClassic:ReceiveMessage_version(tonumber(args[2]), distribution, sender)
	elseif args[1] == CMD_KNOWN then -- known, { transports }
		NauticusClassic:ReceiveMessage_known(tonumber(args[2]), args[3], args[4], distribution, sender)
	end
end

function NauticusClassic:OnCommReceived(prefix, msg, distribution, sender)
	if sender ~= UnitName("player") and strlower(prefix) == strlower(self.DEFAULT_PREFIX) and
		(distribution == "PARTY" or distribution == "RAID" or distribution == "GUILD" or distribution == "YELL") then
		if distribution == "PARTY" then
			distribution = "RAID"
		end
		self:DebugMessage("received sender: "..sender.." ; dist: "..distribution.." ; length: "..strlen(msg))
		ProcessMessage(msg, distribution, sender)
	end
end

---------------------------------------------------------------------------
-- WIDE distribution: realm-wide reach over a hidden custom chat channel.
--
-- SendAddonMessage over "CHANNEL" distribution is rejected by the Classic
-- client (confirmed: returns didSend=false for both custom and built-in
-- channels). So instead of an addon message, WIDE messages are sent as
-- literal chat text (SendChatMessage) on a hidden custom channel, tagged
-- with WIDE_TAG to identify them and suppressed from the chat UI.
--
-- Classic also requires a real hardware event (mouse click / key press) to
-- send a chat message — sends are queued and only flushed from those event
-- handlers, never sent immediately from a timer or slash command.
---------------------------------------------------------------------------

-- no password: a prior test build joined "NauticusSync118" with no password, and a
-- channel's password is fixed at creation, so later joins supplying one against that
-- already-existing unpassworded channel could silently misbehave. Renamed to a fresh
-- name to avoid inheriting that contaminated state.
local WIDE_CHANNEL_BASE = "NauticusSync119" -- do not change; must match across all clients to interoperate
local WIDE_CHANNEL_PW = nil
local WIDE_TAG = "NST1 " -- identifies our messages on the shared channel; also versions the wire format

local wideChannelName = WIDE_CHANNEL_BASE
local wideChannelId
local wideQueue = {} -- FIFO of { text, enqueueTime }
local WIDE_QUEUE_MAX_AGE = 30 -- seconds; drop stale queued sends rather than trickle out outdated data

local widePlayerThrottle = {}
local wideShadowbanned = {}
local WIDE_SHADOWBAN_THRESHOLD = 200 -- messages from one sender before we stop listening to them
local WIDE_THROTTLE_RESET_INTERVAL = 600 -- seconds

local function wideThrottleCheck(sender)
	if wideShadowbanned[sender] then return true; end
	widePlayerThrottle[sender] = (widePlayerThrottle[sender] or 0) + 1
	if widePlayerThrottle[sender] > WIDE_SHADOWBAN_THRESHOLD then
		wideShadowbanned[sender] = true
	end
	return false
end

C_Timer.NewTicker(WIDE_THROTTLE_RESET_INTERVAL, function()
	wipe(widePlayerThrottle)
end)

local function hideWideChannelFromChatFrames()
	for i = 1, 10 do
		if _G["ChatFrame"..i] then
			ChatFrame_RemoveChannel(_G["ChatFrame"..i], wideChannelName)
		end
	end
end

-- suppress our channel's traffic from the chat UI entirely (join/leave/notice/text);
-- also avoids Blizzard's HistoryKeeper building up permanent per-sender entries
-- on a channel with many unique senders
local function wideChatFilter(self, event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, ...)
	if arg9 and strupper(arg9) == strupper(wideChannelName) then
		return true
	end
	return false
end

do
	local addFilter = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
	addFilter("CHAT_MSG_CHANNEL", wideChatFilter)
	addFilter("CHAT_MSG_CHANNEL_NOTICE", wideChatFilter)
	addFilter("CHAT_MSG_CHANNEL_NOTICE_USER", wideChatFilter)
	addFilter("CHAT_MSG_CHANNEL_JOIN", wideChatFilter)
	addFilter("CHAT_MSG_CHANNEL_LEAVE", wideChatFilter)
end

local wideJoinPending = false

-- the client auto-rejoins previously-joined custom channels on login on its own,
-- independent of any addon code, and does so before OnEnable ever runs — so by the
-- time our delayed JoinWideChannel() timer fires, we may already be sitting in a
-- low slot (e.g. 1) that we grabbed before Blizzard's default channels (General/
-- Trade/etc.) loaded. Call this once, immediately, at the start of OnEnable to drop
-- that early auto-rejoin and free the slot, so the later delayed join actually lands
-- in a late slot instead of just adopting whatever number we already had.
function NauticusClassic:LeaveWideChannel()
	LeaveChannelByName(wideChannelName)
end

-- drainWideQueue calls JoinWideChannel() on every hardware event while unjoined
-- (mouse clicks can fire many times a second); wideJoinPending avoids spamming
-- JoinChannelByName while a join attempt is already in flight
function NauticusClassic:JoinWideChannel()
	local id = GetChannelName(wideChannelName)
	if id and id > 0 then
		wideChannelId = id
		hideWideChannelFromChatFrames()
		return
	end

	if wideJoinPending then return end
	wideJoinPending = true

	JoinChannelByName(wideChannelName, WIDE_CHANNEL_PW, nil, false)

	local remainingAttempts = 5
	C_Timer.NewTicker(4, function(ticker)
		local channelNum = GetChannelName(wideChannelName)
		if channelNum and channelNum > 0 then
			wideChannelId = channelNum
			hideWideChannelFromChatFrames()
			wideJoinPending = false
			ticker:Cancel()
			return
		end

		remainingAttempts = remainingAttempts - 1
		if remainingAttempts < 1 then
			ticker:Cancel()
			-- fall back to a differently-named channel in case the base name is unavailable
			wideChannelName = wideChannelName.."b"
			self:DebugMessage("wide channel join failed; trying "..wideChannelName)
			JoinChannelByName(wideChannelName, WIDE_CHANNEL_PW, nil, false)
			-- give the fallback name its own attempt window before allowing a re-trigger
			C_Timer.After(4, function() wideJoinPending = false end)
		end
	end)
end

function NauticusClassic:EnqueueWideMessage(msg)
	table.insert(wideQueue, { WIDE_TAG..msg, GetServerTime() })
end

local function trimStaleWideMessages()
	local now = GetServerTime()
	while #wideQueue > 0 and (now - wideQueue[1][2]) >= WIDE_QUEUE_MAX_AGE do
		table.remove(wideQueue, 1)
	end
end

local function drainWideQueue()
	trimStaleWideMessages()
	if #wideQueue == 0 then return; end

	-- re-resolve the channel id on every attempt rather than trusting the cached
	-- value: channel ids are just slot numbers in the player's channel list, and
	-- they get renumbered whenever that list changes (joining/leaving a channel,
	-- or the user reordering channels). Sending on a stale id silently dumps our
	-- encoded payload into whatever real channel now occupies that slot.
	local currentId = GetChannelName(wideChannelName)
	if not currentId or currentId == 0 then
		wideChannelId = nil
		NauticusClassic:JoinWideChannel()
		return
	end
	wideChannelId = currentId

	local CTL = _G.ChatThrottleLib
	local text = wideQueue[1][1]
	if CTL then
		local cost = strlen(text) + (CTL.MSG_OVERHEAD or 40)
		if CTL.bQueueing or cost >= CTL:UpdateAvail() then
			return -- try again on the next hardware event
		end
	end

	local ok = pcall(C_ChatInfo.SendChatMessage, text, "CHANNEL", nil, wideChannelId)
	if ok then
		table.remove(wideQueue, 1)
	end
end

-- Classic requires a genuine hardware event (mouse click / key press) to send
-- a chat message; a slash command or timer callback does not qualify and the
-- send is silently rejected. Piggyback outbound sends on the player's own
-- ambient input instead of sending immediately.
WorldFrame:HookScript("OnMouseDown", drainWideQueue)

local wideInputFrame = CreateFrame("Frame", nil, UIParent)
wideInputFrame:SetScript("OnKeyDown", drainWideQueue)
wideInputFrame:SetPropagateKeyboardInput(true)

local wideChannelWatcher = CreateFrame("Frame")
wideChannelWatcher:RegisterEvent("CHAT_MSG_CHANNEL")
wideChannelWatcher:SetScript("OnEvent", function(_, _, text, sender)
	if strsub(text, 1, strlen(WIDE_TAG)) ~= WIDE_TAG then return end -- not ours / different protocol version

	local senderName = strsplit("-", sender) -- strip realm suffix
	if senderName == UnitName("player") then return end
	if wideThrottleCheck(senderName) then return end

	local msg = strsub(text, strlen(WIDE_TAG) + 1)
	NauticusClassic:DebugMessage("wide received sender: "..senderName.." ; length: "..strlen(msg))
	ProcessMessage(msg, "WIDE", senderName)
end)

SLASH_NAUTWIDE1 = "/nautwide"
SlashCmdList["NAUTWIDE"] = function()
	print(format("|cff33ff99[NauticusWide]|r channel=%s ; id=%s ; queued=%d ; oldest_age=%s",
		wideChannelName, tostring(wideChannelId), #wideQueue,
		#wideQueue > 0 and tostring(GetServerTime() - wideQueue[1][2]).."s" or "n/a"))
end

function NauticusClassic:ReceiveMessage_version(clientversion, distribution, sender)
	self:DebugMessage(sender.." says: version "..clientversion)

	if clientversion <= 0 or clientversion > self.MAX_VERSION_NUM then
		-- clientversion packs "MAJOR.MINOR.PATCH" assuming each segment is a single digit
		-- (see NautCore.lua); a build with a segment >= 10 produces a bogus huge number that
		-- would otherwise look like a permanent "major update" to everyone who hears it
		self:DebugMessage(sender.." broadcast an implausible version ("..clientversion.."); ignoring")
		return
	end

	if clientversion > self.versionNum then
		if not self.db.global.newerVersion then
			self.db.global.newerVersion = clientversion
			self.db.global.newerVerAge = time()
		elseif clientversion > self.db.global.newerVersion then
			self.db.global.newerVersion = clientversion
		end
	elseif clientversion < self.versionNum then
		requestVersions[distribution] = true
		self:DoRequest(5 + math.random() * 15, distribution)
		return
	end

	requestVersions[distribution] = false

	-- if we don't need to send back any data, cancel our scheduler immediately
	if not next(requestLists[distribution]) then
		self:DebugMessage("received: version; no more to send")
		self:CancelRequest(distribution)
	end
end

function NauticusClassic:ReceiveMessage_known(version, transports, hash, distribution, sender)
	if version ~= DATA_VERSION then return; end

	local lag = GetLag()
	local set, respond, since, boots, swaps
	local safe = (distribution == "WIDE")
	local dec = safe and uncrunchSafe or uncrunch

	--[===[@debug@
	if hash and self.debug then
		local rehash = StringHash(transports)
		hash = dec(hash)
		if hash ~= rehash then
			self:DebugMessage("wrong hash: "..hash.." (supplied) vs "..rehash.." (computed)")
		end
	end
	--@end-debug@]===]

	for transit, values in pairs(self:StringToKnown(transports, safe)) do
		since, boots, swaps = values.since, values.boots, values.swaps

		if since ~= nil then
			since = since/1000.0 + lag
			boots = tonumber(boots)
			swaps = swaps + 1 --imagine data is being transmitted (+1)
		end

		set, respond = self:IsBetter(transit, since, boots, swaps)

		--[===[@debug@
		if self.debug then
			local ourSince, ourBoots, ourSwaps = self:GetKnownCycle(transit)
			local debugColour
			if set == nil then
				debugColour = RED
			elseif set then
				debugColour = GREEN
			elseif respond then
				debugColour = YELLOW
			else
				debugColour = GREY
			end
			local output = sender.." knows "..transit.." "..debugColour..
				(since and since.."|r (b:"..boots..",s:"..swaps..")" or "nil|r").." vs our "..
				(ourSince and format("%0.3f", ourSince).." (b:"..ourBoots..",s:"..ourSwaps..")" or "nil")
			if ourSince and since then
				output = output.." ; diff: "..format("%0.3f", ourSince-since)..
					" ; cycles: "..format("%0.6f", (ourSince-since) / self.rtts[transit])
			end
			self:DebugMessage(output)
		end
		--@end-debug@]===]

		if set ~= nil then -- true or false...
			if set then
				self:SetKnownCycle(transit, since, boots, swaps)
			end
			requestLists[distribution][transit] = respond
		end
	end

	-- if we don't need to send back any data, cancel our scheduler immediately
	if next(requestLists[distribution]) then
		self:DoRequest(5 + math.random() * 15, distribution)
	elseif not requestVersions[distribution] then
		self:DebugMessage("received: known; no more to send")
		self:CancelRequest(distribution)
	end
end

-- returns a, b
-- where a is if we should set our data to theirs (true or false) and b is how we should respond with ours (true or nil)
function NauticusClassic:IsBetter(transit, since, boots, swaps)
	local ourSince, ourBoots, ourSwaps = self:GetKnownCycle(transit)

	if since == nil then
		if ourSince == nil then
			return false -- no set, no response
		else
			return false, true -- no set, respond
		end
	else
		if ourSince == nil then
			return true -- set, no response
		elseif 0 <= since then
			if boots < ourBoots then
				return true -- set, no response
			elseif boots > ourBoots then
				return false, true -- no set, respond
			else
				-- swap difference; positive = better, less than -2 = worse, 0, -1, -2 = depends!
				local swapDiff = ourSwaps - swaps

				if 0 < swapDiff then -- (swaps < ourSwaps)
					return true -- set, no response
				elseif -2 > swapDiff then -- (swaps > ourSwaps+2); imagine data is being transmitted
					return false, true -- no set, respond
				else
					-- age difference; positive = better, negative = worse
					local ageDiff = math.floor((ourSince - since) / self.rtts[transit] + .5)
					local SET, RESPOND = true, true

					--  0 = maybe better for us but response pointless
					-- -1 = ignore/pointless
					-- -2 = worse for us but respond if better time
					if  0 ~= swapDiff then SET = false; end
					if -2 ~= swapDiff then RESPOND = nil; end

					if 0 < ageDiff then -- (age < ourAge)
						return SET -- set, no response
					elseif 0 > ageDiff then -- (age > ourAge)
						return false, RESPOND -- no set, respond
					else
						return false -- no set, no response
					end
				end
			end
		end
	end
end

function NauticusClassic:StringToKnown(transports, safe)
	local dec = safe and uncrunchSafe or uncrunch
	local args_tmp, transit, since, swaps, boots
	local args = GetArgs(transports, ",")
	local trans_tab = {}

	for t = 1, #(args), 1 do
		args_tmp = GetArgs(args[t], ":")
		transit = dec(args_tmp[1])

		if transit and self.transports[transit] then
			since = args_tmp[2]
			if since then
				since, swaps, boots = dec(since), args_tmp[3], args_tmp[4]
				if since then
					trans_tab[transit] = {
						['since'] = since,
						['boots'] = boots and dec(boots) or 0,
						['swaps'] = swaps and dec(swaps) or 1,
					}
				end
			else
				trans_tab[transit] = {}
			end
		elseif transit then
			self:DebugMessage("unknown transit: "..transit)
		end
	end

	return trans_tab
end

local updateChannel

function NauticusClassic:UpdateChannel(wait)
	if updateChannel then self:CancelTimer(updateChannel, true); updateChannel = nil; end

	if wait then
		updateChannel = self:ScheduleTimer("UpdateChannel", wait)
		return
	end

	--[===[@debug@
	if self.debug then
		self:ScheduleTimer("RequestAllTransports", 5)
		return
	end
	--@end-debug@]===]

	for id in pairs(self.transports) do
		requestLists["ALL"][id] = true
		requestLists["WIDE"][id] = true
	end

	requestVersions["ALL"] = true
	self:DoRequest(5 + math.random() * 15, "ALL")

	requestVersions["WIDE"] = true
	self:DoRequest(5 + math.random() * 15, "WIDE")
end
