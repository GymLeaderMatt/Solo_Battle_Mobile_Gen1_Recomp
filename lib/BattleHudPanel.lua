-- The battle HUD as its own furniture, rather than the ROM's -- drawn for a
-- 720x480 handheld first and everything else second.
--
-- The engine draws each side's status block as black glyphs and a 48x8 gauge
-- straight onto the field, and BattleHud filters those pixels: it recolours
-- the gauge, flips the ink and lays the whole band back down at the window's
-- edge. That works, and it is still what HUD STYLE: OG does. What it cannot
-- do is change the PROPORTIONS: the bar is 8 rows of a 32-row block because
-- the ROM put it there, and scaling the block scales the name and the level
-- with it. A bar that reads at arm's length on a 3.4" screen has to be most
-- of its panel, and no amount of scaling a Game Boy HUD produces that.
--
-- So PANEL draws its own: a black box with a white outline, and inside it
-- three stacked rows.
--
-- ------- why THREE rows, when the desktop build uses one
--
-- This is the one place the handheld genuinely needs a different design and
-- not just smaller numbers, so it is worth being explicit about.
--
-- The desktop panel puts the name and the level side by side on one row. It
-- can afford to because its panel is 348 px wide at 1080p and the gutter
-- beside the letterbox is 400. At 720x480 the same panel is 131 px wide, and
-- a row holding both a name and a level splits that between them: seven
-- characters would land at 1x -- eight screen pixels tall, about 0.8 mm on
-- this panel -- which is not a small HUD, it is an unreadable one.
--
-- Splitting the row buys the name the FULL inner width, which is what lifts
-- it to 2x horizontal / 3x vertical (24 px) instead of 1x. The cost is one
-- row of height, and height is the axis this layout has to spend on, because
-- the width is fixed by the gutter and the gutter is what the screen is short
-- of. So:
--
--     +--------------------------------+
--     |  VICTREE                       |  <- name, full width, as large as fits
--     |  (o)(o)(o)             L:15    |  <- party balls / level or status
--     |  (o)(o)(o)                     |
--     |  [##########------------]      |  <- HP bar, full width
--     +--------------------------------+
--
-- The ball cluster moves to the LEFT of the middle row for the same reason:
-- stacked over the level in a right-hand column (as the desktop build does)
-- it would need a column wide enough for both, and there is no such column
-- here. Beside it, the two share one row and the panel keeps its height.
--
-- Three things are deliberately NOT reimplemented, because the engine already
-- does them and doing them again would be doing them differently:
--
--   * the drain. `battler.shownHP` is the HP the bar displays, ticked by
--     BattleState:stepHPDrain at hardware timing -- including the detail that
--     the player's bar drains slower than the foe's because the original
--     spends a frame reprinting the number and the enemy HUD does not. Read
--     it and the bar drains exactly like vanilla, for free.
--   * the status reveal. `battler.shownStatus` lags `mon.status` on purpose,
--     so the label appears in step with the animation rather than the instant
--     the move resolves.
--   * the glyphs. Font owns the charmap, which matters for a nickname the
--     player typed with characters that are not ASCII.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local BattleHudPanel = {}

-- ------- geometry
--
-- Design units are 720x480 SCREEN PIXELS. On the target handheld the scale
-- comes out at exactly 1 and every number below is the number of pixels you
-- can count in a screenshot -- which is the only way to reason about a layout
-- where a single row of pixels is a visible fraction of the whole thing.
BattleHudPanel.REF_W = 720
BattleHudPanel.REF_H = 480

-- WIDTH is the dimension the screen is short of, and it is set from the
-- WINDOW rather than from the letterbox on purpose.
--
-- The desktop build pins the panel to the solo-run overlay's column, which at
-- 16:9 sits comfortably inside the gutter beside the letterbox. At 3:2 it
-- does not: the GB frame is 480 of 720 px across (67%) against 1120 of 1920
-- (58%), so the same fraction of the window overhangs the text box's edge by
-- a dozen pixels. That overhang is the right trade and not a bug -- the
-- panels sit at the top-left and above the box's right end, where nothing
-- they could overlap is drawn -- and the alternative is a panel narrow enough
-- to force the name back down to 1x. The reference framing is matched instead
-- on the numbers that are actually visible: 18% of window width, which is
-- what the desktop shot measures.
BattleHudPanel.PANEL_W = 131

-- ...but never wider than this fraction of window HEIGHT. Without the cap an
-- ultrawide window would get a panel sized to a width it has plenty of and a
-- height it does not. 0.325 is the same shot measured on its short axis, so
-- at 16:9 the cap and the width rule agree to within a pixel and neither is
-- doing anything surprising.
BattleHudPanel.PANEL_W_CAP_H = 0.325

-- ...and never NARROWER than this, in screen pixels, which is the one number
-- here that is deliberately not proportional to anything.
--
-- Both rules above are fractions of the window, and on a small enough window
-- both of them are wrong: at 640x480 they agree on a 116 px panel, which is
-- seven pixels short of what a 2x name needs and so silently drops it to 1x
-- -- the exact illegibility the three-row layout exists to avoid. Legibility
-- is a property of SCREEN pixels, not of the window's proportions, so the
-- floor is one too. 128 is what NAME_MAX characters at 2x plus the outline
-- and padding come to, with a pixel in hand.
--
-- Capped against the window in turn, because a floor that outgrew the display
-- it was protecting would be worse than the thing it is guarding against.
BattleHudPanel.PANEL_W_MIN = 128
BattleHudPanel.PANEL_W_MIN_CAP_W = 0.42

BattleHudPanel.EDGE = 4          -- from the window edge
BattleHudPanel.OUTLINE = 2       -- white border thickness
BattleHudPanel.RADIUS = 7        -- outer corner radius
BattleHudPanel.PAD = 4           -- inside the outline
BattleHudPanel.ROW_GAP = 3       -- between the three rows
BattleHudPanel.COL_GAP = 4       -- balls to level/status

BattleHudPanel.BAR_H = 18
BattleHudPanel.BAR_OUTLINE = 2
BattleHudPanel.BAR_RADIUS = 8

-- The white edge on the coloured fill itself. Without it the fill's moving
-- end is a bare colour-to-track boundary while everything around it is
-- outlined, which reads as unfinished as soon as the bar starts draining.
BattleHudPanel.FILL_OUTLINE = 1

BattleHudPanel.BALL_D = 8        -- one ball, corner to corner
BattleHudPanel.BALL_GAP = 2

-- Names are cut to this many characters and every panel is sized for exactly
-- that many, so the glyphs are the same size on every panel AND as large as
-- the box can carry. Gen 1's cap is 10, and sizing for 10 would drop the name
-- to 1x here; 7 is the trade -- METAPOD fits whole, VICTREEBEL loses its
-- tail. A nickname avoids the cut.
BattleHudPanel.NAME_MAX = 7

-- Glyph scales are whole numbers in both axes or the strokes come out uneven,
-- which at this size is the difference between "pixel font" and "blurry". The
-- vertical scale runs one step ahead of the horizontal, which fills the row's
-- height without spending any of the width the panel cannot spare. Set to 0
-- for square glyphs at the ROM's own proportions.
BattleHudPanel.NAME_STRETCH = 1

-- The level/status label does NOT track the name's scale, and that is the
-- handheld's one real departure from proportional design. Scaled down from
-- the desktop shot the label lands at 1x here -- 8 px, correct as a ratio and
-- illegible as an object. It is floored at 2x instead and only allowed to
-- grow once the name is large enough that a small label would look starved,
-- which keeps it at the reference's own 16 px on a 1080p window as well.
BattleHudPanel.LABEL_MIN = 2

-- How far the foe's panel is lifted off the top of the text box.
BattleHudPanel.ENEMY_LIFT = 8

-- ------- colour
--
-- The bar's three shades are the constants BattleHud's own brightHpGauge
-- already uses for the filtered ROM gauge, so OG and PANEL cannot disagree
-- about what "half health" looks like.
BattleHudPanel.HP_GREEN = { 0.20, 0.92, 0.32 }
BattleHudPanel.HP_YELLOW = { 1.00, 0.82, 0.05 }
BattleHudPanel.HP_RED = { 1.00, 0.16, 0.10 }

-- The empty part of the bar. NOT the panel's black: a green stub floating in
-- an unbounded black box gives no reading of how much is missing, which is
-- most of what the bar is for once it is low.
BattleHudPanel.TRACK = { 0.22, 0.22, 0.22 }
BattleHudPanel.FILL = { 0, 0, 0 }
BattleHudPanel.OUTLINE_COLOR = { 1, 1, 1 }
BattleHudPanel.TEXT = { 1, 1, 1 }

-- Vanilla draws the status in the same ink as everything else. On a black
-- panel there is no reason not to colour it, and a glanceable status is worth
-- more in a solo run than fidelity to a monochrome constraint -- more so on a
-- screen where the three letters are only 16 px tall.
BattleHudPanel.STATUS_COLOR = {
  SLP = { 1.00, 0.37, 0.81 },
  PSN = { 0.63, 0.31, 0.94 },
  BRN = { 1.00, 0.27, 0.19 },
  FRZ = { 0.25, 0.78, 0.94 },
  PAR = { 1.00, 0.82, 0.05 },
}

BattleHudPanel.HP_HIGH = 0.5
BattleHudPanel.HP_LOW = 0.2

-- ------- turning the font's paper into ink
--
-- Font's pages are OPAQUE four-shade grayscale: Font.draw does not paint a
-- letter, it stamps a white tile with a black letter in it. Dropped straight
-- onto a black panel that is a white bar with black text -- the inverse of
-- what is wanted.
--
-- So the string is rendered once into its own small canvas at 1:1 Game Boy
-- pixels, and THAT is drawn scaled through a shader that keeps the dark
-- pixels, discards the paper and re-emits the ink in whatever colour the
-- caller asked for. Nothing translucent survives to the screen; the panel is
-- opaque throughout.
local INK = [[
  uniform vec3 tint;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 p = Texel(tex, tc);
    float luma = dot(p.rgb, vec3(0.299, 0.587, 0.114));
    float a = (p.a > 0.0 && luma <= 0.35) ? 1.0 : 0.0;
    return vec4(tint, a) * color;
  }
]]

