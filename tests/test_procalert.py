"""Run ProcAlert in Lua 5.1 against a fake WoW Forever client.

The fake has only the modern spell API (C_Spell, C_SpellBook, C_UnitAuras), like
WoW Forever, and can make answers "secret" the way the client does in combat.

Needs lupa (Lua for Python):  pip install lupa
    python tests/test_procalert.py        # or: python -m pytest tests
"""

from __future__ import annotations

import importlib
from pathlib import Path

ADDON = Path(__file__).resolve().parent.parent / "ProcAlert"

try:
    lua51 = importlib.import_module("lupa.lua51")
except ImportError:  # pragma: no cover
    import pytest
    pytest.skip("lupa is not installed", allow_module_level=True)

FAKE_WOW = r"""
W = { class = "WARRIOR", book = {}, usable = {}, glow = {}, cd = {}, range = {}, auras = {},
      now = 100, target = true, enemy = true, targetDead = false, chat = {}, sounds = 0,
      events = {}, callbacks = {} }

-- A secret value: the addon may hold it but not compare it (that's an error here too).
SECRET = setmetatable({}, { __tostring = function() return "SECRET" end })
issecretvalue = function(v) return v == SECRET end

NAMES = { [7384] = "Overpower", [7887] = "Overpower", [6572] = "Revenge", [6574] = "Revenge",
          [5308] = "Execute", [1495] = "Mongoose Bite", [19306] = "Counterattack",
          [14251] = "Riposte", [16870] = "Clearcasting", [12536] = "Clearcasting",
          [16246] = "Clearcasting", [17941] = "Shadow Trance" }

local function noop() end
local Stub = {}
Stub.__index = function(t, k) return rawget(Stub, k) or noop end
function Stub.new(kind) return setmetatable({ kind = kind, shown = true, scripts = {} }, Stub) end
function Stub:SetScript(name, fn) self.scripts[name] = fn end
function Stub:GetScript(name) return self.scripts[name] end
-- like the game: showing a hidden frame runs its OnShow, hiding a shown one its OnHide
function Stub:Show()
  local was = self.shown; self.shown = true
  if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Stub:Hide()
  local was = self.shown; self.shown = false
  if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Stub:SetValue(v)
  self.value = v
  if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
end
function Stub:GetValue() return self.value end
function Stub:SetChecked(c) self.checked = c end
function Stub:GetChecked() return self.checked end
function Stub:SetHeight(h) self.h = h end
function Stub:EnableMouseWheel(on) self.wheel = on end
function Stub:IsShown() return self.shown end
function Stub:SetSize(w, h) self.w, self.h = w, h end
function Stub:SetPoint(...) self.point = { ... } end
function Stub:GetPoint() local p = self.point; return p[1], p[2], p[3], p[4], p[5] end
function Stub:SetVertexColor(r, g, b) self.color = { r, g, b } end
function Stub:SetTexture(t) self.texture = t end
function Stub:SetText(t) self.text = t end
function Stub:SetFont(path, size, flags) self.font = { path, size, flags } end
function Stub:SetTextColor(r, g, b) self.textColor = { r, g, b } end
function Stub:SetDesaturated(d) self.grey = d end
function Stub:EnableMouse(on) self.mouse = on end
function Stub:CreateTexture() return Stub.new("Texture") end
function Stub:CreateFontString() return Stub.new("FontString") end
-- like WoW Forever's client: asking for an event it doesn't have is an error
-- (LEARNED_SPELL_IN_TAB and CHARACTER_POINTS_CHANGED are gone there)
EVENTS = { ADDON_LOADED = true, PLAYER_LOGIN = true, SPELLS_CHANGED = true,
           LEARNED_SPELL_IN_SKILL_LINE = true, PLAYER_TALENT_UPDATE = true }
function Stub:RegisterEvent(e)
  if not EVENTS[e] then error("Attempt to register unknown event \"" .. e .. "\"") end
  W.events[e] = self
end

function CreateFrame(kind, name)
  local f = Stub.new(kind)
  if name then _G[name] = f end
  return f
end
UIParent = Stub.new("Frame")
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) W.chat[#W.chat + 1] = msg end }
SlashCmdList = {}
UISpecialFrames = {}
EventRegistry = { RegisterCallback = function(_, event, fn) W.callbacks[event] = fn end }
Enum = { SpellBookSpellBank = { Player = 0 } }

UnitClass = function() return W.class, W.class end
GetTime = function() return W.now end
UnitExists = function() return W.target end
UnitCanAttack = function() return W.enemy end
UnitIsDead = function() return W.targetDead end
PlaySound = function() W.sounds = W.sounds + 1 end

C_Spell = {
  GetSpellName = function(id) return NAMES[id] end,
  GetSpellTexture = function(id) return 1000 + id end,
  IsSpellUsable = function(id) return W.usable[id] or false, false end,
  GetSpellCooldown = function(id)
    return W.cd[id] or { startTime = 0, duration = 0, isActive = false, isOnGCD = false }
  end,
  IsSpellInRange = function(id) if W.range[id] == nil then return true end; return W.range[id] end,
}
C_SpellBook = {
  -- on WoW Forever this said "no" for moves the character has
  IsSpellKnown = function() return false end,
  GetNumSpellBookSkillLines = function() return 1 end,
  GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = #W.book } end,
  GetSpellBookItemInfo = function(slot)
    local s = W.book[slot]
    if s then return { name = s[1], spellID = s[2], itemType = 1 } end
  end,
}
C_SpellActivationOverlay = { IsSpellOverlayed = function(id) return W.glow[id] or false end }
C_UnitAuras = {
  GetPlayerAuraBySpellID = function(id) return W.auras[id] end,
  GetAuraDataByIndex = function() return nil end,
}

function learn(name, id) W.book[#W.book + 1] = { name, id } end
function fire(event, arg)
  local f = W.events[event]
  f.scripts.OnEvent(f, event, arg)
end
function tick() ProcAlert.anchor.scripts.OnUpdate(ProcAlert.anchor, 0.1) end
function showing() return table.concat(ProcAlert:Showing(), ",") end
function slash(msg) SlashCmdList.PROCALERT(msg) end
function click(button) button.scripts.OnClick(button) end
function drag(frame, x, y)
  frame.scripts.OnMouseDown(frame, "LeftButton")
  frame.point = { "TOPLEFT", nil, "BOTTOMLEFT", x, y }
  frame.scripts.OnMouseUp(frame, "LeftButton")
end
function cooldown(id, start, duration, active, gcd)
  W.cd[id] = { startTime = start, duration = duration, isActive = active, isOnGCD = gcd }
end
"""

