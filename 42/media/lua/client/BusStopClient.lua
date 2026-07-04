-- BusStopClient.lua
-- Server responses, context menus and admin name-dialog.

require "BusStopShared"

local MODULE = "BusStop"

-- ── Server command handler ────────────────────────────────────────────────────

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    -- Guard: Kahlua may deliver args as Java null when all values were nil.
    args = args or {}

    if command == "StopList" then
        BusStop.activeStops = args.stops or {}
        if BusStopAdminUI and BusStopAdminUI._current then
            -- admin panel is open; it will refresh on next render
        end

    elseif command == "ReturnTripSync" then
        -- Server is authoritative: resolve stopId to a live stop object.
        -- args.cleared=true means the server explicitly cleared the trip.
        local rt = args.returnTrip
        if rt and type(rt) == "table" and rt.stopId then
            local found = nil
            for _, s in ipairs(BusStop.activeStops) do
                if s.id == rt.stopId then found = s; break end
            end
            BusStop.returnStop   = found
            BusStop.returnExpiry = rt.expiryHours
            -- If not found: stop may not have arrived yet; server will re-send on next RequestStopList.
            if not found then BusStop.returnStop = nil end
        else
            BusStop.returnStop   = nil
            BusStop.returnExpiry = nil
        end

    elseif command == "TeleportTo" then
        local ok, err = pcall(function()
            require "BusStopTransition"
            BusStopTransition.play(args.x, args.y, args.z)
        end)
        if not ok then
            print("[BusStop] ERROR TeleportTo: " .. tostring(err))
            local p = getPlayer()
            if p then
                p:setX(args.x + 0.5); p:setLastX(args.x + 0.5)
                p:setY(args.y + 0.5); p:setLastY(args.y + 0.5)
                p:setZ(args.z);       p:setLastZ(args.z)
            end
        end

    elseif command == "TravelResult" or command == "CreateResult"
        or command == "RemoveResult" or command == "UpdateResult" then
        local player  = getPlayer()
        local msgArgs = args.msgArgs or {}
        if not player then return end
        local textOk, text = pcall(function()
            return getText("IGUI_BusStop_" .. (args.msgKey or ""), unpack(msgArgs))
        end)
        if not textOk then
            print("[BusStop] WARNING getText failed for key '" .. tostring(args.msgKey) .. "': " .. tostring(text))
            text = tostring(args.msgKey)
        end
        if args.ok then
            HaloTextHelper.addGoodText(player, text)
        else
            HaloTextHelper.addBadText(player, text)
        end
    else
        print("[BusStop] WARNING: unhandled server command='" .. command .. "'")
    end
end

Events.OnServerCommand.Add(onServerCommand)

-- ── Request stop list on join ─────────────────────────────────────────────────
-- sendClientCommand sent at frame 1 is discarded by the server because the
-- custom-command channel isn't ready yet. Retry every 3 s until we receive
-- a non-empty list, up to 10 attempts.

local RETRY_MS   = 3000
local MAX_TRIES  = 10
local _tries     = 0
local _nextRetry = 0

local function stopListRetry(player)
    if player ~= getPlayer() then return end
    if #BusStop.activeStops > 0 then
        Events.OnPlayerUpdate.Remove(stopListRetry)
        return
    end
    local now = getTimestampMs()
    if now < _nextRetry then return end
    _tries     = _tries + 1
    _nextRetry = now + RETRY_MS
    local ok, err = pcall(function() sendClientCommand(MODULE, "RequestStopList", {}) end)
    if not ok then
        print("[BusStop] ERROR RequestStopList (attempt " .. _tries .. "): " .. tostring(err))
    end
    if _tries >= MAX_TRIES then
        Events.OnPlayerUpdate.Remove(stopListRetry)
        print("[BusStop] WARNING: gave up requesting stop list after " .. MAX_TRIES .. " attempts")
    end
end

Events.OnGameStart.Add(function()
    _tries     = 0
    _nextRetry = getTimestampMs() + RETRY_MS
    Events.OnPlayerUpdate.Add(stopListRetry)
end)

-- ── Admin name dialog ─────────────────────────────────────────────────────────