local inkShader = nil    -- nil = untried, false = unavailable
local textCache = {}     -- string -> { canvas, w }
local textCount = 0
local ballArt = nil      -- nil = untried, false = none bundled

local function getInk()
  if inkShader == nil then
    local ok, sh = pcall(love.graphics.newShader, INK)
    inkShader = (ok and sh) or false
  end
  return inkShader or nil
end

local function fontModule()
  local ok, Font = pcall(require, "src.render.Font")
  return ok and Font or nil
end

-- The rendered ink for `str`, cached.
--
-- Cached by string rather than rebuilt per frame because binding a canvas is
-- a pipeline break -- and on a Mali-G31 it is an expensive one -- while a
-- name changes about once a battle. The canvas holds Game Boy pixels, so it
-- is resolution-independent: a window resize scales the draw, it does not
-- invalidate the cache.
local function textImage(str)
  if not str or str == "" then return nil end
  local hit = textCache[str]
  if hit then return hit end
  local Font = fontModule()
  if not Font then return nil end

  -- Font.width is the charmap's own measure and the only correct one for a
  -- nickname with non-ASCII glyphs in it; eight pixels a character is the
  -- fallback if a future engine drops the helper.
  local okW, w = pcall(function() return Font.width(str) end)
  if not okW or not w or w <= 0 then w = #str * 8 end
  local ok, canvas = pcall(love.graphics.newCanvas, w, 8)
  if not ok or not canvas then return nil end
  canvas:setFilter("nearest", "nearest")

  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  local drew = pcall(function()
    g.setCanvas(canvas)
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    Font.draw(str, 0, 0)
  end)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not drew then return nil end

  -- A runaway cache would mean a mod feeding it unbounded strings; names,
  -- levels and five statuses do not, but the cap costs nothing and this is a
  -- device with a gigabyte of RAM.
  if textCount > 128 then textCache, textCount = {}, 0 end
  textCache[str] = { canvas = canvas, w = w }
  textCount = textCount + 1
  return textCache[str]
