-- BusStopUI.lua
-- Player travel panel: select destination then confirm travel.

require "BusStopShared"

BusStopUI = BusStopUI or {}

local MODULE = "BusStop"

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function px(n) return math.floor(n) end

local function panelWidth()
    local sw = getCore():getScreenWidth()
    return math.max(px(300), math.min(px(440), math.floor(sw * 0.24)))
end

local function findStopById(id)
    for _, s in ipairs(BusStop.activeStops) do
        if s.id == id then return s end
    end
    return nil
end

local function validReturn(currentStop)
    local r = BusStop.returnStop
    if not r then return nil, nil end
    if r.id == currentStop.id then return nil, nil end
    if not currentStop.rememberreturn then return nil, nil end
    local expiry = BusStop.returnExpiry
    if expiry then
        local gt = getGameTime()
        if gt and gt:getWorldAgeHours() >= expiry then
            BusStop.returnStop   = nil
            BusStop.returnExpiry = nil
            return nil, nil
        end
    end
    local hoursLeft = nil
    if expiry then
        local gt = getGameTime()
        if gt then hoursLeft = math.max(0, math.floor(expiry - gt:getWorldAgeHours())) end
    end
    -- Return trips ignore the origin's `available` flag: the player literally
    -- just came from there, and the server already exempts return travel from
    -- the availability check (see handleRequestTravel). `live` still being nil
    -- (origin deleted) correctly hides the button — the server would reject it.
    local live = findStopById(r.id)
    if live then return live, hoursLeft end
    return nil, nil
end

local function hoursLabel(h)
    if not h then return nil end
    if h < 1 then return "<1h" end
    return tostring(h) .. "h"
end