local function openNameDialog(sq)
    local modal
    modal = ISTextBox:new(
        0, 0, 280, 140,
        BusStop.getText("dlg_name_prompt"),
        BusStop.getText("dlg_name_default"),
        nil,
        function(_, button)
            if button.internal ~= "OK" then return end
            local name = modal.entry:getText()
            local payload = {
                x    = sq:getX(),
                y    = sq:getY(),
                z    = sq:getZ(),
                name = (name ~= "" and name or BusStop.getText("dlg_name_default")),
            }
            local ok, err = pcall(function() sendClientCommand(MODULE, "CreateStop", payload) end)
            if not ok then
                print("[BusStop] ERROR sendClientCommand CreateStop: " .. tostring(err))
            end
        end
    )
    modal:initialise()
    modal:addToUIManager()
    modal:setX(math.floor((getCore():getScreenWidth()  - 280) / 2))
    modal:setY(math.floor((getCore():getScreenHeight() - 140) / 2))
end

-- ── Context menu ─────────────────────────────────────────────────────────────

-- Returns the registered stop located on `sq` (the right-clicked square), but
-- only when the player is within use distance of it. Detection is keyed off the
-- synced registry (BusStop.activeStops), so it works even when the tile has not
-- been spawned yet (new world loaded from an existing config, or a soft-wiped
-- region). Anchoring to the CLICKED square — not merely the player's proximity —
-- keeps the option from appearing when the player right-clicks away from the
-- stop tile, and from lingering after interacting with the stop once.
-- Player proximity uses the same Euclidean radius the server validates against.
local function findStopAtSquare(player, sq)
    if not sq then return nil end
    local cx, cy, cz = sq:getX(), sq:getY(), sq:getZ()
    local px, py     = player:getX(), player:getY()
    local pz         = math.floor(player:getZ())
    local maxSq      = BusStop.MAX_USE_DISTANCE * BusStop.MAX_USE_DISTANCE
    for _, s in ipairs(BusStop.activeStops) do
        if s.x == cx and s.y == cy and s.z == cz then
            local dx, dy = px - s.x, py - s.y
            if pz == s.z and (dx * dx + dy * dy) <= maxSq then
                return s
            end
            return nil   -- right tile, but the player is too far to use it
        end
    end
    return nil
end

-- True if the physical bus-stop object for this stop is present on its tile.
-- Cheap: scans a single gridsquare, and only on a right-click.
local function stopObjectPresent(stop)
    local cellOk, cell = pcall(getCell)
    if not cellOk or not cell then return false end
    local sq = cell:getGridSquare(stop.x, stop.y, stop.z)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local md = objs:get(i):getModData()
        if md.busStop and md.stopId == stop.id then return true end
    end
    return false
end

local function getTargetSquare(player, worldObjects)
    for _, obj in ipairs(worldObjects) do
        if type(obj.getSquare) == "function" then
            local ok, sq = pcall(function() return obj:getSquare() end)
            if ok and sq then return sq end
        end
    end
    return getCell():getGridSquare(
        math.floor(player:getX()),
        math.floor(player:getY()),
        math.floor(player:getZ())
    )
end

local function onFillWorldObjectContextMenu(playerIndex, context, worldObjects, _test)
    local player = getSpecificPlayer(playerIndex)
    if not player then return end

    local isAdmin  = BusStop.isAdmin(player)
    local targetSq = getTargetSquare(player, worldObjects)
    local nearStop = findStopAtSquare(player, targetSq)

    if nearStop then
        -- Usage depends only on the registry. If the physical sprite is missing
        -- (new world / soft-wiped region), lazily ask the server to spawn it —
        -- only when actually absent, so there is no redundant traffic.
        if not stopObjectPresent(nearStop) then
            local ok, err = pcall(function()
                sendClientCommand(MODULE, "EnsureStopTile", { stopId = nearStop.id })
            end)
            if not ok then print("[BusStop] ERROR EnsureStopTile: " .. tostring(err)) end
        end
        context:addOption(
            BusStop.getText("ctx_use_stop", nearStop.displayname or ""),
            { stop = nearStop, player = player },
            function(data)
                require "BusStopUI"
                BusStopUI.open(data.player, data.stop)
            end
        )
    end

    if isAdmin then
        if nearStop then
            context:addOption(
                BusStop.getText("ctx_remove_stop"),
                { stopId = nearStop.id },
                function(data)
                    sendClientCommand(MODULE, "RemoveStop", { stopId = data.stopId })
                end
            )
        else
            if targetSq then
                context:addOption(
                    BusStop.getText("ctx_build_stop"),
                    { sq = targetSq },
                    function(data) openNameDialog(data.sq) end
                )
            end
        end
        context:addOption(
            BusStop.getText("ctx_manage_stops"),
            {},
            function()
                require "BusStopAdminUI"
                BusStopAdminUI.open()
            end
        )
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
