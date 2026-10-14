-- The Trade Center table on Gold/Silver/Crystal, played against a GB-Link
-- peer: what the special TradeCenter shows on the cart (pokecrystal
-- engine/link/link.asm LinkTradeMenu), built from the engine's own Gen 2
-- pieces -- Chrome boxes and text, Gen2SummaryMenu for STATS,
-- Gen2TradeAnim and Gen2EvolutionAnim after a trade, and the autosave.
--
--   wait      "Please wait!" while the parties go across
--   menu      our party, theirs, CANCEL; A on ours -> STATS / TRADE, A on
--             theirs -> STATS
--   picked    our choice is out; waiting for theirs
--   confirm   "Trade X for Y?"  TRADE / CANCEL
--   accepted  our answer is out; waiting for theirs
--   trading   the animation, the evolution, the autosave
--   between   waiting for the other player to sit down again
--   message   a line, then back to the menu (a declined trade) or out
--   leaving   our CANCEL is out; waiting for the link to wind down
--
-- What lands in the party is lib/party2.lua's; this only drives the link
-- (lib/link2.lua) and shows it.

local Chrome = require("src.ui.gen2.Chrome")
local Screens = require("src.ui.Screens")
local Strings = require("src.core.Strings")

local TC = {}
TC.__index = TC
TC.isOpaque = true
function TC:wantsFillScale() return true end

local function noop() end

-- opts: game, link (Link2, nil if the desk never linked), env, Codec2,
-- Party2, Mail, Evolution, log, onDone()
function TC.new(opts)
  local self = setmetatable({
    game = opts.game, link = opts.link, env = opts.env, Codec2 = opts.Codec2,
    Party2 = opts.Party2, Mail = opts.Mail, Evolution = opts.Evolution,
    log = opts.log or noop, onDone = opts.onDone,
    stage = "wait", row = 1, sub = 1, yes = 1,
  }, TC)
  local link = self.link
  if not link or link.closed or link.error then
    self:say(link and link.error or Strings("The link is closed."), "out")
    return self
  end
  if link.ended then
    -- both already left this table once: the visit is over
    self:say(Strings("The trade is over.\nPlease come again."), "out")
    return self
  end
  link.listener = self
  if not link.ours then
    -- the party goes out when we sit down, as the cart's does
    if not link:prepare() then self:say(link.error, "out") end
  end
  if link.ready and link.roundOpen then self:openMenu() end
  return self
end

function TC:save() return self.game.save end
function TC:party() return (self.game.save and self.game.save.party) or {} end

function TC:speciesName(species)
  local def = self.game.data.pokemon and self.game.data.pokemon[species]
  return (def and def.name) or tostring(species or "?")
end

function TC:monName(mon)
  if not mon then return "?" end
  if mon.isEgg then return Strings("EGG") end
  return self:speciesName(mon.species)
end

-- their party as engine records (for names and STATS), rebuilt per round
function TC:theirMons()
  local link = self.link
  local mons = {}
  for i, w in ipairs((link and link.theirs and link.theirs.mons) or {}) do
    local ok, mon = pcall(self.Codec2.engineMon, self.env, w)
    mons[i] = ok and mon or { species = "?" }
  end
  return mons
end

function TC:openMenu()
  self.stage = "menu"
  self.theirs = self:theirMons()
  local n = #self:party()
  if self.row > n then self.row = math.max(1, n) end
end

-- a line in the bottom box; then = "menu" (back to choosing) or "out"
function TC:say(text, after)
  self.stage = "message"
  self.text = tostring(text or "")
  self.after = after or "menu"
end

function TC:finish()
  if self.finished then return end
  self.finished = true
  if self.link and self.link.listener == self then self.link.listener = nil end
  local stack = self.game.stack
  if stack:top() == self then stack:pop() end
  if self.onDone then self.onDone() end
end

-- ------------------------------------------------------------------
-- the link's events
-- ------------------------------------------------------------------

function TC:theirName()
  return (self.link and self.link.theirName) or "?"
end

