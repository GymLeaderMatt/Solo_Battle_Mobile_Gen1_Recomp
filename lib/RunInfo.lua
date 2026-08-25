-- The solo run's own corner: the clock, and two warnings that only appear
-- when they have something to say.
--
-- The desktop overlay (solo_run_overlay) carries a whole column of this --
-- time, resets, badges, repel, bag -- down the right edge of a 1080p window.
-- None of that column fits here, and most of it does not need to: what a run
-- actually wants in front of it at all times is the clock, whether a repel is
-- still up, and whether the bag is about to refuse the next pickup. So three
-- things, in the one corner the battle layout leaves empty.
--
-- ------- why this is not drawn where the HUD panels are
--
-- BattleHudPanel goes into the arena's own image, in snapHUDs, which is the
-- right place for it: it replaces the engine's status block, it belongs to
-- the battle, and it wants to sit under the same depth of field the mons do.
--
-- This does not. A clock that only exists inside battles would be a clock you
-- cannot see while you are walking, which is where the repel is ticking down
-- and where the bag fills up. So it hangs off `render.hud` instead -- the
-- engine's screen-space layer, drawn after Renderer:endFrame and before the
-- touch controls, in LOVE window units. That is one hook, it fires on every
-- frame the game draws, and it puts this on top of the battle, the overworld
-- and everything in between without either path having to know about it.
--
-- Two consequences worth knowing. It is ABOVE the arena rather than in it, so
-- the depth of field never touches it and it stays crisp at the corner. And
-- it is outside the iOS split in snapHUDs entirely, so unlike the panels it
-- draws the same way everywhere.
--
-- ------- the shape
--
--     +--------------------------------+
--     |          1 2 : 3 4 : 5 6       |   <- always
--     +--------------------------------+
--     +------+              +----------+
--     | bag  |              |  R:250   |   <- each only when it applies
--     +------+              +----------+
--
-- The width is BattleHudPanel.PANEL_W, not a number of its own, because the
-- clock and the foe's panel share the window's right edge and a column that
-- is nearly the same width reads worse than one that is exactly the same
-- width. Everything else here is derived from the panel's outline, padding
-- and radius for the same reason -- one set of furniture, not two.
--
-- The repel and the bag are separate boxes rather than two halves of one,
-- which is what the overlay does and is the better of the two arrangements
-- when only one of them is up: a lone icon at the left end of a full-width
-- box looks like a box that failed to load.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local BattleHudPanel = V.require("BattleHudPanel")
local ModSetting = V.require("ModSetting")

local RunInfo = {}

-- ------- the setting
--
-- On a machine with a keyboard the overlay toggles with O or F8. This one has
-- neither, so the only way to put it away is a row, and the mod already has a
-- page full of them.
RunInfo.setting = ModSetting.new("runInfo", "RUN INFO",
  { "OFF", "ON" }, { "OFF", "ON" }, 2)

function RunInfo.enabled()
  return RunInfo.setting:get() == "ON"
end

-- ------- geometry, in 720x480 screen pixels
--
-- Same design units as BattleHudPanel: on the target handheld the scale comes
-- out at exactly 1 and every number below is a pixel you can count.

RunInfo.ROW_H = 36        -- the clock box, and the warning boxes beside it
RunInfo.ROW_GAP = 4       -- between the clock and the warning row

-- The clock's glyphs. Whole numbers in both axes or the strokes come out
-- uneven; the vertical runs one ahead of the horizontal exactly as the
-- panel's name row does, which fills the box's height without spending width
-- the corner cannot spare.
RunInfo.TIME_SCALE = 2
RunInfo.TIME_STRETCH = 1

-- The colon is the reason the clock fits at all.
--
-- Eight glyphs of `HH:MM:SS` at 2x is 128 px against 119 of inner width, so on
-- the face of it the clock has to either drop to 1x -- eight screen pixels,
-- the illegibility the panel layout exists to avoid -- or the box has to grow
-- wider than the panel column and stop lining up with it.
--
-- Neither is necessary, because a colon is not eight pixels of anything. In
-- this font its ink is ONE pixel wide in the middle of its cell, with three
-- either side; measured off a real panel at 2x it lands at offsets 9 and 10 of
-- sixteen. Charging it five pixels of advance instead of eight still leaves a
-- clear gap before the next digit and takes the whole string to 116, which
-- fits with three to spare.
--
-- This is the only glyph that gets the treatment, and only in the clock. It is
-- a fixed-content string of digits and colons that this file generates itself,
-- so there is no nickname or translation to be wrong about.
RunInfo.COLON_ADVANCE = 5

RunInfo.BAG_ICON = 24     -- the warning icon, square

-- ------- colour
RunInfo.TEXT = { 1, 1, 1 }
RunInfo.GOLD = { 1.00, 0.84, 0.29 }      -- the run is over; the clock stopped
RunInfo.FILL = { 0, 0, 0 }
RunInfo.OUTLINE_COLOR = { 1, 1, 1 }

