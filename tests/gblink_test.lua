-- The mod through the real headless loader: what it says it does.
--
--   POKEPORT_DATA_DIR=<red data/generated> luajit mods/gblink/tests/gblink_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "mods/gblink"
local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")
local Data = require("src.core.Data")
Data:load()

local LinkState = require("src.link.LinkState")
local Overworld = require("src.world.OverworldController")

-- stand in for the receptionist's dialog: on YES she pushes LinkState.new
-- (src/world/OverworldController.lua cableClubReceptionist)
local engineNew = LinkState.new
local opened
Overworld._gblinkReceptionist = function(ow, onDone)
  opened = LinkState.new(ow.game)
  if onDone then onDone() end
end

local run = T.sdk.loadMod(here, { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
T.eq(run.loader.exports.gblink.version, run.loader.mods.gblink.manifest.version, "exports its manifest version")

-- ------- the receptionist's door

local presses = {}
local stack = { states = {} }
function stack:push(s) self.states[#self.states + 1] = s end
function stack:pop() return table.remove(self.states) end
function stack:top() return self.states[#self.states] end
local game = {
  data = Data, stack = stack,
  input = { wasPressed = function(_, b)
    if presses[1] == b then table.remove(presses, 1) return true end
    return false
  end },
  save = { player = { name = "RED", id = 1 }, party = {}, pokedex = { seen = {}, owned = {} } },
}

local done = false
Overworld.cableClubReceptionist({ game = game }, function() done = true end)
T.check(done, "the receptionist's own onDone still runs")
T.eq(opened and opened.stage, "door", "at the desk, the link opens on the LAN / GB-LINK door")
T.check(getmetatable(LinkState.new(game)) == LinkState,
        "away from the desk LinkState.new is the engine's own")
T.check(LinkState._gblinkNew == engineNew, "the engine constructor is kept for a hot reload")

stack:push(opened)
presses = { "a" }
opened:update()
T.check(getmetatable(stack:top()) == LinkState, "LAN CABLE hands over to the engine's LAN screen")

Overworld.cableClubReceptionist({ game = game })
stack.states = { opened }
presses = { "down", "a" }
opened:update()
opened:update()
T.eq(opened.stage, "code", "GB-LINK ONLINE asks for a room number")
presses = { "up", "right", "up", "up" }
for _ = 1, 4 do opened:update() end
-- no luasocket (the headless loader, or a build without it): the mod still
-- loads and says so.  Hidden here so the check holds with luasocket installed.
local hiddenSocket, hiddenSearchers = package.loaded.socket, package.loaders
package.loaded.socket = nil
package.loaders = { function(name)
  if name == "socket" then return "\n\tno socket (hidden by the test)" end
  for _, f in ipairs(hiddenSearchers) do
    local r = f(name)
    if type(r) == "function" then return r end
  end
end }
presses = { "a" }
opened:update()
package.loaded.socket, package.loaders = hiddenSocket, hiddenSearchers
T.eq(opened.stage, "message", "with no network library it explains instead of crashing")

-- ------- a received mon keeps its cart catch rate

local mon = { species = "KADABRA", extra = { gblink = { catchRate = 100 } } }
Runtime.emit("pokemon.received", { mon = mon, from = "link" })
T.eq(mon.catchRate, 100, "the carried catch-rate byte becomes the mon's own")
T.eq(mon.extra, nil, "...and the carrier is removed")

-- ------- codec round trips the engine data

local Codec = dofile(here .. "/lib/codec.lua")
local Pokemon = require("src.pokemon.Pokemon")
local env = {
  data = Data, cw = require("src.save_convert.GenSave").crosswalks(Data),
  charmap = require("src.save_convert.data.charmap"),
  Stats = require("src.pokemon.Stats"), Growth = require("src.pokemon.Growth"),
}
local party = { Pokemon.new(Data, "MEW", 50), Pokemon.new(Data, "NIDORAN_M", 9) }
party[1].otId, party[1].ot = 0xFEFE, "GF"
party[2].nickname = "NIDDY"
local s1, s2 = Codec.encodeSections(env, { name = "RED", id = 4321 }, party)
T.eq(#s1, 0x1A2, "section 1 is 0x1A2 bytes")
T.eq(#s2, 0xC5, "section 2 is 0xC5 bytes")
T.check(not s1:find("\254", 1, true), "no $FE survives in section 1")
local d = assert(Codec.decodeSections(env, s1, s2))
T.eq(d.name, "RED", "trainer name")
T.eq(d.party[1].otId, 0xFEFE, "an OT ID of $FEFE comes back through the patch list")
T.eq(d.party[2].nickname, "NIDDY", "nickname")
T.eq(d.party[1].nickname, nil, "an un-nicknamed mon stays un-nicknamed")
local single = assert(Codec.encodeSingle(env, { name = "RED", id = 4321 }, party[1]))
T.eq(#single, 66, "a CHC1 mon is 66 bytes")
local back = Codec.decodeSingle(env, single)
T.eq(back.species, "MEW", "and decodes")
T.eq(#Codec.encodeMoves(env, { name = "RED", id = 4321 }, party[1]), 9, "an MVS1 payload is 9 bytes")

run.release()
T.finish("gblink")
