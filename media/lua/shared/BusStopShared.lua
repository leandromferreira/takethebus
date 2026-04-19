-- BusStopShared.lua
-- Utilities available to both client and server contexts.

BusStop = BusStop or {}

BusStop.MAX_USE_DISTANCE    = 3    -- tiles
BusStop.MAX_ZOMBIE_DISTANCE = 10   -- tiles

-- Client-side cache populated by StopList server command.
BusStop.activeStops    = {}
-- Return-trip memory (client-only, never transmitted).
BusStop.returnStop = nil   -- full stop table of the origin stop

-- ── Translation (native PZ getText) ──────────────────────────────────────────

-- Thin wrapper: keeps all call-sites using BusStop.getText("key", ...)
-- while delegating to PZ's native getText("IGUI_BusStop_key", ...).
function BusStop.getText(key, ...)
    return getText("IGUI_BusStop_" .. key, ...)
end

-- ── Price calculation ─────────────────────────────────────────────────────────

function BusStop.calcPrice(fromX, fromY, dest)
    if dest.pricetype == "free" then return 0 end

    local sv        = SandboxVars.BusStop or {}
    local basePrice = sv.BasePrice    or 1
    local perTile   = (sv.PricePerTile or 1) / 1000.0
    local mult      = tonumber(dest.price_multiplier) or 1.0

    if dest.pricetype == "fixed" then
        return math.ceil(basePrice * mult)
    end

    local dx   = (dest.x or 0) - fromX
    local dy   = (dest.y or 0) - fromY
    local dist = math.sqrt(dx * dx + dy * dy)
    return math.ceil((basePrice + dist * perTile) * mult)
end

function BusStop.priceLabel(fromX, fromY, dest)
    if dest.pricetype == "free" then return BusStop.getText("ui_free_label") end
    local price    = BusStop.calcPrice(fromX, fromY, dest)
    local sv       = SandboxVars.BusStop or {}
    local itemType = sv.CurrencyItem or "Base.Money"
    local name     = itemType:match("%.(.+)$") or itemType
    return price .. "x " .. name
end

-- ── Admin check ───────────────────────────────────────────────────────────────

function BusStop.isAdmin(player)
    if not isClient() then return true end
    local level = string.lower(player:getAccessLevel() or "")
    return level == "admin" or level == "moderator"
end