-- How close to full the bag has to be before it says so, matching the
-- overlay's three states: two slots left, one slot left, none.
RunInfo.BAG_WARN_AT = 2

-- How often the save is read. The clock only changes once a second and the
-- other two change on a footfall, so sixty reads a second buys nothing --
-- and Bag.slots walks the whole inventory.
RunInfo.POLL = 0.25

local bagArt = nil        -- nil = untried, false = none bundled
local state = nil         -- the last poll's answer
local polledAt = nil
local titleState = nil    -- nil = untried, false = unavailable

local function req(path)
  local ok, m = pcall(require, path)
  return ok and m or nil
end

-- ------- reading the save
--
-- Everything the corner shows comes off the live save, and every read is
-- guarded, because this draws on frames where there is no save at all (the
-- title) and on frames where a mod has replaced something (the bag's own
-- capacity is a data constant a mod can override).

local function bagWarning(game, save)
  local Bag = req("src.inventory.Bag")
  if not (Bag and save.inventory) then return nil end

  -- The overlay stops warning once the eighth badge is in: past that point
  -- the run is not picking things up any more, and a permanent icon in the
  -- corner is one that stops being read.
  local Badges = req("src.inventory.Badges")
  if Badges and Badges.count then
    local ok, n = pcall(Badges.count, game.data, save)
    if ok and (n or 0) >= 8 then return nil end
  end

  local okSlots, used = pcall(Bag.slots, save, game.data)
  local okCap, cap = pcall(Bag.capacity, game.data)
  if not (okSlots and okCap and used and cap and cap > 0) then return nil end
  local free = cap - used
  if free > RunInfo.BAG_WARN_AT then return nil end
  if free <= 0 then return "red" end
  if free == 1 then return "yellow" end
  return "green"
end

-- The clock, and whether it has stopped.
--
-- solo_run_splits stamps CHAMPION on the frame the flag fires, which is a
-- fraction of a second earlier than this poll could ever notice, so its time
-- wins when the mod is installed. The flag is the fallback so the corner still
-- freezes correctly on its own. Clearing when neither is there is what makes
-- it self-healing: New Game on the same slot starts the clock again with no
-- event to listen for.
--
-- `mod.find` is called here rather than cached at load, because load order is
-- by priority then id and there is no promise the splits mod exists yet when
-- this file is first read.
local function playTime(save)
  local champ
  local finder = V.mod and V.mod.find
  if finder then
    local ok, splits = pcall(finder, "solo_run_splits")
    local exports = ok and splits and splits.exports
    champ = exports and exports.myTimes and exports.myTimes.CHAMPION
  end
  if not champ and save.flags and save.flags.EVENT_BEAT_CHAMPION_RIVAL then
    champ = (state and state.frozen and state.seconds) or save.playTime
  end
  if champ then return math.floor(champ), true end
  return math.floor(save.playTime or 0), false
end

local function poll(game)
  local save = game and game.save
  if not save then return nil end
  local seconds, frozen = playTime(save)
  return {
    seconds = seconds,
    frozen = frozen,
    repelSteps = math.floor(save.repelSteps or 0),
    bag = bagWarning(game, save),
  }
end

-- ------- drawing

local function clockText(seconds)
  return string.format("%d:%02d:%02d",
                       math.floor(seconds / 3600),
                       math.floor(seconds / 60) % 60,
                       seconds % 60)
end

local function advanceOf(ch)
  if ch == ":" then return RunInfo.COLON_ADVANCE end
  local w = BattleHudPanel.textWidth(ch)
  return (w and w > 0) and w or 8
end

local function tightWidth(str, sx)
  local w = 0
  for i = 1, #str do w = w + advanceOf(str:sub(i, i)) end
  return w * sx
end

-- One glyph at a time, so the colon's advance can be shortened and so the
-- cache holds eleven single characters rather than a new string every second.
local function tightText(str, x, y, sx, sy, color)
  local pen = x
  for i = 1, #str do
    local ch = str:sub(i, i)
    BattleHudPanel.text(ch, pen, y, sx, sy, color)
    pen = pen + advanceOf(ch) * sx
  end
end

local function box(x, y, w, h, s)
  local g = love.graphics
  local outline = BattleHudPanel.OUTLINE * s
  local radius = BattleHudPanel.RADIUS * s
  local oc = RunInfo.OUTLINE_COLOR
  g.setColor(oc[1], oc[2], oc[3], 1)
  g.rectangle("fill", x, y, w, h, radius, radius)
  local f = RunInfo.FILL
  g.setColor(f[1], f[2], f[3], 1)
  g.rectangle("fill", x + outline, y + outline, w - outline * 2, h - outline * 2,
              math.max(0, radius - outline), math.max(0, radius - outline))
  g.setColor(1, 1, 1, 1)
end

