-- BusStopServer.lua
-- Authoritative server: Lua-table persistence, travel validation, teleport.

require "BusStopShared"

local MODULE = "BusStop"

-- ── File I/O ──────────────────────────────────────────────────────────────────
-- File stored at Zomboid/Lua/BusStopData.lua

local FILE_NAME = "BusStopData.lua"
local stops = {}

-- File format: one stop per line, fields separated by TAB.
-- Fields: id \t displayname \t x \t y \t z \t pricetype \t price_multiplier \t available \t rememberreturn

local SEP = "\t"

local function saveStops()
    local writer = getFileWriter(FILE_NAME, true, false)
    if not writer then
        print("[BusStop] ERROR: cannot write " .. FILE_NAME)
        return
    end
    for _, s in ipairs(stops) do
        local line = table.concat({
            s.id,
            (s.displayname or ""):gsub(SEP, " "),
            tostring(s.x or 0),
            tostring(s.y or 0),
            tostring(s.z or 0),
            s.pricetype or "dynamic",
            tostring(tonumber(s.price_multiplier) or 1.0),
            tostring(s.available ~= false),
            tostring(s.rememberreturn == true),
        }, SEP)
        writer:write(line .. "\n")
    end
    writer:close()
end

local function parseTSVLine(line)
    local parts = {}
    for field in (line .. SEP):gmatch("([^" .. SEP .. "]*)" .. SEP) do
        table.insert(parts, field)
    end
    if #parts < 9 then return nil end
    return {
        id               = parts[1],
        displayname      = parts[2],
        x                = tonumber(parts[3]) or 0,
        y                = tonumber(parts[4]) or 0,
        z                = tonumber(parts[5]) or 0,
        pricetype        = parts[6],
        price_multiplier = tonumber(parts[7]) or 1.0,
        available        = parts[8] == "true",
        rememberreturn   = parts[9] == "true",
    }
end

local function parseLuaLine(line)
    -- Old format: { id="...", displayname="...", x=N, y=N, z=N, pricetype="...", ... }
    local id = line:match('id="([^"]*)"')
    if not id then return nil end
    return {
        id               = id,
        displayname      = line:match('displayname="([^"]*)"') or "",
        x                = tonumber(line:match('[^_]x=(-?%d+)')) or 0,
        y                = tonumber(line:match('[^_]y=(-?%d+)')) or 0,
        z                = tonumber(line:match('[^_]z=(-?%d+)')) or 0,
        pricetype        = line:match('pricetype="([^"]*)"') or "dynamic",
        price_multiplier = tonumber(line:match('price_multiplier=([%d%.]+)')) or 1.0,
        available        = line:match('available=(%a+)') == "true",
        rememberreturn   = line:match('rememberreturn=(%a+)') == "true",
    }
end

local function loadStops()
    local reader = getFileReader(FILE_NAME, false)
    if not reader then stops = {}; return end
    stops = {}
    local firstLine = reader:readLine()
    -- Detect format by first line content.
    local isLua = firstLine and (firstLine:find("^return") or firstLine:find("^{"))
    local parseLine = isLua and parseLuaLine or parseTSVLine
    local line = firstLine
    while line ~= nil do
        if line ~= "" and line:sub(1,1) ~= "#" then
            local s = parseLine(line)
            if s then table.insert(stops, s) end
        end
        line = reader:readLine()
    end
    reader:close()
    print("[BusStop] Parsed " .. #stops .. " stop(s) from " .. FILE_NAME
          .. (isLua and " (legacy format, will migrate)" or ""))
    if isLua and #stops > 0 then
        saveStops()  -- re-save in TSV so next load uses new format
        print("[BusStop] Migrated to TSV format")
    end
end

local function findStop(stopId)
    for i, s in ipairs(stops) do
        if s.id == stopId then return s, i end
    end
    return nil, nil
end

-- ── Broadcast ─────────────────────────────────────────────────────────────────

-- Broadcast the full stop list to all connected clients.
-- ModData is updated so new clients joining later also receive the current list.
local function broadcastStopList()
    ModData.add("BusStopData", stops)
    sendServerCommand(MODULE, "StopList", { stops = stops })
end

