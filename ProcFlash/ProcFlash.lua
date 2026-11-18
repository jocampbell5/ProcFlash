-- ProcFlash: no icon means there is nothing to react to. When a proc happens,
-- its icon appears where you placed it, and goes away once it's used or gone.
-- Two kinds of procs:
--   * moves that light up now and then: Overpower after the target dodges,
--     Revenge after you block, dodge or parry, Execute on a target under 20%...
--     The game already knows when these light up (the action bar uses the same
--     check), so the addon just asks it.
--   * buffs that pop on you: Clearcasting (your next spell is free), Shadow
--     Trance (your next Shadow Bolt is instant).
--
-- WoW Forever runs the Classic game on the modern client, so the spell calls
-- are the modern ones (C_Spell, C_SpellBook), and in combat some answers come
-- back "secret" (addons may pass them on but not look at them). Every answer
-- goes through Plain(), which turns a secret into nil = "don't know".
-- Placing the icons: type /procflash for the ProcFlash window (Edit Mode works too).
local ADDON, PA = ...
PA = PA or {}
_G.ProcFlash = PA

-- move = rank 1 of a move that lights up; buff = the buff's spell id.
-- The name is the English one, used if the game can't tell us its own.
local PROCS = {
    WARRIOR = {
        { move = 7384,  name = "Overpower" },      -- after the target dodges (Battle Stance)
        { move = 6572,  name = "Revenge" },        -- after you block, dodge or parry (Defensive Stance)
        { move = 5308,  name = "Execute" },        -- target under 20% health
    },
    HUNTER = {
        { move = 1495,  name = "Mongoose Bite" },  -- after the target dodges
        { move = 19306, name = "Counterattack" },  -- after you parry (Survival talent)
    },
    ROGUE = {
        { move = 14251, name = "Riposte" },        -- after you parry (Combat talent)
    },
    DRUID = {
        { buff = 16870, name = "Clearcasting" },   -- Omen of Clarity: next spell costs no mana
    },
    MAGE = {
        { buff = 12536, name = "Clearcasting" },   -- Arcane Concentration
    },
    SHAMAN = {
        { buff = 16246, name = "Clearcasting" },   -- Elemental Focus
    },
    WARLOCK = {
        { buff = 17941, name = "Shadow Trance" },  -- Nightfall: next Shadow Bolt is instant
    },
}
PA.PROCS = PROCS

local DEFAULTS = { point = { "CENTER", "CENTER", 0, -150 }, size = 48, locked = true, sound = false }
local GCD = 1.5           -- a cooldown this short is just the global cooldown
local TICK = 0.05         -- seconds between checks
local SOUND = 8959        -- the raid warning sound
local QUESTION_MARK = 134400
local unpack = unpack or table.unpack

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ProcFlash|r: " .. msg)
end

-- WoW hides addon errors unless you turn them on, so ProcFlash says them in
-- chat itself (each one once, not 20 times a second).
local reported = {}
local function Report(err)
    err = tostring(err)
    if reported[err] then return end
    reported[err] = true
    Say("|cffff5050something went wrong:|r " .. err)
end
PA.Report = Report

