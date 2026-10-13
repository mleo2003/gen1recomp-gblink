-- The whole visit through main.lua, loaded by the real headless loader:
-- the receptionist's door, the room number, the link screen, two trades on
-- the engine's Trade Center against the pokemon.gblink.io client
-- (tests/fake_peer.lua), then B and END LINK.  luasocket is a fake whose
-- connections end at tests/fake_relay.lua, so lib/ws.lua runs for real.
--
--   POKEPORT_DATA_DIR=<red data/generated> luajit mods/gblink/tests/ingame_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local clock = 0
local function now() return clock end
love.timer.getTime = now

-- the screens LinkState pushes: run their callbacks at once
package.loaded["src.render.TextBox"] = {
  new = function(_, text, onDone) return { isTextBox = true, text = text, onDone = onDone } end,
}
local Screens = require("src.ui.Screens")
Screens.push = function(_, id, opts)
  if id == "TradeAnim" and opts and opts.onDone then opts.onDone() end
end
local Stats = require("src.pokemon.Stats")
package.loaded["src.pokemon.Evolution"] = {
  evolve = function(_, mon, to, onDone)
    local hpLost = mon.stats.hp - mon.hp
    mon.species = to
    mon.stats = Stats.calc(Data.pokemon[to], mon.level, mon.dvs, mon.statExp)
    mon.hp = math.max(1, mon.stats.hp - hpLost)
    onDone()
  end,
}

local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "mods/gblink"
local Proto = dofile(here .. "/lib/proto.lua")
local Codec = dofile(here .. "/lib/codec.lua")
local FakeRelay = dofile(here .. "/tests/fake_relay.lua")
local FakePeer = dofile(here .. "/tests/fake_peer.lua")
local FakeSocket = dofile(here .. "/tests/fake_socket.lua")

math.randomseed(21)
local relay = FakeRelay.new({ Proto = Proto, now = now, latency = 0.06 })
local fakeSocket = FakeSocket.new(relay, now)
package.loaded.socket = fakeSocket

local LinkState = require("src.link.LinkState")
local Overworld = require("src.world.OverworldController")
local CodeEntry = require("src.link.CodeEntry")
local Runtime = require("src.mods.Runtime")
local Pokemon = require("src.pokemon.Pokemon")

local opened
Overworld._gblinkReceptionist = function(ow, onDone)
  opened = LinkState.new(ow.game)
  ow.game.stack:push(opened)
  if onDone then onDone() end
end

