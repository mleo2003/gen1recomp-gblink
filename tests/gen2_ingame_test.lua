-- Gold's Trade Center desk through main.lua, loaded by the real headless
-- loader as a Gen 2 boot: the receptionist's specials run in the order the
-- cart's script (maps/Pokecenter2F.asm) calls them, each in a coroutine the
-- way the script VM runs them (Specials.block parks it), then the table
-- screen trades against a second copy of the Gen 2 stack.  luasocket is a
-- fake whose connections end at tests/fake_relay.lua, so lib/ws.lua runs
-- for real.  The animations are stood in for; the evolution does what
-- Gen2EvolutionAnim does to the party.
--
--   GOLD_CACHE=<imported gold cache dir> luajit mods/gblink/tests/gen2_ingame_test.lua
--   GEN2_GAME=crystal GOLD_CACHE=<imported crystal cache dir> ...   (or silver)
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local cache = assert(os.getenv("GOLD_CACHE"), "set GOLD_CACHE to an imported Gold cache directory")
local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "mods/gblink"

local T = require("tests.modkit")
local GameVersion = require("src.core.GameVersion")
local version = os.getenv("GEN2_GAME") or "gold"
GameVersion.set(version)
local LINK_MODE = version == "crystal" and 0xCF51 or 0xCE51   -- wOtherPlayerLinkMode
local SaveConvert = require("src.save_convert.SaveConvert")
local Gen2Save = require("src.save_convert.Gen2Save")
local Gen2Layout = require("src.save_convert.Gen2Layout")
local Mon = require("src.battle.gen2.Mon")
local Mail = require("src.core.gen2.Mail")
local Evolution = require("src.core.gen2.Evolution")
local CodeEntry = require("src.link.CodeEntry")
local Runtime = require("src.mods.Runtime")

local data = assert(SaveConvert.gen2DataFromDir(cache), "no Gen 2 tables under " .. cache)

local clock = 0
local function now() return clock end
love.timer.getTime = now

