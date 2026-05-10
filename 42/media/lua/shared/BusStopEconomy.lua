-- BusStopEconomy.lua
-- Generic economy protocol for BusStop Fast Travel.
--
-- Protocol: any bank mod that wants to integrate exposes a global API table:
--
--   MyBankMod = MyBankMod or {}
--   MyBankMod.API = {
--       canAfford   = function(player, amount) -> bool, errKey, errArgs end,
--       deduct      = function(player, amount) end,
--       formatLabel = function(amount) -> string end,
--   }
--
-- Sandbox options:
--   BusStop.UseItemPayment = true/false  (default true)
--   BusStop.UseBankPayment = true/false  (default false)
--   BusStop.BankModGlobal  = "MyBankMod" (exact Lua global name)
--
-- When both are enabled, inventory items are deducted first; the bank covers
-- any remaining amount that items could not cover.

BusStopEconomy = BusStopEconomy or {}

-- Resolves and validates the bank mod API. Returns nil with a log on any failure.
function BusStopEconomy.getAPI()
    local sv = SandboxVars.BusStop or {}
    if not sv.UseBankPayment then return nil end
    local gname = sv.BankModGlobal or ""
    if gname == "" then
        print("[BusStop][ECON] getAPI: BankModGlobal not set")
        return nil
    end
    local mod = _G[gname]
    if not mod then
        print("[BusStop][ECON] getAPI: global '" .. gname .. "' not found — bank mod not loaded?")
        return nil
    end
    local api = mod.API
    if not api then
        print("[BusStop][ECON] getAPI: '" .. gname .. "'.API is nil")
        return nil
    end
    if not (api.canAfford and api.deduct and api.formatLabel) then
        print("[BusStop][ECON] getAPI: '" .. gname .. "'.API missing canAfford / deduct / formatLabel")
        return nil
    end
    print("[BusStop][ECON] getAPI: '" .. gname .. "'.API OK")
    return api
end

-- Returns a currency label for the given price.
-- Called from BusStopShared.priceLabel() on both client and server.
function BusStopEconomy.formatLabel(price)
    if price <= 0 then
        return getText("IGUI_BusStop_ui_free_label")
    end
    local sv      = SandboxVars.BusStop or {}
    local useItem = sv.UseItemPayment ~= false   -- default true
    local useBank = sv.UseBankPayment == true

    -- Bank-only: delegate to the bank mod's formatter.
    if useBank and not useItem then
        local api = BusStopEconomy.getAPI()
        if api then return api.formatLabel(price) end
        return "$" .. tostring(price) .. " (" .. (sv.BankModGlobal or "bank") .. ")"
    end

    -- Item (possibly with bank as overflow): show item label.
    local itemType = sv.CurrencyItem or "Base.Money"
    local name     = itemType:match("%.(.+)$") or itemType
    return tostring(price) .. "x " .. name
end