# Feeble, the level 17 warrior: Overpower rank 2, Revenge rank 2, no Execute yet.
FEEBLE = (("Battle Stance", 2457), ("Overpower", 7384), ("Overpower", 7887),
          ("Revenge", 6572), ("Revenge", 6574))
OVERPOWER, REVENGE, EXECUTE = 7887, 6574, 5308


def game(cls="WARRIOR", book=FEEBLE, saved=None):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE_WOW)
    g = lua.globals()
    W = g.W
    W["class"] = cls
    for name, spell_id in book:
        g.learn(name, spell_id)
    if saved is not None:
        lua.execute(saved)
    src = (ADDON / "ProcAlert.lua").read_text(encoding="utf-8")
    chunk = lua.eval("loadstring")(src, "@ProcAlert.lua")
    chunk("ProcAlert", lua.table())
    g.fire("ADDON_LOADED", "ProcAlert")
    g.fire("PLAYER_LOGIN")
    g.tick()
    return lua, g, W


def chat(W):
    return list(W.chat.values())


def names(g):
    return [p.name for p in g.ProcAlert.known.values()]


def test_finds_feebles_moves_in_the_spellbook_at_their_highest_rank():
    lua, g, W = game()
    assert names(g) == ["Overpower", "Revenge"]
    spells = [p.spell for p in g.ProcAlert.known.values()]
    assert spells == [OVERPOWER, REVENGE]
    assert not any("none of the procs" in m for m in chat(W))


def test_nothing_shows_until_a_move_lights_up():
    lua, g, W = game()
    assert g.showing() == ""                    # starts locked, nothing up
    W.usable[OVERPOWER] = True
    g.tick()
    assert g.showing() == "Overpower"
    W.usable[OVERPOWER] = False                 # used, or the 5 seconds ran out
    g.tick()
    assert g.showing() == ""