---The function, wrapped so an error is reported instead of hidden.
local function Safely(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then Report(err) end
    end
end

---------------------------------------------------------------------------
-- Asking the game. Each call tries the modern API first, then the old one.
---------------------------------------------------------------------------
local issecret = issecretvalue or function() return false end

---The value, or nil if the game made it secret.
local function Plain(v)
    if issecret(v) then return nil end
    return v
end
PA.Plain = Plain

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return Plain(C_Spell.GetSpellName(id)) end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        return info and Plain(info.name)
    end
    if GetSpellInfo then return Plain((GetSpellInfo(id))) end
end

local function SpellIcon(id)
    if C_Spell and C_Spell.GetSpellTexture then return Plain(C_Spell.GetSpellTexture(id)) end
    if GetSpellTexture then return Plain(GetSpellTexture(id)) end
    if GetSpellInfo then return Plain(select(3, GetSpellInfo(id))) end
end

---Every spell in your spellbook: name -> spell id (the highest rank you have,
---since ranks are listed lowest first).
local function Spellbook()
    local found = {}
    local function add(name, id)
        name, id = Plain(name), Plain(id)
        if name and id then found[name] = id end
    end
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() or 0 do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                local first = info.itemIndexOffset or 0
                for slot = first + 1, first + (info.numSpellBookItems or 0) do
                    local item = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                    if item then add(item.name, item.spellID or item.actionID) end
                end
            end
        end
    elseif GetSpellBookItemName then
        for slot = 1, 1000 do
            local name = GetSpellBookItemName(slot, "spell")
            if not name then break end
            add(name, select(2, GetSpellBookItemInfo(slot, "spell")))
        end
    end
    return found
end
PA.Spellbook = Spellbook

---The spell id to ask about if the character knows the move, else nil.
local function FindMove(proc, book, name)
    local id = book[name] or book[proc.name]
    if id then return id end
    if C_SpellBook and C_SpellBook.IsSpellKnown and Plain(C_SpellBook.IsSpellKnown(proc.move)) then return proc.move end
    if IsPlayerSpell and Plain(IsPlayerSpell(proc.move)) then return proc.move end
    if IsSpellKnown and Plain(IsSpellKnown(proc.move)) then return proc.move end
end

---true / false, or nil when the game won't say.
local function Usable(id)
    if C_Spell and C_Spell.IsSpellUsable then return Plain(C_Spell.IsSpellUsable(id)) end
    if IsUsableSpell then return Plain(IsUsableSpell(id)) end
end

local function Glowing(id)
    local f = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed or IsSpellOverlayed
    if f then return Plain(f(id)) end
end

---True when the move is waiting on its own cooldown (not just the global one).
local function OnCooldown(id, now)
    local start, duration, active, onGCD
    if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(id)
        if not cd then return false end
        start, duration = Plain(cd.startTime), Plain(cd.duration)
        active, onGCD = Plain(cd.isActive), Plain(cd.isOnGCD)
    elseif GetSpellCooldown then
        start, duration = GetSpellCooldown(id)
        start, duration = Plain(start), Plain(duration)
    end
    if onGCD then return false end
    if start and duration then
        return start > 0 and duration > GCD and start + duration > now
    end
    -- times are secret: trust isActive only when we also know it's not the GCD
    return active == true and onGCD == false
end

---false when the target is out of reach, true otherwise (also when unknown).
local function InRange(id)
    local r
    if C_Spell and C_Spell.IsSpellInRange then
        r = C_Spell.IsSpellInRange(id, "target")
    elseif IsSpellInRange then
        r = IsSpellInRange(id, "target")
    end
    r = Plain(r)
    return not (r == 0 or r == false)
end

local function HasEnemyTarget()
    local exists = UnitExists("target")
    if not issecret(exists) and not exists then return false end
    local enemy = UnitCanAttack("player", "target")
    if not issecret(enemy) and not enemy then return false end
    local dead = UnitIsDead("target")
    if not issecret(dead) and dead then return false end
    return true
end

---True if the buff is on you (matched by spell id, or by name).
local function HasBuff(proc)
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(proc.buff)
        if issecret(aura) then return true end
        if aura then return true end
    end
    -- Scanning the buff list by index is only a fallback for a buff whose id differs.
    -- In combat the client hides the list and the call errors, so stop at the first error.
    for i = 1, 40 do
        local name, spellId
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
            if not ok or not aura or issecret(aura) then return false end
            name, spellId = Plain(aura.name), Plain(aura.spellId)
        elseif UnitBuff then
            local n, _, _, _, _, _, _, _, _, sid = UnitBuff("player", i)
            if not n then return false end
            name, spellId = Plain(n), Plain(sid)
        else
            return false
        end
        if spellId == proc.buff or (name and name == proc.name) then return true end
    end
    return false
end

---Is the proc up right now?
function PA.Ready(proc, now)
    if proc.buff then return HasBuff(proc) end
    if not HasEnemyTarget() then return false end
    local usable = Usable(proc.spell)
    if usable == nil then usable = Glowing(proc.spell) end   -- the game won't say; use the button glow
    if not usable then return false end
    return not OnCooldown(proc.spell, now or GetTime())
end

---------------------------------------------------------------------------
-- The icons
---------------------------------------------------------------------------
PA.icons, PA.known = {}, {}

local anchor = CreateFrame("Frame", "ProcFlashFrame", UIParent)
PA.anchor = anchor
anchor:SetMovable(true)
anchor:SetClampedToScreen(true)
anchor:Hide()

-- the box you drag, shown only while placing it (like Edit Mode's blue boxes)
local backdrop = anchor:CreateTexture(nil, "BACKGROUND")
backdrop:SetPoint("TOPLEFT", -4, 4)
backdrop:SetPoint("BOTTOMRIGHT", 4, -4)
backdrop:SetColorTexture(0.1, 0.45, 0.9, 0.45)
local label = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
label:SetPoint("BOTTOM", anchor, "TOP", 0, 8)
PA.backdrop, PA.label = backdrop, label

-- grab it the moment the button goes down (no waiting for the game to call it a drag)
anchor:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
        self:StartMoving()
        self.dragging = true
    end
end)
anchor:SetScript("OnMouseUp", function(self)
    if not self.dragging then return end
    self.dragging = false
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    PA.db.point = { point, relativePoint, x, y }
end)
anchor:SetScript("OnHide", function(self)
    if self.dragging then self:GetScript("OnMouseUp")(self) end
end)
-- the mouse wheel over the box makes the icons bigger or smaller
anchor:SetScript("OnMouseWheel", Safely(function(_, delta) PA:SetIconSize(PA.db.size + 4 * delta) end))

local MIN_SIZE, MAX_SIZE = 16, 200

---Change the icon size (kept between 16 and 200 pixels).
function PA:SetIconSize(n)
    n = math.floor(math.max(MIN_SIZE, math.min(MAX_SIZE, n)) + 0.5)
    self.db.size = n
    if self.options then self.options:Refresh() end
    self:Update()
    return n
end

function PA:Place()
    local p = self.db.point
    anchor:ClearAllPoints()
    anchor:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

function PA:NewIcon(i)
    local b = CreateFrame("Frame", nil, anchor)
    b:EnableMouse(false)
    local edge = b:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    edge:SetColorTexture(1, 0.82, 0, 1)               -- thin gold frame
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 2, -2)
    tex:SetPoint("BOTTOMRIGHT", -2, 2)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)           -- trim the icon's own border
    b.tex = tex
    -- the proc's name under the icon, so "Revenge" says Revenge
    local name = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("TOP", b, "BOTTOM", 0, -3)
    name:SetTextColor(0.85, 0.85, 0.88)               -- silver
    b.name = name
    b:Hide()
    self.icons[i] = b
    return b
