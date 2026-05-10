-- BusStopTransition.lua
-- Full-screen fade to black + sounds before teleporting the player.

BusStopTransition = BusStopTransition or {}

-- Timing calibrated to the custom .ogg files (each ~3 s):
--   partida.ogg (bus_arrive) plays during fade-in + black hold
--   acelera.ogg (bus_depart) plays during fade-out
local FADE_IN_S  = 2.0   -- fade to black while "partida" plays
local BLACK_S    = 0.6   -- hold black, teleport happens here
local FADE_OUT_S = 2.8   -- fade back while "acelera" plays

local SND_ARRIVE = "BusStop_Arrive"   -- partida.ogg
local SND_DEPART = "BusStop_Depart"   -- acelera.ogg

local PROTECTION_MS = 5000   -- max protection duration in milliseconds

local function playSound(player, name)
    print("[BusStop][SOUND] playSound('" .. tostring(name) .. "')")
    local vol = (BusStopSettings and BusStopSettings.getVolume()) or 0.5
    print("[BusStop][SOUND]   volume=" .. tostring(vol))
    if vol <= 0 then
        print("[BusStop][SOUND]   volume is 0, skipping")
        return
    end
    local p = player or getPlayer()
    if not p then
        print("[BusStop][SOUND]   ERROR: no player object")
        return
    end
    print("[BusStop][SOUND]   player=" .. tostring(p:getUsername())
          .. " pos=(" .. p:getX() .. "," .. p:getY() .. "," .. p:getZ() .. ")")

    local worldOk, world = pcall(getWorld)
    if not worldOk or not world then
        print("[BusStop][SOUND]   ERROR: getWorld() failed: " .. tostring(world))
        return
    end
    print("[BusStop][SOUND]   getWorld() OK")

    local emitterOk, emitter = pcall(function() return world:getFreeEmitter() end)
    if not emitterOk then
        print("[BusStop][SOUND]   ERROR: getFreeEmitter() threw: " .. tostring(emitter))
        return
    end
    if not emitter then
        print("[BusStop][SOUND]   ERROR: getFreeEmitter() returned nil")
        return
    end
    print("[BusStop][SOUND]   emitter OK — type=" .. tostring(type(emitter)))

    local posOk, posErr = pcall(function() emitter:setPos(p:getX(), p:getY(), p:getZ()) end)
    if not posOk then
        print("[BusStop][SOUND]   ERROR: emitter:setPos threw: " .. tostring(posErr))
    else
        print("[BusStop][SOUND]   setPos OK")
    end

    local id
    local playOk, playErr = pcall(function()
        id = emitter:playSoundImpl(name, false, p)
    end)
    if not playOk then
        print("[BusStop][SOUND]   ERROR: playSoundImpl('" .. name .. "', false, player) threw: " .. tostring(playErr))
        -- Try without player argument
        print("[BusStop][SOUND]   Retrying with 2 args: playSoundImpl('" .. name .. "', false)")
        local retry, retryErr = pcall(function()
            id = emitter:playSoundImpl(name, false)
        end)
        if not retry then
            print("[BusStop][SOUND]   ERROR retry also failed: " .. tostring(retryErr))
            return
        end
    end
    print("[BusStop][SOUND]   playSoundImpl returned id=" .. tostring(id))

    if id and id ~= 0 then
        local volOk, volErr = pcall(function() emitter:setVolume(id, vol) end)
        if volOk then
            print("[BusStop][SOUND]   setVolume(" .. tostring(id) .. ", " .. vol .. ") OK")
        else
            print("[BusStop][SOUND]   WARN setVolume: " .. tostring(volErr))
        end
    else
        print("[BusStop][SOUND]   WARN: id=" .. tostring(id) .. " — setVolume skipped")
    end
    print("[BusStop][SOUND]   playSound('" .. name .. "') complete")
end

-- ── Protection countdown HUD ──────────────────────────────────────────────────

local ProtHUD = ISPanel:derive("BusStopProtHUD")

function ProtHUD:new(playerNum)
    local sw = getCore():getScreenWidth()
    local w, h = 180, 36
    local o = ISPanel.new(self, math.floor((sw - w) / 2), 64, w, h)
    o.playerNum  = playerNum
    o.secsLeft   = 0
    o.active     = false
    o.backgroundColor = { r=0.05, g=0.05, b=0.05, a=0.75 }
    return o
end

function ProtHUD:render()
    ISPanel.render(self)
    if not self.active then return end
    local label = getText("IGUI_BusStop_prot_countdown", tostring(self.secsLeft))
    -- amber colour: full when almost done, green when plenty remains
    local t = self.secsLeft / (PROTECTION_MS / 1000)
    self:drawTextCentre(label, self.width / 2, 8, t, 1, 0.1, 1, UIFont.Medium)
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 0.9, 0.5, 0.2, 0.8)
end