local function trimText(font, text, maxW)
    local tm = getTextManager()
    if tm:MeasureStringX(font, text) <= maxW then return text end
    local ell = "\xe2\x80\xa6"
    while #text > 0 and (tm:MeasureStringX(font, text) + tm:MeasureStringX(font, ell)) > maxW do
        text = text:sub(1, #text - 1)
    end
    return text .. ell
end

local function formatPrice(price)
    if price <= 0 then return BusStop.getText("ui_free_label") end
    if BusStopEconomy and BusStopEconomy.formatLabel then
        return BusStopEconomy.formatLabel(price)
    end
    local sv = SandboxVars.BusStop or {}
    local it = sv.CurrencyItem or "Base.Money"
    return tostring(price) .. "x " .. (it:match("%.(.+)$") or it)
end

-- ── ISPanel subclass ──────────────────────────────────────────────────────────

local TravelPanel = ISPanel:derive("BusStopTravelPanel")

local ROW_H    = px(36)
local PADDING  = px(10)
local TITLE_H  = px(44)
local SEARCH_H = px(28)
local CLOSE_SZ = px(24)
local INFO_H   = px(22)
local BTN_H    = px(40)

function TravelPanel:new(player, stop)
    local PANEL_W = panelWidth()
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()

    -- `stop` is the synced registry entry (BusStop.activeStops), not a physical
    -- world object — usage no longer depends on the tile being spawned.
    local currentStop = stop

    local allDests = {}
    for _, s in ipairs(BusStop.activeStops) do
        if s.id ~= stop.id and s.available then
            table.insert(allDests, s)
        end
    end

    local returnDest, returnHours = nil, nil
    if currentStop then
        returnDest, returnHours = validReturn(currentStop)
    end

    local sv          = SandboxVars.BusStop or {}
    local randomPrice = sv.RandomTripPrice or 0
    local hasRandom   = #allDests > 0 and sv.EnableRandomTrip ~= false

    -- Fixed regions (top + bottom)
    local fixedH = TITLE_H
                 + (returnDest and (ROW_H + PADDING) or 0)
                 + (hasRandom  and (ROW_H + PADDING) or 0)
                 + SEARCH_H + PADDING
                 + PADDING              -- gap above info/button
                 + INFO_H + px(4)      -- selected stop info line
                 + BTN_H + PADDING     -- travel confirm button + bottom pad

    -- List height: up to 55% screen, min 80px
    local maxListH = math.max(px(80), math.min(
        math.floor(sh * 0.50),
        sh - fixedH - px(40)))
    local idealH = math.max(1, #allDests) * (ROW_H + 2)
    local listH  = math.max(px(80), math.min(idealH, maxListH))

    local totalH = math.min(fixedH + listH, sh - px(40))

    local o = ISPanel.new(self,
        math.floor((sw - PANEL_W) / 2),
        math.max(px(20), math.floor((sh - totalH) / 2)),
        PANEL_W, totalH)
    o.player           = player
    o.stop             = stop
    o.stopId           = stop.id
    o.currentStop      = currentStop
    o.allDests         = allDests
    o.returnDest       = returnDest
    o.returnHours      = returnHours
    o.hasRandom        = hasRandom
    o.randomPrice      = randomPrice
    o._PANEL_W         = PANEL_W
    o._listH           = listH
    o._lastSearch      = ""
    o._selectedDestId  = nil
    o._selectedName    = nil
    o._selectedPrice   = nil
    o.moveWithMouse    = true
    return o
end

function TravelPanel:createChildren()
    ISPanel.createChildren(self)

    local PANEL_W = self._PANEL_W
    local listH   = self._listH
    local tm      = getTextManager()

    -- X close button
    local xBtn = ISButton:new(PANEL_W - CLOSE_SZ - px(4), px(4), CLOSE_SZ, CLOSE_SZ,
        "X", self, self.close)
    xBtn:initialise(); xBtn:instantiate()
    self:addChild(xBtn)

    self._titleText = BusStop.getText("ui_title", self.stop.displayname or "")
    self._titleY    = math.floor((TITLE_H - tm:getFontHeight(UIFont.Medium)) / 2)

    local yOff = TITLE_H

    -- Return button
    if self.returnDest then
        local rd  = self.returnDest
        local hl  = hoursLabel(self.returnHours)
        local lbl = hl
            and trimText(UIFont.Small, BusStop.getText("ui_return_expires", rd.displayname, hl), PANEL_W - PADDING * 2 - px(4))
            or  trimText(UIFont.Small, BusStop.getText("ui_return_to",      rd.displayname),     PANEL_W - PADDING * 2 - px(4))
        local retBtn = ISButton:new(PADDING, yOff, PANEL_W - PADDING * 2, ROW_H,
            lbl, self, self.onReturnClick)
        retBtn:initialise(); retBtn:instantiate()
        retBtn.backgroundColor = { r=0.35, g=0.25, b=0.05, a=0.95 }
        self:addChild(retBtn)
        yOff = yOff + ROW_H + PADDING
    end

    -- Random Trip button
    if self.hasRandom then
        local priceStr  = formatPrice(self.randomPrice)
        local randomLbl = BusStop.getText("ui_random_trip") .. "  [" .. priceStr .. "]"
        local randBtn   = ISButton:new(PADDING, yOff, PANEL_W - PADDING * 2, ROW_H,
            randomLbl, self, self.onRandomClick)
        randBtn:initialise(); randBtn:instantiate()
        randBtn.backgroundColor = { r=0.08, g=0.18, b=0.38, a=0.95 }
        self:addChild(randBtn)
        yOff = yOff + ROW_H + PADDING
    end

    -- Search bar (plain text entry, no placeholder — setEmptyString not available)
    local entry = ISTextEntryBox:new("", PADDING, yOff, PANEL_W - PADDING * 2, SEARCH_H)
    entry:initialise(); entry:instantiate()
    self._searchEntry = entry
    self:addChild(entry)
    yOff = yOff + SEARCH_H + PADDING

    -- Scrollable destination list
    local listW = PANEL_W - PADDING * 2
    local list  = ISScrollingListBox:new(PADDING, yOff, listW, listH)
    list.font       = UIFont.Small
    list.itemheight = ROW_H
    list.drawBorder = true
    list:initialise(); list:instantiate()

    local panel = self

    -- Row rendering: name left, price right, highlight on selection
    function list:doDrawItem(y, item, alt)
        local data = item.item
        local sbw  = self.vscroll and self.vscroll.width or 0
        local w    = self.width - sbw

        if self.selected == item.index then
            self:drawRect(0, y, w, item.height, 0.6, 0.25, 0.55, 0.15)
        elseif alt then
            self:drawRect(0, y, w, item.height, 0.05, 0.12, 0.12, 0.12)
        end

        local tm2  = getTextManager()
        local pStr = data.priceStr or ""
        local pW   = tm2:MeasureStringX(UIFont.Small, pStr)
        local nameMaxW = math.max(10, w - pW - px(20))
        local nameStr  = trimText(UIFont.Small, data.name or "", nameMaxW)

        local nr, ng, nb = 1, 1, 1
        if self.selected == item.index then nr, ng, nb = 1, 1, 0.5 end

        self:drawText(nameStr, px(8), y + px(10), nr, ng, nb, 1, UIFont.Small)
        if pStr ~= "" then
            self:drawText(pStr, w - pW - px(6), y + px(10), 1, 0.85, 0.2, 1, UIFont.Small)
        end
        return y + item.height
    end

    -- Click selects and updates the travel button — does NOT travel immediately
    function list:onMouseDown(x, y)
        ISScrollingListBox.onMouseDown(self, x, y)
        local item = self.items and self.items[self.selected]
        if item and item.item and item.item.destId then
            panel._selectedDestId = item.item.destId
            panel._selectedName   = item.item.name
            panel._selectedPrice  = item.item.priceStr
        else
            panel._selectedDestId = nil
            panel._selectedName   = nil
            panel._selectedPrice  = nil
        end
        panel:_updateTravelBtn()
    end

    self._list = list
    self:addChild(list)
    yOff = yOff + listH

    -- Info + travel button area
    yOff = yOff + PADDING
    self._infoY  = yOff
    self._infoW  = PANEL_W - PADDING * 2
    yOff = yOff + INFO_H + px(4)

    local travelBtn = ISButton:new(PADDING, yOff, PANEL_W - PADDING * 2, BTN_H,
        BusStop.getText("ui_select_hint"), self, self.onTravelBtnClick)
    travelBtn:initialise(); travelBtn:instantiate()
    travelBtn.backgroundColor = { r=0.12, g=0.12, b=0.12, a=0.9 }
    self._travelBtn = travelBtn
    self:addChild(travelBtn)

    self:_filterList("")
    self:_updateTravelBtn()
end

-- ── Selection + search ────────────────────────────────────────────────────────

function TravelPanel:_updateTravelBtn()
    local btn = self._travelBtn
    if not btn then return end
    if self._selectedDestId then
        local lbl = BusStop.getText("ui_travel_to", self._selectedName or "")
        btn:setTitle(lbl)
        btn.backgroundColor = { r=0.1, g=0.38, b=0.1, a=0.95 }
    else
        btn:setTitle(BusStop.getText("ui_select_hint"))
        btn.backgroundColor = { r=0.12, g=0.12, b=0.12, a=0.9 }
    end
end

function TravelPanel:update()
    ISPanel.update(self)
    if not self._searchEntry then return end
    local cur = self._searchEntry:getText() or ""
    if cur ~= self._lastSearch then
        self._lastSearch = cur
        self:_filterList(cur)
    end
end

function TravelPanel:_filterList(filter)
    local list = self._list
    if not list then return end
    local lf   = string.lower(filter or "")
    local px_p = self.player:getX()
    local py_p = self.player:getY()
    list:clear()
    local count = 0
    local selStillVisible = false
    for _, dest in ipairs(self.allDests) do
        local name = dest.displayname or ""
        if lf == "" or string.find(string.lower(name), lf, 1, true) then
            local priceStr = BusStop.priceLabel(px_p, py_p, dest)
            list:addItem(name, { name = name, destId = dest.id, priceStr = priceStr })
            if dest.id == self._selectedDestId then selStillVisible = true end
            count = count + 1
        end
    end
    if count == 0 then
        list:addItem("", { name = BusStop.getText("ui_no_destinations"), destId = nil, priceStr = "" })
    end
    -- Clear selection if it's no longer visible in filtered results
    if not selStillVisible and self._selectedDestId then
        self._selectedDestId = nil
        self._selectedName   = nil
        self._selectedPrice  = nil
        self:_updateTravelBtn()
    end
end

function TravelPanel:onResolutionChange(ow, oh, nw, nh)
    local PANEL_W = panelWidth()
    self:setWidth(PANEL_W)
    self:setX(math.floor((nw - PANEL_W) / 2))
    self:setY(math.max(px(20), math.floor((nh - self.height) / 2)))
    self._PANEL_W = PANEL_W
end

-- ── Travel ────────────────────────────────────────────────────────────────────

function TravelPanel:onTravelBtnClick()
    if self._selectedDestId then
        self:_travel(self._selectedDestId, false)
    end
end

function TravelPanel:_travel(destId, isReturn)
    local dest = findStopById(destId)

    if isReturn then
        BusStop.returnStop   = nil
        BusStop.returnExpiry = nil
    elseif dest and dest.rememberreturn then
        BusStop.returnStop = self.currentStop
    end

    -- Origin coordinates come straight from the registry entry; the server
    -- re-validates proximity against its own copy, so these are advisory only.
    sendClientCommand(MODULE, "RequestTravel", {
        stopId        = self.stopId,
        destinationId = destId,
        x             = self.stop.x,
        y             = self.stop.y,
        z             = self.stop.z,
        isReturn      = isReturn or false,
    })
    self:close()
end

function TravelPanel:_travelRandom()
    sendClientCommand(MODULE, "RequestTravel", {
        stopId   = self.stopId,
        x        = self.stop.x,
        y        = self.stop.y,
        z        = self.stop.z,
        isRandom = true,
    })
    self:close()
end

function TravelPanel:onReturnClick()
    if self.returnDest then
        self:_travel(self.returnDest.id, true)
    end
end

function TravelPanel:onRandomClick()
    self:_travelRandom()
end

-- ── Misc ──────────────────────────────────────────────────────────────────────

function TravelPanel:close()
    self:setVisible(false)
    self:removeFromUIManager()
    BusStopUI._current = nil
end

function TravelPanel:render()
    ISPanel.render(self)

    local tm = getTextManager()

    if self._titleText then
        self:drawText(self._titleText, PADDING, self._titleY or 8, 1, 1, 1, 1, UIFont.Medium)
    end

    -- Info line above travel button
    if self._infoY then
        local info, r, g, b
        if self._selectedName then
            info = self._selectedName .. "  —  " .. (self._selectedPrice or "")
            r, g, b = 1, 1, 0.5
        else
            info = BusStop.getText("ui_search_label")
            r, g, b = 0.5, 0.5, 0.5
        end
        local tw   = tm:MeasureStringX(UIFont.Small, info)
        local maxW = self._infoW or (self.width - PADDING * 2)
        if tw > maxW then info = trimText(UIFont.Small, info, maxW) end
        self:drawText(info, PADDING, self._infoY, r, g, b, 1, UIFont.Small)
    end

    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 1, 1, 1)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BusStopUI.open(player, stop)
    if BusStopUI._current then
        BusStopUI._current:close()
    end
    local panel = TravelPanel:new(player, stop)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    BusStopUI._current = panel
end
