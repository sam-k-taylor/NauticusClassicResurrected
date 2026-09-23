
local L = LibStub("AceLocale-3.0"):NewLocale("NauticusClassic", "enUS", true)
if not L then return; end

-- addon description
L["Tracks the precise arrival & departure schedules of boats and Zeppelins around Azeroth and displays them on the Mini-Map and World Map in real-time."] = true

-- slash commands (no spaces!)
L["icons"] = true
L["minishow"] = true
L["worldshow"] = true
L["minisize"] = true
L["minisizeforever"] = true
L["worldsize"] = true
L["framerate"] = true
L["faction"] = true
L["minibutton"] = true
L["autoselect"] = true
L["alarm"] = true
L["arrivalding"] = true
L["channel"] = true

-- options
L["Options"] = true
L["General Settings"] = true
L["Map Icons"] = true
L["Options for displaying transports as icons on the Mini-Map and World Map."] = true
L["Show on Mini-Map"] = true
L["Toggle display of icons on the Mini-Map."] = true
L["Show on World Map"] = true
L["Toggle display of icons on the World Map."] = true
L["Mini-Map icon size"] = true
L["Change the size of the Mini-Map icons."] = true
L["Change the size of the Mini-Map icons. Small is the default/current size, Large is double that, Medium is halfway between."] = true -- Forever-only preset version of the above, see iconminisizeforever in NautCore.lua
L["Small"] = true
L["Medium"] = true
L["Large"] = true
L["World Map icon size"] = true
L["Change the size of the World Map icons."] = true
L["Icon framerate"] = true
L["Change the framerate of the World Map/Mini-Map icons (lower this value if you are seeing performance issues with the map open)."] = true
L["Faction only"] = true
L["Hide transports of opposite faction from the map, showing only neutral and those of your faction."] = true
L["Auto select transport"] = true
L["Automatically select nearest transport when standing at platform."] = true
L["Alarm delay"] = true
L["Change the alarm delay (in seconds)."] = true
L["Arrival sound"] = true
L["Play a sound when a tracked transport arrives at a platform you're standing near."] = true
L["Mini-Map button"] = true
L["Toggle the Mini-Map button."] = true
L["Broadcast channel"] = true
L["Channel to broadcast your currently tracked transport (will broadcast to \"%s\" if the selected channel is unavailable)."] = true -- %s=channel

-- miscellaneous
L["Arrival"] = true
L["Departure"] = true
L["Select Transport"] = true
L["Select None"] = true
L["No Transport Selected"] = true
L["Not Available"] = true
L["N/A"] = true -- abbreviation for Not Available
L["NauticusClassic Options"] = true
L["Alarm is now: "] = true
L["ON"] = true
L["OFF"] = true

L["List friendly faction only"] = true
L["Shows only neutral transports and those of your faction."] = true
L["List relevant to current zone only"] = true
L["Shows only transports relevant to your current zone."] = true
L["Hint: Click to cycle transport."] = true
L["Alt-Click to set up alarm."] = true
L["Ctrl-Click to broadcast in %s."] = true -- %s=channel
L["New version available! Visit curseforge.com/wow/addons/nauticusclassicresurrected"] = true

-- ship names
L["The Thundercaller"] = true
L["The Iron Eagle"] = true
L["The Purple Princess"] = true
L["The Maiden's Fancy"] = true
L["The Bravery"] = true
L["The Lady Mehley"] = true
L["The Moonspray"] = true
L["Feathermoon Ferry"] = true
L["Deeprun Tram North"] = true
L["Deeprun Tram South"] = true
L["Unnamed Vessel"] = true -- placeholder until the real name of the Stormwind Harbor<->Auberdine boat (and [13], the Alliance Zephras Isle<->Dalaran City boat) is known
L["The Skycutter"] = true -- TODO: placeholder -- "Skycutter" is the vessel TYPE per the dockmaster's announcement, not a confirmed proper name; see data.lua's [12] vessel_name comment

-- zones
L["Orgrimmar"] = true
L["Undercity"] = true
L["Durotar"] = true
L["Tirisfal Glades"] = true
L["Stranglethorn Vale"] = true
L["The Barrens"] = true
L["Wetlands"] = true
L["Darkshore"] = true
L["Dustwallow Marsh"] = true
L["Teldrassil"] = true
L["Feralas"] = true
L["Stormwind City"] = true
L["Ironforge"] = true
L["Deeprun Tram"] = true
L["Hillsbrad Foothills"] = true -- Forever-only 3rd stop on [5]'s route, see data.lua's transportOverrides_forever
L["Zephras Isle"] = true -- Forever-only new starting zone (Horde route [12], also the Alliance side of [13])
L["Mulgore"] = true
L["Dalaran City"] = true -- [13]'s Alliance route destination, confirmed via screenshot -- a relocated/renamed Dalaran in Alterac Mountains on Forever, not the classic Alterac Valley zone or retail's Dalaran
L["Alterac Mountains"] = true
L["Riverglades"] = true -- Forever-only new zone, [14]'s route -- not yet confirmed whether it has Azeroth-composite-map placement or needs :rawp treatment like Zephras Isle
L["Tanaris"] = true -- real classic Kalimdor zone, [14]'s route destination

-- subzones
L["Grom'gol"] = true
L["Booty Bay"] = true
L["Ratchet"] = true
L["Menethil Harbor"] = true
L["Stormwind Harbor"] = true
L["Auberdine"] = true
L["Theramore"] = true
L["Rut'Theran Village"] = true
L["Sardor Isle"] = true
L["Feathermoon"] = true
L["Forgotten Coast"] = true
L["Southshore"] = true -- Forever-only 3rd stop on [5]'s route (Hillsbrad Foothills)
L["Windshapers Dock"] = true -- TODO: dock name partially cut off in the confirming screenshot ("Windshapers Dock..."), confirm full name in-game
L["Skywatch Plateau"] = true -- TODO: best-guess spelling of the Mulgore-side dock, not yet confirmed in-game
L["High Order Dock"] = true -- TODO: guessed from the "High Order Dockmaster" NPC name (screenshot 2026-09-21) -- [13]'s Zephras Isle (Alliance) dock, no confirmed proper name yet
L["Powderfuse Port"] = true -- [14]'s Riverglades-side dock
L["Steamwheedle Port"] = true -- [14]'s Tanaris-side dock

-- abbreviations
L["Org"] = true -- Orgrimmar
L["UC"]  = true -- Undercity
L["GG"]  = true -- Grom'gol
L["BB"]  = true -- Booty Bay
L["Rat"] = true -- Ratchet
L["MH"]  = true -- Menethil Harbor
L["Aub"] = true -- Auberdine
L["Th"]  = true -- Theramore
L["RTV"] = true -- Rut'Theran Village
L["FMS"] = true -- Feathermoon
L["Fer"] = true -- Feralas
L["SW"] = true -- Stormwind City
L["IF"] = true -- Ironforge
L["SS"] = true -- Southshore
L["ZI"] = true -- Zephras Isle
L["Mul"] = true -- Mulgore
L["Dal"] = true -- Dalaran City
L["Riv"] = true -- Riverglades
L["Tan"] = true -- Tanaris

-- channels
L["Say"] = true
L["Yell"] = true
L["Party"] = true
L["Raid"] = true
L["Guild"] = true
