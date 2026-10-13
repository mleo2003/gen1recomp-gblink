-- One GB-Link visit to the Cable Club: the online session plus what each
-- side's party looks like to the other, held for as long as the room stays
-- open (several LinkState screens can come and go over one Link).
--
-- After a trade neither side re-sends its party (lib/session.lua); both
-- rebuild the other's the way the cart itself does:
--
--   engine/link/cable_club.asm .doTrade: RemovePokemon, then
--   AddEnemyMonToPlayerParty -- the traded-away mon leaves its slot, the
--   others close up, and the received one goes on the END of the party
--
-- so this keeps the far player's party in that order, evolves the mon we
-- sent if its species trade-evolves (gsc_trading_data_utils.py
-- evolution_procedure / update_stats), and takes their MVS1 for the last
-- slot.  main.lua puts our own received mon at the end of game.save.party
-- for the same reason: the far side picks by slot number.

local Link = {}
Link.__index = Link

local function noop() end

-- opts: game, env, Codec, session, log
function Link.new(opts)
  return setmetatable({
    game = opts.game,
    env = opts.env,
    Codec = opts.Codec,
    session = opts.session,
    log = opts.log or noop,
    theirName = nil,
    theirParty = nil,
    ready = false,       -- the far party is known and the menu is open
    roundOpen = false,   -- the engine may show a trade screen now
    cur = {},            -- this menu iteration: slots and mons
    listener = nil,
    ended = false,
    error = nil,
  }, Link)
end

function Link:player()
  local p = self.game.save.player or {}
  return { name = p.name, id = p.id }
end

-- round 1's data, straight from the save
function Link:prepare()
  local s1, s2 = self.Codec.encodeSections(self.env, self:player(), self.game.save.party)
  if not s1 then
    self.error = "your party can't be sent: " .. tostring(s2)
    return false
  end
  self.session:setOurs(s1, s2)
  return true
end

function Link:notify(ev)
  if self.listener then self.listener:onLink(ev) end
end

function Link:fail(why)
  if self.error then return end
  self.error = why
  self:notify({ type = "error", message = why })
end

-- ------------------------------------------------------------------
-- the far party
-- ------------------------------------------------------------------

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

-- the engine's TRADE evolution for a species, if it has one
function Link:tradeEvolution(species)
  local def = self.env.data.pokemon[species]
  for _, evo in ipairs(def and def.evolutions or {}) do
    if evo.method == "TRADE" then return evo.species end
  end
  return nil
end

-- update_stats: new stats from the new species, current HP moved by the
-- change in max HP
function Link:evolvePacked(mon, to)
  local Stats = self.env.Stats
  local fromDef, toDef = self.env.data.pokemon[mon.species], self.env.data.pokemon[to]
  if not fromDef or not toDef then return end
  local level = tonumber(mon.level) or 5
  local before = Stats.calc(fromDef, level, mon.dvs or {}, mon.statExp).hp
  local after = Stats.calc(toDef, level, mon.dvs or {}, mon.statExp).hp
  mon.species = to
  mon.hp = math.max(0, math.min(after, (tonumber(mon.hp) or before) + after - before))
end