function TC:onLink(ev)
  local t = ev.type
  if t == "party" or t == "round" then
    if self.stage == "wait" or self.stage == "between" then self:openMenu() end
  elseif t == "theirPick" then
    self.log("they offer slot %d%s", (ev.slot or 0) + 1, ev.mismatch and " (not in our copy: declining)" or "")
    self.theirPick = ev
    if self.stage == "picked" then self:openConfirm() end
  elseif t == "theirStop" then
    self:say(Strings("%s canceled\nthe trade.", self:theirName()), "out")
  elseif t == "theirAccept" then
    self.log("they %s", ev.ok and "accept" or "decline")
  elseif t == "again" then
    self.theirPick = nil
    self:say(Strings("Too bad! The trade\nwas canceled!"), "menu")
  elseif t == "traded" then
    self:trade(ev)
  elseif t == "ended" then
    if self.stage ~= "message" then self:finish() end
  elseif t == "error" then
    self:say(TC.sentence(ev.message), "out")
  end
end

-- "the other player left" -> "The other player left."
function TC.sentence(text)
  text = tostring(text or "")
  text = text:gsub("^%l", string.upper)
  if not text:match("[%.!?]$") then text = text .. "." end
  return text
end

function TC:openConfirm()
  local pick = self.theirPick
  if pick.mismatch then
    -- not the mon their own party data says: never trade it
    self.link:accept(false)
    self.stage = "accepted"
    return
  end
  self.stage, self.yes = "confirm", 1
end

-- ------------------------------------------------------------------
-- a trade: file it, show it, evolve it, save it, then sit down again
-- ------------------------------------------------------------------

function TC:trade(ev)
  self.stage = "trading"
  self.theirPick = nil
  local game = self.game
  local landed = self.Party2.receive({ env = self.env, Codec2 = self.Codec2, save = game.save,
                                       Mail = self.Mail, Evolution = self.Evolution },
                                     ev.ourSlot, ev.received)
  self.log("traded %s for %s", tostring(landed.given and landed.given.species), tostring(landed.mon.species))
  local function finishRound()
    if game.writeSave then pcall(game.writeSave, game) end
    self.link:roundDone(game.save.party[landed.index])
    self.stage = "between"
    if self.link.roundOpen then self:openMenu() end
  end
  local function evolve()
    if not landed.entry then return finishRound() end
    local ok = pcall(Screens.push, game, "Gen2EvolutionAnim", {
      mon = landed.mon, entry = landed.entry, index = landed.index,
      party = game.save.party, save = game.save,
      -- a trade evolution cannot be stopped: both clients have already
      -- evolved their copy of this mon
      force = true,
      onDone = function()
        if game.stack:top() ~= self then game.stack:pop() end
        finishRound()
      end,
    })
    if not ok then
      self.Party2.evolveNow({ env = self.env, save = game.save, Evolution = self.Evolution }, landed)
      finishRound()
    end
  end
  local tables = game.world and game.world.eventTables
  local ok = pcall(Screens.push, game, "Gen2TradeAnim", {
    given = landed.given, received = landed.mon, save = game.save,
    row = { otName = self:theirName(), otId = landed.mon.otId },
    eventTables = tables,
    onDone = function()
      if game.stack:top() ~= self then game.stack:pop() end
      evolve()
    end,
  })
  if not ok then evolve() end
end

-- ------------------------------------------------------------------
-- input
-- ------------------------------------------------------------------

function TC:rows()
  return #self:party() + #(self.theirs or {}) + 1
end

function TC:rowKind(row)
  local n, m = #self:party(), #(self.theirs or {})
  if row <= n then return "ours", row end
  if row <= n + m then return "theirs", row - n end
  return "cancel"
end

function TC:openStats(mon)
  local game = self.game
  pcall(Screens.push, game, "Gen2SummaryMenu", {
    mon = mon, save = game.save,
    onClose = function() game.stack:pop() end,
  })
end

function TC:cancelTable()
  self.link:choose(nil)
  self.stage = "leaving"
end

