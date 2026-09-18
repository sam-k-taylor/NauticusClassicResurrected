# NauticusClassicResurrected

Tracks the precise arrival & departure schedules of boats and Zeppelins around Azeroth and displays them on the Mini-Map and World Map in real-time.

Look up arrival & departure schedules for any transport and know exactly when you need to be there. Less time waiting on platforms, more time at the AH or mailbox, less duelling rogues or shamies who want you to take a seat while they crit you... 'for fun'...

## 🆕 WoW: Forever support

NauticusClassicResurrected now runs on **WoW: Forever** as well as **WoW Classic Era** — same addon, same install, both clients supported from one download.

**Known issue:** on Forever, every transport tracks correctly *except* the Menethil Harbor ↔ Auberdine boat (Wetlands ↔ Darkshore, "The Bravery") — Forever added a new stop at Southshore partway along that route which the addon doesn't yet account for, so schedules for that one boat won't show. A fix is coming, alongside support for the new transports Forever has added that Era never had. Everything else — all other boats, both zeppelins, and the Deeprun Tram — works on Forever today.

## Main Features

* Plots all Horde, Alliance and neutral transports on the World Map in real time
  * Displays the most relevant transports on the Mini-Map, based on your current zone
  * Map icons rotate to show their actual direction at any point in time
  * Shows arrival or departure schedule for each platform when you mouse over any map icon
* Shows Deeprun Tram Mini-Map icons with arrival/departure times when inside the instance
* Discovers each schedule by travelling the route in either direction
  * Calculates future schedules based on precisely measured round-trip cycles
* Automatically shares schedules with other users of the addon on your realm
  * Differential delayed updates keep communication bandwidth low even with many users
  * Ranks quality of data based on number of reboots and swaps, always picking the best
* Remembers schedule data even after a computer reboot
* Select any transport for viewing in any LibDataBroker (LDB) display addon
  * Shows the next arrival or departure event in the button text
  * Button icon changes colour to indicate status (yellow = docked, red = about to depart, green = in transit)
  * Auto-selects the nearest transport when standing at a platform (optional)
  * Alt-click the button to manually set an audio alarm to warn you before the next departure

**Important:** this addon works best the more players on your realm are also running it — schedules sync automatically between everyone using Nauticus, so get your friends and guild mates to install it too. It runs quietly in the background, and you can disable the map icons entirely for zero visual footprint if you just want to feed/receive schedule data.

## Compatibility

* ✅ WoW Classic Era
* ✅ WoW: Forever *(new — see known issue above)*
