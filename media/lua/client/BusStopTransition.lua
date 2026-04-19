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
    pcall(function()
        local vol = BusStopSettings and BusStopSettings.getVolume() or 0.5
        if vol <= 0 then return end
        local p = player or getPlayer()
        if not p then return end
        local emitter = getWorld():getFreeEmitter()
        if not emitter then return end
        emitter:setPos(p:getX(), p:getY(), p:getZ())
        local id = emitter:playSoundImpl(name, false, p)
        if id and id ~= 0 then emitter:setVolume(id, vol) end
    end)
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

-- ── Arrival protection (mirrors SafeUserLogin pattern) ────────────────────────
-- Zombies won't attack and the player glows white for up to PROTECTION_MS ms.
-- Protection ends early if the player moves or attacks.

local function startArrivalProtection(player)
    local playerNum = 0   -- split-screen index; always 0 in MP

    player:setZombiesDontAttack(true)
    player:setOutlineHighlight(true)
    player:setOutlineHighlightCol(1, 1, 1, 0.25)
    HaloTextHelper.addText(player, getText("IGUI_BusStop_prot_start"), "", HaloTextHelper.getColorGreen())

    -- Create and show the countdown HUD.
    local hud = ProtHUD:new(playerNum)
    hud:initialise()
    hud:instantiate()
    hud:addToUIManager()

    local startTime  = nil   -- nil until player moves/attacks
    local lastSecond = -1
    local done       = false

    local function stopProtection()
        if done then return end
        done = true
        hud.active = false
        hud:setVisible(false)
        hud:removeFromUIManager()
        player:setZombiesDontAttack(false)
        player:setOutlineHighlight(false)
        HaloTextHelper.addText(player, getText("IGUI_BusStop_prot_end"), "", HaloTextHelper.getColorRed())
    end

    local updateFn
    updateFn = function(p)
        if p ~= player then return end
        if done then
            Events.OnPlayerUpdate.Remove(updateFn)
            return
        end

        -- Keep the outline pulsing while protected.
        player:setOutlineHighlight(true)
        player:setOutlineHighlightCol(1, 1, 1, 0.25)

        -- Start the countdown the moment the player acts.
        if not startTime then
            if p:isPlayerMoving() or p:isAttackStarted() then
                startTime = getTimestampMs()
                hud.active = true
            end
            return
        end

        -- Update the HUD once per second.
        local elapsed = getTimestampMs() - startTime
        local secsLeft = math.max(0, math.ceil((PROTECTION_MS - elapsed) / 1000))
        if secsLeft ~= lastSecond then
            lastSecond     = secsLeft
            hud.secsLeft   = secsLeft
        end

        -- End protection after timeout.
        if elapsed >= PROTECTION_MS then
            Events.OnPlayerUpdate.Remove(updateFn)
            stopProtection()
        end
    end

    Events.OnPlayerUpdate.Add(updateFn)
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
    -- Ignore if a transition is already running.
    if BusStopTransition._active then return end
    BusStopTransition._active = true

    -- Create and show the overlay.
    local overlay = FadeOverlay:new()
    overlay:initialise()
    overlay:instantiate()
    overlay:addToUIManager()

    local gameTime   = getGameTime()
    local elapsed    = 0
    local teleported = false

    -- Play bus-arriving sound immediately.
    local p = getPlayer()
    if p then
        playSound(p, SND_ARRIVE)
    end

    local tickFn
    tickFn = function()
        elapsed = elapsed + gameTime:getRealworldSecondsSinceLastUpdate()

        if elapsed < FADE_IN_S then
            -- Phase 1: fade to black.
            overlay.alpha = elapsed / FADE_IN_S

        elseif elapsed < FADE_IN_S + BLACK_S then
            -- Phase 2: hold black + teleport once at the midpoint.
            overlay.alpha = 1
            if not teleported then
                teleported = true
                local player = getPlayer()
                if player then
                    local x = destX + 0.5
                    local y = destY + 0.5
                    local z = destZ
                    player:setX(x); player:setLastX(x)
                    player:setY(y); player:setLastY(y)
                    player:setZ(z); player:setLastZ(z)
                    playSound(player, SND_DEPART)
                    startArrivalProtection(player)
                end
            end

        elseif elapsed < FADE_IN_S + BLACK_S + FADE_OUT_S then
            -- Phase 3: fade back from black.
            local t = (elapsed - FADE_IN_S - BLACK_S) / FADE_OUT_S
            overlay.alpha = 1 - t

        else
            -- Done.
            overlay.alpha = 0
            overlay:setVisible(false)
            overlay:removeFromUIManager()
            Events.OnTickEvenPaused.Remove(tickFn)
            BusStopTransition._active = false
        end
    end

    Events.OnTickEvenPaused.Add(tickFn)
end