-- ── Arrival protection (SafeUserLogin pattern) ────────────────────────────────
-- setZombiesDontAttack prevents new attacks; OnZombieUpdate actively clears
-- detection and disables zombies already facing the player (the same mechanism
-- SafeUserLogin uses for spawn protection). Countdown HUD starts when the player
-- first moves or attacks and expires after PROTECTION_MS.

local function startArrivalProtection(player)
    print("[BusStop][TRANS] startArrivalProtection for " .. tostring(player:getUsername()))
    local playerNum = 0   -- split-screen index; always 0 in MP

    player:setZombiesDontAttack(true)
    pcall(function() player:setOutlineHighlight(true) end)
    pcall(function() player:setOutlineHighlightCol(1, 1, 1, 0.25) end)
    pcall(function() HaloTextHelper.addText(player, getText("IGUI_BusStop_prot_start"), "", HaloTextHelper.getColorGreen()) end)

    -- Create and show the countdown HUD.
    local hud = ProtHUD:new(playerNum)
    hud:initialise()
    hud:instantiate()
    hud:addToUIManager()

    local startTime   = nil
    local lastSecond  = -1
    local done        = false
    local playerReady = false
    local zombiesList = {}

    -- Forward declarations so stopProtection can reference the listener functions.
    local stopProtection, zombieFn, updateFn, deathFn

    stopProtection = function()
        if done then return end
        done        = true
        playerReady = true
        print("[BusStop][TRANS] stopProtection()")
        hud.active = false
        hud:setVisible(false)
        hud:removeFromUIManager()
        player:setZombiesDontAttack(false)
        pcall(function() player:setOutlineHighlight(false) end)
        pcall(function() HaloTextHelper.addText(player, getText("IGUI_BusStop_prot_end"), "", HaloTextHelper.getColorRed()) end)
        -- Remove all listeners immediately so nothing leaks after death or timeout.
        Events.OnZombieUpdate.Remove(zombieFn)
        Events.OnPlayerUpdate.Remove(updateFn)
        Events.OnPlayerDeath.Remove(deathFn)
    end

    -- Per-zombie tick: clear detection and disable zombies facing the player.
    -- Mirrors SafeUserLogin's OnZombieUpdate logic exactly.
    zombieFn = function(zombie)
        -- Restore previously disabled zombies so they can re-evaluate each frame.
        for i = 1, #zombiesList do
            local z = zombiesList[i]
            if z and z:isUseless() then z:setUseless(false) end
        end

        if not playerReady then
            zombie:spotted(player, false)
            if zombie:CanSee(player) and not zombie:isUseless() then
                if zombie:isFacingObject(player, 0.0) then
                    zombie:setUseless(true)
                    local found = false
                    for i = 1, #zombiesList do
                        if zombiesList[i] == zombie then found = true; break end
                    end
                    if not found then table.insert(zombiesList, zombie) end
                end
            end
        else
            zombiesList = nil
            Events.OnZombieUpdate.Remove(zombieFn)
        end
    end

    updateFn = function(p)
        if p ~= player then return end
        if done then
            Events.OnPlayerUpdate.Remove(updateFn)
            return
        end

        -- Keep the outline pulsing while protected.
        pcall(function() player:setOutlineHighlight(true) end)
        pcall(function() player:setOutlineHighlightCol(1, 1, 1, 0.25) end)

        -- Start the countdown the moment the player acts.
        if not startTime then
            local moving    = pcall(function() return p:isPlayerMoving() end) and p:isPlayerMoving()
            local attacking = pcall(function() return p:isAttackStarted() end) and p:isAttackStarted()
            if moving or attacking then
                startTime  = getTimestampMs()
                hud.active = true
                print("[BusStop][TRANS] Player acted — protection countdown started")
            end
            return
        end

        -- Update the HUD once per second.
        local elapsed  = getTimestampMs() - startTime
        local secsLeft = math.max(0, math.ceil((PROTECTION_MS - elapsed) / 1000))
        if secsLeft ~= lastSecond then
            lastSecond   = secsLeft
            hud.secsLeft = secsLeft
        end

        -- End protection after timeout.
        if elapsed >= PROTECTION_MS then
            stopProtection()
        end
    end

    -- Clean up if the player dies while protected (HUD would otherwise stay on screen).
    deathFn = function(p)
        if p ~= player then return end
        stopProtection()
    end

    Events.OnZombieUpdate.Add(zombieFn)
    Events.OnPlayerUpdate.Add(updateFn)
    Events.OnPlayerDeath.Add(deathFn)
end

-- ── Fade overlay panel ────────────────────────────────────────────────────────

local FadeOverlay = ISPanel:derive("BusStopFadeOverlay")

