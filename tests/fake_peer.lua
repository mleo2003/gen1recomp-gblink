-- The other player: a Game Boy on pokemon.gblink.io, modelled on a
-- simulated clock from how its client behaves on the network.  The section
-- algorithm is the one in Lorenzooone's MIT-licensed reference
-- (gsc_trading.py synch_synch_section_new / synch_exchange_section_new),
-- with the timings and polling the web client uses on top:
--
--   section sync  -- the 2-transfer lead, the one-byte safety margin, burst
--     transfers, and the 800 ms "byte dropped, abort" rule
--   messages      -- consume-once receive buffers, GET re-requests, the
--     counter tolerance
--   the menu      -- CHC1 / ACP1 / ASK1 / SUC1, then MVS1 and the party
--     rebuilt in the cart's order for the next round
--
-- `python = true` adds what the Python client does on top: it rebuilds the
-- party it was sent with the trade applied and the received mon evolved
-- (gsc_trading_data_utils.py trade_mon / requires_input / evolve_mon), and
-- refuses a CHC1 whose mon is not in that rebuild (search_for_mon with
-- RBYTradingPokémonInfo.is_equal) -- the strictest check a peer applies.
--
-- The "Game Boy" is its party block: on each transfer it returns the next
-- byte of its own section, and what it is fed is recorded.

local bit = require("bit")

local FakePeer = {}
FakePeer.__index = FakePeer

local MARKER = 0xFFFF
local NO_INPUT = 0xFE

-- opts: Proto, Codec, env, relay, path, now, rng, party (engine mons),
-- player { name, id }, mode "sync"|"buffered", picks = { slot | "stop", ...
-- per menu iteration }, accepts = { true/false ... }, python, think (s)
function FakePeer.new(opts)
  local self = setmetatable({}, FakePeer)
  for k, v in pairs(opts) do self[k] = v end
  self.ep = opts.relay:connect(opts.path)
  self.recv, self.sendDict = {}, {}
  self.wake = 0
  self.fed = { {}, {} }
  self.got = {}
  self.log = {}
  self.choicesSeen = {}
  self.validity = {}
  self.iteration = 0
  self.think = opts.think or 0.5
  local s1, s2 = assert(opts.Codec.encodeSections(opts.env, opts.player, opts.party))
  self.sections = { s1, s2 }
  -- its GB's party, decoded bytes (patches applied), for CHC1 and MVS1
  self.gbParty = self:decodedParty(s1, s2)
  self.co = coroutine.create(function()
    local ok, err = pcall(self.run, self)
    if not ok then self.err = tostring(err) end
  end)
  return self
end