end

-- Draw `str` with its top-left at (x, y), magnified `sx` by `sy`, in `color`.
-- Returns the width drawn, so a caller can lay the next thing after it.
--
-- The origin is FLOORED. The magnification is already whole (see layout), but
-- the panel's own origin is not once the window is not 720x480, and half a
-- pixel of offset under a nearest filter is the difference between a clean
-- stroke and a doubled one.
function BattleHudPanel.text(str, x, y, sx, sy, color)
  local img = textImage(str)
  if not img then return 0 end
  local sh = getInk()
  local g = love.graphics
  if sh then
    g.setShader(sh)
    pcall(sh.send, sh, "tint", { color[1], color[2], color[3] })
    -- the shader supplies the colour; the draw must not also multiply by it
    g.setColor(1, 1, 1, 1)
  else
    -- No shader: the font's paper comes with it, so the glyphs read as dark
    -- on light instead of light on dark. Legible, right size, wrong polarity
    -- -- and a driver that cannot compile a four-line shader is not a reason
    -- to draw no HUD at all.
    g.setColor(color[1], color[2], color[3], 1)
  end
  g.draw(img.canvas, math.floor(x + 0.5), math.floor(y + 0.5), 0, sx, sy or sx)
  g.setShader()
  g.setColor(1, 1, 1, 1)
  return img.w * sx