function Link:applyTrade()
  local cur = self.cur
  local party = self.theirParty
  if not party or cur.theirSlot == nil or not cur.ourMon then return end
  table.remove(party, cur.theirSlot + 1)
  local given = copy(cur.ourMon)
  local to = self:tradeEvolution(given.species)
  if to then self:evolvePacked(given, to) end
  party[#party + 1] = given
end

-- ------------------------------------------------------------------
-- what our player does (called by lib/bridge.lua)
-- ------------------------------------------------------------------

-- slot is 0-based into game.save.party
function Link:choose(slot)
  local mon = self.game.save.party[slot + 1]
  if not mon then return false end
  local single, why = self.Codec.encodeSingle(self.env, self:player(), mon)
  if not single then
    self:fail("that POKéMON can't be sent: " .. tostring(why))
    return false
  end
  self.cur.ourSlot = slot
  self.cur.ourMon = self.Codec.decodeSingle(self.env, single)
  self.session:choose(slot, single)
  return true
end

function Link:accept(ok)
  self.session:accept(ok)
end

function Link:cancel()
  self.session:cancel()
end

-- the engine opened the next round after a trade: the received mon has
-- arrived (and evolved), so its moves can go out
function Link:engineRound()
  if not self.afterTrade then return end
  self.afterTrade = false
  local party = self.game.save.party
  local last = party[#party]
  local mvs = last and self.Codec.encodeMoves(self.env, self:player(), last)
  self.session:nextRound(mvs or string.rep("\0", 9))
end

function Link:leave()
  self.session:leave()
end

-- TRADE AGAIN after a screen was backed out of: a CANCEL that has not gone
-- out yet is dropped, so the next pick is the one that counts
function Link:resume()
  self.session.cancelling = false
end

-- ------------------------------------------------------------------
-- pump (main.lua calls this once per fixed step for every live Link)
-- ------------------------------------------------------------------

function Link:update()
  if self.closed then return end
  self.session:update()
  for _, ev in ipairs(self.session:takeEvents()) do self:handle(ev) end
end

function Link:handle(ev)
  local kind = ev.type
  if kind == "paired" or kind == "mode" then
    self:notify(ev)
  elseif kind == "party" then
    local d, why = self.Codec.decodeSections(self.env, ev.sec1, ev.sec2)
    if not d then
      self:fail("the other player's party could not be read (" .. tostring(why) .. ")")
      return
    end
    self.theirName, self.theirParty = d.name, d.party
    self.ready, self.roundOpen = true, true
    self:notify({ type = "party" })
  elseif kind == "round" then
    self.roundOpen = true
    self:notify({ type = "round" })
  elseif kind == "theirChoice" then
    if ev.stop then
      self.cur.theirSlot = nil
      self:notify({ type = "theirStop" })
    else
      self.cur.theirSlot = ev.slot
      local mon = ev.mon and self.Codec.decodeSingle(self.env, ev.mon)
      -- the far side's own bytes for the mon it offers are the truth; our
      -- copy of its party is only a rebuild
      if mon and self.theirParty and self.theirParty[ev.slot + 1] then
        self.theirParty[ev.slot + 1] = mon
      end
      self:notify({ type = "theirPick", slot = ev.slot, mon = mon })
    end
  elseif kind == "theirAccept" then
    self:notify({ type = "theirAccept", ok = ev.ok })
  elseif kind == "traded" then
    self:applyTrade()
    self.afterTrade = true
    self.roundOpen = false
    self.cur = {}
    self:notify({ type = "traded" })
  elseif kind == "again" then
    self.cur = {}
    self:notify({ type = "again" })
  elseif kind == "mvs" then
    local party = self.theirParty
    if party and party[#party] then self.Codec.applyMoves(self.env, party[#party], ev.data) end
  elseif kind == "ended" then
    self.ended = true
    self:notify({ type = "ended" })
  elseif kind == "error" then
    self:fail(ev.message)
  end
end

-- engine/link/cable_club.asm .doTrade files the received mon at the END of
-- the party (RemovePokemon, then AddEnemyMonToPlayerParty); the far side
-- counts our slots that way, so the engine's in-place swap is undone here
function Link.fileAtEnd(party, received)
  for i, mon in ipairs(party or {}) do
    if mon == received then
      table.remove(party, i)
      party[#party + 1] = mon
      return true
    end
  end
  return false
end

-- the catch-rate byte rode in `extra` (the link sanitizer keeps nothing
-- else); once the mon lands it becomes the mon's own field
function Link.land(mon)
  local carried = mon and type(mon.extra) == "table" and mon.extra.gblink
  if type(carried) ~= "table" then return false end
  if carried.catchRate then mon.catchRate = carried.catchRate end
  mon.extra.gblink = nil
  if next(mon.extra) == nil then mon.extra = nil end
  return true
end

function Link:status()
  return self.session.status, self.session.progress, self.session.mode
end

function Link:close()
  if self.closed then return end
  self.closed = true
  self.session:close()
end

return Link
