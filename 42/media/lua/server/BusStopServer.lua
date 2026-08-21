-- BusStopServer.lua
-- Authoritative server: Lua-table persistence, travel validation, teleport.

require "BusStopShared"
require "BusStopEconomy"

local MODULE  = "BusStop"
-- Namespace key used to isolate this mod's data inside player:getModData().
-- Never write outside this key to avoid colliding with other mods or players.
local MOD_KEY = "BusStopFastTravel"

-- Safe accessor: creates the sub-table on first use, never touches other keys.
local function getPlayerData(player)
    local md = player:getModData()
    if not md[MOD_KEY] then md[MOD_KEY] = {} end
    return md[MOD_KEY]
end

-- ── File I/O ──────────────────────────────────────────────────────────────────
-- File stored at Zomboid/Lua/BusStopData.txt
-- B42.20 added an extension allowlist to getFileWriter (ini/cfg/txt/log only),
-- so the save file can no longer use a .lua extension — getFileWriter would
-- silently return nil and saveStops() would never persist. getFileReader has
-- no such restriction, so OLD_FILE_NAME below is only ever read (for
-- migrating saves created before this rename), never written.

local FILE_NAME           = "BusStopData.txt"
local OLD_FILE_NAME       = "BusStopData.lua"   -- legacy name, read-only (see above)
local stops               = {}
local _rndIdx             = 0   -- round-robin counter for random trips
local _pendingProtections = {}  -- { {player, expiry}, ... } for arrival protection cleanup

-- File format: one stop per line, fields separated by TAB.
-- Fields: id \t displayname \t x \t y \t z \t pricetype \t price_multiplier \t available \t rememberreturn

local SEP = "\t"

local function saveStops()
    local writer = getFileWriter(FILE_NAME, true, false)
    if not writer then
        print("[BusStop] ERROR saveStops: getFileWriter returned nil")
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
            tostring(s.accepttickets ~= false),
        }, SEP)
        local ok, err = pcall(function() writer:write(line .. "\n") end)
        if not ok then
            print("[BusStop] ERROR saveStops: write failed for id=" .. tostring(s.id) .. ": " .. tostring(err))
        end
    end
    local _, closeErr = pcall(function() writer:close() end)
    if closeErr then print("[BusStop] ERROR saveStops: close failed: " .. tostring(closeErr)) end
end

local function parseTSVLine(line)
    local parts = {}
    for field in (line .. SEP):gmatch("([^" .. SEP .. "]*)" .. SEP) do
        table.insert(parts, field)
    end
    if #parts < 9 then
        print("[BusStop][LOAD]   SKIP TSV line (only " .. #parts .. " fields, need at least 9): " .. line)
        return nil
    end
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
        -- Field 10 (accepttickets) was added after the initial release; older
        -- save lines only have 9 fields, so default to true (accept) when absent.
        accepttickets    = parts[10] == nil or parts[10] == "true",
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
        accepttickets    = line:match('accepttickets=(%a+)') ~= "false",
    }
end

local function loadStops()
    local reader = getFileReader(FILE_NAME, false)
    local usedOldFile = false
    if not reader then
        -- Fall back to the pre-42.20 filename (getFileReader has no extension
        -- restriction, so this legacy file is still readable even though it
        -- can no longer be written — see FILE_NAME comment above).
        reader = getFileReader(OLD_FILE_NAME, false)
        usedOldFile = reader ~= nil
    end
    if not reader then
        stops = {}
        print("[BusStop] No save file found — starting with empty stop list")
        return
    end
    stops = {}
    local firstLine = reader:readLine()
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
    print("[BusStop] Loaded " .. #stops .. " stop(s)"
        .. (isLua and " (legacy table format — migrating)" or "")
        .. (usedOldFile and (" (from legacy " .. OLD_FILE_NAME .. " — migrating to " .. FILE_NAME .. ")") or ""))
    if (isLua or usedOldFile) and #stops > 0 then
        saveStops()
    end
end

local function findStop(stopId)
    for i, s in ipairs(stops) do
        if s.id == stopId then return s, i end
    end
    return nil, nil
end