end

function BattleHudPanel.textWidth(str)
  local img = textImage(str)
  return img and img.w or 0
end

-- ------- the party balls
--
-- Drawn rather than blitted. The engine's own sheet is four 8x8 tiles of
-- FOUR-SHADE GRAY: on the Game Boy pipeline the zone pass colours them, but
-- this panel is composited into the world image downstream of that pass, so
-- the tiles arrive gray -- and a gray ball on a black box is the thing that
-- disappeared into the background in the first place.
--
-- A ball is a circle, a band and a button, so it costs a handful of draw
-- calls to make one that is actually red, scales to any size without going
-- mushy against the smooth chrome around it, and needs no art shipped.
-- Custom art overrides it if any is bundled -- see ballImages.
local BALL_RED = { 0.93, 0.11, 0.14 }
local BALL_WHITE = { 0.95, 0.95, 0.95 }
local BALL_DARK = { 0.05, 0.05, 0.05 }
local BALL_KO = { 0.32, 0.32, 0.32 }        -- fainted: no colour left in it
local BALL_KO_DIM = { 0.18, 0.18, 0.18 }
local BALL_STATUS = { 1.00, 0.82, 0.05 }    -- statused: the HUD's own amber

-- Optional bundled art, one PNG per state, at
-- assets/battle/hud/ball_{ok,status,ko}.png. Absent by default: the drawn
-- ball below is the shipped look. Through the mod's asset resolver, never a
-- bare relative path -- the mod is mounted, so "assets/..." on its own
-- resolves against the GAME's root and silently finds nothing.
local function ballImages()
  if ballArt ~= nil then return ballArt or nil end
  local out, found = {}, false
  for _, name in ipairs({ "ok", "status", "ko" }) do
    local ok, img = pcall(function()
      local path = V.mod.assets:path("assets/battle/hud/ball_"
                                     .. name .. ".png")
      local image = love.graphics.newImage(path)
      image:setFilter("nearest", "nearest")
      return image
    end)
    if ok and img then out[name], found = img, true end
  end
  ballArt = found and out or false
  return ballArt or nil
