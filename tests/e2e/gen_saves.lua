-- Two throwaway saves for a live trade test, both standing in front of the
-- Viridian Pokémon Center's Cable Club receptionist with the Pokédex flag
-- set (the cart's CableClubNPC refuses without it):
--
--   EMU    (id 12345)  a cartridge .sav for the emulator (BGB): SPOONY the
--                      KADABRA, ONIX, PIDGEY
--   RECOMP (id 54321)  a gen1recomp save slot: PIKACHU, MACHOKE, SPEAROW
--
-- Trading KADABRA for MACHOKE exercises both trade evolutions, a nickname
-- and two different OT names/IDs. The cartridge save is also exported for
-- the gen1recomp side (recomp_before.sav) so both sides can be checked with
-- the same PKHeX tool.
--
-- Run from the engine root, with that game's imported cache:
--   POKEPORT_DATA_DIR=<cache>/data/generated luajit <mod>/tests/e2e/gen_saves.lua <out dir> [red|blue|yellow]
-- The files are named after the game (emu_<game>.sav, recomp_<game>_slot1.lua, ...).
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local out = assert(arg[1], "usage: gen_saves.lua <out dir> [red|blue|yellow]")
local game = arg[2] or "red"
assert(game == "red" or game == "blue" or game == "yellow", "game must be red, blue or yellow")
local Data = require("src.core.Data")
Data:load()
local Pokemon = require("src.pokemon.Pokemon")
local SaveConvert = require("src.save_convert.SaveConvert")
local SaveSerializer = require("src.core.SaveSerializer")
local Version = require("src.core.Version")

-- the cache root, i.e. the folder holding data/generated (convert.lua's RED_CACHE)
local cache = os.getenv("RED_CACHE")
  or (os.getenv("POKEPORT_DATA_DIR") or ""):gsub("/data/generated/?$", "")
local stub = assert(SaveConvert.gen1DataFromDir(cache), "no Gen 1 tables under " .. tostring(cache))
SaveConvert.setGen1DataStub(stub, game)

math.randomseed(1996)

-- caughtAs: the species it was caught as. Evolution keeps the catch-rate
-- byte from capture, which is what PKHeX checks a Gen 1 mon's origin by.
local function mon(species, level, ot, otId, nickname, caughtAs)
  local m = Pokemon.new(Data, species, level, math.random)
  m.ot, m.otId = ot, otId
  if caughtAs then m.catchRate = Data.pokemon[caughtAs].catchRate end
  if nickname then m.nickname = nickname end
  return m
end

local function save(name, id, party)
  local s = {
    meta = { format = Version.saveFormat, mods = {}, version = game },
    version = game,
    player = { map = "VIRIDIAN_POKECENTER", x = 11, y = 4, facing = "up",
               name = name, rival = "RIVAL", id = id, surfing = false },
    flags = {
      EVENT_1ST_ROUTE22_RIVAL_BATTLE = true, EVENT_BATTLED_RIVAL_IN_OAKS_LAB = true,
      EVENT_CHOSE_SQUIRTLE = true, EVENT_FOLLOWED_OAK_INTO_LAB = true,
      EVENT_FOLLOWED_OAK_INTO_LAB_2 = true, EVENT_GOT_OAKS_PARCEL = true,
      EVENT_GOT_POKEDEX = true, EVENT_GOT_POTION_SAMPLE = true, EVENT_GOT_STARTER = true,
      EVENT_GOT_TOWN_MAP = true, EVENT_OAK_ASKED_TO_CHOOSE_MON = true,
      EVENT_OAK_GOT_PARCEL = true, EVENT_ROUTE22_RIVAL_WANTS_BATTLE = true,
    },
    objectToggles = {
      BLUES_HOUSE = { BLUESHOUSE_TOWN_MAP = false },
      OAKS_LAB = { OAKSLAB_BULBASAUR_POKE_BALL = false, OAKSLAB_OAK1 = true, OAKSLAB_OAK2 = false,
                   OAKSLAB_POKEDEX1 = false, OAKSLAB_POKEDEX2 = false, OAKSLAB_RIVAL = false,
                   OAKSLAB_SQUIRTLE_POKE_BALL = false },
      PALLET_TOWN = { PALLETTOWN_OAK = false },
      ROUTE_22 = { ROUTE22_RIVAL1 = true },
      VIRIDIAN_CITY = { VIRIDIANCITY_OLD_MAN = true, VIRIDIANCITY_OLD_MAN_SLEEPY = false },
    },
    visited = { PALLET_TOWN = true, VIRIDIAN_CITY = true },
    inventory = { POTION = 1, TOWN_MAP = 1 }, bagOrder = { "POTION", "TOWN_MAP" },
    pcItems = { POTION = 1 },
    party = party, box = {},
    money = 3000, defeatedTrainers = {},
    pokedex = { seen = {}, owned = {} },
    lastHeal = { map = "VIRIDIAN_POKECENTER", x = 3, y = 3,
                 outdoor = { id = "VIRIDIAN_CITY", x = 23, y = 25 } },
    lastOutdoor = { id = "VIRIDIAN_CITY", x = 23, y = 25 },
    usedPokecenter = true, repelSteps = 0, poisonSteps = 0, playTime = 0,
    modData = {},
  }
  for _, m in ipairs(party) do
    s.pokedex.seen[m.species], s.pokedex.owned[m.species] = true, true
  end
  return s
end

local emu = save("EMU", 12345, {
  mon("KADABRA", 30, "EMU", 12345, "SPOONY", "ABRA"), mon("ONIX", 20, "EMU", 12345), mon("PIDGEY", 10, "EMU", 12345),
})
local recomp = save("RECOMP", 54321, {
  mon("PIKACHU", 25, "RECOMP", 54321), mon("MACHOKE", 32, "RECOMP", 54321, nil, "MACHOP"), mon("SPEAROW", 15, "RECOMP", 54321),
})

local function write(path, body)
  local f = assert(io.open(out .. "/" .. path, "wb"))
  f:write(body)
  f:close()
  print("wrote " .. out .. "/" .. path)
end

local function export(s, path)
  local bytes, note = SaveConvert.exportSav(s, game)
  assert(bytes, note)
  if note then io.stderr:write(path .. ": " .. note .. "\n") end
  assert(#bytes == SaveConvert.SAVE_SIZE)
  write(path, bytes)
  -- read it back the way the launcher imports a cartridge save
  local back, err = SaveConvert.importSav(bytes, Version.saveFormat, game)
  assert(back, err)
  assert(back.player.name == s.player.name and back.player.id == s.player.id, path .. ": trainer did not round-trip")
  assert(back.player.map == s.player.map and back.player.x == s.player.x and back.player.y == s.player.y,
         path .. ": position did not round-trip")
  for i, m in ipairs(s.party) do
    local b = back.party[i]
    assert(b and b.species == m.species and b.level == m.level and b.ot == m.ot and b.otId == m.otId,
           path .. ": party slot " .. i .. " did not round-trip")
    for _, k in ipairs({ "hp", "attack", "defense", "speed", "special" }) do
      assert(b.dvs[k] == m.dvs[k], path .. ": DVs did not round-trip")
    end
  end
  return bytes
end

local suffix = game == "red" and "" or ("_" .. game)
export(emu, "emu_" .. game .. ".sav")
export(recomp, "recomp" .. suffix .. "_before.sav")
write("recomp" .. suffix .. "_slot1.lua", SaveSerializer.encode(recomp))
print("round trip ok: both saves re-import with the same trainer, position and party")