-- ── Solo-mode command relay ──────────────────────────────────────────────────
-- sendServerCommand's engine binding only ever dispatches through GameServer
-- (guarded by isServer()) — unlike sendClientCommand, it has no fallback to
-- SinglePlayerServer for true single-player. isServer() and isClient() are
-- BOTH false in true single-player (they're true only for a real dedicated
-- server / a real network connection respectively), so on a fresh solo game
-- sendServerCommand is a silent no-op: OnServerCommand never fires client-side.
-- This breaks everything server->client: StopList sync, TeleportTo, return
-- trip sync, and all halo-text replies.
-- Workaround: ModData is a single Java-side map regardless of client/server
-- Lua context, so add()/get() need no network round-trip at all. In true solo
-- we relay through a ModData queue instead of sendServerCommand; the client
-- polls and drains it (see BusStopClient.lua). Real MP is untouched — it still
-- goes through sendServerCommand exactly as before.
local SOLO_QUEUE_TAG = "BusStopSoloQueue"

local function isTrueSolo()
    return not isServer() and not isClient()
end

-- player is ignored in the solo path: true solo only ever has the one local
-- player, and the client-side poller doesn't need to address it.
--
-- IMPORTANT: sendServerCommand(module, command, args) [3 args, broadcast to
-- everyone] and sendServerCommand(player, module, command, args) [4 args,
-- targeted] are two DIFFERENT Java overloads, resolved by argument count —
-- calling the 4-arg form with player=nil is NOT the same as calling the 3-arg
-- form; it does not broadcast. Passing player=nil here must call the 3-arg
-- broadcast overload, not the 4-arg one with a nil player.
local function serverSend(player, command, args)
    if isTrueSolo() then
        local ok, q = pcall(ModData.getOrCreate, SOLO_QUEUE_TAG)
        if ok and q then
            table.insert(q, { command = command, args = args or {} })
        else
            print("[BusStop] ERROR serverSend: ModData.getOrCreate failed for '" .. command .. "'")
        end
    elseif player then
        sendServerCommand(player, MODULE, command, args)
    else
        sendServerCommand(MODULE, command, args)
    end
end

-- ── Broadcast ─────────────────────────────────────────────────────────────────

-- Broadcast the full stop list to all connected clients.
-- ModData is updated so new clients joining later also receive the current list.
local function broadcastStopList()
    local _, mdErr = pcall(function() ModData.add("BusStopData", stops) end)
    if mdErr then print("[BusStop] ERROR broadcastStopList ModData.add: " .. tostring(mdErr)) end
    local _, cmdErr = pcall(function() serverSend(nil, "StopList", { stops = stops }) end)
    if cmdErr then print("[BusStop] ERROR broadcastStopList serverSend: " .. tostring(cmdErr)) end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- msgKey: translation key; msgArgs: optional array of format args for the client.
local function reply(player, command, ok, msgKey, msgArgs)
    serverSend(player, command, {
        ok      = ok,
        msgKey  = msgKey,
        msgArgs = msgArgs,
    })
end