end

local function drawBall(cx, cy, r, state)
  local g = love.graphics
  local art = ballImages()
  if art then
    local img = art[state] or art.ok
    if img then
      local iw, ih = img:getDimensions()
      g.setColor(1, 1, 1, 1)
      g.draw(img, cx - r, cy - r, 0, (r * 2) / iw, (r * 2) / ih)
      return
    end
  end

  local top, bottom, ink = BALL_RED, BALL_WHITE, BALL_DARK
  if state == "ko" then
    top, bottom = BALL_KO, BALL_KO_DIM
  elseif state == "status" then
    top = BALL_STATUS
  end

  -- Eight pixels across is four pixels of radius, and the button and its
  -- ring stop resolving below about that -- so at handheld size the ball is
  -- deliberately reduced to the three marks that still read: a red top, a
  -- white bottom and the dark band between them. Drawing the full detail
  -- anyway would put a two-pixel smudge in the middle of every ball.
  local detailed = r >= 5

  g.setColor(bottom[1], bottom[2], bottom[3], 1)
  g.circle("fill", cx, cy, r)
  g.setColor(top[1], top[2], top[3], 1)
  g.arc("fill", cx, cy, r, math.pi, math.pi * 2)
  local band = math.max(1, r * 0.26)
  g.setColor(ink[1], ink[2], ink[3], 1)
  g.rectangle("fill", cx - r, cy - band / 2, r * 2, band)
  if detailed then
    g.circle("fill", cx, cy, r * 0.34)
    g.setColor(bottom[1], bottom[2], bottom[3], 1)
    g.circle("fill", cx, cy, r * 0.19)
    g.setColor(ink[1], ink[2], ink[3], 1)
  end
  g.setLineWidth(math.max(1, r * 0.16))
  g.circle("line", cx, cy, r)
  g.setLineWidth(1)
  g.setColor(1, 1, 1, 1)
end

-- Which state a slot is in, matching BattleState:drawBallRow's own reading.
local function ballState(mon)
  if not mon then return nil end            -- omitted, not drawn as empty
  if (mon.hp or 0) <= 0 then return "ko" end
  if mon.status then return "status" end
  return "ok"
end

-- The 2x3 cluster, LEFT-aligned and filling from the left:
--
--     1 2 3
--     4 5 6
--
-- Left-aligned because on this layout the cluster is the left-hand item of
-- the middle row rather than a right-hand column, so a short party keeps its
-- clean edge against the panel's inside wall. Empty slots are omitted rather
-- than drawn as an empty tile, so a rival with two badges does not look like
-- a party that failed to load.
local function occupied(party)
  local drawn = 0
  for slot = 1, 6 do
    if ballState(party[slot]) then drawn = math.max(drawn, slot) end
  end
  return drawn
end

-- How much room the cluster will take, without drawing it. Split out so the
-- caller can centre it in a row that may be taller than it is.
function BattleHudPanel.clusterSize(party, d, gap)
  if not party then return 0, 0 end
  local drawn = occupied(party)
  if drawn == 0 then return 0, 0 end
  local cols = math.min(3, drawn)
  local rows = drawn > 3 and 2 or 1
  return cols * d + (cols - 1) * gap, rows * d + (rows - 1) * gap
end

function BattleHudPanel.drawBalls(party, left, top, d, gap)
  if not party then return 0, 0 end
  local r = d / 2
  for slot = 1, 6 do
    local state = ballState(party[slot])
    if state then
      local col = (slot - 1) % 3
      local row = math.floor((slot - 1) / 3)
      drawBall(left + r + col * (d + gap), top + r + row * (d + gap),
               r, state)
    end
  end
  return BattleHudPanel.clusterSize(party, d, gap)