def test_the_icon_says_the_procs_name():
    lua, g, W = game()
    lua.execute('GameFontNormal = { GetFont = function() return "Fonts/FRIZQT__.TTF", 12 end }')
    W.usable[REVENGE] = True
    g.tick()
    icon = g.ProcAlert.icons[2]
    assert g.showing() == "Revenge"
    assert icon.name.text == "Revenge"
    assert list(icon.name.textColor.values()) == [0.85, 0.85, 0.88]   # silver
    assert icon.name.font[2] == 14              # 48 px icon: 14 pt letters
    g.slash("size 100")
    g.tick()
    assert icon.name.font[2] == 30              # bigger icon, bigger name


def test_every_proc_shows_in_the_same_spot_one_at_a_time():
    lua, g, W = game(book=FEEBLE + (("Execute", EXECUTE),))
    W.usable[EXECUTE] = True
    g.tick()
    assert g.showing() == "Execute"
    assert g.ProcAlert.icons[3].point[4] == 0   # same spot as the others
    W.usable[REVENGE] = True                    # two up at once: the first listed wins
    g.tick()
    assert g.showing() == "Revenge"
    assert g.ProcAlert.icons[2].point[4] == 0
    assert g.ProcAlert.anchor.w == 48


def test_cooldown_hides_it_but_the_global_cooldown_does_not():
    lua, g, W = game()
    W.usable[OVERPOWER] = True
    g.cooldown(OVERPOWER, 99, 1.5, True, True)  # global cooldown after another move
    g.tick()
    assert g.showing() == "Overpower"
    g.cooldown(OVERPOWER, 99, 5, True, False)   # Overpower's own 5 s cooldown
    g.tick()
    assert g.showing() == ""
    W.now = 105
    g.tick()
    assert g.showing() == "Overpower"


def test_secret_cooldown_times_do_not_break_it():
    lua, g, W = game()
    S = g.SECRET
    W.usable[OVERPOWER] = True
    g.cooldown(OVERPOWER, S, S, True, False)    # times hidden, but it says: own cooldown
    g.tick()
    assert g.showing() == ""
    g.cooldown(OVERPOWER, S, S, True, True)     # times hidden, global cooldown
    g.tick()
    assert g.showing() == "Overpower"
    g.cooldown(OVERPOWER, S, S, S, S)           # nothing readable: show it rather than hide it
    g.tick()
    assert g.showing() == "Overpower"


def test_secret_usable_falls_back_to_the_button_glow():
    lua, g, W = game()
    W.usable[OVERPOWER] = g.SECRET
    g.tick()
    assert g.showing() == ""
    W.glow[OVERPOWER] = True
    g.tick()
    assert g.showing() == "Overpower"


def test_needs_a_live_enemy_target_and_goes_red_out_of_range():
    lua, g, W = game()
    W.usable[OVERPOWER] = True
    W.target = None
    g.tick()
    assert g.showing() == ""
    W.target = True
    W.enemy = False                             # a friendly target
    g.tick()
    assert g.showing() == ""
    W.enemy = True
    W.targetDead = True
    g.tick()
    assert g.showing() == ""
    W.targetDead = False
    W.range[OVERPOWER] = False
    g.tick()
    assert g.showing() == "Overpower"
    assert g.ProcAlert.icons[1].tex.color[2] < 1      # tinted red
    W.range[OVERPOWER] = True
    g.tick()
    assert g.ProcAlert.icons[1].tex.color[2] == 1
    W.target = W.enemy = W.targetDead = g.SECRET      # can't tell: don't hide it
    g.tick()
    assert g.showing() == "Overpower"


def test_learning_a_move_adds_it():
    lua, g, W = game(book=(("Overpower", 7384),))
    assert names(g) == ["Overpower"]
    g.learn("Revenge", 6572)
    g.fire("LEARNED_SPELL_IN_SKILL_LINE")
    assert names(g) == ["Overpower", "Revenge"]


def test_druid_clearcasting_buff():
    lua, g, W = game(cls="DRUID", book=())
    assert g.showing() == ""
    W.target = None                             # buffs don't need a target
    W.auras[16870] = lua.table(name="Clearcasting")
    g.tick()
    assert g.showing() == "Clearcasting"
    W.auras[16870] = None
    g.tick()
    assert g.showing() == ""
    W.auras[16870] = g.SECRET                   # hidden contents still mean it's there
    g.tick()
    assert g.showing() == "Clearcasting"