end

---Find which of this class's procs the character has and give each an icon.
---Buffs count from the start: they only show when they pop, and a character
---without the talent just never sees them.
function PA:Rebuild()
    local _, class = UnitClass("player")
    local book = Spellbook()
    local known = {}
    for _, proc in ipairs(PROCS[class] or {}) do
        local id = proc.move or proc.buff
        local name = SpellName(id) or proc.name
        local spell = proc.buff or FindMove(proc, book, name)
        if spell then
            known[#known + 1] = { move = proc.move, buff = proc.buff, spell = spell, name = name,
                                  key = proc.name:lower(), icon = SpellIcon(spell) or SpellIcon(id) or QUESTION_MARK }
        end
    end
    self.known = known
    for i, proc in ipairs(known) do
        local b = self.icons[i] or self:NewIcon(i)
        b.proc = proc
        b.tex:SetTexture(proc.icon)
    end
    for i = #known + 1, #self.icons do
        self.icons[i].proc = nil
        self.icons[i]:Hide()
    end
    if #known > 0 then anchor:Show() else anchor:Hide() end
    if self.options and self.options:IsShown() then self.options:Refresh() end
    self:Update()
end

---Placing the icons: the /procflash window or Edit Mode is open, or /procflash move.
function PA:Moving()
    return self.optionsOpen or self.editing or not self.db.locked
end

---Set the name under an icon, its letters sized to the icon (at least 10 pt).
local function NameText(fs, text, size)
    fs:SetText(text)
    if fs.size ~= size then
        fs.size = size
        local font = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
        if font then fs:SetFont(font, math.max(10, math.floor(size * 0.3 + 0.5)), "OUTLINE") end
    end
end