function FadeOverlay:new()
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local o  = ISPanel.new(self, 0, 0, sw, sh)
    o.alpha  = 0
    return o
end

function FadeOverlay:render()
    self:drawRect(0, 0, self.width, self.height, self.alpha, 0, 0, 0)
end

-- Block all mouse interaction during the transition.
function FadeOverlay:onMouseDown(x, y)     end
function FadeOverlay:onMouseUp(x, y)       end
function FadeOverlay:onRightMouseDown(x,y) end
function FadeOverlay:onRightMouseUp(x, y)  end

function FadeOverlay:onResolutionChange(ow, oh, nw, nh)
    self:setWidth(nw)
    self:setHeight(nh)
end

-- ── Public entry point ────────────────────────────────────────────────────────

function BusStopTransition.play(destX, destY, destZ)
    print("[BusStop][TRANS] play() called — dest=(" .. tostring(destX) .. "," .. tostring(destY) .. "," .. tostring(destZ) .. ")")

    -- Ignore if a transition is already running.
    if BusStopTransition._active then
        print("[BusStop][TRANS] already active — ignoring")
        return
    end
    BusStopTransition._active = true
    print("[BusStop][TRANS] Starting transition: fadeIn=" .. FADE_IN_S .. "s black=" .. BLACK_S .. "s fadeOut=" .. FADE_OUT_S .. "s")

    -- Create and show the overlay.
    local overlayOk, overlay = pcall(function()
        local o = FadeOverlay:new()
        o:initialise()
        o:instantiate()
        o:addToUIManager()
        return o
    end)
    if not overlayOk then
        print("[BusStop][TRANS] ERROR creating overlay: " .. tostring(overlay))
        BusStopTransition._active = false
        return
    end
    print("[BusStop][TRANS] Overlay created OK")

    local gameTime   = getGameTime()
    local elapsed    = 0
    local teleported = false
    local phase      = "fade_in"

    -- Play bus-arriving sound immediately.
    local p = getPlayer()
    if p then
        print("[BusStop][TRANS] Playing arrive sound")
        playSound(p, SND_ARRIVE)
    else
        print("[BusStop][TRANS] WARNING: getPlayer() nil — cannot play arrive sound")
    end

    local tickFn
    tickFn = function()
        local dt = gameTime:getRealworldSecondsSinceLastUpdate()
        elapsed = elapsed + dt

        if elapsed < FADE_IN_S then
            -- Phase 1: fade to black.
            if phase ~= "fade_in" then
                phase = "fade_in"
                print("[BusStop][TRANS] Phase: fade_in")
            end
            overlay.alpha = elapsed / FADE_IN_S

        elseif elapsed < FADE_IN_S + BLACK_S then
            -- Phase 2: hold black + teleport once at the midpoint.
            if phase ~= "black" then
                phase = "black"
                print("[BusStop][TRANS] Phase: black hold")
            end
            overlay.alpha = 1
            if not teleported then
                teleported = true
                local player = getPlayer()
                if player then
                    local x = destX + 0.5
                    local y = destY + 0.5
                    local z = destZ
                    print("[BusStop][TRANS] Teleporting player to (" .. x .. "," .. y .. "," .. z .. ")")
                    local tpOk, tpErr = pcall(function()
                        player:setX(x); player:setLastX(x)
                        player:setY(y); player:setLastY(y)
                        player:setZ(z); player:setLastZ(z)
                    end)
                    if tpOk then
                        print("[BusStop][TRANS] Teleport setX/Y/Z OK")
                    else
                        print("[BusStop][TRANS] ERROR teleport: " .. tostring(tpErr))
                    end
                    print("[BusStop][TRANS] Playing depart sound")
                    playSound(player, SND_DEPART)
                    startArrivalProtection(player)
                else
                    print("[BusStop][TRANS] ERROR: getPlayer() nil at teleport moment")
                end
            end

        elseif elapsed < FADE_IN_S + BLACK_S + FADE_OUT_S then
            -- Phase 3: fade back from black.
            if phase ~= "fade_out" then
                phase = "fade_out"
                print("[BusStop][TRANS] Phase: fade_out")
            end
            local t = (elapsed - FADE_IN_S - BLACK_S) / FADE_OUT_S
            overlay.alpha = 1 - t

        else
            -- Done.
            print("[BusStop][TRANS] Transition complete (elapsed=" .. string.format("%.2f", elapsed) .. "s)")
            overlay.alpha = 0
            overlay:setVisible(false)
            overlay:removeFromUIManager()
            Events.OnTickEvenPaused.Remove(tickFn)
            BusStopTransition._active = false
        end
    end

    Events.OnTickEvenPaused.Add(tickFn)
    print("[BusStop][TRANS] Tick handler registered")
end