function FakePeer:note(fmt, ...)
  self.log[#self.log + 1] = string.format("%.3f ", self.now()) .. string.format(fmt, ...)
end

-- ------------------------------------------------------------------
-- WebSocketClient
-- ------------------------------------------------------------------

function FakePeer:pump()
  for _, m in ipairs(self.ep:poll()) do
    if m.text then
      if m.text == "CLIENT" then self.paired = true end
    else
      local msg = self.Proto.decode(m.binary)
      if msg then
        self.paired = true
        if msg.req == "G" then
          local d = self.sendDict[msg.kind]
          if d then self.ep:send(self.Proto.send(msg.kind, d)) end
        else
          self.recv[msg.kind] = msg.data
        end
      end
    end
  end
end

function FakePeer:step()
  if self.err or self.done then return end
  self:pump()
  if self.now() >= self.wake - 1e-9 and coroutine.status(self.co) == "suspended" then
    local ok, err = coroutine.resume(self.co)
    if not ok then self.err = tostring(err) end
    if coroutine.status(self.co) == "dead" then self.done = true end
  end
end

function FakePeer:sleep(s)
  self.wake = self.now() + s
  coroutine.yield()
end

function FakePeer:sendData(kind, data)
  if type(data) == "table" then data = self.Proto.bytes(data) end
  self.sendDict[kind] = data
  self.ep:send(self.Proto.send(kind, data))
end

function FakePeer:sendGet(kind) self.ep:send(self.Proto.get(kind)) end

function FakePeer:sendCounter(kind, data)
  if type(data) == "table" then data = self.Proto.bytes(data) end
  self:sendData(kind, string.char(self.ownCtr) .. data)
  self.ownCtr = (self.ownCtr + 1) % 256
end

function FakePeer:waitForMessage(kind, timeout)
  local deadline = self.now() + (timeout or 30)
  local lastGet = -1
  while true do
    local d = self.recv[kind]
    if d then self.recv[kind] = nil return d end
    if self.now() >= deadline then return nil end
    if self.now() - lastGet > 0.5 then self:sendGet(kind); lastGet = self.now() end
    self:sleep(0.1)
  end
end

function FakePeer:getCounterMessage(kind, timeout)
  local deadline = self.now() + (timeout or 600)
  local lastGet = -1
  while self.now() < deadline do
    local d = self.recv[kind]
    if d and #d > 0 then
      local ctr = d:byte(1)
      local stale = false
      if self.peerCtr ~= nil then
        local diff = (ctr - self.peerCtr) % 256
        if diff > 128 then stale = true end
      end
      if stale then
        self.recv[kind] = nil
      else
        self.peerCtr = (ctr + 1) % 256
        self.recv[kind] = nil
        return d
      end
    end
    if self.now() - lastGet > 0.5 then self:sendGet(kind); lastGet = self.now() end
    self:sleep(0.05)
  end
  error("timed out waiting for " .. kind)
end

-- ------------------------------------------------------------------
-- party bytes
-- ------------------------------------------------------------------

local MONS_AT, OT_AT, NICK_AT = 0x13, 0x11B, 0x15D

-- section 1 with the patch list applied: real bytes, as the GB holds them
function FakePeer:decodedParty(s1, s2)
  local b = { s1:byte(1, -1) }
  local part, base = 0, 0
  for i = 1, #s2 do
    local c = s2:byte(i)
    if c == 0xFF then
      part = part + 1
      base = 0xFC
      if part == 2 then break end
    elseif c ~= 0 and c ~= 0xFD and c ~= 0xFE then
      b[MONS_AT + base + c] = 0xFE
    end
  end
  return b
end

local function single(b, slot)
  local out = {}
  for i = 0, 43 do out[#out + 1] = string.char(b[MONS_AT + slot * 44 + i + 1]) end
  for i = 0, 10 do out[#out + 1] = string.char(b[OT_AT + slot * 11 + i + 1]) end
  for i = 0, 10 do out[#out + 1] = string.char(b[NICK_AT + slot * 11 + i + 1]) end
  return table.concat(out)
end

FakePeer.single = single

local function partySize(b) return b[0x0B + 1] end

-- remove `slot`, close up, append the 66-byte `mon` with species byte
local function tradeInto(b, slot, mon)
  local n = partySize(b)
  local last = n - 1
  for i = slot, last - 1 do
    for j = 0, 43 do b[MONS_AT + i * 44 + j + 1] = b[MONS_AT + (i + 1) * 44 + j + 1] end
    for j = 0, 10 do b[OT_AT + i * 11 + j + 1] = b[OT_AT + (i + 1) * 11 + j + 1] end
    for j = 0, 10 do b[NICK_AT + i * 11 + j + 1] = b[NICK_AT + (i + 1) * 11 + j + 1] end
    b[0x0C + i + 1] = b[0x0C + i + 2]
  end
  for j = 0, 43 do b[MONS_AT + last * 44 + j + 1] = mon:byte(j + 1) end
  for j = 0, 10 do b[OT_AT + last * 11 + j + 1] = mon:byte(45 + j) end
  for j = 0, 10 do b[NICK_AT + last * 11 + j + 1] = mon:byte(56 + j) end
  b[0x0C + last + 1] = mon:byte(1)
end

-- RBYTradingPokémonInfo.is_equal(weak=True): struct ranges, then moves and
-- PP as a matched multiset
local RANGES = { { 0, 2 }, { 4, 7 }, { 0xC, 0x1C }, { 0x21, 0x2B } }
local function isEqualWeak(a, b)
  for _, r in ipairs(RANGES) do
    for j = r[1], r[2] do
      if a:byte(j + 1) ~= b:byte(j + 1) then return false, j end
    end
  end
  local used = {}
  for i = 0, 3 do
    local found = false
    for j = 0, 3 do
      if not used[j] and a:byte(9 + i) == b:byte(9 + j) and a:byte(30 + i) == b:byte(30 + j) then
        used[j], found = true, true
        break
      end
    end
    if not found then return false, "moves" end
  end
  return true
end

FakePeer.isEqualWeak = isEqualWeak

-- ------------------------------------------------------------------
-- the trade
-- ------------------------------------------------------------------

function FakePeer:getTradeData()
  local d = self.recv.SNG1
  if not d then
    if not self.lastSngGet or self.now() - self.lastSngGet > 0.1 then
      self.lastSngGet = self.now()
      self:sendGet("SNG1")
    end
    return nil
  end
  self.recv.SNG1 = nil
  return self.Proto.decodeWindow(d)
end

function FakePeer:packet(ring, k)
  local e = {}
  for i = 0, 7 do
    e[i + 1] = ring[i] or { pos = MARKER, value = 0xFF, section = k }
  end
  return self.Proto.encodeWindow(e)
end

function FakePeer:synchSynch(k)
  self:sendData("SNG1", self.Proto.markerWindow(k))
  local wrong = 0
  local deadline = self.now() + 300
  while true do
    if self.now() > deadline then error("section " .. k .. ": never synchronized") end
    local rb = self:getTradeData()
    if rb then
      local last = rb[8]
      if last.pos == MARKER and last.section == k then break end
      if last.pos == MARKER and last.section ~= k and last.section ~= k - 1 then
        wrong = wrong + 1
        if wrong >= 5 then error("section " .. k .. ": incompatible trade state") end
      else
        local implicit = false
        for _, e in ipairs(rb) do
          if e.pos ~= MARKER and e.section == k then implicit = true end
        end
        if implicit then break end
      end
    end
    self:sleep(0.1)
  end
  self:sleep(0.1)
  self:sendData("SNG1", self.Proto.markerWindow(k))
end

function FakePeer:synchExchange(k)
  local length = self.Proto.SECTION_LENGTHS[k]
  local mine = self.sections[k]
  self:sleep(0.02) -- the GB runs its preamble
  local ring = { [0] = { pos = 0, value = mine:byte(1), section = k } }
  local sendIndex = 1
  local posSend, posRecv, iFeed, bytesOffset = 1, 0, 0, 1
  local recvData, otherBuf = {}, {}
  local lastTransfer = self.now()
  self:sendData("SNG1", self:packet(ring, k))
  local maxWait = 0
  while iFeed < length - 3 do
    local rb = self:getTradeData()
    if rb then
      -- the web client merges every window it reads; the Python client
      -- keeps only the newest packet's positions (get_swappable_bytes_new)
      if self.python then recvData = {} end
      for _, e in ipairs(rb) do
        if e.pos ~= MARKER and e.section <= k and e.section == k and e.pos <= length then
          recvData[e.pos] = e.value
        end
      end
      while recvData[posRecv] ~= nil and posRecv < length do
        local v = recvData[posRecv]
        otherBuf[posRecv] = v == NO_INPUT and 0xFF or v
        posRecv = posRecv + 1
      end
    end
    local byte = NO_INPUT
    local schedule = false
    local waited = self.now() - lastTransfer
    if waited >= 0.8 then schedule = true end
    if bytesOffset < 3 then
      schedule = true
    elseif posRecv > iFeed then
      byte = otherBuf[iFeed]
      if posRecv > iFeed + 1 then schedule = true end
      if schedule then iFeed = iFeed + 1 end
    end
    if schedule then
      if byte == NO_INPUT then
        bytesOffset = bytesOffset + 1
        if bytesOffset > 3 then
          error(("section %d: no data from the other player - byte dropped (fed %d/%d)")
                :format(k, iFeed, length))
        end
      else
        self.fed[k][#self.fed[k] + 1] = byte
      end
      if waited > maxWait then maxWait = waited end
      local nextByte = mine:byte(posSend + 1) or 0
      ring[sendIndex % 8] = { pos = posSend, value = nextByte, section = k }
      sendIndex = sendIndex + 1
      posSend = posSend + 1
      self:sendData("SNG1", self:packet(ring, k))
      lastTransfer = self.now()
      -- web: one USB round trip; Python: sleep_func inside swap_byte
      self:sleep(self.python and 0.02 or 0.001)
    end
    if self.python then
      self:sleep(0.02) -- sleep_func at the bottom of every loop
    elseif not schedule or byte == NO_INPUT then
      self:sleep(0.004)
    end
  end
  self.maxStall = math.max(self.maxStall or 0, maxWait)
  local got = {}
  for p = 0, length - 1 do got[p + 1] = string.char(otherBuf[p] or 0) end
  self.got[k] = table.concat(got)
end

function FakePeer:run()
  local P = self.Proto
  self.ownCtr = self.rng(0, 255)
  self:sendData("VEC1", P.VERSION)       -- registers (swallowed by the server)
  self:sleep(0.3)                         -- the GB enters the room
  local mode = self.mode == "buffered" and P.BUFFERED or P.SYNC
  if not self.lateBuf then
    -- RBYTrading.startTrade: BUF1 goes out (and into sendDict) on entering
    -- the room, usually before the other player has even connected
    self.sendDict.BUF1 = string.char(self.ownCtr, mode)
    self:sendCounter("BUF1", { mode })
  end
  self.ep:send("")
  while not self.paired do self:sleep(0.05) end
  self:note("paired")
  local pb = self:waitForMessage("BUF1", 60)
  assert(pb, "no BUF1 from the native client")
  self.peerCtr = (pb:byte(1) + 1) % 256
  if self.lateBuf then
    self:sendCounter("BUF1", { mode })
    if pb:byte(2) ~= mode then
      -- completeBufferedNegotiation: NEG1 until one side is higher
      local weAdapt
      repeat
        local v = self.rng(1, 255)
        self:sendCounter("NEG1", { v })
        local pv = self:getCounterMessage("NEG1", 30):byte(2)
        if pv > v then weAdapt = true elseif pv < v then weAdapt = false end
      until weAdapt ~= nil
      self.negotiated = weAdapt and "we adapted" or "they adapted"
      if weAdapt then
        mode = pb:byte(2)
        self:sendCounter("BUF1", { mode })
      else
        local nb = self:getCounterMessage("BUF1", 30)
        assert(nb:byte(2) == mode, "the native client did not switch")
      end
      self.mode = mode == P.BUFFERED and "buffered" or "sync"
    end
  else
    assert(pb:byte(2) == mode, "the native client did not adopt our mode")
  end
  self:sleep(1.0)                         -- sits at the table
  self:sleep(0.1)
  self:sendGet("VES1")
  assert(self:waitForMessage("VES1", 30), "no VES1")
  assert(self:waitForMessage("VEC1", 10), "the native client sent no VEC1")
  self:sendGet("RAN1")
  assert(self:waitForMessage("RAN1", 30), "no RAN1")
  self:sleep(0.05)                        -- section 0 with its own GB
  if self.mode == "buffered" then
    self:sendData("FLL1", string.rep("\0", 10) .. self.sections[1] .. self.sections[2])
    local fll = self:waitForMessage("FLL1", 300)
    assert(fll, "no FLL1")
    self.got[1] = fll:sub(11, 10 + 0x1A2)
    self.got[2] = fll:sub(11 + 0x1A2)
  else
    self:synchSynch(1)
    self:synchExchange(1)
    self:synchSynch(2)
    self:synchExchange(2)
  end
  self:note("sections done")
  -- its picture of our party: what it fed its GB
  self.theirParty = self:decodedParty(self.got[1], self.got[2])
  self.ownBlank, self.otherBlank = true, true

  local round = 1
  while true do
    if round > 1 then
      self.recv.CHC1, self.recv.ACP1, self.recv.ASK1 = nil, nil, nil
      self.recv.SUC1, self.recv.MVS1, self.recv.SNG1 = nil, nil, nil
      if self.ownBlank and self.otherBlank then
        -- re-entry: no MVS1 read
      elseif self.otherBlank then
        local m = self:getCounterMessage("MVS1", 60)
        self.mvsSeen = m
      else
        self.peerCtr = self.peerCtr and (self.peerCtr + 1) % 256
      end
      self:sleep(0.5)                     -- sits and exchanges with its GB
      local n = partySize(self.gbParty)
      local s = single(self.gbParty, n - 1)
      self:sendCounter("MVS1", s:sub(1, 1) .. s:sub(9, 12) .. s:sub(30, 33))
      self.ownBlank, self.otherBlank = true, true
    end
    local r = self:menu(round)
    if r == "ended" then return end
    round = round + 1
  end
end

function FakePeer:menu(round)
  local P = self.Proto
  while true do
    self.iteration = self.iteration + 1
    self.sendDict.CHC1, self.sendDict.ACP1, self.sendDict.SUC1 = nil, nil, nil
    self:sleep(self.think)
    local pick = self.picks[self.iteration]
    if pick == nil then pick = "stop" end
    local choice = pick == "stop" and P.STOP or (P.FIRST_INDEX + pick)
    if choice == P.STOP then
      self:sendCounter("CHC1", { P.STOP })
    else
      self:sendCounter("CHC1", string.char(choice) .. single(self.gbParty, pick))
    end
    local their = self:getCounterMessage("CHC1", 600)
    local theirChoice = their:byte(2)
    self.choicesSeen[#self.choicesSeen + 1] = theirChoice
    self:note("iteration %d: mine %02X theirs %02X", self.iteration, choice, theirChoice)
    if choice == P.STOP or theirChoice == P.STOP then
      if choice == P.STOP and theirChoice == P.STOP then return "ended" end
    else
      local theirSlot = theirChoice - P.FIRST_INDEX
      local theirMon = their:sub(3, 68)
      local valid = true
      if self.python then
        valid = false
        local n = partySize(self.theirParty)
        for i = 0, n - 1 do
          if isEqualWeak(theirMon, single(self.theirParty, i)) then valid = true break end
        end
      end
      -- index-wise, the web client's view of the mon at that slot
      -- identity, not species: the web client never evolves its copy of
      -- the party it was sent, so only OT ID, experience and DVs say
      -- whether the slot named is the mon that was offered
      local view = theirSlot < partySize(self.theirParty) and single(self.theirParty, theirSlot)
      local same = view ~= nil
      for _, j in ipairs({ 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x1B, 0x1C }) do
        if same and view:byte(j + 1) ~= theirMon:byte(j + 1) then same = false end
      end
      self.validity[#self.validity + 1] = { valid = valid, slot = theirSlot, sameAsView = same }
      self:sleep(self.think)
      local wants = self.accepts[self.iteration]
      if wants == nil then wants = true end
      local acc = (wants and valid) and P.ACCEPT or P.DECLINE
      self:sendCounter("ACP1", { acc })
      local theirAcc = self:getCounterMessage("ACP1", 120):byte(2)
      if acc == P.ACCEPT and theirAcc == P.ACCEPT then
        self:sendCounter("ASK1", { P.NO_NEED_DATA })
        local ask = self:getCounterMessage("ASK1", 120)
        self.ownBlank = ask:byte(2) == P.NEED_DATA
        self.otherBlank = false
        self:sleep(2.0)                   -- the trade animation
        self:sendCounter("SUC1", { 0x61 })
        self:getCounterMessage("SUC1", 60)
        -- both GBs: their mon leaves, ours goes on the end
        local mine = single(self.gbParty, pick)
        tradeInto(self.gbParty, pick, theirMon)
        tradeInto(self.theirParty, theirSlot, mine)
        if self.python and self.evolve then self.evolve(self.theirParty) end
        self.traded = (self.traded or 0) + 1
        self:note("traded #%d", self.traded)
        return "traded"
      end
    end
  end
end

return FakePeer