-- the screens the table pushes: the animations finish at once; the
-- evolution does to the party what Gen2EvolutionAnim:commit does
local pushed = {}
local Screens = require("src.ui.Screens")
Screens.push = function(game, id, opts)
  pushed[#pushed + 1] = id
  game.stack:push({ stub = id })
  if id == "Gen2TradeAnim" then
    opts.onDone()
  elseif id == "Gen2EvolutionAnim" then
    local evolved = Evolution.apply(game.data, opts.mon, opts.entry)
    opts.party[opts.index] = evolved
    Evolution.markPokedex(opts.save, evolved.species)
    opts.onDone({ evolved = evolved })
  end
  return {}
end

local Proto = dofile(here .. "/lib/proto.lua")
local P2 = Proto.forGen(2)
local Codec2 = dofile(here .. "/lib/codec2.lua")
local Session = dofile(here .. "/lib/session.lua")
local Link2 = dofile(here .. "/lib/link2.lua")
local FakeRelay = dofile(here .. "/tests/fake_relay.lua")
local FakeSocket = dofile(here .. "/tests/fake_socket.lua")

math.randomseed(23)
local relay = FakeRelay.new({ Proto = P2, now = now, latency = 0.06 })
package.loaded.socket = FakeSocket.new(relay, now)

local env = { data = data, cw = Gen2Save.crosswalks(data), charmap = Gen2Layout.charmap,
              Mon = Mon, crystal = version == "crystal" }

local function mon(species, level, opts)
  opts = opts or {}
  local m = assert(Mon.new(data, species, level, { item = opts.item, nickname = opts.nickname }))
  m.ot, m.otId = opts.ot, opts.otId
  return m
end

-- ------------------------------------------------------------------
-- our game: a save, a stack, scripted presses
-- ------------------------------------------------------------------

local presses = {}
local saves = 0
local stack = { states = {} }
function stack:push(s) self.states[#self.states + 1] = s end
function stack:pop() return table.remove(self.states) end
function stack:top() return self.states[#self.states] end

local game = {
  data = data, stack = stack,
  save = {
    player = { name = "RECOMP", id = 44444 },
    party = {
      mon("MACHOKE", 32, { ot = "RECOMP", otId = 44444 }),
      mon("KADABRA", 30, { ot = "RECOMP", otId = 44444, nickname = "SPOONY" }),
      mon("SENTRET", 10, { ot = "RECOMP", otId = 44444 }),
    },
    pokedex = { seen = {}, caught = {} },
  },
  input = { wasPressed = function(_, b)
    if presses[1] == b then table.remove(presses, 1) return true end
    return false
  end },
  writeSave = function() saves = saves + 1 return true end,
}

-- ------------------------------------------------------------------
-- the far side: a Game Boy's client, as a second copy of the Gen 2 stack
-- ------------------------------------------------------------------

local peer = { traded = 0, picks = { 0, "stop" }, round = 0 }
do
  local save = { player = { name = "CART", id = 33333 }, party = {
    mon("ONIX", 30, { ot = "CART", otId = 33333, item = "METAL_COAT" }),
    mon("HAUNTER", 31, { ot = "CART", otId = 33333 }),
  } }
  peer.save = save
  local session = Session.new({ conn = relay:connect("/link2/12345"), Proto = P2, now = now,
                                rng = math.random, needMail = Link2.needMail })
  local link = Link2.new({ game = { save = save, data = data }, env = env, Codec2 = Codec2,
                           session = session, Mail = Mail })
  assert(link:prepare(), link.error)
  peer.link = link
  link.listener = { onLink = function(_, ev)
    if ev.type == "party" or ev.type == "round" then
      peer.round = peer.round + 1
      local pick = peer.picks[peer.round]
      if pick == "stop" then link:leave() link:choose(nil) elseif pick then link:choose(pick) end
    elseif ev.type == "traded" then
      peer.traded = peer.traded + 1
      table.remove(save.party, ev.ourSlot + 1)
      save.party[#save.party + 1] = Codec2.engineMon(env, ev.received)
      peer.roundAt = clock + 0.5
    elseif ev.type == "error" then
      peer.err = ev.message
    end
  end }
  function peer:step()
    link:update()
    if link.session.status == "confirm" and link.session.pendingAccept == nil then link:accept(true) end
    if self.roundAt and clock >= self.roundAt then
      self.roundAt = nil
      link:roundDone(save.party[#save.party])
    end
  end
end

-- ------------------------------------------------------------------
-- load the mod as a Gen 2 boot
-- ------------------------------------------------------------------

local run = T.sdk.loadMod(here, { data = data, generation = 2 })
T.eq(#run.errors, 0, "the mod loads on a Gen 2 boot (" .. tostring(run.errors[1]) .. ")")
local Specials = require("src.script.gen2.Specials")
T.check(Specials._gblinkMerged, "it took over the cable club specials")
T.eq(Specials.HANDLER_SOURCE.TradeCenter, "mod:gblink", "TradeCenter is the mod's")
T.eq(Specials.HANDLER_SOURCE.TryQuickSave ~= "mod:gblink", true, "TryQuickSave stays the engine's")

local vm = { scriptVar = 0, mem = {},
             specials = { game = function() return game end, save = function() return game.save end,
                          data = function() return data end } }
function vm:resume(value)
  local ok, err = coroutine.resume(self.co, value)
  assert(ok, err)
end

-- run a special the way the VM does: in the script's coroutine
local function special(name)
  vm.co = coroutine.create(function() Specials.ALL[name](vm) end)
  local ok, err = coroutine.resume(vm.co)
  assert(ok, err)
end

local function frame()
  clock = clock + 1 / 60
  relay:tick()
  Runtime.call("input.step", function() end, game, 1 / 60)
  local top = stack:top()
  if top and top.update then top:update(1 / 60) end
  peer:step()
end

local function frames(n, untilFn)
  for _ = 1, n do
    frame()
    if untilFn and untilFn() then return true end
  end
  return untilFn == nil
end

-- the battle desk: still "your friend is not ready"
special("SetBitsForBattleRequest")
special("WaitForLinkedFriend")
T.eq(vm.scriptVar, 0, "the Colosseum desk still finds nobody")
T.eq(#stack.states, 0, "and opens nothing")

-- the trade desk
special("SetBitsForLinkTradeRequest")
special("WaitForLinkedFriend")
local room = stack:top()
T.check(room and room.stage == "code", "WaitForLinkedFriend opens the room number screen")
T.eq(coroutine.status(vm.co), "suspended", "the script waits on it")
room.code = CodeEntry.fromText("12345", { length = 5, charset = "0123456789" })
presses = { "a" }
frame()
T.eq(room.stage, "linking", "A dials the room")
T.check(frames(600, function() return coroutine.status(vm.co) == "dead" end), "the other game answers")
T.eq(vm.scriptVar, 1, "WaitForLinkedFriend: TRUE once linked")
T.eq(#stack.states, 0, "the room screen is gone")

special("CheckLinkTimeout_Receptionist")
T.eq(vm.scriptVar, 1, "CheckLinkTimeout_Receptionist: the link is up")
T.eq(vm.mem[LINK_MODE], 1, "wOtherPlayerLinkMode reads as a Gen 2 partner")
special("CheckBothSelectedSameRoom")
T.eq(vm.scriptVar, 1, "CheckBothSelectedSameRoom: TRUE")
T.eq(vm.mem[LINK_MODE], nil, "and the byte is cleared again (vm.mem rides the save)")

-- the walk in is the cart's script; at the table:
special("TradeCenter")
local tc = stack:top()
T.check(tc and tc.stage == "wait", "TradeCenter opens the table: PLEASE WAIT while the parties cross")
T.check(frames(3000, function() return tc.stage == "menu" end), "the trade menu opens")
T.eq(#tc.theirs, 2, "their party is listed")
T.eq(tc:monName(tc.theirs[1]), "ONIX", "ONIX first")
presses = { "a", "right", "a" }   -- MACHOKE -> STATS / TRADE -> TRADE
frame(); frame(); frame()
T.eq(tc.stage, "picked", "MACHOKE offered")
T.check(frames(600, function() return tc.stage == "confirm" end), "their offer arrives: Trade MACHOKE for ONIX?")
presses = { "a" }
frame()
T.check(frames(1200, function() return tc.stage == "menu" end), "the trade runs and both sit down again")
local names = {}
for i, m in ipairs(game.save.party) do names[i] = m.species end
T.eq(table.concat(names, ","), "KADABRA,SENTRET,STEELIX", "ONIX arrived at the end and became STEELIX")
T.eq(game.save.party[3].item, nil, "the Metal Coat was used up")
T.eq(game.save.party[3].ot, "CART", "with its OT")
T.check(game.save.pokedex.caught.STEELIX and game.save.pokedex.caught.ONIX, "both are in the pokedex")
T.check(saves >= 1, "the game saved after the trade")
T.check(pushed[1] == "Gen2TradeAnim" and pushed[2] == "Gen2EvolutionAnim", "the trade and evolution screens ran")
T.eq(peer.save.party[#peer.save.party].species, "MACHOKE", "the far side got the MACHOKE")
local peerWire = peer.link.theirs.mons
for i, w in ipairs(tc.link.ours.mons) do
  T.eq(peerWire[i].struct, w.struct, "the far side's copy of our slot " .. i .. " is exact")
end

-- round 2: they choose CANCEL as soon as they sit down again
T.check(frames(1200, function() return tc.stage == "message" end), "their CANCEL is shown")
T.check(tostring(tc.text):find("CART canceled", 1, true) ~= nil, "as \"CART canceled the trade.\"")
presses = { "a" }
frame()
T.check(frames(600, function() return coroutine.status(vm.co) == "dead" end), "A leaves the table")
T.eq(#stack.states, 0, "the table screen is gone (the script then reloads the room)")
T.check(frames(600, function() return tc.link.ended end), "our CANCEL went out and the trade menu ended")
T.check(frames(600, function() return peer.link.ended end), "on both sides")

special("WaitForOtherPlayerToExit")
T.check(tc.link.closed, "walking out closes the link")

-- sitting down again after the visit ended: a message, no hang
special("TradeCenter")
local again = stack:top()
T.eq(again and again.stage, "message", "a second sit-down explains the visit is over")
presses = { "a" }
frame()
T.eq(coroutine.status(vm.co), "dead", "and lets the script go on")

-- B at the room number: "your friend is not ready"
special("SetBitsForLinkTradeRequest")
special("WaitForLinkedFriend")
presses = { "b" }
frame()
T.eq(coroutine.status(vm.co), "dead", "B leaves the room screen")
T.eq(vm.scriptVar, 0, "WaitForLinkedFriend: FALSE")

run.release()
T.finish("gblink gen2 ingame (" .. version .. ")")