def test_other_classes_get_nothing_and_no_box():
    lua, g, W = game(cls="PRIEST", book=())
    assert g.ProcAlert.anchor.shown is False
    assert not any("type /proc" in m for m in chat(W))
    g.slash("help")
    assert "none of the procs" in chat(W)[-1]
    g.slash("")                                 # the window still opens, and says so
    assert g.ProcAlertOptions.none.shown is True


def test_edit_mode_shows_the_box_to_drag():
    lua, g, W = game()
    assert any("type /proc" in m for m in chat(W))         # first login tells you how
    assert g.ProcAlert.backdrop.shown is False
    W.callbacks["EditMode.Enter"]()
    g.tick()
    assert g.showing() == "Overpower"           # one icon, so you see what you're placing
    assert g.ProcAlert.backdrop.shown is True
    assert g.ProcAlert.label.text == "ProcAlert"
    assert g.ProcAlert.anchor.mouse is True     # draggable
    g.drag(g.ProcAlert.anchor, 300, 200)
    W.callbacks["EditMode.Exit"]()
    g.tick()
    assert g.showing() == ""
    assert g.ProcAlert.backdrop.shown is False
    assert g.ProcAlert.anchor.mouse is False    # clicks go through to the game
    db = g.ProcAlertDB
    assert list(db.point.values()) == ["TOPLEFT", "BOTTOMLEFT", 300, 200]
    assert db.placed is True


def test_slash_move_and_lock_still_work_and_settings_are_saved():
    lua, g, W = game()
    g.slash("move")
    g.tick()
    assert g.showing() == "Overpower"
    assert "/proc lock" in g.ProcAlert.label.text
    g.slash("lock")
    g.slash("size 64")
    g.slash("sound")
    g.tick()
    assert g.showing() == ""
    db = g.ProcAlertDB
    assert db.size == 64 and db.sound is True and db.locked is True and db.placed is True

    lua2, g2, W2 = game(saved="ProcAlertDB = { point = {'TOPLEFT','BOTTOMLEFT',300,200}, "
                              "size = 64, locked = true, placed = true, sound = true, off = {} }")
    assert list(g2.ProcAlert.anchor.point.values())[2:] == ["BOTTOMLEFT", 300, 200]
    assert not any("type /proc" in m for m in chat(W2))    # already placed
    W2.usable[OVERPOWER] = True
    g2.tick()
    assert g2.ProcAlert.icons[1].w == 64
    assert W2.sounds == 1
    g2.tick()
    assert W2.sounds == 1                       # once when it appears, not every check


def test_settings_from_the_first_version_start_locked():
    lua, g, W = game(saved="ProcAlertDB = { point = {'CENTER','CENTER',0,-150}, size = 48, "
                           "locked = false, sound = false, off = {} }")
    assert g.ProcAlertDB.locked is True
    assert g.ProcAlert.backdrop.shown is False


def test_turn_one_off_by_name():
    lua, g, W = game()
    g.slash("revenge")
    W.usable[REVENGE] = True
    W.usable[OVERPOWER] = True
    g.tick()
    assert g.showing() == "Overpower"
    g.slash("Revenge")
    W.usable[OVERPOWER] = False
    g.tick()
    assert g.showing() == "Revenge"
    g.slash("fireball")
    assert "nothing called" in chat(W)[-1]


def options(g):
    return g.ProcAlertOptions


def test_slash_proc_opens_the_window_and_shows_the_box_to_move():
    lua, g, W = game()
    g.slash("")
    f = options(g)
    assert f.shown is True
    g.tick()
    assert g.showing() == "Overpower"           # no Execute yet, and that's fine
    assert g.ProcAlert.backdrop.shown is True
    assert g.ProcAlert.anchor.mouse is True and g.ProcAlert.anchor.wheel is True
    assert "drag" in g.ProcAlert.label.text
    g.drag(g.ProcAlert.anchor, 420, 260)
    assert list(g.ProcAlertDB.point.values()) == ["TOPLEFT", "BOTTOMLEFT", 420, 260]
    click = g.click
    click(f.done)
    assert f.shown is False
    g.tick()
    assert g.showing() == ""
    assert g.ProcAlert.anchor.mouse is False
    assert g.ProcAlertDB.placed is True and g.ProcAlertDB.locked is True
    g.slash("")                                 # /proc again opens it again
    assert f.shown is True
    g.slash("")                                 # and once more closes it
    assert f.shown is False