-- The bag art, one image per state, through the mod's asset resolver -- a bare
-- relative path resolves against the GAME's root and silently finds nothing.
-- Filtered linearly rather than nearest: unlike the font and the balls this is
-- not pixel art, it is a 96 px illustration being drawn at 24, and a nearest
-- downscale of that is a mess of dropped rows.
local function bagImages()
  if bagArt ~= nil then return bagArt or nil end
  local out, found = {}, false
  for _, name in ipairs({ "red", "yellow", "green" }) do
    local ok, img = pcall(function()
      local path = V.mod.assets:path("assets/battle/hud/bag_" .. name .. ".png")
      local image = love.graphics.newImage(path)
      image:setFilter("linear", "linear")
      return image
    end)
    if ok and img then out[name], found = img, true end
  end
  bagArt = found and out or false
  return bagArt or nil
end

-- Everything in the corner, top-right, measured to the OUTSIDE of the white
-- outline -- that edge is part of the box, not something drawn around it, and
-- it is what the eye lines the column up against.
function RunInfo.draw(game, viewport)
  if not RunInfo.enabled() then return end
  local g = love.graphics
  local w, h = g.getDimensions()
  if viewport and (viewport.width or 0) > 0 and (viewport.height or 0) > 0 then
    w, h = viewport.width, viewport.height
  end
  local s = BattleHudPanel.scale({ pw = w, ph = h })
  if s <= 0 then return end

  -- The title screen has a save attached and a play time in it, and a clock
  -- over the copyright is not what anyone means by an always-on HUD.
  if titleState == nil then titleState = req("src.ui.TitleState") or false end
  local top = game and game.stack and game.stack.top and game.stack:top()
  if titleState and top and getmetatable(top) == titleState then return end

  local now = love.timer and love.timer.getTime and love.timer.getTime() or nil
  if not (state and polledAt and now and (now - polledAt) < RunInfo.POLL) then
    state = poll(game)
    polledAt = now
  end
  if not state then return end

  local pw = BattleHudPanel.PANEL_W * s
  local edge = BattleHudPanel.EDGE * s
  local outline = BattleHudPanel.OUTLINE * s
  local pad = BattleHudPanel.PAD * s
  local rowH = RunInfo.ROW_H * s
  local inset = outline + pad
  local cw = pw - inset * 2

  local x = w - edge - pw
  local y = edge

  g.push("all")
  g.origin()
  g.setBlendMode("alpha")

  -- the clock
  box(x, y, pw, rowH, s)
  local str = clockText(state.seconds)
  -- Sized for the string in hand rather than for a worst case, because there
  -- is no worst case to size for: an hour count has no upper bound. 2x holds
  -- everything up to 99:59:59 and the step down past that is the honest
  -- alternative to a clock that runs off the end of its box.
  local sx = RunInfo.TIME_SCALE
  while sx > 1 and tightWidth(str, sx) > cw do sx = sx - 1 end
  local sy = sx + RunInfo.TIME_STRETCH
  local tw = tightWidth(str, sx)
  local color = state.frozen and RunInfo.GOLD or RunInfo.TEXT
  tightText(str, x + inset + (cw - tw) / 2,
            y + (rowH - 8 * sy) / 2, sx, sy, color)

  -- the two warnings, each on the end of the column it is anchored to
  local rowY = y + rowH + RunInfo.ROW_GAP * s
  local bag = state.bag and bagImages()
  local bagImg = bag and bag[state.bag]
  if bagImg then
    local icon = RunInfo.BAG_ICON * s
    local bw = icon + inset * 2
    box(x, rowY, bw, rowH, s)
    local iw, ih = bagImg:getDimensions()
    g.setColor(1, 1, 1, 1)
    g.draw(bagImg, x + inset, rowY + (rowH - icon) / 2, 0, icon / iw, icon / ih)
    g.setColor(1, 1, 1, 1)
  end

  if state.repelSteps > 0 then
    -- `R:` for the same reason the panel's level is `L:` -- one letter, a
    -- colon and a number is the idiom this HUD already speaks, and it costs
    -- three glyphs where the word REPEL costs five it does not have.
    local label = "R:" .. tostring(state.repelSteps)
    local lsx = RunInfo.TIME_SCALE
    while lsx > 1 and tightWidth(label, lsx) > cw do lsx = lsx - 1 end
    local lsy = lsx + RunInfo.TIME_STRETCH
    local lw = tightWidth(label, lsx)
    local rw = lw + inset * 2
    local rx = x + pw - rw
    box(rx, rowY, rw, rowH, s)
    tightText(label, rx + inset, rowY + (rowH - 8 * lsy) / 2, lsx, lsy,
              RunInfo.TEXT)
  end

  g.pop()
end

-- Only the art. The polled state is deliberately kept: it holds the latched
-- champion time, and dropping it would re-latch off whatever the clock reads
-- now rather than the moment the flag fired.
function RunInfo.invalidate()
  bagArt = nil
end

return RunInfo