local run = T.sdk.loadMod(here, { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

-- every line the screens draw has to fit the 160 px screen, 8 px a character
local Font = require("src.render.Font")
local overflow = {}
Font.draw = function(text, x)
  text = tostring(text)
  if x + #text * 8 > 160 then overflow[#overflow + 1] = ("%q at x=%d"):format(text, x) end
end
Font.drawCode = function() end

local env = {
  data = Data, cw = require("src.save_convert.GenSave").crosswalks(Data),
  charmap = require("src.save_convert.data.charmap"), Stats = Stats,
  Growth = require("src.pokemon.Growth"),
}
local function mons(list, ot, otId)
  local out = {}
  for _, row in ipairs(list) do
    local m = Pokemon.new(Data, row[1], row[2])
    m.ot, m.otId = ot, otId
    out[#out + 1] = m
  end
  return out
end

-- the far Game Boy
local peer = FakePeer.new({
  Proto = Proto, Codec = Codec, env = env, relay = relay, path = "/link1/31337",
  now = now, rng = math.random, mode = "sync", player = { name = "BLUE", id = 777 },
  party = mons({ { "KADABRA", 30 }, { "ONIX", 20 } }, "BLUE", 777),
  picks = { 0, 1, "stop" }, accepts = { true, true },
})

-- this player
local presses = {}
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
local saves = 0
local game = {
  data = Data, stack = stack,
  input = { wasPressed = function(_, b)
    if presses[1] == b then table.remove(presses, 1) return true end
    return false
  end },
  save = { player = { name = "RED", id = 1234 },
           party = mons({ { "PIKACHU", 25 }, { "SPEAROW", 20 }, { "GRAVELER", 28 } }, "RED", 1234),
           pokedex = { seen = {}, owned = {} }, flags = {} },
  writeSave = function() saves = saves + 1 end,
}
local overworld = { isOverworld = true }
stack:push(overworld)

Overworld.cableClubReceptionist({ game = game })
T.eq(opened and opened.stage, "door", "the receptionist opens the door")
opened:draw()
presses = { "down", "a" }
opened:update(); opened:update()
T.eq(opened.stage, "code", "GB-LINK ONLINE asks for a room")
opened:draw()
opened.code = CodeEntry.fromText("31337", { length = 5, charset = "0123456789" })
presses = { "a" }
opened:update()
T.eq(opened.stage, "linking", "A dials the room")

local sawAgain, sawMessage, sawStatus = false, nil, {}
local lastTrade, round = nil, 0
local plan = { 3, "last", "b" }
local nextFrame = 0
while clock < 120 do
  clock = clock + 0.001
  relay:tick()
  peer:step()
  if clock >= nextFrame then
    nextFrame = nextFrame + 1 / 60
    Runtime.call("input.step", function() end, game, 1 / 60)
    local top = stack:top()
    if top == opened and opened.link then sawStatus[opened.link.session.status] = true end
    if top == opened then
      if opened.stage == "again" then
        sawAgain = true
        presses = { "down", "a" }           -- END LINK
      elseif opened.stage == "message" then
        sawMessage = opened.text
        presses = { "a" }
      end
      opened:update()
      if stack:top() == opened then opened:draw() end
    elseif top and getmetatable(top) == LinkState then
      top:update(1 / 60)
      local t = top.trade
      if top.stage == "trade" and t and t.stage == "picking" and lastTrade ~= t and t.theirParty then
        lastTrade = t
        round = round + 1
        local want = plan[round]
        if want == "b" then
          presses = { "b" }
        elseif want then
          local slot = want == "last" and #game.save.party or want
          presses = {}
          for _ = 2, slot do presses[#presses + 1] = "down" end
          presses[#presses + 1] = "a"; presses[#presses + 1] = "right"; presses[#presses + 1] = "a"
        end
      elseif top.stage == "trade" and t and t.stage == "confirming" and top.confirmed == nil and #presses == 0 then
        presses = { "a" }
      end
    end
    if stack:top() == overworld and peer.done then break end
  end
  if peer.err then break end
end
for _ = 1, 600 do  -- let END LINK's background CANCEL finish
  clock = clock + 1 / 60
  relay:tick()
  peer:step()
  Runtime.call("input.step", function() end, game, 1 / 60)
end

T.eq(peer.err, nil, "the far client ran clean")
T.eq(#overflow, 0, "every line on the mod's screens fits the 160 px screen ("
     .. tostring(overflow[1]) .. ")")
T.check(sawStatus.waiting or sawStatus.negotiating, "the link screen showed its progress")
T.eq(peer.traded, 2, "two trades went through main.lua's own screens")
local p = game.save.party
T.eq(p[3] and p[3].species, "GOLEM", "main.lua filed the received mon at the end: our GRAVELER back as GOLEM")
T.eq(p[3] and p[3].catchRate, Data.pokemon.GRAVELER.catchRate,
     "the cart catch-rate byte landed on the mon (GRAVELER's, not GOLEM's)")
T.eq(p[3] and p[3].extra, nil, "and left no carrier behind")
T.check(saves >= 2, "autosaved after each trade")
T.eq(stack:top(), overworld, "back in the overworld after the link")
local closed = true
for _, c in ipairs(fakeSocket.connections) do
  if not c.closed then closed = false end
end
T.check(closed, "the connection was closed once the far player cancelled too")
T.check(sawAgain or (type(sawMessage) == "string" and sawMessage:find("left", 1, true)),
        "after the last screen: TRADE AGAIN / END LINK, or the other player left (" .. tostring(sawMessage) .. ")")

run.release()
T.finish("gblink ingame")