---Show the proc that's up, in the one spot. Procs rarely overlap; if two are up
---at once, the first in the list wins (for warriors: Overpower, Revenge, Execute).
function PA:Update()
    local db = self.db
    local moving = self:Moving()
    local size = db.size
    local now = GetTime()
    local chosen
    for _, b in ipairs(self.icons) do
        local proc = b.proc
        if proc and not chosen then
            if moving then
                chosen = b                             -- one icon to show where it goes
            elseif not db.off[proc.key] and PA.Ready(proc, now) then
                chosen = b
            end
        end
    end
    local appeared = false
    for _, b in ipairs(self.icons) do
        if b == chosen then
            b:SetSize(size, size)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
            NameText(b.name, b.proc.name, size)
            b.tex:SetDesaturated(false)
            if moving or b.proc.buff or InRange(b.proc.spell) then b.tex:SetVertexColor(1, 1, 1)
            else b.tex:SetVertexColor(1, 0.3, 0.3) end   -- red: step closer
            if not b:IsShown() then
                b:Show()
                if not moving then appeared = true end
            end
        else
            b:Hide()
        end
    end
    if appeared and db.sound and PlaySound then PlaySound(SOUND, "Master") end

    anchor:SetSize(size, size)
    anchor:EnableMouse(moving)
    anchor:EnableMouseWheel(moving)
    if moving then
        if self.optionsOpen then label:SetText("ProcFlash: drag to move, scroll to resize")
        elseif self.editing then label:SetText("ProcFlash")
        else label:SetText("ProcFlash: drag me, then type /procflash lock") end
        backdrop:Show() label:Show()
    else
        backdrop:Hide() label:Hide()
    end
end

---Names of the icons on screen right now (for tests).
function PA:Showing()
    local out = {}
    for _, b in ipairs(self.icons) do
        if b.proc and b:IsShown() then out[#out + 1] = b.proc.name end
    end
    return out
end

local elapsed = 0
anchor:SetScript("OnUpdate", Safely(function(_, dt)
    elapsed = elapsed + dt
    if elapsed < TICK then return end
    elapsed = 0
    PA:Update()
end))

-- Edit Mode (Esc > Edit Mode) shows the box to drag, like the game's own frames.
function PA:EnterEditMode()
    self.editing = true
    if self.db then self:Update() end
end

function PA:ExitEditMode()
    self.editing = false
    if self.db then
        self.db.placed = true
        self:Update()
    end
end

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("EditMode.Enter", Safely(function() PA:EnterEditMode() end))
    EventRegistry:RegisterCallback("EditMode.Exit", Safely(function() PA:ExitEditMode() end))
    PA.hasEditMode = true
end

---------------------------------------------------------------------------
-- The /procflash window. While it's open the icon box is on screen to drag
-- and resize; closing it locks the box again.
---------------------------------------------------------------------------
local DIALOG = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
local SLIDER = {
    bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 6, bottom = 6 },
}
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
local ROW = 26

