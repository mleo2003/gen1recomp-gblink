-- One player's side of a Gen 1 or Gen 2 online trade, spoken directly to the trade
-- server -- the role pokemon.gblink.io and the Python client play for a
-- Game Boy plugged into a GB-Link (or BGB), except that the "Game Boy" here
-- is the engine's own party and trade screen.
--
-- The order of messages is gsc_trading.py's player_trade / do_trade, and the
-- counter discipline is its send_with_counter / get_with_counter: BUF1,
-- NEG1, CHC1, ACP1, ASK1, SUC1 and MVS1 share one counter per side, so this
-- side must send exactly the sequence the reference does or the other client
-- waits forever for a number that never comes.
--
--   pair      first message registers the room; the server says "CLIENT"
--   versions  S VEC1 4.1.0, and the peer's VEC1 must exist (protocol 4+)
--   mode      the peer's BUF1 is adopted, so nobody is asked to switch
--   round 1   sync: SNG1 windows for sections 1 (party) and 2 (patches)
--             buffered: one FLL1 each way
--   menu      CHC1 each (slot or $6F), then ACP1 each ($62 / $61); a trade
--             that both accept is closed by ASK1 + SUC1 each
--   round n   no section exchange: each side rebuilds the other's party
--             from what it already knows and sends one MVS1 for the mon it
--             just received
--
-- Gen 2 (/link2/, Proto.forGen(2)) is the same flow with "2" names, a
-- 0x1BC-byte party section, a mail section 3 that is synced only when either
-- party holds mail (opts.needMail decides, from both section 1s, exactly as
-- the peer does), a 0x76-byte CHC2 mon and an 8-byte MVS2.
--
-- After a trade this side always answers ASK1 with "no data needed".  The
-- Python client re-exchanges sections only when BOTH answers say "needed",
-- and the web client never does, so this keeps both on the same path: no
-- re-exchange, one MVS1 from each side per round.

local Session = {}
Session.__index = Session

local function noop() end

-- opts: conn (lib/ws.lua shape), Proto (lib/proto.lua, or Proto.forGen(2)),
-- now(), rng(lo, hi), log(fmt, ...), needMail(ours, theirs) for Gen 2
function Session.new(opts)
  local T = opts.Proto.T
  local self = setmetatable({
    T = T,
    counterKinds = { [T.BUF] = true, [T.NEG] = true, [T.CHC] = true, [T.ACP] = true,
                     [T.ASK] = true, [T.SUC] = true, [T.MVS] = true },
    needMail = opts.needMail,
    preferMode = opts.preferMode,
    conn = opts.conn,
    Proto = opts.Proto,
    now = opts.now,
    rng = opts.rng,
    log = opts.log or noop,
    status = "connecting",
    progress = nil,
    paired = false,
    mode = nil,
    sendDict = {},
    plain = {},           -- latest VEC1 / FLL1 / VES1 payloads
    queues = {},          -- counter kinds: FIFO of accepted payloads
    ownCtr = nil,
    expect = nil,
    events = {},
    ours = nil,           -- { [1] = section 1, [2] = section 2 } for round 1
    theirs = {},
    cur = nil,            -- the sync section in flight
    pendingChoice = nil,  -- { slot, mon } or { stop = true }, sent from menu()
    pendingAccept = nil,
    cancelling = false,
    leaving = false,
    nextMvs = nil,
    round = 0,
    gets = {},
  }, Session)
  self.co = coroutine.create(function()
    local ok, err = pcall(self.main, self)
    if not ok and not self.failed then self:fail(tostring(err)) end
  end)
  return self
end