end

-- ------- the bar

local function hpColor(frac)
  if frac > BattleHudPanel.HP_HIGH then return BattleHudPanel.HP_GREEN end
  if frac > BattleHudPanel.HP_LOW then return BattleHudPanel.HP_YELLOW end
  return BattleHudPanel.HP_RED
end

-- The bar, with the outline that makes it read as a gauge rather than as a
-- coloured smear on a dark field, and the one clamp the shape needs.
--
-- A rounded fill narrower than the bar is tall stops being a bar: the two end
-- caps meet and it collapses into a lens, then a sliver, then nothing. Which
-- would mean 1 HP and 0 HP look the same, and they are the two states that
-- must never be confused.
--
-- Vanilla has the same problem and solves it the same way -- GetHPBarLength,
-- via Timing.hpBarPixels, clamps to a minimum of one pixel whenever hp > 0.
-- The bottom few percent of the bar stop being linear; that is the correct
-- trade.
function BattleHudPanel.drawBar(x, y, w, h, frac, outline, radius, fillOutline)
  local g = love.graphics
  local oc = BattleHudPanel.OUTLINE_COLOR
  g.setColor(oc[1], oc[2], oc[3], 1)
  g.rectangle("fill", x, y, w, h, radius, radius)

  local ix, iy = x + outline, y + outline
  local iw, ih = w - outline * 2, h - outline * 2
  if iw <= 0 or ih <= 0 then g.setColor(1, 1, 1, 1) return end
  local ir = math.max(0, radius - outline)

  local t = BattleHudPanel.TRACK
  g.setColor(t[1], t[2], t[3], 1)
  g.rectangle("fill", ix, iy, iw, ih, ir, ir)
  if not (frac and frac > 0) then g.setColor(1, 1, 1, 1) return end

  local fw = iw * math.min(1, frac)
  if fw < ih then fw = ih end               -- never thinner than a round cap

  -- the fill gets the same treatment as the box: a white shape with the
  -- colour inset into it, rather than a coloured shape with a stroke drawn
  -- over its edge -- a stroke would straddle the boundary and leave a half
  -- pixel of track colour showing through on the inside of the curve
  local fo = math.min(fillOutline or 0, ih / 2 - 1)
  if fo > 0 then
    g.setColor(oc[1], oc[2], oc[3], 1)
    g.rectangle("fill", ix, iy, fw, ih, ir, ir)
  end
  local cxx, cyy = ix + fo, iy + fo
  local cww, chh = fw - fo * 2, ih - fo * 2
  if cww > 0 and chh > 0 then
    local c = hpColor(frac)
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("fill", cxx, cyy, cww, chh,
                math.max(0, ir - fo), math.max(0, ir - fo))
  end
  g.setColor(1, 1, 1, 1)
end

-- ------- how big the box is
--
-- One scale for everything, and it is derived from the panel's own finished
-- WIDTH rather than declared against a reference height. That inversion is
-- what keeps the design honest at 3:2: the width is the constrained axis, so
-- it is the axis that gets resolved first, and the padding, the glyphs, the
-- balls and the bar all follow from whatever it came out as.
function BattleHudPanel.scale(shot)
  local P = BattleHudPanel
  local pw, ph = shot and shot.pw or 0, shot and shot.ph or 0
  if not (pw > 0 and ph > 0) then return 0 end
  local w = math.min(P.PANEL_W * (pw / P.REF_W), P.PANEL_W_CAP_H * ph)
  w = math.max(w, math.min(P.PANEL_W_MIN, P.PANEL_W_MIN_CAP_W * pw))
  if w <= 0 then return 0 end
  return w / P.PANEL_W
end

