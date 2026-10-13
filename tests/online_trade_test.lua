-- End to end on a simulated clock: the engine's real LinkState, adopted onto
-- lib/bridge.lua -> lib/link.lua -> lib/session.lua, through a fake trade
-- server with latency, against a model of the pokemon.gblink.io client
-- (tests/fake_peer.lua) driving a Game Boy's party -- and against a second
-- copy of this mod.
--
--   round 1  we give GRAVELER (it becomes GOLEM over there), they give
--            KADABRA (it becomes ALAKAZAM here)
--   round 2  both trade the evolved mon straight back, which the Python
--            client only accepts if our copy of it matches its own rebuild
--   round 3  both choose CANCEL and the link ends
--
--   POKEPORT_DATA_DIR=<red data/generated> luajit mods/gblink/tests/online_trade_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "mods/gblink"
local Data = require("src.core.Data")
if not Data.pokemon then Data:load() end

-- the screens LinkState pushes after a trade run their callbacks at once
package.loaded["src.render.TextBox"] = {
  new = function(_, text, onDone) return { isTextBox = true, text = text, onDone = onDone } end,
}
local Screens = require("src.ui.Screens")
Screens.push = function(_, id, opts)
  if id == "TradeAnim" and opts and opts.onDone then opts.onDone() end
