-- BusStopMapMarker.lua
-- Renders bus stop markers on the world map and minimap (B42 mapAPI).

require "BusStopShared"

local ICON_SIZE_WORLD = 16
local ICON_SIZE_MINI  = 8

local markerTex = nil
local function getTex()
    if not markerTex then
        markerTex = getTexture("media/textures/bus_stop_sign_icon.png")
    end
    return markerTex
end

-- Returns alpha, r, g, b for `stop`'s marker (always drawn — nothing is
-- hidden from the map).
-- Gold  = normal, usable stop. Also the default look for a disabled stop —
--         same full color as active, unless ShowDisabledStopsAsTransparent
--         is on, which restores the old faded/muted look.
-- Red   = arrival-only — still a valid destination, just can't be used to
--         depart from. Only checked for stops that are still available;
--         a disabled stop is never shown red.
local function markerColor(stop)
    if not stop.available then
        local sv = SandboxVars.BusStop or {}
        if sv.ShowDisabledStopsAsTransparent == true then
            return 0.4, 0.6, 0.6, 0.6
        end
        return 1.0, 1.0, 0.85, 0.2
    end
    if stop.arrivalonly == true then
        return 1.0, 0.9, 0.15, 0.15
    end
    return 1.0, 1.0, 0.85, 0.2
end

-- ── World map ─────────────────────────────────────────────────────────────────

local origWorldMapRender = ISWorldMap.render

function ISWorldMap:render()
    origWorldMapRender(self)
    local tex = getTex()
    if not tex or not self.mapAPI then return end

    local half = ICON_SIZE_WORLD / 2
    for _, stop in ipairs(BusStop.activeStops) do
        local alpha, r, g, b = markerColor(stop)
        if alpha then
            local sx = self.mapAPI:worldToUIX(stop.x, stop.y)
            local sy = self.mapAPI:worldToUIY(stop.x, stop.y)
            self:drawTextureScaledAspect(tex, sx - half, sy - half, ICON_SIZE_WORLD, ICON_SIZE_WORLD, alpha, r, g, b)
        end
    end
end

-- ── Minimap ───────────────────────────────────────────────────────────────────

-- Use render (not prerender) so icons draw on top of the Java-rendered map.
local origMiniMapRender = ISMiniMapInner.render

function ISMiniMapInner:render()
    if origMiniMapRender then origMiniMapRender(self) end
    local tex = getTex()
    if not tex or not self.mapAPI then return end

    local half = ICON_SIZE_MINI / 2
    for _, stop in ipairs(BusStop.activeStops) do
        local alpha, r, g, b = markerColor(stop)
        if alpha then
            local sx = self.mapAPI:worldToUIX(stop.x, stop.y)
            local sy = self.mapAPI:worldToUIY(stop.x, stop.y)
            if sx >= 0 and sx <= self.width and sy >= 0 and sy <= self.height then
                self:drawTextureScaledAspect(tex, sx - half, sy - half, ICON_SIZE_MINI, ICON_SIZE_MINI, alpha, r, g, b)
            end
        end
    end
end