local function distanceSq(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function hasNearbyZombies(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local rSq = BusStop.MAX_ZOMBIE_DISTANCE * BusStop.MAX_ZOMBIE_DISTANCE
    local cellOk, cell = pcall(getCell)
    if not cellOk or not cell then return false end
    local zombies = cell:getZombieList()
    for i = 0, zombies:size() - 1 do
        local z = zombies:get(i)
        if z:getZ() == pz and distanceSq(px, py, z:getX(), z:getY()) <= rSq then
            return true
        end
    end
    return false
end

local function playerIsAdmin(player)
    -- True single-player (not hosted, not dedicated) never goes through the
    -- whitelist/role system, so getAccessLevel() never returns "admin" there
    -- even for the local host. isServer() is true only on a real dedicated
    -- server; isClient() is true only for a real network connection (Host or
    -- Join). Both are false only in true single-player, so this bypass can't
    -- be reached on an actual multi-user server. Mirrors the client-side
    -- bypass in BusStop.isAdmin (BusStopShared.lua).
    if not isServer() and not isClient() then return true end
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

-- canAfford: returns ok(bool), errKey(string), errArgs(table)
-- When both item and bank are enabled, items are the primary source; the bank
-- covers any shortfall. Both sources combined must be >= price.
local function canAfford(player, price)
    if price <= 0 then return true end
    local sv      = SandboxVars.BusStop or {}
    local useItem = sv.UseItemPayment ~= false   -- default true
    local useBank = sv.UseBankPayment == true
    if not useItem and not useBank then useItem = true end   -- safety fallback

    local itemType  = sv.CurrencyItem or "Base.Money"
    local itemCount = useItem and countItemType(player:getInventory(), itemType) or 0

    if itemCount >= price then return true end

    local remaining = price - itemCount

    if not useBank then
        local itemName = itemType:match("%.(.+)$") or itemType
        return false, "err_no_currency", { itemName, tostring(price), tostring(itemCount) }
    end

    local api = BusStopEconomy.getAPI()
    if not api then
        local label = useItem and (itemType:match("%.(.+)$") or itemType) or (sv.BankModGlobal or "bank")
        return false, "err_no_currency", { label, tostring(price), tostring(itemCount) }
    end

    return api.canAfford(player, remaining)
end

local function deductCurrency(player, price)
    if price <= 0 then return end
    local sv      = SandboxVars.BusStop or {}
    local useItem = sv.UseItemPayment ~= false
    local useBank = sv.UseBankPayment == true
    if not useItem and not useBank then useItem = true end

    local itemType  = sv.CurrencyItem or "Base.Money"
    local itemCount = useItem and countItemType(player:getInventory(), itemType) or 0
    local fromItems = math.min(itemCount, price)
    local fromBank  = price - fromItems

    if fromItems > 0 then
        local inv = player:getInventory()
        for _ = 1, fromItems do removeItemType(inv, itemType) end
    end

    if fromBank > 0 then
        local api = useBank and BusStopEconomy.getAPI()
        if api then
            api.deduct(player, fromBank)
        else
            print("[BusStop] WARNING deductCurrency: fromBank=" .. fromBank .. " but bank API unavailable")
        end
    end
end

-- ── Command handlers ──────────────────────────────────────────────────────────

local function handleRequestTravel(player, args)
    local user   = tostring(player:getUsername())
    local stopId = args.stopId
    local destId = args.destinationId

    if player:getVehicle() then
        reply(player, "TravelResult", false, "err_in_vehicle"); return
    end
    if hasNearbyZombies(player) then
        reply(player, "TravelResult", false, "err_zombies_nearby"); return
    end
    -- Usage is validated against the server's own registry, not the physical
    -- tile: a stop can exist in the registry without a spawned object yet (new
    -- world loaded from an existing config, or a soft-wiped region). Coordinates
    -- come from the registry, so the client cannot claim to be somewhere it isn't.
    local currStop = findStop(stopId)
    if not currStop then
        reply(player, "TravelResult", false, "err_stop_not_found"); return
    end

    local px, py = player:getX(), player:getY()
    local maxD   = BusStop.MAX_USE_DISTANCE
    if math.floor(player:getZ()) ~= currStop.z
       or distanceSq(px, py, currStop.x, currStop.y) > maxD * maxD then
        reply(player, "TravelResult", false, "err_too_far"); return
    end

    local isRandom = args.isRandom == true or args.isRandom == "true"
    local isReturn = args.isReturn == true or args.isReturn == "true"

    -- Random trip: server picks destination so client can't abuse the discount.
    local resolvedDestId = destId
    if isRandom then
        local candidates = {}
        for _, s in ipairs(stops) do
            if s.id ~= stopId and s.available then
                table.insert(candidates, s)
            end
        end
        if #candidates == 0 then
            reply(player, "TravelResult", false, "err_no_random_dest"); return
        end
        local cnt = #candidates
        _rndIdx = _rndIdx + 1
        if _rndIdx > cnt then _rndIdx = 1 end
        resolvedDestId = candidates[_rndIdx].id
    end

    local dest = findStop(resolvedDestId)
    if not dest then
        reply(player, "TravelResult", false, "err_unknown_dest"); return
    end
    if not dest.available and not isReturn and not isRandom then
        reply(player, "TravelResult", false, "err_unavailable"); return
    end
    if resolvedDestId == stopId then
        reply(player, "TravelResult", false, "err_already_here"); return
    end

    local isFree   = isReturn and currStop and currStop.rememberreturn == true

    local price
    if isRandom then
        local sv2 = SandboxVars.BusStop or {}
        price = sv2.RandomTripPrice or 0
    else
        price = isFree and 0 or BusStop.calcPrice(px, py, dest)
    end

    -- Bus Ticket item: a free fare, consumed on use, honored only when the
    -- destination accepts it (dest.accepttickets ~= false). Checked against
    -- the resolved destination, so this also applies to random trips.
    local usedTicket = false
    if price > 0 and BusStop.ticketAppliesTo(player, dest) then
        local sv3        = SandboxVars.BusStop or {}
        local ticketType = sv3.TicketItem or "BusStop.BusTicket"
        if removeItemType(player:getInventory(), ticketType) then
            usedTicket = true
            price      = 0
        end
    end

    local ok, errKey, errArgs = canAfford(player, price)
    if not ok then
        reply(player, "TravelResult", false, errKey, errArgs); return
    end

    deductCurrency(player, price)

    -- Return-trip persistence (server-authoritative, stored under MOD_KEY).
    -- Use {cleared=true} instead of {returnTrip=nil}: an all-nil table serializes
    -- to Java null in Kahlua and crashes the client handler.
    local pData = getPlayerData(player)
    if isReturn then
        pData.returnTrip = nil
        serverSend(player, "ReturnTripSync", { cleared = true })
    elseif dest.rememberreturn then
        local sv2b   = SandboxVars.BusStop or {}
        local hours  = sv2b.ReturnTripHours or 24
        local gt     = getGameTime()
        local expiry = gt and (gt:getWorldAgeHours() + hours) or 999999
        pData.returnTrip = { stopId = stopId, expiryHours = expiry }
        serverSend(player, "ReturnTripSync", { returnTrip = pData.returnTrip })
    end

    print("[BusStop] " .. user .. " traveled to '" .. dest.displayname .. "'"
        .. (isRandom and " (random)" or "")
        .. (usedTicket and " (used Bus Ticket)" or ""))
    serverSend(player, "TeleportTo", { x = dest.x, y = dest.y, z = dest.z })

    -- Arrival protection: applied server-side so zombie AI (which runs on the server)
    -- actually respects the flag. Client-side calls on a non-admin player are ignored.
    pcall(function() player:setZombiesDontAttack(true) end)
    table.insert(_pendingProtections, { player = player, expiry = getTimestampMs() + 5000 })

    if usedTicket then
        reply(player, "TravelResult", true, "msg_arrived_ticket", { dest.displayname })
    else
        reply(player, "TravelResult", true, "msg_arrived", { dest.displayname })
    end
end

-- Spawns the physical bus-stop IsoThumpable at the stop's registry coordinate.
-- The registry is the source of truth: the object is derived from it and can be
-- (re)created on demand when a player interacts with a stop whose tile is missing
-- (new world loaded from an existing config, or a soft-wiped region).
-- Idempotent: returns the existing object if one with this stopId already sits on
-- the tile. Returns nil on failure (square not loaded / creation error).
local function spawnStopObject(stop)
    local cellOk, cell = pcall(getCell)
    if not cellOk or not cell then
        print("[BusStop] ERROR spawnStopObject: getCell() failed")
        return nil
    end
    local sq = cell:getGridSquare(stop.x, stop.y, stop.z)
    if not sq then
        print("[BusStop] spawnStopObject: square not loaded at " .. stop.x .. "," .. stop.y .. "," .. stop.z)
        return nil
    end

    -- Idempotency: bail if an object with this stopId is already on the tile.
    local existing = sq:getObjects()
    for i = 0, existing:size() - 1 do
        local emd = existing:get(i):getModData()
        if emd.busStop and emd.stopId == stop.id then return existing:get(i) end
    end

    local obj
    local isoOk, isoErr = pcall(function()
        obj = IsoThumpable.new(sq:getCell(), sq, "bus_0", false, {})
    end)
    if not isoOk or not obj then
        print("[BusStop] ERROR spawnStopObject: IsoThumpable.new failed: " .. tostring(isoErr))
        return nil
    end

    local md = obj:getModData()
    md.busStop = true; md.stopId = stop.id; md.name = stop.displayname

    local _, addErr = pcall(function() sq:AddSpecialObject(obj) end)
    if addErr then print("[BusStop] ERROR spawnStopObject AddSpecialObject: " .. tostring(addErr)) end

    pcall(function() obj:setMaxHealth(999999); obj:setHealth(999999) end)
    pcall(function() obj:transmitCompleteItemToClients() end)
    print("[BusStop] spawnStopObject: materialized '" .. tostring(stop.displayname)
          .. "' (" .. tostring(stop.id) .. ") at " .. stop.x .. "," .. stop.y .. "," .. stop.z)
    return obj
end

local function handleCreateStop(player, args)
    local user = tostring(player:getUsername())
    if not playerIsAdmin(player) then
        reply(player, "CreateResult", false, "err_permission"); return
    end

    local x, y, z = args.x, args.y, args.z
    local name     = (args.name and args.name ~= "") and args.name or "Bus Stop"

    local newStop = {
        id = string.format("stop_%d_%d_%d_%d", x, y, z, getTimestampMs() % 1000000),
        displayname = name, x = x, y = y, z = z,
        pricetype = "dynamic", price_multiplier = 1.0, available = true, rememberreturn = false,
        accepttickets = true,
    }

    if not spawnStopObject(newStop) then
        print("[BusStop] ERROR CreateStop: could not spawn stop object at " .. x .. "," .. y .. "," .. z)
        reply(player, "CreateResult", false, "err_invalid_tile"); return
    end

    table.insert(stops, newStop)
    saveStops()
    broadcastStopList()
    print("[BusStop] " .. user .. " created stop '" .. name .. "' (" .. newStop.id .. ")")
    reply(player, "CreateResult", true, "msg_stop_created", { name })
end

-- Lazily (re)creates the physical tile for a registered stop when a player
-- interacts with it. The stop and its coordinate come from the server's own
-- registry — the client only supplies the stopId — and we require the player to
-- actually be standing next to it, so this cannot be used to spawn objects
-- anywhere. Idempotent and cheap: only ever runs on a player's use interaction.
local function handleEnsureStopTile(player, args)
    local stop = findStop(args and args.stopId)
    if not stop then return end

    local px, py = player:getX(), player:getY()
    local maxD   = BusStop.MAX_USE_DISTANCE
    if math.floor(player:getZ()) ~= stop.z
       or distanceSq(px, py, stop.x, stop.y) > maxD * maxD then
        return
    end

    spawnStopObject(stop)
end

local function handleRemoveStop(player, args)
    local user = tostring(player:getUsername())
    if not playerIsAdmin(player) then
        reply(player, "RemoveResult", false, "err_permission"); return
    end

    local stopId = args.stopId
    local stop   = findStop(stopId)
    if stop then
        local cellOk, cell = pcall(getCell)
        local sq = (cellOk and cell) and cell:getGridSquare(stop.x, stop.y, stop.z) or nil
        if sq then
            local objs = sq:getObjects()
            for i = objs:size() - 1, 0, -1 do
                local obj   = objs:get(i)
                local objMd = obj:getModData()
                if objMd.busStop and objMd.stopId == stopId then
                    local _, rmErr = pcall(function() sq:transmitRemoveItemFromSquare(obj) end)
                    if rmErr then print("[BusStop] ERROR RemoveStop transmitRemove: " .. tostring(rmErr)) end
                    break
                end
            end
        end
    end

    local _, idx = findStop(stopId)
    if idx then
        local name = stops[idx].displayname
        table.remove(stops, idx)
        saveStops(); broadcastStopList()
        print("[BusStop] " .. user .. " removed stop '" .. name .. "'")
        reply(player, "RemoveResult", true, "msg_stop_removed")
    else
        print("[BusStop] ERROR RemoveStop: id=" .. tostring(stopId) .. " not in registry")
        reply(player, "RemoveResult", false, "err_not_in_registry")
    end
end

local function handleUpdateStop(player, args)
    if not playerIsAdmin(player) then
        reply(player, "UpdateResult", false, "err_permission"); return
    end

    local entry, idx = findStop(args.id)
    if not idx then
        reply(player, "UpdateResult", false, "err_not_in_registry"); return
    end

    if args.displayname      then entry.displayname      = args.displayname end
    if args.x                then entry.x                = tonumber(args.x) end
    if args.y                then entry.y                = tonumber(args.y) end
    if args.z                then entry.z                = tonumber(args.z) end
    if args.pricetype        then entry.pricetype        = args.pricetype end
    if args.price_multiplier then entry.price_multiplier = tonumber(args.price_multiplier) or 1.0 end
    if args.available     ~= nil then entry.available     = (args.available     == true or args.available     == "true") end
    if args.rememberreturn ~= nil then entry.rememberreturn = (args.rememberreturn == true or args.rememberreturn == "true") end
    if args.accepttickets  ~= nil then entry.accepttickets  = (args.accepttickets  == true or args.accepttickets  == "true") end

    stops[idx] = entry
    saveStops(); broadcastStopList()
    reply(player, "UpdateResult", true, "msg_stop_updated")
end

local function handleRequestStopList(player, _)
    local _, err = pcall(function()
        serverSend(player, "StopList", { stops = stops })
    end)
    if err then print("[BusStop] ERROR StopList send: " .. tostring(err)) end

    -- Restore persisted return trip (check expiry first).
    -- Send {cleared=true} instead of {returnTrip=nil} — an all-nil table
    -- serializes to Java null in Kahlua and crashes the client handler.
    local pData = getPlayerData(player)
    if pData.returnTrip then
        local gt = getGameTime()
        if gt and gt:getWorldAgeHours() >= pData.returnTrip.expiryHours then
            pData.returnTrip = nil
        end
    end
    local payload = pData.returnTrip
        and { returnTrip = pData.returnTrip }
        or  { cleared = true }
    local _, rtErr = pcall(function()
        serverSend(player, "ReturnTripSync", payload)
    end)
    if rtErr then print("[BusStop] ERROR ReturnTripSync send: " .. tostring(rtErr)) end
end

-- ── Event wiring ──────────────────────────────────────────────────────────────

local HANDLERS = {
    RequestTravel   = handleRequestTravel,
    CreateStop      = handleCreateStop,
    RemoveStop      = handleRemoveStop,
    UpdateStop      = handleUpdateStop,
    RequestStopList = handleRequestStopList,
    EnsureStopTile  = handleEnsureStopTile,
}

Events.OnTick.Add(function()
    if #_pendingProtections == 0 then return end
    local now  = getTimestampMs()
    local keep = {}
    for _, entry in ipairs(_pendingProtections) do
        if now < entry.expiry then
            table.insert(keep, entry)
        else
            pcall(function() entry.player:setZombiesDontAttack(false) end)
        end
    end
    _pendingProtections = keep
end)

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    local h = HANDLERS[command]
    if h then
        local ok, err = pcall(h, player, args or {})
        if not ok then
            print("[BusStop] ERROR in handler '" .. command .. "': " .. tostring(err))
        end
    else
        print("[BusStop] WARNING: unhandled command='" .. command .. "'")
    end
end)

Events.OnServerStarted.Add(function()
    print("[BusStop][INIT] OnServerStarted fired")
    loadStops()
    print("[BusStop][INIT] Loaded " .. #stops .. " stop(s) from " .. FILE_NAME)
end)

Events.OnGameTimeLoaded.Add(function()
    print("[BusStop][INIT] OnGameTimeLoaded fired — current stop count=" .. #stops)
    if #stops == 0 then
        print("[BusStop][INIT] stops empty, calling loadStops()")
        loadStops()
    end
    -- No orphan cleanup: the registry is the source of truth. A stop with no
    -- physical tile (new world / soft-wiped region) is materialized on demand
    -- when a player interacts with it (see handleEnsureStopTile / spawnStopObject).
end)
