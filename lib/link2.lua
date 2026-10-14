-- One GB-Link visit to a Gen 2 (Gold/Silver/Crystal) Trade Center: the
-- online session, and both parties as the bytes each side sees.
--
-- The far side (a cart driven by pokemon.gblink.io, or Lorenzooone's Python
-- client) keeps a model of OUR party and checks every mon we offer against
-- it byte for byte (gsc_trading.py search_for_mon); a mismatch is an
-- automatic "no".  So both parties live here as wire mons (lib/codec2.lua)
-- from the moment section 1 goes out, and every trade changes them exactly
-- the way the cart and the clients do (trade_mon, evolve_mon): the given mon
-- leaves its slot, the rest close up, the received mon goes on the END and
-- trade-evolves there.  The engine's own party is lib/tradecenter2.lua's
-- business; this only says what was traded.

local Codec2 = nil  -- set in new()

local Link2 = {}
Link2.__index = Link2

local function noop() end

local function copy(w)
  local out = {}
  for k, v in pairs(w) do out[k] = v end
  return out
end

-- opts: game, env (lib/codec2.lua env), Codec2, session, Mail (src.core.gen2.Mail), log
function Link2.new(opts)
  Codec2 = opts.Codec2
  local self = setmetatable({
    game = opts.game,
    env = opts.env,
    Codec2 = opts.Codec2,
    session = opts.session,
    Mail = opts.Mail,
    log = opts.log or noop,
    ours = nil,          -- wire party: { name, id, mons }
    theirs = nil,
    theirName = nil,
    ready = false,
    roundOpen = false,
    cur = {},
    listener = nil,
    ended = false,
    error = nil,
  }, Link2)
  return self
end

function Link2:notify(ev)
  if self.listener then self.listener:onLink(ev) end
end

function Link2:fail(why)
  if self.error then return end
  self.error = why
  self:notify({ type = "error", message = why })
end

local function mailOf(Mail, save, slot)
  if not Mail then return nil end
  local ok, state = pcall(Mail.state, save)
  return ok and state and state.party and state.party[slot] or nil
end

-- round 1's data, straight from the save
function Link2:prepare()
  local save = self.game.save
  local player = save.player or {}
  local ok, why = pcall(function()
    local mons = {}
    for i, mon in ipairs(save.party or {}) do
      mons[i] = self.Codec2.wireMon(self.env, mon, mailOf(self.Mail, save, i))
    end
    self.ours = {
      name = self.Codec2.name(self.env, player.name or "GOLD", 7),
      id = player.id or 0,
      mons = mons,
    }
  end)
  if not ok then
    self.error = "your party can't be sent: " .. tostring(why)
    return false
  end
  if #self.ours.mons == 0 then
    self.error = "your party is empty"
    return false
  end
  local s1, s2, s3 = self.Codec2.sections(self.ours)
  self.session:setOurs(s1, s2, s3)
  return true
end

-- the mail section goes both ways exactly when either section 1 holds mail
function Link2.needMail(ours, theirs)
  return Codec2.sectionHasMail(ours[1]) or Codec2.sectionHasMail(theirs[1])
end

-- ------------------------------------------------------------------
-- what our player does (called by lib/tradecenter2.lua)
-- ------------------------------------------------------------------

-- slot is 0-based into our party; nil is CANCEL
function Link2:choose(slot)
  if slot == nil then
    self.session:choose(nil)
    return true
  end
  local w = self.ours and self.ours.mons[slot + 1]
  if not w then return false end
  self.cur.ourSlot = slot
  self.session:choose(slot, self.Codec2.single(w))
  return true
end

-- an offer that matched nothing in our copy is always a "no"
function Link2:accept(ok) self.session:accept(ok and not self.cur.mismatch) end
function Link2:cancel() self.session:cancel() end
function Link2:leave() self.session:leave() end

