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

-- ── World map ─────────────────────────────────────────────────────────────────

local origWorldMapRender = ISWorldMap.render

function ISWorldMap:render()
    origWorldMapRender(self)
    local tex = getTex()
    if not tex or not self.mapAPI then return end

    local half = ICON_SIZE_WORLD / 2
    for _, stop in ipairs(BusStop.activeStops) do
        local sx = self.mapAPI:worldToUIX(stop.x, stop.y)
        local sy = self.mapAPI:worldToUIY(stop.x, stop.y)
        local alpha = stop.available and 1.0 or 0.4
        local r, g, b = stop.available and 1.0 or 0.6,
                        stop.available and 0.85 or 0.6,
                        stop.available and 0.2 or 0.6
        self:drawTextureScaledAspect(tex, sx - half, sy - half, ICON_SIZE_WORLD, ICON_SIZE_WORLD, alpha, r, g, b)
    end
end

-- ── Minimap ───────────────────────────────────────────────────────────────────

local origMiniMapPrerender = ISMiniMapInner.prerender

function ISMiniMapInner:prerender()
    origMiniMapPrerender(self)
    local tex = getTex()
    if not tex or not self.mapAPI then return end

    local half = ICON_SIZE_MINI / 2
    for _, stop in ipairs(BusStop.activeStops) do
        local sx = self.mapAPI:worldToUIX(stop.x, stop.y)
        local sy = self.mapAPI:worldToUIY(stop.x, stop.y)
        if sx >= 0 and sx <= self.width and sy >= 0 and sy <= self.height then
            local alpha = stop.available and 1.0 or 0.4
            local r, g, b = stop.available and 1.0 or 0.6,
                            stop.available and 0.85 or 0.6,
                            stop.available and 0.2 or 0.6
            self:drawTextureScaledAspect(tex, sx - half, sy - half, ICON_SIZE_MINI, ICON_SIZE_MINI, alpha, r, g, b)
        end
    end
end
