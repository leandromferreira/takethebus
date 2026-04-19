-- BusStopClient.lua
-- Server responses, context menus and admin name-dialog.

require "BusStopShared"

local MODULE = "BusStop"

-- ── Server command handler ────────────────────────────────────────────────────

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end

    if command == "StopList" then
        BusStop.activeStops = args.stops or {}
        print("[BusStop] StopList received: " .. #BusStop.activeStops .. " stop(s)"
              .. (BusStopAdminUI and BusStopAdminUI._current and " (admin panel open, refreshing)" or ""))

    elseif command == "TeleportTo" then
        require "BusStopTransition"
        BusStopTransition.play(args.x, args.y, args.z)

    elseif command == "TravelResult" or command == "CreateResult"
        or command == "RemoveResult" or command == "UpdateResult" then
        local player  = getPlayer()
        local msgArgs = args.msgArgs or {}
        print("[BusStop] " .. command .. " ok=" .. tostring(args.ok) .. " key=" .. tostring(args.msgKey))
        local text = getText("IGUI_BusStop_" .. (args.msgKey or ""), unpack(msgArgs))
        if args.ok then
            HaloTextHelper.addGoodText(player, text)
        else
            HaloTextHelper.addBadText(player, text)
        end
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
    sendClientCommand(MODULE, "RequestStopList", {})
    print("[BusStop] RequestStopList sent (attempt " .. _tries .. ")")
    if _tries >= MAX_TRIES then
        Events.OnPlayerUpdate.Remove(stopListRetry)
        print("[BusStop] Gave up requesting stop list after " .. MAX_TRIES .. " attempts")
    end
end

Events.OnGameStart.Add(function()
    _tries     = 0
    _nextRetry = getTimestampMs() + RETRY_MS   -- first attempt after 3 s
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
            sendClientCommand(MODULE, "CreateStop", {
                x    = sq:getX(),
                y    = sq:getY(),
                z    = sq:getZ(),
                name = (name ~= "" and name or BusStop.getText("dlg_name_default")),
            })
        end
    )
    modal:initialise()
    modal:addToUIManager()
    modal:setX(math.floor((getCore():getScreenWidth()  - 280) / 2))
    modal:setY(math.floor((getCore():getScreenHeight() - 140) / 2))
end

-- ── Context menu ─────────────────────────────────────────────────────────────

local function findNearStop(player, worldObjects)
    for _, obj in ipairs(worldObjects) do
        local md = obj:getModData()
        if md and md.busStop then
            local sq = obj:getSquare()
            if sq then
                local dx = math.abs(player:getX() - sq:getX())
                local dy = math.abs(player:getY() - sq:getY())
                if dx <= BusStop.MAX_USE_DISTANCE and dy <= BusStop.MAX_USE_DISTANCE then
                    return obj
                end
            end
        end
    end
    return nil
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
    local nearStop = findNearStop(player, worldObjects)

    -- All players: use stop via context menu (reliable fallback for left-click).
    if nearStop then
        local md = nearStop:getModData()
        context:addOption(
            BusStop.getText("ctx_use_stop", md.name or ""),
            { obj = nearStop, player = player },
            function(data)
                require "BusStopUI"
                BusStopUI.open(data.player, data.obj)
            end
        )
    end

    -- Admin-only options.
    if isAdmin then
        if nearStop then
            local md = nearStop:getModData()
            context:addOption(
                BusStop.getText("ctx_remove_stop"),
                { stopId = md.stopId },
                function(data)
                    sendClientCommand(MODULE, "RemoveStop", { stopId = data.stopId })
                end
            )
        else
            local targetSq = getTargetSquare(player, worldObjects)
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