function Session:emit(ev)
  self.events[#self.events + 1] = ev
end

function Session:takeEvents()
  local out = self.events
  self.events = {}
  return out
end

function Session:setStatus(s, progress)
  self.status = s
  self.progress = progress
end

function Session:fail(why)
  if self.failed then return end
  self.failed = true
  self.error = why
  self.status = "error"
  self.log("gblink: %s", tostring(why))
  self:emit({ type = "error", message = why })
end

-- ------------------------------------------------------------------
-- sending
-- ------------------------------------------------------------------

function Session:raw(bytes)
  self.conn:send(bytes)
end

function Session:sendPlain(kind, data)
  if type(data) == "table" then data = self.Proto.bytes(data) end
  self.sendDict[kind] = data
  self:raw(self.Proto.send(kind, data))
end

function Session:sendCounter(kind, data)
  if type(data) == "table" then data = self.Proto.bytes(data) end
  if self.ownCtr == nil then
    self.ownCtr = self.rng(0, 255)
  else
    self.ownCtr = (self.ownCtr + 1) % 256
  end
  self:sendPlain(kind, string.char(self.ownCtr) .. data)
end

function Session:requestGet(kind, every)
  local t = self.now()
  local last = self.gets[kind]
  if last and t - last < (every or 1) then return end
  self.gets[kind] = t
  self:raw(self.Proto.get(kind))
end

-- ------------------------------------------------------------------
-- receiving
-- ------------------------------------------------------------------

-- the shared counter: a message is new when it is at or past the one we
-- expect (the web client's tolerance, so a skipped MVS1 or a duplicate
-- answered GET never wedges the menu)
function Session:acceptCounter(ctr)
  if self.expect == nil then
    self.expect = (ctr + 1) % 256
    return true
  end
  local ahead = (ctr - self.expect) % 256
  if ahead >= 128 then return false end
  self.expect = (ctr + 1) % 256
  return true
end

function Session:onMessage(m)
  if m.text then
    if m.text == "CLIENT" then self.paired = true end
    return
  end
  local msg = self.Proto.decode(m.binary)
  if not msg then return end
  if msg.req == "G" then
    local data = self.sendDict[msg.kind]
    if msg.kind == self.T.SNG and self.cur and self.cur.safe and not self.cur.finished then
      data = self.cur.safe
    end
    if data then self:raw(self.Proto.send(msg.kind, data)) end
    return
  end
  -- a peer that talks has paired, even if the CLIENT line was missed
  self.paired = true
  if msg.kind == self.T.SNG then
    self:onWindow(msg.data)
  elseif self.counterKinds[msg.kind] then
    local data = msg.data
    if #data < 1 or not self:acceptCounter(data:byte(1)) then return end
    local q = self.queues[msg.kind]
    if not q then q = {}; self.queues[msg.kind] = q end
    q[#q + 1] = data:sub(2)
    self:onCounterMessage(msg.kind, data:sub(2))
  else
    self.plain[msg.kind] = msg.data
  end
end

-- events the UI wants at once, not when the flow gets round to them
function Session:onCounterMessage(kind, data)
  local P, T = self.Proto, self.T
  if kind == T.CHC then
    local choice = data:byte(1)
    if choice == P.STOP then
      self:emit({ type = "theirChoice", stop = true })
    else
      self:emit({ type = "theirChoice", slot = choice - P.FIRST_INDEX,
                  mon = #data >= 1 + P.MON_LENGTH and data:sub(2, 1 + P.MON_LENGTH) or nil })
    end
  elseif kind == T.ACP then
    self:emit({ type = "theirAccept", ok = data:byte(1) == P.ACCEPT })
  elseif kind == T.MVS then
    self:emit({ type = "mvs", data = data })
  end
end

function Session:take(kind)
  local q = self.queues[kind]
  if q and #q > 0 then return table.remove(q, 1) end
  return nil
end

function Session:peek(kind)
  local q = self.queues[kind]
  return q and q[1]
end

-- ------------------------------------------------------------------
-- SNG1.  The far Game Boy streams its section one transfer at a time and its
-- client sends the last eight bytes after each transfer; it feeds ours to
-- its Game Boy only once it already holds the one after (a 2-transfer lead,
-- a 1-byte margin), and if 0.8 s pass with nothing to feed it drops a byte
-- and aborts the whole trade (gsc_trading.py synch_exchange_section_new,
-- crash_on_sync_drop).  Each packet is read once and only the newest counts.
--
-- If P is the highest position it has sent us, it has fed our bytes up to
-- P - 3 and still holds at least P - 1, so a window starting at
-- max(0, P - 1) (0 while P <= 2) is always usable.  On top of that:
--
--   * before its first byte arrives, every frame carries our first seven
--     bytes with this section's marker in slot 8 -- both clients take that
--     as the go-ahead, and a fresh copy is waiting the moment its exchange
--     starts, so the first bytes never cost a round trip
--   * while P stands still, the frames rotate through the windows after
--     the safe one: the web client merges every window it reads, the Python
--     client uses whichever covers its next byte, and a section moves at
--     several windows per round trip instead of one
-- ------------------------------------------------------------------

local ROTATE = 4

function Session:onWindow(s)
  local entries = self.Proto.decodeWindow(s)
  local st = self.cur
  if not entries or not st then return end
  for _, e in ipairs(entries) do
    if e.pos ~= self.Proto.MARKER and e.section == st.section and e.pos < st.length then
      if e.filler then
        for j = 0, math.max(1, e.fillerLen) - 1 do
          local p = e.pos + j
          if p < st.length and st.got[p] == nil then st.got[p] = e.value; st.count = st.count + 1 end
        end
      elseif st.got[e.pos] == nil then
        st.got[e.pos] = e.value
        st.count = st.count + 1
      end
      if e.pos > st.max then st.max = e.pos end
      st.started = true
    end
  end
end

function Session:safeStart(st)
  if st.max <= 2 then return 0 end
  return st.max - 1
end

function Session:leadWindow(st)
  local P = self.Proto
  local e = {}
  for i = 1, P.WINDOW - 1 do
    local pos = math.min(i - 1, st.length - 1)
    e[i] = { pos = pos, value = st.ours:byte(pos + 1) or 0, section = st.section }
  end
  e[P.WINDOW] = { pos = P.MARKER, value = 0xFF, section = st.section }
  return P.encodeWindow(e)
end

-- one window per frame while a section is open
function Session:answerWindow()
  local st = self.cur
  if not st or st.finished then return end
  if not st.started then
    self:sendPlain(self.T.SNG, self:leadWindow(st))
    return
  end
  if st.max > st.answered then
    st.answered = st.max
    st.turn = 0
  else
    st.turn = ((st.turn or 0) + 1) % ROTATE
  end
  local start = self:safeStart(st) + st.turn * self.Proto.WINDOW
  if start > st.length - 1 then
    st.turn = 0
    start = self:safeStart(st)
  end
  self:sendPlain(self.T.SNG, self.Proto.dataWindow(st.section, st.ours, start))
  -- a GET means the far side has nothing new: give it the safe window
  st.safe = self.Proto.dataWindow(st.section, st.ours, self:safeStart(st))
end

-- ------------------------------------------------------------------
-- the flow
-- ------------------------------------------------------------------

function Session:wait(cond, opts)
  opts = opts or {}
  local deadline = opts.timeout and (self.now() + opts.timeout)
  while true do
    local v = cond()
    if v then return v end
    if self.failed then error(self.error or "failed", 0) end
    if deadline and self.now() > deadline then return nil end
    if opts.get then self:requestGet(opts.get, opts.every) end
    coroutine.yield()
  end
end

function Session:main()
  self:setStatus("waiting")
  -- any first message registers us in the room (the Python client sends an
  -- empty frame too); nothing is relayed until the server pairs us
  self:raw("")
  self:wait(function() return self.paired end)
  self:setStatus("paired")
  self:emit({ type = "paired" })
  self:sendPlain(self.T.VEC, self.Proto.VERSION)

  self:setStatus("negotiating")
  self.mode = self:agreeMode()
  local vec = self:wait(function() return self.plain[self.T.VEC] end,
                        { get = self.T.VEC, every = 1, timeout = 20 })
  if not vec then
    error("the other player's trade client is too old (it needs version 4)", 0)
  end
  self:emit({ type = "mode", mode = self.mode })

  while true do
    self.round = self.round + 1
    if self.round == 1 then
      self:setStatus("ready")
      self:wait(function() return self.ours end)
      if self.mode == "sync" then
        for _, k in ipairs(self.Proto.SYNC_SECTIONS) do self:syncSection(k) end
        -- Gen 2: the mail section only when either party holds mail, decided
        -- from both section 1s exactly as the peer decides it
        local mail = self.Proto.MAIL_SECTION
        if mail and self.needMail and self.needMail(self.ours, self.theirs) then
          self:syncSection(mail)
        end
      else
        self:bufferedSections()
      end
      self:emit({ type = "party", round = 1, sec1 = self.theirs[1], sec2 = self.theirs[2],
                  sec3 = self.theirs[3] })
    else
      self:setStatus("between")
      self:wait(function() return self.nextMvs end)
      self:sendCounter(self.T.MVS, self.nextMvs)
      self.nextMvs = nil
      -- the peer sits down again, rebuilds our party on its own and sends
      -- its MVS1 before it can choose; its CHC1 also proves it is back
      self:setStatus("waitTable")
      self:wait(function() return self:peek(self.T.MVS) or self:peek(self.T.CHC) end,
                { get = self.T.MVS, every = 2 })
      self:take(self.T.MVS)
      self:emit({ type = "round", round = self.round })
    end
    local result = self:menu()
    if result == "ended" then
      self:setStatus("ended")
      self:emit({ type = "ended" })
      return self:afterEnd()
    end
  end
end

-- after a CANCEL from only one side the Python client hands that CANCEL to
-- its Game Boy, whose player is back at the menu and may pick again: it then
-- sends a CHC and waits for ours.  While the connection is kept open
-- (main.lua lingers a little), every such pick is answered with CANCEL.
-- A CANCEL from both sides closes both menus and leaves nothing to answer.
function Session:afterEnd()
  local P = self.Proto
  if not self.oneSidedEnd then return end
  self.answering = true
  while true do
    local theirs = self:wait(function() return self:take(self.T.CHC) end)
    if theirs:byte(1) ~= P.STOP then self:sendCounter(self.T.CHC, { P.STOP }) end
  end
end

-- buffered or sync (GSCBufferedNegotiator.choose_if_buffered).  The web and
-- Python clients send their BUF1 the moment they enter the room, so it is
-- normally here within a round trip and simply adopted: equal answers end
-- the negotiation before anyone is asked to switch.  Another copy of this
-- mod waits too, so after a short wait this side offers sync itself; if the
-- answers still differ it bids 0 in NEG1, which makes it the side that
-- switches, so the other player is never prompted.
function Session:agreeMode()
  local P = self.Proto
  local function name(v) return v == P.BUFFERED and "buffered" or "sync" end
  local T = self.T
  if self.preferMode then
    -- offer a mode first (tests use this to stand in for a peer that picks
    -- buffered); a different answer is settled the usual way below
    local mine = self.preferMode == "buffered" and P.BUFFERED or P.SYNC
    self:sendCounter(T.BUF, { mine })
    local buf = self:wait(function() return self:take(T.BUF) end, { get = T.BUF, every = 1 })
    if buf:byte(1) == mine then return name(mine) end
    local theirs = buf:byte(1)
    while true do
      self:sendCounter(T.NEG, { 0 })
      local neg = self:wait(function() return self:take(T.NEG) end, { get = T.NEG, every = 1 })
      if neg:byte(1) > 0 then break end
    end
    self:sendCounter(T.BUF, { theirs })
    return name(theirs)
  end
  local buf = self:wait(function() return self:take(T.BUF) end,
                        { get = T.BUF, every = 1, timeout = 3 })
  if buf then
    self:sendCounter(T.BUF, { buf:byte(1) })
    return name(buf:byte(1))
  end
  self:sendCounter(T.BUF, { P.SYNC })
  buf = self:wait(function() return self:take(T.BUF) end, { get = T.BUF, every = 1 })
  local theirs = buf:byte(1)
  if theirs == P.SYNC then return "sync" end
  while true do
    self:sendCounter(T.NEG, { 0 })
    local neg = self:wait(function() return self:take(T.NEG) end, { get = T.NEG, every = 1 })
    if neg:byte(1) > 0 then break end
  end
  self:sendCounter(T.BUF, { theirs })
  return name(theirs)
end

function Session:syncSection(k)
  local length = self.Proto.SECTION_LENGTHS[k]
  local st = { section = k, length = length, ours = self.ours[k], got = {},
               count = 0, max = -1, answered = -1, started = false, turn = 0 }
  self.cur = st
  self:setStatus("exchanging", { section = k, done = 0, total = length })
  self:wait(function()
    self.progress = { section = k, done = st.count, total = length }
    return st.count >= length
  end)
  -- the last windows stay in sendDict for its GETs; no new ones go out
  -- until the next section's lead window replaces them
  st.finished = true
  local out = {}
  for p = 0, length - 1 do out[p + 1] = string.char(st.got[p]) end
  self.theirs[k] = table.concat(out)
end

-- one FLL each way: the random section (ignored by every receiver), then
-- the party, the patch list and, on Gen 2, the mail section
function Session:bufferedSections()
  local P, T = self.Proto, self.T
  self:setStatus("exchanging", { section = 0, done = 0, total = 1 })
  local parts = { string.rep("\0", P.SECTION_LENGTHS[0]) }
  local last = P.MAIL_SECTION or 2
  for k = 1, last do parts[#parts + 1] = self.ours[k] end
  self:sendPlain(T.FLL, table.concat(parts))
  local fll = self:wait(function() return self.plain[T.FLL] end, { get = T.FLL, every = 2 })
  local at = P.SECTION_LENGTHS[0]
  for k = 1, last do
    self.theirs[k] = fll:sub(at + 1, at + P.SECTION_LENGTHS[k])
    at = at + P.SECTION_LENGTHS[k]
  end
end

-- one trip through the trade menu; returns "traded" or "ended"
--
-- Every iteration pairs one CHC1 from each side.  Ours is only sent from
-- here, never straight from choose(), so the shared counter keeps the
-- reference order (SUC1, MVS1, CHC1, ...) however early the player acts.
function Session:menu()
  local P = self.Proto
  self:setStatus("menu")
  while true do
    local mine = self:wait(function()
      if not self.pendingChoice and (self.leaving or self.cancelling) then
        self.pendingChoice = { stop = true }
      end
      return self.pendingChoice
    end)
    self.pendingChoice = nil
    local mineByte
    if mine.stop then
      mineByte = P.STOP
      self:sendCounter(self.T.CHC, { P.STOP })
    else
      mineByte = P.FIRST_INDEX + mine.slot
      self:sendCounter(self.T.CHC, string.char(mineByte) .. mine.mon)
    end
    self:setStatus("choosing")
    local theirs = self:wait(function() return self:peek(self.T.CHC) end, { get = self.T.CHC, every = 3 })
    self:take(self.T.CHC)
    local theirByte = theirs:byte(1)
    -- a CANCEL on EITHER side closes the trade menu on both carts: the
    -- Python client forwards a one-sided $6F/$7F to its Game Boy, whose menu
    -- then closes, and the web client ends on any of them -- nobody is
    -- left at the table to send another choice
    if mineByte == P.STOP or theirByte == P.STOP then
      self.cancelling = false
      self.oneSidedEnd = mineByte ~= theirByte
      return "ended"
    end
    if mineByte ~= P.STOP and theirByte ~= P.STOP then
      self:setStatus("confirm")
      local ok = self:wait(function()
        if self.pendingAccept == nil and (self.leaving or self.cancelling) then
          self.pendingAccept = false
        end
        return self.pendingAccept ~= nil
      end) and self.pendingAccept
      self.pendingAccept = nil
      local mineAcp = ok and P.ACCEPT or P.DECLINE
      self:sendCounter(self.T.ACP, { mineAcp })
      local their = self:wait(function() return self:peek(self.T.ACP) end, { get = self.T.ACP, every = 3 })
      self:take(self.T.ACP)
      if mineAcp == P.ACCEPT and their:byte(1) == P.ACCEPT then
        self.cancelling = false
        self:sendCounter(self.T.ASK, { P.NO_NEED_DATA })
        self:sendCounter(self.T.SUC, { P.SUCCESS })
        self:emit({ type = "traded" })
        self:setStatus("finishing")
        -- the peer answers ASK1 at once and SUC1 after its Game Boy has
        -- played the trade animation
        self:wait(function() return self:peek(self.T.ASK) end, { get = self.T.ASK, every = 3 })
        self:take(self.T.ASK)
        self:wait(function() return self:peek(self.T.SUC) end, { get = self.T.SUC, every = 3 })
        self:take(self.T.SUC)
        return "traded"
      end
    end
    -- a "no" at the confirm: both games go back to choosing
    -- (.tradeCancelled), with no new data
    self.cancelling = false
    self:emit({ type = "again" })
    self:setStatus("menu")
  end
end

-- ------------------------------------------------------------------
-- what our player does
-- ------------------------------------------------------------------

-- round 1 data, already in the cart's $FE-patched form: section 1 (Gen 1
-- 0x1A2 bytes, Gen 2 0x1BC), section 2 (0xC5) and, on Gen 2, section 3 (the
-- 0x181-byte mail block, the no-mail block when nobody holds mail)
function Session:setOurs(sec1, sec2, sec3)
  self.ours = { [1] = sec1, [2] = sec2, [3] = sec3 }
end

-- slot is 0-based; nil is CANCEL.  mon66 = the Proto.MON_LENGTH payload
-- (Gen 1: struct + OT + nickname; Gen 2: + mail + egg flag).
function Session:choose(slot, mon66)
  if self.pendingChoice then return end
  if slot == nil then
    self.pendingChoice = { stop = true }
  else
    self.pendingChoice = { slot = slot, mon = mon66 }
  end
end

function Session:accept(ok)
  if self.pendingAccept ~= nil then return end
  self.pendingAccept = ok and true or false
end

-- the player backed out of this round: CANCEL if nothing was chosen yet,
-- "no" if the confirm is still open
function Session:cancel()
  self.cancelling = true
end

-- after a completed trade: our MVS1 payload for the mon we received
-- (species, four moves, four PP), sent once the engine has evolved it
function Session:nextRound(mvs9)
  self.nextMvs = mvs9
end

-- walk away: every further choice is CANCEL and every confirm is no, until
-- the other player cancels too
function Session:leave()
  self.leaving = true
end

function Session:close()
  if self.closed then return end
  self.closed = true
  self.conn:close(1000)
end

-- ------------------------------------------------------------------
-- pump
-- ------------------------------------------------------------------

function Session:update()
  if self.closed then return end
  self.conn:update()
  for _, m in ipairs(self.conn:poll()) do self:onMessage(m) end
  if self.conn.closed and not self.failed and self.status ~= "ended" then
    self:fail(self.conn.error or (self.paired and "the other player left"
                                  or "the connection closed"))
  end
  if coroutine.status(self.co) == "suspended" then
    local ok, err = coroutine.resume(self.co)
    if not ok then self:fail(tostring(err)) end
  end
  self:answerWindow()
end

return Session