function TC:update()
  local input = self.game.input
  local link = self.link
  if self.stage ~= "message" and link and link.error then
    return self:say(TC.sentence(link.error), "out")
  end
  local stage = self.stage
  if stage == "menu" then
    local rows = self:rows()
    if input:wasPressed("up") then self.row = self.row > 1 and self.row - 1 or rows
    elseif input:wasPressed("down") then self.row = self.row < rows and self.row + 1 or 1
    elseif input:wasPressed("b") then self.row = rows
    elseif input:wasPressed("a") then
      local kind, i = self:rowKind(self.row)
      if kind == "ours" then
        self.stage, self.sub = "sub", 1
      elseif kind == "theirs" then
        self:openStats(self.theirs[i])
      else
        self:cancelTable()
      end
    end
  elseif stage == "sub" then
    if input:wasPressed("left") or input:wasPressed("right") then self.sub = 3 - self.sub
    elseif input:wasPressed("b") then self.stage = "menu"
    elseif input:wasPressed("a") then
      local _, i = self:rowKind(self.row)
      if self.sub == 1 then
        self.stage = "menu"
        self:openStats(self:party()[i])
      else
        self.picked = i
        if link:choose(i - 1) then
          self.stage = "picked"
        else
          self.stage = "menu"
        end
      end
    end
  elseif stage == "picked" then
    if self.theirPick then self:openConfirm() end
  elseif stage == "confirm" then
    if input:wasPressed("up") or input:wasPressed("down") then self.yes = 3 - self.yes
    elseif input:wasPressed("b") then
      link:accept(false)
      self.stage = "accepted"
    elseif input:wasPressed("a") then
      self.log("we %s", self.yes == 1 and "accept" or "decline")
      link:accept(self.yes == 1)
      self.stage = "accepted"
    end
  elseif stage == "message" then
    if input:wasPressed("a") or input:wasPressed("b") then
      if self.after == "out" then
        if link and not link.ended and not link.closed and not link.error then link:leave() end
        return self:finish()
      end
      self:openMenu()
    end
  elseif stage == "leaving" then
    if not link or link.ended or link.closed then self:finish() end
  end
end

-- ------------------------------------------------------------------
-- drawing: the cart's layout -- our party in the top box, theirs in the
-- middle one, CANCEL under them, and the bottom box for every question
-- ------------------------------------------------------------------

local function names(self, list, name, top)
  Chrome.textbox(0, top, 18, 6)
  Chrome.print(name, 2, top)
  for i, mon in ipairs(list) do Chrome.print(self:monName(mon), 5, top + i) end
end

local function bottom(lines)
  Chrome.textbox(0, 12, 18, 4)
  for i, line in ipairs(lines) do Chrome.print(line, 1, 12 + i * 2) end
end

function TC:draw()
  Chrome.clear()
  local stage = self.stage
  if stage == "wait" or not self.theirs then
    Chrome.textbox(3, 8, 12, 1)
    Chrome.print(Strings("PLEASE WAIT!"), 4, 9)
    local status, progress = self.link and self.link:status()
    if status == "exchanging" and progress and (progress.total or 0) > 1 then
      Chrome.print(("%d/%d"):format(progress.done or 0, progress.total or 0), 6, 12)
    end
    if stage == "message" then bottom(Chrome.wrap(self.text, 18)) end
    love.graphics.setColor(1, 1, 1, 1)
    return
  end
  local player = (self.game.save and self.game.save.player) or {}
  names(self, self:party(), player.name or "GOLD", 0)
  names(self, self.theirs, self:theirName(), 8)
  Chrome.print(Strings("CANCEL"), 2, 16)
  local kind, i = self:rowKind(self.row)
  local cursorY = kind == "ours" and i or kind == "theirs" and (8 + i) or 16
  local cursorX = kind == "cancel" and 1 or 4
  if stage == "menu" then
    Chrome.cursor(cursorX, cursorY)
  else
    Chrome.cursor(cursorX, cursorY, true)
  end
  if stage == "sub" then
    Chrome.textbox(0, 15, 18, 1)
    Chrome.print(Strings("STATS"), 2, 16)
    Chrome.print(Strings("TRADE"), 11, 16)
    Chrome.cursor(self.sub == 1 and 1 or 10, 16)
  elseif stage == "picked" or stage == "accepted" or stage == "between" or stage == "leaving" then
    bottom({ Strings("Waiting for"), Strings("%s...", self:theirName()) })
  elseif stage == "confirm" then
    local pick = self.theirPick
    local theirs = pick and pick.mon and self.Codec2.engineMon(self.env, pick.mon)
    bottom({ Strings("Trade %s", self:monName(self:party()[self.picked])),
             Strings("for %s?", self:monName(theirs)) })
    Chrome.textbox(10, 7, 8, 3)
    Chrome.print(Strings("TRADE"), 12, 8)
    Chrome.print(Strings("CANCEL"), 12, 10)
    Chrome.cursor(11, self.yes == 1 and 8 or 10)
  elseif stage == "message" then
    bottom(Chrome.wrap(self.text, 18))
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return TC