-- Checks all registered stops whose tile is currently loaded.
-- Removes any entry whose tile is loaded but has no matching physical object.
-- Stops in unloaded chunks are left untouched (can't verify).
local function cleanOrphanedStops()
    local removed = {}
    for i = #stops, 1, -1 do
        local s  = stops[i]
        local sq = getCell():getGridSquare(s.x, s.y, s.z)
        if sq then
            local found = false
            local objs  = sq:getObjects()
            for j = 0, objs:size() - 1 do
                local md = objs:get(j):getModData()
                if md.busStop and md.stopId == s.id then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(removed, s.displayname .. " (" .. s.id .. ")")
                table.remove(stops, i)
            end
        end
    end
    if #removed > 0 then
        saveStops()
        pcall(broadcastStopList)
        for _, name in ipairs(removed) do
            print("[BusStop] Removed orphaned stop: " .. name)
        end
    end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- msgKey: translation key; msgArgs: optional array of format args for the client.
local function reply(player, command, ok, msgKey, msgArgs)
    sendServerCommand(player, MODULE, command, {
        ok      = ok,
        msgKey  = msgKey,
        msgArgs = msgArgs,
    })
end

local function distanceSq(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function tileHasBusStop(x, y, z, stopId)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local md = objs:get(i):getModData()
        if md.busStop and md.stopId == stopId then return true end
    end
    return false
end

local function hasNearbyZombies(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local rSq = BusStop.MAX_ZOMBIE_DISTANCE * BusStop.MAX_ZOMBIE_DISTANCE
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        local z = zombies:get(i)
        if z:getZ() == pz and distanceSq(px, py, z:getX(), z:getY()) <= rSq then
            return true
        end
    end
    return false
end

local function playerIsAdmin(player)
    local level = string.lower(player:getAccessLevel() or "")
    return level == "admin" or level == "moderator"
end

-- ── Price / inventory ─────────────────────────────────────────────────────────

local function countItemType(inv, fullType)
    local count = 0
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        if items:get(i):getFullType() == fullType then
            count = count + 1
        end
    end
    return count
end

local function removeItemType(inv, fullType)
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getFullType() == fullType then
            inv:Remove(item)
            sendRemoveItemFromContainer(inv, item)
            return true
        end
    end
    return false
end

local function deductCurrency(player, price)
    if price <= 0 then return true end
    local sv       = SandboxVars.BusStop or {}
    local itemType = sv.CurrencyItem or "Base.Money"
    local inv      = player:getInventory()
    local count    = countItemType(inv, itemType)
    if count < price then return false, count end
    for _ = 1, price do
        removeItemType(inv, itemType)
    end
    return true
end

-- ── Command handlers ──────────────────────────────────────────────────────────

local function handleRequestTravel(player, args)
    local stopId    = args.stopId
    local destId    = args.destinationId
    local sx, sy, sz = args.x, args.y, args.z

    if player:getVehicle() then
        reply(player, "TravelResult", false, "err_in_vehicle")
        return
    end

    if hasNearbyZombies(player) then
        reply(player, "TravelResult", false, "err_zombies_nearby")
        return
    end

    if not (sx and sy and sz) then
        reply(player, "TravelResult", false, "err_invalid_location")
        return
    end

    if not tileHasBusStop(sx, sy, sz, stopId) then
        reply(player, "TravelResult", false, "err_stop_not_found")
        return
    end

    local px, py = player:getX(), player:getY()
    local maxD   = BusStop.MAX_USE_DISTANCE
    if distanceSq(px, py, sx, sy) > maxD * maxD then
        reply(player, "TravelResult", false, "err_too_far")
        return
    end

    local dest = findStop(destId)
    if not dest then
        reply(player, "TravelResult", false, "err_unknown_dest")
        return
    end

    if not dest.available then
        reply(player, "TravelResult", false, "err_unavailable")
        return
    end

    if destId == stopId then
        reply(player, "TravelResult", false, "err_already_here")
        return
    end

    -- Return trips are free when the stop the player is AT has rememberreturn enabled.
    local currStop = findStop(stopId)
    local isFree  = args.isReturn == true and currStop and currStop.rememberreturn == true
    local price   = isFree and 0 or BusStop.calcPrice(px, py, dest)
    if price > 0 then
        local sv       = SandboxVars.BusStop or {}
        local itemType = sv.CurrencyItem or "Base.Money"
        local itemName = itemType:match("%.(.+)$") or itemType
        local count    = countItemType(player:getInventory(), itemType)
        if count < price then
            reply(player, "TravelResult", false, "err_no_currency", { itemName, price, count })
            return
        end
    end

    deductCurrency(player, price)

    sendServerCommand(player, MODULE, "TeleportTo", { x = dest.x, y = dest.y, z = dest.z })
    reply(player, "TravelResult", true, "msg_arrived", { dest.displayname })
end

local function handleCreateStop(player, args)
    if not playerIsAdmin(player) then
        reply(player, "CreateResult", false, "err_permission")
        return
    end

    local x, y, z = args.x, args.y, args.z
    local name     = (args.name and args.name ~= "") and args.name or "Bus Stop"

    local sq = getCell():getGridSquare(x, y, z)
    if not sq then
        reply(player, "CreateResult", false, "err_invalid_tile")
        return
    end

    -- Generate a unique id from position + timestamp.
    local stopId = string.format("stop_%d_%d_%d_%d", x, y, z, getTimestampMs() % 1000000)

    -- Place the physical sign object in the world (B42 API).
    local STOP_SPRITE = "bus_stop"
    print("[BusStop] Creating object with sprite '" .. STOP_SPRITE .. "' at " .. x .. "," .. y .. "," .. z)
    local obj = IsoThumpable.new(getCell(), sq, STOP_SPRITE, false)
    if not obj then
        print("[BusStop] ERROR: IsoThumpable.new returned nil")
        reply(player, "CreateResult", false, "err_invalid_tile")
        return
    end
    local md = obj:getModData()
    md.busStop  = true
    md.stopId   = stopId
    md.name     = name
    sq:AddSpecialObject(obj)
    pcall(function()
        obj:setMaxHealth(999999)
        obj:setHealth(999999)
    end)
    local ok2, err2 = pcall(function() obj:transmitCompleteItemToClients() end)
    if not ok2 then
        print("[BusStop] WARN transmitCompleteItemToClients: " .. tostring(err2))
    end
    print("[BusStop] Object created, stopId=" .. stopId)

    -- Add to registry.
    table.insert(stops, {
        id               = stopId,
        displayname      = name,
        x                = x,
        y                = y,
        z                = z,
        pricetype        = "dynamic",
        price_multiplier = 1.0,
        available        = true,
        rememberreturn   = false,
    })
    saveStops()
    broadcastStopList()

    reply(player, "CreateResult", true, "msg_stop_created", { name })
end

local function handleRemoveStop(player, args)
    if not playerIsAdmin(player) then
        reply(player, "RemoveResult", false, "err_permission")
        return
    end

    local stopId = args.stopId

    -- Remove physical object from world if we know its tile.
    local stop = findStop(stopId)
    if stop then
        local sq = getCell():getGridSquare(stop.x, stop.y, stop.z)
        if sq then
            local objs = sq:getObjects()
            for i = objs:size() - 1, 0, -1 do
                local obj = objs:get(i)
                local objMd = obj:getModData()
                if objMd.busStop and objMd.stopId == stopId then
                    sq:transmitRemoveItemFromSquare(obj)
                    break
                end
            end
        end
    end

    -- Remove from registry.
    local _, idx = findStop(stopId)
    if idx then
        table.remove(stops, idx)
        saveStops()
        broadcastStopList()
        reply(player, "RemoveResult", true, "msg_stop_removed")
    else
        reply(player, "RemoveResult", false, "err_not_in_registry")
    end
end

local function handleUpdateStop(player, args)
    if not playerIsAdmin(player) then
        reply(player, "UpdateResult", false, "err_permission")
        return
    end

    local entry, idx = findStop(args.id)
    if not idx then
        reply(player, "UpdateResult", false, "err_not_in_registry")
        return
    end

    -- Only allow updating safe fields.
    if args.displayname     then entry.displayname     = args.displayname     end
    if args.x               then entry.x               = tonumber(args.x)     end
    if args.y               then entry.y               = tonumber(args.y)     end
    if args.z               then entry.z               = tonumber(args.z)     end
    if args.pricetype       then entry.pricetype       = args.pricetype       end
    if args.price_multiplier then entry.price_multiplier = tonumber(args.price_multiplier) or 1.0 end
    if args.available ~= nil then entry.available        = (args.available == true or args.available == "true") end
    if args.rememberreturn ~= nil then entry.rememberreturn = (args.rememberreturn == true or args.rememberreturn == "true") end

    stops[idx] = entry
    saveStops()
    broadcastStopList()
    reply(player, "UpdateResult", true, "msg_stop_updated")
end

local function handleRequestStopList(player, _)
    print("[BusStop] RequestStopList from " .. tostring(player:getUsername())
          .. " — sending " .. #stops .. " stop(s)")
    sendServerCommand(player, MODULE, "StopList", { stops = stops })
end

-- ── Event wiring ──────────────────────────────────────────────────────────────

local HANDLERS = {
    RequestTravel   = handleRequestTravel,
    CreateStop      = handleCreateStop,
    RemoveStop      = handleRemoveStop,
    UpdateStop      = handleUpdateStop,
    RequestStopList = handleRequestStopList,
}

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    local h = HANDLERS[command]
    if h then h(player, args or {}) end
end)

Events.OnServerStarted.Add(function()
    loadStops()
    print("[BusStop] Loaded " .. #stops .. " stop(s) from " .. FILE_NAME)
end)

Events.OnGameTimeLoaded.Add(function()
    if #stops == 0 then loadStops() end
    -- cleanOrphanedStops may remove stops and broadcast internally;
    -- wrap so a nil getCell() at startup doesn't kill the event.
    pcall(cleanOrphanedStops)
end)