def test_window_resizes_the_icons():
    lua, g, W = game()
    g.slash("")
    f = options(g)
    assert f.slider.value == 48 and f.sizeValue.text == "48 px"
    f.slider.SetValue(f.slider, 72)             # drag the slider
    g.tick()
    assert g.ProcAlertDB.size == 72
    assert g.ProcAlert.icons[1].w == 72
    assert g.ProcAlert.anchor.w == 72
    g.ProcAlert.anchor.scripts.OnMouseWheel(g.ProcAlert.anchor, -1)   # scroll down
    assert g.ProcAlertDB.size == 68
    assert f.slider.value == 68 and f.sizeValue.text == "68 px"
    for _ in range(100):
        g.ProcAlert.anchor.scripts.OnMouseWheel(g.ProcAlert.anchor, -1)
    assert g.ProcAlertDB.size == 16             # never smaller than 16
    click = g.click
    click(f.reset)
    assert g.ProcAlertDB.size == 48
    assert list(g.ProcAlertDB.point.values()) == ["CENTER", "CENTER", 0, -150]


def test_window_turns_procs_and_sound_on_and_off():
    lua, g, W = game()
    g.slash("")
    f = options(g)
    labels = [f.checks[i].label.text for i in (1, 2)]
    assert labels == ["Show Overpower", "Show Revenge"]
    assert f.checks[1].checked is True and f.sound.checked is False
    f.checks[2].checked = False                 # untick Revenge
    g.click(f.checks[2])
    f.sound.checked = True
    g.click(f.sound)
    g.click(f.done)
    W.usable[REVENGE] = True
    W.usable[OVERPOWER] = True
    g.tick()
    assert g.showing() == "Overpower"
    assert W.sounds == 1
    assert g.ProcAlertDB.off.revenge is True
    g.slash("revenge")                          # typed toggles show in the window too
    g.slash("")
    assert f.checks[2].checked is True


def test_learning_a_move_while_the_window_is_open_adds_its_box():
    lua, g, W = game(book=(("Overpower", 7384),))
    g.slash("")
    f = options(g)
    assert f.checks[1].label.text == "Show Overpower"
    g.learn("Execute", EXECUTE)
    g.fire("LEARNED_SPELL_IN_SKILL_LINE")
    assert f.checks[2].label.text == "Show Execute" and f.checks[2].shown is True


def test_it_loads_on_a_client_without_the_old_events():
    lua, g, W = game()
    assert g.ProcAlertDB is not None and g.ProcAlert.db is not None
    assert set(W.events.keys()) == {"ADDON_LOADED", "PLAYER_LOGIN", "SPELLS_CHANGED",
                                    "LEARNED_SPELL_IN_SKILL_LINE", "PLAYER_TALENT_UPDATE"}
    assert not any("went wrong" in m for m in chat(W))


def test_errors_are_said_in_chat_once():
    lua, g, W = game()
    lua.execute('C_Spell.IsSpellUsable = function() error("boom") end')
    for _ in range(5):
        g.tick()
    errors = [m for m in chat(W) if "went wrong" in m]
    assert len(errors) == 1 and "boom" in errors[0]


def test_debug_reports_what_the_game_says():
    lua, g, W = game(book=(("Overpower", 7887),))
    W.usable[OVERPOWER] = g.SECRET
    g.cooldown(OVERPOWER, g.SECRET, g.SECRET, g.SECRET, g.SECRET)
    g.slash("debug")
    out = "\n".join(chat(W))
    assert "Edit Mode hook on" in out
    assert "Overpower (spell 7887): usable secret" in out
    assert "Revenge: not in your spellbook" in out
    lua, g, W = game(cls="DRUID", book=())
    g.slash("debug")
    assert "Clearcasting (buff 16870): on you now: false" in chat(W)[-1]


if __name__ == "__main__":
    import sys
    import traceback
    failed = 0
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_")]
    for name, fn in tests:
        try:
            fn()
            print("ok  ", name)
        except Exception:  # noqa: BLE001
            failed += 1
            print("FAIL", name)
            traceback.print_exc()
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
