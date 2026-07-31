-- BusStopAdminUI.lua
-- Admin panel for editing bus stop destination properties.

require "BusStopShared"

BusStopAdminUI = BusStopAdminUI or {}

local MODULE = "BusStop"

-- ── Resolution helpers ────────────────────────────────────────────────────────

local function px(n) return math.floor(n) end

local function trimText(font, text, maxW)
    local tm = getTextManager()
    if tm:MeasureStringX(font, text) <= maxW then return text end
    local ell = "\xe2\x80\xa6"
    while #text > 0 and (tm:MeasureStringX(font, text) + tm:MeasureStringX(font, ell)) > maxW do
        text = text:sub(1, #text - 1)
    end
    return text .. ell
end

-- Tooltip keys map — resolved via getText() inside buildLayout() so the
-- correct language is used at the moment the panel opens.
local TIP_KEYS = {
    name     = "tip_name",    coords   = "tip_coords",  mult     = "tip_mult",
    free     = "tip_free",    fixed    = "tip_fixed",   dynamic  = "tip_dynamic",
    availYes = "tip_avail_yes", availNo = "tip_avail_no",
    rrYes    = "tip_rr_yes",  rrNo     = "tip_rr_no",
    save     = "tip_save",    delete   = "tip_delete",  goto_btn = "tip_goto",
}

-- ── ISPanel subclass ──────────────────────────────────────────────────────────

local AdminPanel = ISPanel:derive("BusStopAdminPanel")

function AdminPanel:new()
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()

    -- 62% of screen width / 70% of screen height, clamped min/max.
    local W = math.max(px(560), math.min(px(800), math.floor(sw * 0.62)))
    local H = math.max(px(380), math.min(px(540), math.floor(sh * 0.70)))

    local o = ISPanel.new(self,
        math.floor((sw - W) / 2),
        math.max(px(20), math.floor((sh - H) / 2)),
        W, H)
    o.moveWithMouse  = true
    o.selected       = nil
    o.selectedId     = nil
    o._rebuildCooldown = 0
    o._prevW, o._prevH = W, H
    return o
end

-- ── Layout builder ────────────────────────────────────────────────────────────
-- All metrics are derived from self.width / self.height so the layout is
-- correct after any resize. Called from createChildren() and prerender().

function AdminPanel:buildLayout()
    -- Remove all existing children before rebuilding.
    for _, child in ipairs(self:getChildren() or {}) do
        self:removeChild(child)
    end

    local W        = self.width
    local H        = self.height
    local PADDING  = px(10)
    local HEADER_H = px(36)
    local FOOTER_H = px(48)
    local ROW_H    = px(28)
    local GAP      = px(6)

    -- List occupies 29% of panel width.
    local LIST_W  = math.max(px(160), math.floor(W * 0.29))
    local SEP_X   = LIST_W + PADDING
    local FORM_X  = SEP_X + px(12)
    local FORM_W  = W - FORM_X - PADDING

    -- Label column: 36% of form area, field column gets the rest.
    local LABEL_W = math.floor(FORM_W * 0.36)
    local FIELD_X = FORM_X + LABEL_W + GAP
    local FIELD_W = W - FIELD_X - PADDING

    -- Store for render().
    self._sepX    = SEP_X
    self._headerH = HEADER_H
    self._footerH = FOOTER_H
    self._padding = PADDING

    local tm       = getTextManager()
    local fontSmH  = tm:getFontHeight(UIFont.Small)
    local fontMedH = tm:getFontHeight(UIFont.Medium)

    -- Title is drawn in render() to avoid ISLabel coordinate ambiguity.
    self._titleText = BusStop.getText("adm_title")
    self._titleY    = math.floor((HEADER_H - fontMedH) / 2)
    self._fontMedH  = fontMedH

    -- ── Tooltip regions — list of { x,y,w,h, lines={} } ──
    -- getText() is called here (not at module load) so the active language is used.
    self._tooltipRegions = {}
    local function addTip(x, y, w, h, tipKey)
        local key  = TIP_KEYS[tipKey] or tipKey
        local text = BusStop.getText(key)
        local lines = {}
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(lines, line)
        end
        table.insert(self._tooltipRegions, { x=x, y=y, w=w, h=h, lines=lines })
    end

    -- ── Stop list ──
    self.stopList = ISScrollingListBox:new(PADDING, HEADER_H, LIST_W, H - HEADER_H - FOOTER_H - PADDING)
    self.stopList:initialise()
    self.stopList:instantiate()
    self.stopList.font = UIFont.Small
    self.stopList:setOnMouseDownFunction(self, AdminPanel.onSelectStop)
    self:addChild(self.stopList)

    -- ── Edit form ──
    local labelGap = px(8)

    self._labels = {}
    local function addLabel(text, yOff)
        local tw   = tm:MeasureStringX(UIFont.Small, text)
        local lblX = FIELD_X - tw - labelGap
        local lblY = yOff + math.floor((ROW_H - fontSmH) / 2)
        table.insert(self._labels, { text = text, x = lblX, y = lblY })
    end

    local function addRow(labelText, fieldName, yOff, isNumber, tipKey)
        addLabel(labelText, yOff)
        local field = ISTextEntryBox:new("", FIELD_X, yOff, FIELD_W, ROW_H)
        field:initialise(); field:instantiate()
        field.isNumber  = isNumber
        self[fieldName] = field
        self:addChild(field)
        -- Tooltip covers full row width (label + field).
        if tipKey then addTip(FORM_X, yOff, W - FORM_X - PADDING, ROW_H, tipKey) end
        return yOff + ROW_H + PADDING
    end

    local y = HEADER_H + PADDING
    y = addRow(BusStop.getText("adm_displayname"), "fieldName", y, false, "name")

    -- Coordinates: read-only, shown inline as text (not editable fields).
    addLabel(BusStop.getText("adm_coords"), y)
    self._coordY    = y + math.floor((ROW_H - fontSmH) / 2)
    self._coordX    = FIELD_X
    self._coordStr  = ""
    addTip(FORM_X, y, W - FORM_X - PADDING, ROW_H, "coords")
    y = y + ROW_H + PADDING

    y = addRow(BusStop.getText("adm_multiplier"),  "fieldMult", y, true, "mult")

    -- Price type — 3 equal buttons.
    addLabel(BusStop.getText("adm_pricetype"), y)
    local bW    = math.floor((FIELD_W - GAP * 2) / 3)
    local bRem  = FIELD_W - GAP * 2 - bW * 3   -- rounding remainder → last button
    self.btnFree    = self:makePriceBtn(BusStop.getText("adm_price_free"),    "free",    FIELD_X,                  y, bW)
    self.btnFixed   = self:makePriceBtn(BusStop.getText("adm_price_fixed"),   "fixed",   FIELD_X + bW + GAP,       y, bW)
    self.btnDynamic = self:makePriceBtn(BusStop.getText("adm_price_dynamic"), "dynamic", FIELD_X + (bW + GAP) * 2, y, bW + bRem)
    addTip(FIELD_X,                  y, bW,       ROW_H, "free")
    addTip(FIELD_X + bW + GAP,       y, bW,       ROW_H, "fixed")
    addTip(FIELD_X + (bW + GAP) * 2, y, bW + bRem, ROW_H, "dynamic")
    y = y + ROW_H + PADDING

    -- Available — 2 equal buttons.
    addLabel(BusStop.getText("adm_available"), y)
    local halfW = math.floor((FIELD_W - GAP) / 2)
    self.btnAvailYes = self:makeToggleBtn(BusStop.getText("adm_yes"), true,  FIELD_X,               y, halfW)
    self.btnAvailNo  = self:makeToggleBtn(BusStop.getText("adm_no"),  false, FIELD_X + halfW + GAP, y, FIELD_W - halfW - GAP)
    addTip(FIELD_X,               y, halfW,                    ROW_H, "availYes")
    addTip(FIELD_X + halfW + GAP, y, FIELD_W - halfW - GAP,    ROW_H, "availNo")
    y = y + ROW_H + PADDING

    -- Remember-return — 2 equal buttons.
    addLabel(BusStop.getText("adm_remember_return"), y)
    self.btnRRYes = self:makeRRBtn(BusStop.getText("adm_yes"), true,  FIELD_X,               y, halfW)
    self.btnRRNo  = self:makeRRBtn(BusStop.getText("adm_no"),  false, FIELD_X + halfW + GAP, y, FIELD_W - halfW - GAP)
    addTip(FIELD_X,               y, halfW,                    ROW_H, "rrYes")
    addTip(FIELD_X + halfW + GAP, y, FIELD_W - halfW - GAP,    ROW_H, "rrNo")
    y = y + ROW_H + PADDING

    -- ── Footer — 3 buttons distributed across the form area ──
    local footerY  = H - FOOTER_H + PADDING
    local formW    = W - FORM_X - PADDING
    local btnGap   = GAP
    local bW3      = math.floor((formW - btnGap * 2) / 3)

    self.btnSave = ISButton:new(FORM_X, footerY, bW3, ROW_H,
        BusStop.getText("adm_save"), self, self.onSave)
    self.btnSave:initialise(); self.btnSave:instantiate(); self:addChild(self.btnSave)
    addTip(FORM_X, footerY, bW3, ROW_H, "save")

    self.btnDelete = ISButton:new(FORM_X + bW3 + btnGap, footerY, bW3, ROW_H,
        BusStop.getText("adm_delete"), self, self.onDelete)
    self.btnDelete:initialise(); self.btnDelete:instantiate(); self:addChild(self.btnDelete)
    addTip(FORM_X + bW3 + btnGap, footerY, bW3, ROW_H, "delete")

    self.btnGoto = ISButton:new(FORM_X + (bW3 + btnGap) * 2, footerY, formW - (bW3 + btnGap) * 2, ROW_H,
        BusStop.getText("adm_goto"), self, self.onGoto)
    self.btnGoto:initialise(); self.btnGoto:instantiate(); self:addChild(self.btnGoto)
    addTip(FORM_X + (bW3 + btnGap) * 2, footerY, formW - (bW3 + btnGap) * 2, ROW_H, "goto_btn")

    -- X close button — top-right corner.
    local CLOSE_SZ = px(24)
    local xBtn = ISButton:new(W - CLOSE_SZ - px(4), px(4), CLOSE_SZ, CLOSE_SZ,
        "X", self, self.close)
    xBtn:initialise(); xBtn:instantiate(); self:addChild(xBtn)

    self:setFormEnabled(false)
    self:refreshList()

    -- Restore selection state after rebuild.
    if self.selectedId then
        local s = self:_findActive(self.selectedId)
        if s then self:onSelectStop(s) end
    end
end

function AdminPanel:_findActive(id)
    for _, s in ipairs(BusStop.activeStops) do
        if s.id == id then return s end
    end
    return nil
end

function AdminPanel:createChildren()
    ISPanel.createChildren(self)
    self:buildLayout()
end

-- Detect resize; rebuild after 2 stable frames (matches ProtectVehicle pattern).
function AdminPanel:prerender()
    ISPanel.prerender(self)
    local w, h = self.width, self.height
    if w ~= self._prevW or h ~= self._prevH then
        self._prevW, self._prevH = w, h
        self._rebuildCooldown = 2
    elseif self._rebuildCooldown > 0 then
        self._rebuildCooldown = self._rebuildCooldown - 1
        if self._rebuildCooldown == 0 then
            self:buildLayout()
        end
    end
    -- Refresh when a new StopList has been processed, however it arrived (real
    -- OnServerCommand, or the true-solo ModData relay poller in
    -- BusStopClient.lua, which doesn't fire this file's own OnServerCommand
    -- listener). BusStop._activeStopsVersion is bumped in BusStopClient.lua's
    -- onServerCommand every time BusStop.activeStops is reassigned.
    if BusStop._activeStopsVersion ~= self._lastStopsVersion then
        self._lastStopsVersion = BusStop._activeStopsVersion
        self:refreshList(BusStop.activeStops)
    end
end

-- ── Button factories ──────────────────────────────────────────────────────────

function AdminPanel:makePriceBtn(label, pt, x, y, w)
    local ROW_H = px(28)
    local btn = ISButton:new(x, y, w, ROW_H, label, self, function() self:onPriceType(pt) end)
    btn:initialise(); btn:instantiate(); self:addChild(btn)
    return btn
end

function AdminPanel:makeToggleBtn(label, val, x, y, w)
    local ROW_H = px(28)
    local btn = ISButton:new(x, y, w, ROW_H, label, self, function() self:onAvailable(val) end)
    btn:initialise(); btn:instantiate(); self:addChild(btn)
    return btn
end

function AdminPanel:makeRRBtn(label, val, x, y, w)
    local ROW_H = px(28)
    local btn = ISButton:new(x, y, w, ROW_H, label, self, function() self:onRememberReturn(val) end)
    btn:initialise(); btn:instantiate(); self:addChild(btn)
    return btn
end

-- ── Highlight helpers ─────────────────────────────────────────────────────────

local function hi(btn, active)
    btn.backgroundColor = active
        and { r=0.3, g=0.6, b=0.3, a=0.9 }
        or  { r=0.2, g=0.2, b=0.2, a=0.9 }
end

function AdminPanel:setPriceType(pt)
    self.priceType = pt
    hi(self.btnFree,    pt == "free")
    hi(self.btnFixed,   pt == "fixed")
    hi(self.btnDynamic, pt == "dynamic")
end

function AdminPanel:setAvailable(val)
    self.availableVal = val
    hi(self.btnAvailYes, val == true)
    hi(self.btnAvailNo,  val == false)
end

function AdminPanel:setRememberReturn(val)
    self.rememberReturnVal = val
    hi(self.btnRRYes, val == true)
    hi(self.btnRRNo,  val == false)
end

function AdminPanel:onPriceType(pt)    self:setPriceType(pt) end
function AdminPanel:onAvailable(val)   self:setAvailable(val) end
function AdminPanel:onRememberReturn(v) self:setRememberReturn(v) end

function AdminPanel:setFormEnabled(enabled)
    self.fieldName:setEditable(enabled)
    self.fieldMult:setEditable(enabled)
    for _, b in ipairs({ self.btnSave, self.btnDelete, self.btnGoto,
                         self.btnFree, self.btnFixed, self.btnDynamic,
                         self.btnAvailYes, self.btnAvailNo,
                         self.btnRRYes, self.btnRRNo }) do
        b:setEnable(enabled)
    end
end

-- ── List / selection ──────────────────────────────────────────────────────────

function AdminPanel:refreshList(stopList)
    stopList = stopList or BusStop.activeStops
    self.stopList:clear()
    for _, s in ipairs(stopList) do
        local label = trimText(UIFont.Small, s.displayname, self.stopList:getWidth() - px(16))
                   .. (s.available and "" or " [off]")
        self.stopList:addItem(label, s)
    end
end

function AdminPanel:onSelectStop(s)
    if not s then return end
    self.selected   = s
    self.selectedId = s.id
    self:setFormEnabled(true)
    self.fieldName:setText(s.displayname or "")
    self._coordStr = "X: " .. tostring(s.x or 0) .. "   Y: " .. tostring(s.y or 0) .. "   Z: " .. tostring(s.z or 0)
    self.fieldMult:setText(tostring(s.price_multiplier or 1))
    self:setPriceType(s.pricetype or "dynamic")
    self:setAvailable(s.available ~= false)
    self:setRememberReturn(s.rememberreturn == true)
end

function AdminPanel:onSave()
    if not self.selectedId then return end
    sendClientCommand(MODULE, "UpdateStop", {
        id               = self.selectedId,
        displayname      = self.fieldName:getText(),
        x                = self.selected.x or 0,
        y                = self.selected.y or 0,
        z                = self.selected.z or 0,
        pricetype        = self.priceType or "dynamic",
        price_multiplier = tonumber(self.fieldMult:getText()) or 1.0,
        available        = (self.availableVal ~= false),
        rememberreturn   = (self.rememberReturnVal == true),
    })
end

function AdminPanel:onDelete()
    if not self.selectedId then return end
    sendClientCommand(MODULE, "RemoveStop", { stopId = self.selectedId })
    -- Optimistic removal: strip from local list immediately so the UI
    -- reflects the deletion before the server's StopList response arrives.
    for i, s in ipairs(BusStop.activeStops) do
        if s.id == self.selectedId then
            table.remove(BusStop.activeStops, i)
            break
        end
    end
    self.selected   = nil
    self.selectedId = nil
    self:setFormEnabled(false)
    self:refreshList()
end

function AdminPanel:onGoto()
    if not self.selected then return end
    local s = self.selected
    require "BusStopTransition"
    BusStopTransition.play(s.x, s.y, s.z)
    self:close()
end

function AdminPanel:close()
    self:setVisible(false)
    self:removeFromUIManager()
    BusStopAdminUI._current = nil
end

-- ── Tooltip renderer ──────────────────────────────────────────────────────────

local TIP_PAD  = 6
local TIP_LPAD = 2   -- extra leading between lines

function AdminPanel:_drawTooltip(lines)
    local tm  = getTextManager()
    local fh  = tm:getFontHeight(UIFont.Small)
    local maxW = 0
    for _, line in ipairs(lines) do
        local lw = tm:MeasureStringX(UIFont.Small, line)
        if lw > maxW then maxW = lw end
    end
    local tw = maxW + TIP_PAD * 2
    local th = #lines * (fh + TIP_LPAD) + TIP_PAD * 2 - TIP_LPAD

    local mx = self:getMouseX()
    local my = self:getMouseY()
    local tx = math.min(mx + 14, self.width  - tw - 2)
    local ty = math.max(2, math.min(my - th - 4, self.height - th - 2))

    self:drawRect(tx, ty, tw, th, 0.96, 0.07, 0.07, 0.07)
    self:drawRectBorder(tx, ty, tw, th, 1, 0.75, 0.65, 0.25)
    for i, line in ipairs(lines) do
        self:drawText(line, tx + TIP_PAD, ty + TIP_PAD + (i - 1) * (fh + TIP_LPAD),
            1, 0.95, 0.82, 1, UIFont.Small)
    end
end

-- ── Render ────────────────────────────────────────────────────────────────────

function AdminPanel:render()
    ISPanel.render(self)
    local sepX    = self._sepX    or px(220)
    local headerH = self._headerH or px(36)
    local footerH = self._footerH or px(48)
    local padding = self._padding or px(10)
    -- Title text.
    if self._titleText then
        self:drawText(self._titleText, padding, self._titleY or 8, 1, 1, 1, 1, UIFont.Medium)
    end
    -- Field labels (ISLabel doesn't honour parent coords in B42).
    for _, lbl in ipairs(self._labels or {}) do
        self:drawText(lbl.text, lbl.x, lbl.y, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end
    -- Coordinates inline text.
    if self._coordStr and self._coordStr ~= "" then
        self:drawText(self._coordStr, self._coordX or 0, self._coordY or 0, 1, 1, 1, 1, UIFont.Small)
    end
    -- Vertical separator between list and form.
    self:drawRect(sepX, headerH, 1, self.height - headerH - footerH, 0.7, 0.5, 0.5, 0.5)
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 1, 1, 1)

    -- Tooltip on hover.
    if self:isMouseOver() then
        local mx = self:getMouseX()
        local my = self:getMouseY()
        for _, tip in ipairs(self._tooltipRegions or {}) do
            if mx >= tip.x and mx <= tip.x + tip.w
            and my >= tip.y and my <= tip.y + tip.h then
                self:_drawTooltip(tip.lines)
                break
            end
        end
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BusStopAdminUI.open()
    if BusStopAdminUI._current then
        BusStopAdminUI._current:close()
    end
    local panel = AdminPanel:new()
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    BusStopAdminUI._current = panel
end


-- ── Inject button into vanilla admin panel (F2) ───────────────────────────────

local origAdminPanelCreate = ISAdminPanelUI.create

function ISAdminPanelUI:create()
    local tm               = getTextManager()
    local FONT_HGT_SMALL   = tm:getFontHeight(UIFont.Small)
    local FONT_HGT_MEDIUM  = tm:getFontHeight(UIFont.Medium)
    local UI_BORDER_SPACING = px(10)
    local BUTTON_HGT        = FONT_HGT_SMALL + px(6)
    local btnWid            = px(200)

    self.busStopManagerBtn = ISButton:new(
        UI_BORDER_SPACING + 1,
        FONT_HGT_MEDIUM + UI_BORDER_SPACING * 2 + 1,
        btnWid, BUTTON_HGT,
        BusStop.getText("adm_title"), self, BusStopAdminUI.open)
    self.busStopManagerBtn.internal    = ""
    self.busStopManagerBtn.borderColor = self.buttonBorderColor
    self.busStopManagerBtn:initialise()
    self.busStopManagerBtn:instantiate()
    self:addChild(self.busStopManagerBtn)

    origAdminPanelCreate(self)
end