-- HEIGHT is derived, not declared. The box is one padding, the name row, a
-- gap, the middle row, a gap, the bar, one padding -- where the gap equals
-- the padding, so the margins read as one rhythm rather than as a box with
-- its contents pushed to the ends. Nothing floats in slack, which is also why
-- the player's panel comes out two pixels shorter than the foe's: no ball
-- cluster to make room for.
function BattleHudPanel.layout(s, hasBalls)
  local P = BattleHudPanel
  local w = P.PANEL_W * s
  local outline, pad = P.OUTLINE * s, P.PAD * s
  local cw = w - (outline + pad) * 2
  local gap = P.COL_GAP * s
  local barH = P.BAR_H * s
  local rowGap = P.ROW_GAP * s

  -- The name gets the whole inner width, and the magnification is the largest
  -- whole number that still fits NAME_MAX characters -- sized for the cut
  -- length rather than for the name in hand, so every panel's glyphs are the
  -- same size and a short name does not get a huge one.
  local nameX = math.max(1, math.floor(cw / (P.NAME_MAX * 8)))
  local nameY = nameX + (P.NAME_STRETCH or 0)
  local nameH = 8 * nameY

  local ballD, ballGap = P.BALL_D * s, P.BALL_GAP * s
  local clusterW = ballD * 3 + ballGap * 2
  local clusterH = ballD * 2 + ballGap

  -- Reserve for the WIDEST label the column can ever hold ("L:100"), not for
  -- the one in hand: a panel that changed width between level 99 and 100, or
  -- between a level and a status, would visibly twitch.
  local labelScale = math.max(P.LABEL_MIN, math.floor(nameX / 2))
  local reserve = hasBalls and (clusterW + gap) or 0
  while labelScale > 1 and (5 * 8 * labelScale + reserve) > cw do
    labelScale = labelScale - 1
  end
  local labelH = 8 * labelScale
  local rowH = hasBalls and math.max(clusterH, labelH) or labelH

  return {
    w = w,
    h = outline * 2 + pad * 2 + nameH + rowGap + rowH + rowGap + barH,
    outline = outline, pad = pad, cw = cw, gap = gap,
    barH = barH, rowGap = rowGap, rowH = rowH,
    nameX = nameX, nameY = nameY, nameH = nameH,
    labelScale = labelScale, labelH = labelH,
    ballD = ballD, ballGap = ballGap,
  }
end

-- ------- the panel

-- What the bar should read, from the battler the engine is already animating.
local function fractionOf(battler)
  local mon = battler and battler.mon
  if not mon then return nil end
  local maxHP = mon.stats and mon.stats.hp
  if not maxHP or maxHP <= 0 then return nil end
  local shown = battler.shownHP or mon.hp or 0
  if shown < 0 then shown = 0 end
  return math.min(1, shown / maxHP)
end

-- The right-hand label: the status if there is one, the level if there is
-- not. Exactly the ROM's own swap (BattleState:statusLabel is documented as
-- "the HUD label drawn in place of the level for a statused mon"), so the
-- panel never has to find room for both.
local function rightLabel(battler)
  local status = battler and battler.shownStatus
  if status then
    return tostring(status), BattleHudPanel.STATUS_COLOR[status]
                             or BattleHudPanel.TEXT
  end
  local level = battler and battler.mon and battler.mon.level
  return "L:" .. tostring(level or "?"), BattleHudPanel.TEXT
end

