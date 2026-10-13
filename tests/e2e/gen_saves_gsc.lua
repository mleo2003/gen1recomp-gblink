-- A Gold/Silver/Crystal cartridge save for a Time Capsule test: the player
-- stands in front of the Time Capsule receptionist on Pokémon Center 2F,
-- with the capsule open, and a party the capsule will accept (Gen 1 species
-- with Gen 1 moves only).
--
--   CAPSULE  (id 22222)  HAUNTER (holding a BERRY), RATTATA, PIDGEY
--
-- Trading the HAUNTER to gen1recomp's Red exercises a trade evolution on the
-- Gen 1 side and the cart's held-item -> catch-rate conversion; what comes
-- back exercises catch-rate -> held item.
--
-- The receptionist (pokecrystal Pokecenter2F, TIME_CAPSULE desk at 13,3) is
-- open only when EVENT_MET_BILL and the daily ENGINE_TIME_CAPSULE are clear;
-- a fresh event set has both clear. Run from the engine root:
--
--   luajit <mod>/tests/e2e/gen_saves_gsc.lua <cache dir> <out dir> [gold|silver|crystal]
--
-- Gold/Silver keep no caught data, so their mons are legal as built here.
-- Crystal stamps caught time/place/level, which this does not fill in, so
-- PKHeX flags Crystal-built mons (the trade itself is still checked).
--
-- <cache dir> holds data/generated (an imported Gen 2 ROM cache).
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local cache, out = arg[1], arg[2]
local game = arg[3] or "gold"
assert(cache and out, "usage: gen_saves_gsc.lua <cache dir> <out dir> [crystal|gold|silver]")

local GameVersion = require("src.core.GameVersion")
GameVersion.set(game)
local SaveConvert = require("src.save_convert.SaveConvert")
local Version = require("src.core.Version")
local GoldSave = require("src.core.gen2.Save")
local Mon = require("src.battle.gen2.Mon")

local data = assert(SaveConvert.gen2DataFromDir(cache), "no Gen 2 tables under " .. cache)
SaveConvert.setGen2DataStub(data)

local function moves(list)
  local out = {}
  for i, id in ipairs(list) do
    local def = assert(data.moves[id], "unknown move " .. id)
    out[i] = { id = id, pp = def.pp }
  end
  return out
end

local function mon(species, level, opts)
  local m = assert(Mon.new(data, species, level, {
    item = opts.item, nickname = opts.nickname,
    moves = moves(opts.moves),
    dvs = opts.dvs, happiness = 70,
  }), "unknown species " .. species)
  m.ot, m.otId = "CAPSULE", 22222
  return m
end

local save = GoldSave.newGame({ playerName = "CAPSULE", rivalName = "RIVAL", trainerId = 22222 })
save.version = game
save.player.id = 22222
save.player.name = "CAPSULE"
save.position = { map = "POKECENTER_2F", mapGroup = 20, mapNumber = 1, x = 13, y = 4, facing = "up" }
save.party = {
  -- level 31: Haunter learns CONFUSE_RAY at 31 in Gold/Silver/Crystal
  mon("HAUNTER", 31, { item = "BERRY", moves = { "LICK", "HYPNOSIS", "NIGHT_SHADE", "CONFUSE_RAY" },
                       dvs = { attack = 11, defense = 6, speed = 13, special = 9 } }),
  mon("RATTATA", 12, { moves = { "TACKLE", "TAIL_WHIP", "QUICK_ATTACK" },
                       dvs = { attack = 5, defense = 8, speed = 10, special = 3 } }),
  mon("PIDGEY", 10, { moves = { "TACKLE", "SAND_ATTACK" },
                      dvs = { attack = 7, defense = 7, speed = 7, special = 7 } }),
}
save.pokedex = save.pokedex or { seen = {}, caught = {} }
for _, m in ipairs(save.party) do
  save.pokedex.seen[m.species], save.pokedex.caught[m.species] = true, true
end

local bytes, note = SaveConvert.exportSav(save, game)
assert(bytes, note)
if note then io.stderr:write("export note: " .. note .. "\n") end
local path = out .. "/capsule_" .. game .. ".sav"
local f = assert(io.open(path, "wb"))
f:write(bytes)
f:close()
print(("wrote %s (%d bytes)"):format(path, #bytes))

-- read it back the way the launcher imports a cartridge save
local back, err = SaveConvert.importSav(bytes, Version.saveFormat, game)
assert(back, err)
local pos = back.position or {}
assert(back.player.name == "CAPSULE" and back.player.id == 22222, "trainer did not round-trip")
assert(pos.map == "POKECENTER_2F" and pos.x == 13 and pos.y == 4,
       ("position did not round-trip (%s %s,%s)"):format(tostring(pos.map), tostring(pos.x), tostring(pos.y)))
for i, m in ipairs(save.party) do
  local b = back.party[i]
  assert(b and b.species == m.species and b.level == m.level and b.item == m.item,
         ("party slot %d did not round-trip (%s %s %s)"):format(i, tostring(b and b.species),
           tostring(b and b.level), tostring(b and b.item)))
end
print("round trip ok: trainer, position (POKECENTER_2F 13,4) and party re-import")