-- after a trade, once the engine has filed (and evolved) the received mon:
-- its moves go out as MVS2.  A move the engine taught or the player chose
-- at evolution overwrites the wire copy, the way the peer's model takes our
-- MVS2 (gsc_trading.py get_move_data_only).
function Link2:roundDone(engineMon)
  if not self.afterTrade then return end
  self.afterTrade = false
  local last = self.ours.mons[#self.ours.mons]
  if engineMon and last then
    local fresh = self.Codec2.wireMon(self.env, engineMon, nil)
    self.Codec2.applyMoves(last, self.Codec2.moves(fresh))
  end
  self.session:nextRound(last and self.Codec2.moves(last) or string.rep("\0", 8))
end

-- ------------------------------------------------------------------
-- pump
-- ------------------------------------------------------------------

function Link2:update()
  if self.closed then return end
  self.session:update()
  for _, ev in ipairs(self.session:takeEvents()) do self:handle(ev) end
end

function Link2:handle(ev)
  local kind = ev.type
  if kind == "paired" or kind == "mode" then
    self:notify(ev)
  elseif kind == "party" then
    local party, why = self.Codec2.parseSections(ev.sec1, ev.sec2, ev.sec3)
    if not party then
      self:fail("the other player's party could not be read (" .. tostring(why) .. ")")
      return
    end
    self.theirs = party
    self.theirName = self.Codec2.decodeText(self.env, party.name, 0, 11)
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
      -- CHC2's bytes only say WHICH mon: it is looked up in our copy of
      -- their party, which is what trades (the Python client does the same,
      -- and a far side whose own copy of its party went wrong -- seen live:
      -- its client re-reading a cart over a slipping link -- then still
      -- trades the real mon).  An offer that is not in our copy at all is
      -- declined, as the Python client's sanity checks decline it.
      local w = ev.mon and self.Codec2.fromSingle(ev.mon)
      local idx = w and self.theirs and self.Codec2.findMon(self.theirs.mons, w)
      if idx then
        self.cur.theirSlot, self.cur.mismatch = idx - 1, nil
        self:notify({ type = "theirPick", slot = idx - 1, mon = self.theirs.mons[idx] })
      else
        self.cur.theirSlot, self.cur.mismatch = ev.slot, true
        self.log("gblink: their offer (slot %d) is not in our copy of their party; declining", ev.slot + 1)
        self:notify({ type = "theirPick", slot = ev.slot, mismatch = true,
                      mon = self.theirs and self.theirs.mons[ev.slot + 1] })
      end
    end
  elseif kind == "theirAccept" then
    self:notify({ type = "theirAccept", ok = ev.ok })
  elseif kind == "traded" then
    local c = self.cur
    local ourGiven = self.ours.mons[c.ourSlot + 1]
    local theirGiven = self.theirs.mons[c.theirSlot + 1]
    -- what arrives here, before any evolution: the engine evolves its own copy
    local arrived = copy(theirGiven)
    self.Codec2.trade(self.env, self.ours, c.ourSlot + 1, theirGiven)
    self.Codec2.trade(self.env, self.theirs, c.theirSlot + 1, ourGiven)
    self.afterTrade = true
    self.roundOpen = false
    self.cur = {}
    self:notify({ type = "traded", ourSlot = c.ourSlot, theirSlot = c.theirSlot, received = arrived })
  elseif kind == "again" then
    self.cur = {}
    self:notify({ type = "again" })
  elseif kind == "mvs" then
    local last = self.theirs and self.theirs.mons[#self.theirs.mons]
    if last then self.Codec2.applyMoves(last, ev.data) end
  elseif kind == "ended" then
    self.ended = true
    self:notify({ type = "ended" })
  elseif kind == "error" then
    self:fail(ev.message)
  end
end

function Link2:status()
  return self.session.status, self.session.progress, self.session.mode
end

function Link2:close()
  if self.closed then return end
  self.closed = true
  self.session:close()
end

return Link2
