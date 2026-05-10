-- BusStopSettings.lua
-- Per-player sound volume via PZAPI.ModOptions (appears in Options → Mods tab).

BusStopSettings = BusStopSettings or {}

local modOptions   = PZAPI.ModOptions:create("BusStopFastTravel", "Bus Stop Fast Travel")
local volumeOption = modOptions:addSlider(
    "BusStop_SoundVolume",
    getText("IGUI_BusStop_sound_label"),
    0,    -- min
    100,  -- max
    1,    -- step
    50    -- default (50%)
)

function BusStopSettings.getVolume()
    return volumeOption:getValue() / 100
end