local function Text(parent, font, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetText(text)
    return fs
end

local function Checkbox(parent, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb.label = Text(cb, "GameFontHighlight", "")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb:SetScript("OnClick", Safely(function(self) onClick(self, self:GetChecked() and true or false) end))
    return cb
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", Safely(onClick))
    return b
end

function PA:BuildOptions()
    local f = CreateFrame("Frame", "ProcFlashOptions", UIParent, BACKDROP_TEMPLATE)
    f:Hide()
    f:SetSize(290, 260)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if f.SetBackdrop then f:SetBackdrop(DIALOG) end
    if UISpecialFrames then table.insert(UISpecialFrames, "ProcFlashOptions") end   -- Esc closes it

    local title = Text(f, "GameFontNormalLarge", "ProcFlash")
    title:SetPoint("TOP", 0, -18)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)

    local hint = Text(f, "GameFontHighlightSmall",
        "Drag the blue box to move the icons.\nScroll over it to make them bigger or smaller.")
    hint:SetPoint("TOP", 0, -44)
    f.hint = hint

    local sizeLabel = Text(f, "GameFontNormal", "Icon size")
    sizeLabel:SetPoint("TOPLEFT", 24, -86)
    local slider = CreateFrame("Slider", "ProcFlashSizeSlider", f, BACKDROP_TEMPLATE)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(140, 17)
    slider:SetPoint("LEFT", sizeLabel, "RIGHT", 12, 0)
    if slider.SetBackdrop then slider:SetBackdrop(SLIDER) end
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetMinMaxValues(MIN_SIZE, MAX_SIZE)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetScript("OnValueChanged", Safely(function(_, value)
        if not f.refreshing then PA:SetIconSize(value) end
    end))
    local sizeValue = Text(f, "GameFontHighlight", "")
    sizeValue:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    f.slider, f.sizeValue = slider, sizeValue

    f.checks = {}
    f.sound = Checkbox(f, function(_, on) PA.db.sound = on end)
    f.sound.label:SetText("Play a sound when an icon appears")
    f.none = Text(f, "GameFontDisable", "This character has none of the procs\nProcFlash watches.")

    f.reset = Button(f, "Reset position", 120, function()
        PA.db.point, PA.db.size = { unpack(DEFAULTS.point) }, DEFAULTS.size
        PA:Place()
        PA:SetIconSize(DEFAULTS.size)
    end)
    f.reset:SetPoint("BOTTOMLEFT", 20, 18)
    f.done = Button(f, "Done", 100, function() f:Hide() end)
    f.done:SetPoint("BOTTOMRIGHT", -20, 18)

    ---Match the window to the settings and to the procs this character has.
    local function fill()
        local db = PA.db
        slider:SetValue(db.size)
        sizeValue:SetText(db.size .. " px")
        local y = -120
        for i, proc in ipairs(PA.known) do
            local cb = f.checks[i] or Checkbox(f, function(self, on)
                db.off[self.key] = (not on) or nil
                PA:Update()
            end)
            f.checks[i] = cb
            cb.key = proc.key
            cb.label:SetText("Show " .. proc.name)
            cb:SetChecked(not db.off[proc.key])
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", 20, y)
            cb:Show()
            y = y - ROW
        end
        for i = #PA.known + 1, #f.checks do f.checks[i]:Hide() end
        if #PA.known == 0 then
            f.none:ClearAllPoints()
            f.none:SetPoint("TOP", 0, y - 4)
            f.none:Show()
            y = y - 2 * ROW
        else
            f.none:Hide()
        end
        f.sound:ClearAllPoints()
        f.sound:SetPoint("TOPLEFT", 20, y - 6)
        f.sound:SetChecked(db.sound and true or false)
        f:SetHeight(-y + 6 + ROW + 56)
    end
    local function refresh()
        f.refreshing = true           -- moving the slider here isn't the player changing the size
        local ok, err = pcall(fill)
        f.refreshing = false
        if not ok then Report(err) end
    end
    f.Refresh = refresh               -- f:Refresh() works too; the argument is ignored

    f:SetScript("OnShow", Safely(function()
        PA.optionsOpen = true
        PA:Update()                   -- the box first, so it's there even if the window has trouble
        refresh()
    end))
    f:SetScript("OnHide", Safely(function()
        PA.optionsOpen = false
        PA.db.locked, PA.db.placed = true, true
        PA:Update()
    end))
    self.options = f
    return f
end

function PA:ToggleOptions()
    local f = self.options or self:BuildOptions()
    if f:IsShown() then f:Hide() else f:Show() end
end

---------------------------------------------------------------------------
-- /procflash
---------------------------------------------------------------------------
local function KnownNames()
    local names = {}
    for _, proc in ipairs(PA.known) do
        names[#names + 1] = proc.name .. (PA.db.off[proc.key] and " (off)" or "")
    end
    return table.concat(names, ", ")
end

local NOTHING = "this character has none of the procs ProcFlash watches."

local function Shown(v)
    if issecret(v) then return "secret" end
    return tostring(v)
end

---What the game says about each proc, to see why one does or doesn't show.
function PA:Debug()
    local _, class = UnitClass("player")
    local book = Spellbook()
    local count = 0
    for _ in pairs(book) do count = count + 1 end
    Say(("class %s, %d spells in the spellbook, Edit Mode hook %s."):format(
        tostring(class), count, self.hasEditMode and "on" or "missing"))
    for _, proc in ipairs(PROCS[class] or {}) do
        if proc.buff then
            local aura = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
                         and C_UnitAuras.GetPlayerAuraBySpellID(proc.buff)
            Say(("%s (buff %d): on you now: %s"):format(proc.name, proc.buff,
                issecret(aura) and "secret" or tostring(aura ~= nil)))
        else
            local name = SpellName(proc.move) or proc.name
            local id = FindMove(proc, book, name)
            if not id then
                Say(("%s: not in your spellbook (looked for \"%s\")."):format(proc.name, name))
            else
                local usable, noMana
                if C_Spell and C_Spell.IsSpellUsable then usable, noMana = C_Spell.IsSpellUsable(id)
                elseif IsUsableSpell then usable, noMana = IsUsableSpell(id) end
                local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(id)
                Say(("%s (spell %d): usable %s, short on rage %s, glowing %s, cooldown active %s / on GCD %s, ready %s"):format(
                    name, id, Shown(usable), Shown(noMana), Shown(Glowing(id)),
                    cd and Shown(cd.isActive) or "?", cd and Shown(cd.isOnGCD) or "?",
                    tostring(PA.Ready({ spell = id, name = name }))))
            end
        end
    end
    if not PROCS[class] then Say(NOTHING) end
end

function PA:Command(msg)
    local db = self.db
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local word, rest = msg:match("^(%S*)%s*(.-)$")

    if word == "debug" then return self:Debug() end
    if word == "" or word == "options" or word == "config" then return self:ToggleOptions() end
    if #self.known == 0 then
        Say(NOTHING .. " (/procflash debug shows what the game reports.)")
        return
    end

    if word == "move" or word == "unlock" then
        db.locked = false
        Say("drag the icons where you want them, then type /procflash lock.")
    elseif word == "lock" then
        db.locked, db.placed = true, true
        Say("locked. Icons now only show up when a proc is up.")
    elseif word == "size" then
        local n = tonumber(rest)
        if n and n >= MIN_SIZE and n <= MAX_SIZE then
            Say("icons are now " .. self:SetIconSize(n) .. " pixels.")
        else
            Say("size is a number from 16 to 200, e.g. /procflash size 64 (now " .. db.size .. ").")
        end
    elseif word == "sound" then
        db.sound = not db.sound
        Say(db.sound and "plays a sound when an icon appears." or "no sound.")
        if self.options then self.options:Refresh() end
    elseif word == "reset" then
        db.point = { unpack(DEFAULTS.point) }
        self:Place()
        self:SetIconSize(DEFAULTS.size)
        Say("back in the middle of the screen at the normal size.")
    elseif word == "help" then
        Say("watching " .. KnownNames() .. ".")
        Say("/procflash - the ProcFlash window: move, resize, turn procs on or off")
        Say("/procflash size 64   /procflash sound   /procflash reset   /procflash <name> (e.g. /procflash revenge)")
        Say("/procflash move, /procflash lock - move it without the window   /procflash debug")
    else
        for _, proc in ipairs(self.known) do
            if proc.key == msg or proc.name:lower() == msg then
                db.off[proc.key] = not db.off[proc.key] or nil
                Say(proc.name .. (db.off[proc.key] and " is off." or " is on."))
                if self.options then self.options:Refresh() end
                self:Update()
                return
            end
        end
        Say("nothing called \"" .. msg .. "\". Watching " .. KnownNames() .. ". Type /procflash for help.")
        return
    end
    self:Update()
end

SLASH_PROCFLASH1 = "/procflash"
SlashCmdList.PROCFLASH = Safely(function(msg)
    if not PA.db then
        Say("didn't finish loading. Type /reload; if this keeps happening, look for a red error above.")
        return
    end
    PA:Command(msg)
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:SetScript("OnEvent", Safely(function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg ~= ADDON then return end
        ProcFlashDB = ProcFlashDB or {}
        local db = ProcFlashDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = type(v) == "table" and { unpack(v) } or v end
        end
        db.off = db.off or {}
        if not db.placed then db.locked = true end    -- placing it is the /procflash window's job now
        PA.db = db
        PA:Place()
    elseif event == "PLAYER_LOGIN" then
        PA:Rebuild()
        if #PA.known > 0 and not PA.db.placed then
            Say("type /procflash to place the icons and set them up.")
        end
    elseif PA.db then
        PA:Rebuild()                                  -- learned a spell or a talent
    end
end))

-- Newer clients renamed or dropped some events, and asking for one that doesn't
-- exist is an error, so ask for each on its own and skip the missing ones.
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "SPELLS_CHANGED",
                         "LEARNED_SPELL_IN_SKILL_LINE", "LEARNED_SPELL_IN_TAB",
                         "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE" }) do
    pcall(events.RegisterEvent, events, event)
end