end
local Stats = require("src.pokemon.Stats")
local evolved = {}
package.loaded["src.pokemon.Evolution"] = {
  -- src/pokemon/Evolution.lua:101 keeps the HP lost across the new max
  evolve = function(_, mon, to, onDone)
    evolved[#evolved + 1] = to
    local hpLost = mon.stats.hp - mon.hp
    mon.species = to
    mon.stats = Stats.calc(Data.pokemon[to], mon.level, mon.dvs, mon.statExp)
    mon.hp = math.max(1, mon.stats.hp - hpLost)
    onDone()
  end,
}

local function lib(name) return dofile(here .. "/lib/" .. name .. ".lua") end
local Codec, Proto, Session = lib("codec"), lib("proto"), lib("session")
local Link, Bridge = lib("link"), lib("bridge")
local FakeRelay = dofile(here .. "/tests/fake_relay.lua")
local FakePeer = dofile(here .. "/tests/fake_peer.lua")
local LinkState = require("src.link.LinkState")
local Protocol = require("src.link.Protocol")
local Pokemon = require("src.pokemon.Pokemon")
local Runtime = require("src.mods.Runtime")

local env = {
  data = Data,
  cw = require("src.save_convert.GenSave").crosswalks(Data),
  charmap = require("src.save_convert.data.charmap"),
  Stats = Stats,
  Growth = require("src.pokemon.Growth"),
}

local failures = 0
local function check(cond, msg)
  if cond then print("ok   " .. msg) else failures = failures + 1; print("FAIL " .. msg) end
end

local function mons(list, ot, otId)
  local out = {}
  for _, row in ipairs(list) do
    local m = Pokemon.new(Data, row[1], row[2])
    m.ot, m.otId = ot, otId
    for k, v in pairs(row[3] or {}) do m[k] = v end
    out[#out + 1] = m
  end
  return out
end

-- main.lua's trade.completed / pokemon.received handlers, for every native
-- player in the run (main.lua routes them to the one Link on screen)
local natives = {}
local realEmit = Runtime.emit
Runtime.emit = function(name, payload)
  if name == "trade.completed" then
    for _, n in ipairs(natives) do Link.fileAtEnd(n.game.save.party, payload.received) end
  elseif name == "pokemon.received" then
    Link.land(payload.mon)
  end
  return realEmit(name, payload)
end

-- one player of this game: a Session over an endpoint, a Link, and the
-- engine's LinkState driven by scripted button presses
-- plan: per trade screen, a 1-based party slot, "last", or "b"
local function native(relay, now, name, id, party, plan)
  local presses = {}
  local input = { wasPressed = function(_, b)
    if presses[1] == b then table.remove(presses, 1) return true end
    return false
  end }
  local stack = { states = {} }
  function stack:push(s)
    if type(s) == "table" and s.isTextBox then
      if s.onDone then s.onDone() end
      return
    end
    self.states[#self.states + 1] = s
  end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  local self = {
    game = {
      data = Data, input = input, stack = stack,
      save = { player = { name = name, id = id }, party = party,
               pokedex = { seen = {}, owned = {} }, flags = {} },
      writeSave = function(g) g.saves = (g.saves or 0) + 1 end,
    },
    round = 0,
  }
  local s1, s2 = Codec.encodeSections(env, { name = name, id = id }, party)
  self.s1, self.s2 = s1, s2
  self.ep = relay:connect("/link1/31337")
  self.session = Session.new({ conn = self.ep, Proto = Proto, now = now, rng = math.random })
  self.link = Link.new({ game = self.game, env = env, Codec = Codec, session = self.session })
  assert(self.link:prepare())
  natives[#natives + 1] = self

  function self:frame()
    self.link:update()
    if not self.ls and self.link.ready then
      self.bridge = Bridge.new({ link = self.link, Protocol = Protocol })
      self.ls = LinkState.newFromSession(self.game, self.bridge, "trade", true)
      self.bridge.state = self.ls
      stack:push(self.ls)
    end
    local ls = self.ls
    if not (ls and stack:top() == ls) then return end
    ls:update(1 / 60)
    local t = ls.trade
    if ls.stage == "trade" and t and t.stage == "picking" and self.lastTrade ~= t and t.theirParty then
      self.lastTrade = t
      self.round = self.round + 1
      local want = plan[self.round]
      if want == "b" then
        presses[#presses + 1] = "b"
      elseif want then
        local slot = want == "last" and #self.game.save.party or want
        for _ = 2, slot do presses[#presses + 1] = "down" end
        presses[#presses + 1] = "a"; presses[#presses + 1] = "right"; presses[#presses + 1] = "a"
      end
    elseif ls.stage == "trade" and t and t.stage == "confirming" and ls.confirmed == nil and #presses == 0 then
      presses[#presses + 1] = "a"
    end
  end
  function self:closed() return self.ls ~= nil and stack:top() ~= self.ls end
  return self
end

local function ourParty()
  return mons({ { "PIKACHU", 25 }, { "SPEAROW", 20 }, { "GRAVELER", 28 } }, "RED", 1234)
end

local function theirParty()
  return mons({ { "KADABRA", 30 }, { "ONIX", 20, { nickname = "ROCKY" } } }, "BLUE", 777)
end

-- the Game Boy evolves what it receives; the Python client also evolves
-- its rebuild of our party
local function evolveLast(b)
  local n = b[0x0B + 1]
  local s = FakePeer.single(b, n - 1)
  local mon = Codec.decodeSingle(env, s)
  local probe = Link.new({ env = env })
  local to = probe:tradeEvolution(mon.species)
  if not to then return end
  probe:evolvePacked(mon, to)
  local again = assert(Codec.encodeSingle(env, { name = mon.ot, id = mon.otId }, mon))
  for j = 0, 43 do b[0x13 + (n - 1) * 44 + j + 1] = again:byte(j + 1) end
  for j = 0, 10 do b[0x15D + (n - 1) * 11 + j + 1] = again:byte(56 + j) end
  b[0x0C + n] = again:byte(1)
end

local function againstPeer(label, opts)
  print("-- " .. label)
  math.randomseed(opts.seed or 1)
  natives = {}
  evolved = {}
  local clock = 0
  local function now() return clock end
  local relay = FakeRelay.new({ Proto = Proto, now = now, latency = opts.latency or 0.08,
                                jitter = opts.jitter or 0 })
  local peer = FakePeer.new({
    Proto = Proto, Codec = Codec, env = env, relay = relay, path = "/link1/31337",
    now = now, rng = math.random, mode = opts.mode or "sync", python = opts.python,
    lateBuf = opts.lateBuf, player = { name = "BLUE", id = 777 }, party = theirParty(),
    picks = { 0, 1, "stop" },       -- KADABRA, then the GOLEM it received, then CANCEL
    accepts = { true, true },
  })
  peer.evolve = evolveLast
  local peerMenu = peer.menu
  peer.menu = function(self, round)
    local r = peerMenu(self, round)
    if r == "traded" then evolveLast(self.gbParty) end
    return r
  end

  local me = native(relay, now, "RED", 1234, ourParty(), { 3, "last", "b" })
  local nextFrame, settle = 0, nil
  while clock < (opts.seconds or 240) do
    clock = clock + 0.001
    relay:tick()
    peer:step()
    if clock >= nextFrame then
      nextFrame = nextFrame + 1 / 60
      me:frame()
      if me:closed() and (peer.done or peer.err) then
        settle = settle or (clock + 3)
        if me.link.ended or me.link.error or clock > settle then break end
      end
    end
    if peer.err then break end
  end

  check(peer.err == nil, label .. ": the far client ran clean (" .. tostring(peer.err) .. ")")
  check(peer.done, label .. ": the far client finished its script")
  if opts.expectNegotiation then
    check(peer.negotiated == "they adapted",
          label .. ": a late BUF1 that differs is settled in NEG1, and we are the side that switches ("
          .. tostring(peer.negotiated) .. ")")
  end
  if peer.mode ~= "buffered" then
    check(peer.maxStall ~= nil and peer.maxStall <= (opts.stallLimit or 0.8),
          label .. (": the far Game Boy never starved (worst wait %.3f s)"):format(peer.maxStall or -1))
    local fed1 = string.char(unpack(peer.fed[1]))
    local fed2 = string.char(unpack(peer.fed[2]))
    check(fed1 == me.s1:sub(1, #fed1) and #fed1 >= 0x1A2 - 3,
          label .. (": its Game Boy was fed our party block (%d bytes)"):format(#fed1))
    check(fed2 == me.s2:sub(1, #fed2) and #fed2 >= 0xC5 - 3,
          label .. (": ...and our patch list (%d bytes)"):format(#fed2))
  end
  check(me.session.theirs[1] == peer.sections[1] and me.session.theirs[2] == peer.sections[2],
        label .. ": we got its sections byte for byte")
  check(me.ls and me.ls.verdict == "full", label .. ": the mirrored hello reads as a full link")
  check(peer.traded == 2, label .. (": two trades completed (%s)"):format(tostring(peer.traded)))
  check(evolved[1] == "ALAKAZAM", label .. ": KADABRA evolved on arrival")
  local p = me.game.save.party
  check(#p == 3, label .. ": still three in the party")
  check(p[3] and p[3].species == "GOLEM" and p[3].ot == "RED" and p[3].otId == 1234,
        label .. ": round 2 brought our GRAVELER home as a GOLEM, our OT intact")
  check(p[1].species == "PIKACHU" and p[2].species == "SPEAROW",
        label .. ": the untouched mons kept their slots")
  for i, v in ipairs(peer.validity) do
    check(v.sameAsView, label .. (": iteration %d: the slot we named holds the mon we sent, in its view"):format(i))
    if opts.python then
      check(v.valid, label .. (": iteration %d: the Python client found our mon in its rebuild"):format(i))
    end
  end
  check(peer.choicesSeen[3] == Proto.STOP, label .. ": our B at the third menu went out as CANCEL")
  check(me.link.ended, label .. ": both cancelled, the link ended")
  check(me:closed(), label .. ": LinkState unwound")
  check((me.game.saves or 0) >= 2, label .. ": autosaved after each trade")
  local gb = peer.gbParty
  local lastSpecies = env.cw.pokemonByIndex[gb[0x13 + (gb[0x0C] - 1) * 44 + 1]]
  check(lastSpecies == "ALAKAZAM", label .. (": its Game Boy ended with our ALAKAZAM (%s)"):format(tostring(lastSpecies)))
  if failures > 0 then
    for _, line in ipairs(peer.log) do print("   peer " .. line) end
  end
end

-- two players of this game: neither speaks first, so both offer sync
local function nativeToNative(label, opts)
  print("-- " .. label)
  math.randomseed(opts.seed or 1)
  natives = {}
  evolved = {}
  local clock = 0
  local function now() return clock end
  local relay = FakeRelay.new({ Proto = Proto, now = now, latency = opts.latency or 0.08 })
  local a = native(relay, now, "RED", 1234, ourParty(), { 3, "last", "b" })
  local b = native(relay, now, "BLUE", 777, theirParty(), { 1, 2, "b" })
  local nextFrame = 0
  while clock < 240 do
    clock = clock + 0.001
    relay:tick()
    if clock >= nextFrame then
      nextFrame = nextFrame + 1 / 60
      a:frame()
      b:frame()
      if a.link.ended and b.link.ended then break end
      if a.link.error or b.link.error then break end
    end
  end
  check(a.link.error == nil and b.link.error == nil,
        label .. (": no errors (%s / %s)"):format(tostring(a.link.error), tostring(b.link.error)))
  check(a.session.mode == "sync" and b.session.mode == "sync", label .. ": both settled on sync")
  check(a.session.theirs[1] == b.s1 and b.session.theirs[1] == a.s1, label .. ": both got the other's party block")
  local pa, pb = a.game.save.party, b.game.save.party
  check(pa[3].species == "GOLEM" and pa[3].ot == "RED", label .. ": RED ends with its GRAVELER back, as GOLEM")
  check(pb[2].species == "ALAKAZAM" and pb[2].ot == "BLUE", label .. ": BLUE ends with its KADABRA back, as ALAKAZAM")
  check(#pa == 3 and #pb == 2, label .. ": party sizes unchanged")
  check(a.link.ended and b.link.ended, label .. ": both cancelled, the link ended on both sides")
end

againstPeer("web client, sync", { python = false })
againstPeer("python client, sync", { python = true, seed = 9 })
-- past ~0.35 s each way the reference protocol itself runs out of slack
-- (its 0.8 s rule); this one still completes, right at the edge
againstPeer("web client, sync, 250 ms each way with jitter",
            { latency = 0.25, jitter = 0.1, seed = 3, stallLimit = 0.85, seconds = 400 })
againstPeer("python client, buffered", { python = true, mode = "buffered", seed = 5 })
againstPeer("python client, buffered, BUF1 sent late",
            { python = true, mode = "buffered", lateBuf = true, expectNegotiation = true, seed = 11 })
nativeToNative("this game on both ends", { seed = 4 })

Runtime.emit = realEmit
print(failures == 0 and "gblink online: all passed" or ("gblink online: %d failures"):format(failures))
os.exit(failures == 0 and 0 or 1)
