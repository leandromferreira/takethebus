-- BusStopUI.lua
-- Player travel panel: destinations, remember-return toggle, return button.

require "BusStopShared"

BusStopUI = BusStopUI or {}

local MODULE = "BusStop"

-- ── Resolution helpers ────────────────────────────────────────────────────────

local function px(n) return math.floor(n) end

local function panelWidth()
    local sw = getCore():getScreenWidth()
    return math.max(px(280), math.min(px(420), math.floor(sw * 0.22)))
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function findStopById(id)
    for _, s in ipairs(BusStop.activeStops) do
        if s.id == id then return s end
    end
    return nil
end

local function validReturn(currentStop)
    local r = BusStop.returnStop
    if not r then return nil end
    if r.id == currentStop.id then return nil end
    if not currentStop.rememberreturn then return nil end
    local live = findStopById(r.id)
    if live and live.available then return live end
    return nil
end

-- Trim text to maxW pixels, appending "…" if needed.
local function trimText(font, text, maxW)
    local tm = getTextManager()
    if tm:MeasureStringX(font, text) <= maxW then return text end
    local ell = "\xe2\x80\xa6"  -- UTF-8 ellipsis
    while #text > 0 and (tm:MeasureStringX(font, text) + tm:MeasureStringX(font, ell)) > maxW do
        text = text:sub(1, #text - 1)
    end
    return text .. ell
end

-- ── ISPanel subclass ──────────────────────────────────────────────────────────

local TravelPanel = ISPanel:derive("BusStopTravelPanel")

function TravelPanel:new(player, stopObj)
    local ROW_H   = px(36)
    local PADDING = px(10)
    local TITLE_H = px(44)
    local PANEL_W = panelWidth()

    local stopData    = stopObj:getModData()
    local currentStop = findStopById(stopData.stopId)
    local dests       = {}
    for _, s in ipairs(BusStop.activeStops) do
        if s.id ~= stopData.stopId and s.available then
            table.insert(dests, s)
        end
    end

    local returnDest = currentStop and validReturn(currentStop) or nil

    local CLOSE_SZ = px(24)  -- X button size
    local destRows = math.max(1, #dests)
    local totalH   = TITLE_H
                   + (returnDest and (ROW_H + PADDING) or 0)
                   + (destRows * (ROW_H + PADDING))
                   + PADDING

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    -- Clamp height so panel never overflows the screen.
    totalH = math.min(totalH, sh - px(40))

    local o               = ISPanel.new(self,
        math.floor((sw - PANEL_W) / 2),
        math.max(px(20), math.floor((sh - totalH) / 2)),
        PANEL_W, totalH)
    o.player          = player
    o.stopObj         = stopObj
    o.stopData        = stopData
    o.currentStop     = currentStop
    o.dests           = dests
    o.returnDest      = returnDest
    o.moveWithMouse   = true
    o._ROW_H          = ROW_H
    o._PADDING        = PADDING
    o._TITLE_H        = TITLE_H
    o._PANEL_W        = PANEL_W
    o._CLOSE_SZ       = CLOSE_SZ
    return o
end

function TravelPanel:createChildren()
    ISPanel.createChildren(self)

    local ROW_H   = self._ROW_H
    local PADDING = self._PADDING
    local TITLE_H = self._TITLE_H
    local PANEL_W = self._PANEL_W
    local CLOSE_SZ = self._CLOSE_SZ
    local PRICE_W = px(95)

    -- X close button — top-right corner.
    local xBtn = ISButton:new(PANEL_W - CLOSE_SZ - px(4), px(4), CLOSE_SZ, CLOSE_SZ,
        "X", self, self.close)
    xBtn:initialise(); xBtn:instantiate()
    self:addChild(xBtn)

    local tm       = getTextManager()
    local fontSmH  = tm:getFontHeight(UIFont.Small)
    local fontMedH = tm:getFontHeight(UIFont.Medium)

    -- Title is drawn in render() to avoid ISLabel coordinate ambiguity.
    self._titleText = BusStop.getText("ui_title", self.stopData.name or "")
    self._titleY    = math.floor((TITLE_H - fontMedH) / 2)

    local yOff = TITLE_H

    -- Return button.
    if self.returnDest then
        local rd     = self.returnDest
        local btnLbl = trimText(UIFont.Small, BusStop.getText("ui_return_to", rd.displayname), PANEL_W - PADDING * 2 - px(4))
        local retBtn = ISButton:new(PADDING, yOff, PANEL_W - PADDING * 2, ROW_H, btnLbl, self, self.onReturnClick)
        retBtn:initialise(); retBtn:instantiate()
        retBtn.backgroundColor = { r=0.35, g=0.25, b=0.05, a=0.95 }
        self:addChild(retBtn)
        yOff = yOff + ROW_H + PADDING
    end

    local px_player = self.player:getX()
    local py_player = self.player:getY()
    local btnW      = PANEL_W - PADDING * 2 - PRICE_W - px(6)

    -- ISLabel children don't honour parent-relative coords in B42; store
    -- all text-only labels for drawText in render() instead.
    self._drawLabels = {}

    -- Destination rows.
    if #self.dests == 0 then
        local noY = yOff + math.floor((ROW_H - fontSmH) / 2)
        table.insert(self._drawLabels, { text = BusStop.getText("ui_no_destinations"),
            x = PADDING, y = noY, r=0.7, g=0.7, b=0.7 })
        yOff = yOff + ROW_H + PADDING
    else
        for _, dest in ipairs(self.dests) do
            local priceStr = BusStop.priceLabel(px_player, py_player, dest)
            local nameStr  = trimText(UIFont.Small, dest.displayname, btnW - PADDING * 2)

            local btn = ISButton:new(PADDING, yOff, btnW, ROW_H, nameStr, self, self.onTravelClick)
            btn.destId = dest.id
            btn:initialise(); btn:instantiate()
            self:addChild(btn)

            -- Price: right-aligned, stored for drawText in render().
            local pW = tm:MeasureStringX(UIFont.Small, priceStr)
            local pX = PANEL_W - PADDING - pW
            local pY = yOff + math.floor((ROW_H - fontSmH) / 2)
            table.insert(self._drawLabels, { text = priceStr,
                x = pX, y = pY, r=1, g=0.85, b=0.2 })

            yOff = yOff + ROW_H + PADDING
        end
    end


end

-- Recentre when resolution changes.
function TravelPanel:onResolutionChange(ow, oh, nw, nh)
    local PANEL_W = panelWidth()
    self:setWidth(PANEL_W)
    self:setX(math.floor((nw - PANEL_W) / 2))
    self:setY(math.max(px(20), math.floor((nh - self.height) / 2)))
    self._PANEL_W = PANEL_W
end

-- ── Travel ────────────────────────────────────────────────────────────────────

function TravelPanel:_travel(destId, isReturn)
    local sq   = self.stopObj:getSquare()
    local dest = findStopById(destId)
    if dest and dest.rememberreturn then
        BusStop.returnStop = self.currentStop
    end
    sendClientCommand(MODULE, "RequestTravel", {
        stopId        = self.stopData.stopId,
        destinationId = destId,
        x             = sq:getX(),
        y             = sq:getY(),
        z             = sq:getZ(),
        isReturn      = isReturn or false,
    })
    self:close()
end

function TravelPanel:onTravelClick(button)
    self:_travel(button.destId, false)
end


function TravelPanel:onReturnClick()
    if self.returnDest then
        self:_travel(self.returnDest.id, true)
    end
end

-- ── Misc ──────────────────────────────────────────────────────────────────────

function TravelPanel:close()
    self:setVisible(false)
    self:removeFromUIManager()
    BusStopUI._current = nil
end

function TravelPanel:render()
    ISPanel.render(self)
    if self._titleText then
        self:drawText(self._titleText, self._PADDING, self._titleY or 8, 1, 1, 1, 1, UIFont.Medium)
    end
    for _, lbl in ipairs(self._drawLabels or {}) do
        self:drawText(lbl.text, lbl.x, lbl.y, lbl.r, lbl.g, lbl.b, 1, UIFont.Small)
    end
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 1, 1, 1)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BusStopUI.open(player, stopObj)
    if BusStopUI._current then
        BusStopUI._current:close()
    end
    local panel = TravelPanel:new(player, stopObj)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    BusStopUI._current = panel
end