-- Draw one panel with its top-left at (x, y), for `battler`.
-- `party` draws the ball cluster; pass nil for the player's side.
function BattleHudPanel.draw(battler, party, x, y, s)
  if not battler then return end
  local g = love.graphics
  local P = BattleHudPanel
  local L = P.layout(s, party and true or false)
  local w, h = L.w, L.h
  local radius = P.RADIUS * s

  -- box: white outline, then the black field inset into it
  local oc = P.OUTLINE_COLOR
  g.setColor(oc[1], oc[2], oc[3], 1)
  g.rectangle("fill", x, y, w, h, radius, radius)
  local f = P.FILL
  g.setColor(f[1], f[2], f[3], 1)
  g.rectangle("fill", x + L.outline, y + L.outline,
              w - L.outline * 2, h - L.outline * 2,
              math.max(0, radius - L.outline), math.max(0, radius - L.outline))
  g.setColor(1, 1, 1, 1)

  local cx = x + L.outline + L.pad
  local cy = y + L.outline + L.pad
  local right = cx + L.cw

  -- row 1: the name, cut to NAME_MAX, across the full inner width
  local name = battler.name or "?"
  if #name > P.NAME_MAX then name = name:sub(1, P.NAME_MAX) end
  P.text(name, cx, cy, L.nameX, L.nameY, P.TEXT)

  -- row 2: the balls at the left, the level or status flush right, each
  -- centred against the taller of the two so neither sits high in the row
  local rowY = cy + L.nameH + L.rowGap
  if party then
    -- measured before it is drawn, so a party of three or fewer -- one row of
    -- balls in a slot sized for two -- sits centred rather than hanging from
    -- the top of the row
    local _, ballH = P.clusterSize(party, L.ballD, L.ballGap)
    P.drawBalls(party, cx, rowY + (L.rowH - ballH) / 2, L.ballD, L.ballGap)
  end
  local label, labelColor = rightLabel(battler)
  local labelW = P.textWidth(label) * L.labelScale
  P.text(label, right - labelW, rowY + (L.rowH - L.labelH) / 2,
         L.labelScale, L.labelScale, labelColor)

  -- row 3: the bar, across the full inner width
  P.drawBar(cx, rowY + L.rowH + L.rowGap, L.cw, L.barH, fractionOf(battler),
            P.BAR_OUTLINE * s, P.BAR_RADIUS * s, P.FILL_OUTLINE * s)
end

-- ------- where the two panels go
--
-- The sides keep the arrangement the snapped HUD already uses (the player
-- near, the foe far, per HUD_SIDES_SWAPPED), because that is the framing the
-- shot is composed around: the player's mon stands low and left, the foe's
-- high and right, and the text box owns the bottom rows. What that leaves
-- free is the TOP-LEFT corner and the band on the RIGHT between the foe and
-- the box, which is exactly where these two go.
--
-- Both are measured from the WINDOW's corners rather than from the letterbox,
-- for the reason the snapped HUD is: at 3:2 the gutter is 120 px and there is
-- no version of this panel that lives inside it. The one letterbox-relative
-- measurement is the foe's bottom edge, which hangs off the top of the text
-- box because the box is the thing it must not collide with.
--
-- Every edge is measured to the OUTSIDE of the white outline, which is what
-- the eye lines up against: the outline is part of the panel, not something
-- drawn around it.
function BattleHudPanel.place(shot, swapped, boxTopRow, enemyHasBalls)
  local P = BattleHudPanel
  local s = P.scale(shot)
  if s <= 0 then return nil end
  local pl = P.layout(s, false)
  local en = P.layout(s, enemyHasBalls and true or false)
  local edge = P.EDGE * s
  local boxTop = shot.ly + (boxTopRow or 96) * shot.scale
  local lift = P.ENEMY_LIFT * s

  local nearX = edge
  local farX = shot.pw - edge - pl.w
  local playerX = swapped and nearX or farX
  local enemyX = swapped and farX or nearX

  -- the near side hangs from the top of the window, the far side from the
  -- top of the text box
  local playerY = swapped and edge or (boxTop - lift - pl.h)
  local enemyY = swapped and (boxTop - lift - en.h) or edge

  return {
    player = { math.floor(playerX + 0.5), math.floor(playerY + 0.5) },
    enemy = { math.floor(enemyX + 0.5), math.floor(enemyY + 0.5) },
    scale = s,
  }
end

function BattleHudPanel.invalidate()
  textCache, textCount = {}, 0
  ballArt = nil
end

return BattleHudPanel
