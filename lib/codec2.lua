-- Gen 2 (Gold/Silver/Crystal) party data as the Pokémon GB online trade
-- server carries it: the cart's link sections, and the engine's Gen 2 mon
-- records on either side of them.
--
--   section 1  0x1BC  name, count, species list, trainer ID, six 48-byte
--                     party structs, OT names, nicknames, 3 trailing bytes
--   section 2  0xC5   patch list for the trainer ID + structs (290 bytes)
--   section 3  0x181  mail: six 33-byte messages, six 14-byte metadata
--                     records, and their own patch list (sent only when
--                     either party holds mail)
--
-- References: pokecrystal engine/link/link.asm (Link_PrepPartyData_Gen2,
-- the patch lists), gsc_trading_data_utils.py (the same layout as the
-- Python client models it) and the engine's own cart codec
-- (src/save_convert/Gen2Save.lua), whose field rules this mirrors.
--
-- A "wire mon" is the bytes the peer sees: { struct (48), ot (11), nick (11),
-- mail (33), meta (14), egg }.  Both parties are kept as wire mons for the
-- whole visit and changed exactly the way the cart and the Python client
-- change them (trade_mon, evolve_mon), because the Python client checks every
-- offered mon byte for byte against its own model of our party.  The engine's
-- save gets engine mon records built from the same bytes.

local bit = require("bit")

local Codec2 = {}

Codec2.SEC1, Codec2.SEC2, Codec2.SEC3 = 0x1BC, 0xC5, 0x181
local NAME = 11
local STRUCT = 0x30
Codec2.STRUCT = STRUCT
local PARTY = 6
local ID_AT = 0x13
local STRUCTS_AT = 0x15
local OTS_AT = 0x135
local NICKS_AT = 0x177
local PATCH_PART = 0xFC
local PATCH_SPAN = 2 + STRUCT * PARTY      -- 290: trainer ID + structs
local MAIL_MSG = 0x21
local MAIL_META = 0x0E
local META_AT = 0xC6
local MAIL_PATCH_AT = 0x11A
local MAIL_PATCH_SPAN = MAIL_META * PARTY  -- 0x54
local NO_DATA = 0xFE
local TERM = 0xFF
local EGG = 0xFD
local EGG_FLAG = 0x38
local EVERSTONE = 0x70
local MAIL_REPLACEMENT = 0x21              -- a $FE in a mail message travels as $21
local TERMINATOR = 0x50
Codec2.EGG = EGG

local MAIL_ITEMS = {
  [0x9E] = true, [0xB5] = true, [0xB6] = true, [0xB7] = true, [0xB8] = true,
  [0xB9] = true, [0xBA] = true, [0xBB] = true, [0xBC] = true, [0xBD] = true,
}
Codec2.MAIL_ITEMS = MAIL_ITEMS

-- ------------------------------------------------------------------
-- bytes
-- ------------------------------------------------------------------

local function buf(n, fill)
  local t = {}
  for i = 0, n - 1 do t[i] = fill or 0 end
  return t
end

local function toString(t, n)
  local out = {}
  for i = 0, n - 1 do out[i + 1] = string.char(bit.band(t[i] or 0, 0xFF)) end
  return table.concat(out)
end

local function fromString(s, n)
  local t = buf(n)
  for i = 0, n - 1 do t[i] = s:byte(i + 1) or 0 end
  return t
end

local function put(t, at, s)
  for i = 1, #s do t[at + i - 1] = s:byte(i) end
end

local function be(t, o, n)
  local v = 0
  for i = 0, n - 1 do v = v * 256 + (t[o + i] or 0) end
  return v
end

local function putBE(t, o, v, n)
  v = math.floor(tonumber(v) or 0)
  for i = n - 1, 0, -1 do
    t[o + i] = v % 256
    v = math.floor(v / 256)
  end
end

Codec2.toString, Codec2.fromString = toString, fromString

-- ------------------------------------------------------------------
-- text (the international Gen 2 charset, src/save_convert/Gen2Layout.lua)
-- ------------------------------------------------------------------

local PAIRS = { PK = true, MN = true, ["'d"] = true, ["'l"] = true, ["'m"] = true,
                ["'r"] = true, ["'s"] = true, ["'t"] = true, ["'v"] = true }

local function utf8Len(s, i)
  local c = s:byte(i)
  if not c or c < 0x80 then return 1 end
  if c >= 0xF0 then return 4 elseif c >= 0xE0 then return 3 elseif c >= 0xC0 then return 2 end
  return 1
end

local function reverse(env)
  if env._reverse then return env._reverse end
  local r = {}
  for code, glyph in pairs(env.charmap) do
    if type(glyph) == "string" and #glyph == utf8Len(glyph, 1) then
      if r[glyph] == nil or code < r[glyph] then r[glyph] = code end
    end
  end
  for code, glyph in pairs(env.charmap) do
    if PAIRS[glyph] then r[glyph] = code end
  end
  env._reverse = r
  return r
end

function Codec2.encodeText(env, str, limit, lineBreak)
  local codes, out, i = reverse(env), {}, 1
  str = tostring(str or "")
  while i <= #str and #out < limit do
    local two = str:sub(i, i + 1)
    if PAIRS[two] and codes[two] then
      out[#out + 1] = codes[two]; i = i + 2
    elseif lineBreak and str:sub(i, i) == "\n" then
      out[#out + 1] = 0x4E; i = i + 1
    else
      local w = utf8Len(str, i)
      out[#out + 1] = codes[str:sub(i, i + w - 1)] or 0xE6
      i = i + w
    end
  end
  return out
end

function Codec2.decodeText(env, s, at, n, lineBreak)
  local out = {}
  for i = 0, n - 1 do
    local c = s:byte(at + i + 1)
    if not c or c == TERMINATOR then break end
    if lineBreak and c == 0x4E then out[#out + 1] = "\n"
    else out[#out + 1] = env.charmap[c] or "?" end
  end
  return table.concat(out)
end

-- an 11-byte name the way the cart and the Python client pad it: the text,
-- then $50 to the end (gsc_trading_data_utils.py GSCTradingText.create_from_string)
function Codec2.name(env, str, chars)
  local codes = Codec2.encodeText(env, str, chars or (NAME - 1))
  local out = {}
  for i = 1, NAME do out[i] = string.char(codes[i] or TERMINATOR) end
  return table.concat(out)
end

local function speciesName(env, species)
  local def = env.data.pokemon[species]
  return (def and def.name) or tostring(species)
end
Codec2.speciesName = speciesName

-- ------------------------------------------------------------------
-- the 48-byte party struct <-> the engine's Gen 2 mon record
-- ------------------------------------------------------------------

local function index(map, id, what)
  if id == nil then return 0 end
  local v = map[id]
  if v == nil and type(id) == "number" then v = id end
  if v == nil then error(("%s %s has no cart index"):format(what, tostring(id)), 0) end
  return v
end

local function named(map, i)
  if i == nil or i == 0 then return nil end
  return map[i] or i
end

-- constants/battle_constants.asm: SLP is bits 0-2, PSN 3, BRN 4, FRZ 5, PAR 6
local STATUS_BITS = { { 3, "poison" }, { 4, "burn" }, { 5, "freeze" }, { 6, "paralyze" } }
local STATUS_CLASS = {
  sleep = "sleep", slp = "sleep", poison = "poison", psn = "poison", toxic = "poison",
  tox = "poison", burn = "burn", brn = "burn", freeze = "freeze", frz = "freeze",
  paralyze = "paralyze", par = "paralyze", paralysis = "paralyze",
}

local function encodeStatus(mon)
  if type(mon.cartStatus) == "number" then return mon.cartStatus end
  local class = mon.status and STATUS_CLASS[tostring(mon.status):lower()]
  if not class then return 0 end
  if class == "sleep" then return math.min(math.max(math.floor(tonumber(mon.statusTurns) or 1), 1), 7) end
  for _, row in ipairs(STATUS_BITS) do
    if row[2] == class then return 2 ^ row[1] end
  end
  return 0
end

local function decodeStatus(byte)
  local turns = byte % 8
  if turns > 0 then return "sleep", turns end
  for _, row in ipairs(STATUS_BITS) do
    if math.floor(byte / 2 ^ row[1]) % 2 == 1 then return row[2], nil end
  end
  return nil, nil
end

local function moveIdOf(mv)
  if type(mv) == "table" then return mv.id end
  return mv
end

-- engine mon -> 48 bytes
function Codec2.packMon(env, mon)
  local cw = env.cw
  local t = buf(STRUCT)
  t[0] = index(cw.pokemonIndex, mon.species, "species")
  t[1] = mon.item and index(cw.itemIndex, mon.item, "item") or 0
  for i = 1, 4 do
    local mv = mon.moves and mon.moves[i]
    local id = moveIdOf(mv)
    if id then
      t[1 + i] = index(cw.moveIndex, id, "move")
      local pp = type(mv) == "table" and mv.pp or (env.data.moves[id] and env.data.moves[id].pp) or 0
      local ups = type(mv) == "table" and mv.ppUps or 0
      t[0x16 + i] = (ups % 4) * 64 + (pp % 64)
    end
  end
  putBE(t, 0x06, mon.otId or 0, 2)
  putBE(t, 0x08, mon.experience or 0, 3)
  local se = mon.statExp or {}
  putBE(t, 0x0B, se.hp or 0, 2); putBE(t, 0x0D, se.attack or 0, 2)
  putBE(t, 0x0F, se.defense or 0, 2); putBE(t, 0x11, se.speed or 0, 2)
  putBE(t, 0x13, se.special or 0, 2)
  local dv = mon.dvs or {}
  t[0x15] = ((dv.attack or 0) % 16) * 16 + ((dv.defense or 0) % 16)
  t[0x16] = ((dv.speed or 0) % 16) * 16 + ((dv.special or 0) % 16)
  t[0x1B] = mon.isEgg and (mon.eggSteps or 0) or (mon.happiness or 70)
  t[0x1C] = mon.pokerus or 0
  if env.crystal then
    local time = math.floor(tonumber(mon.caughtTime) or 0) % 4
    local level = math.floor(tonumber(mon.caughtLevel) or 0) % 0x40
    local loc = math.floor(tonumber(mon.caughtLocation) or 0) % 0x80
    local g = mon.caughtByGender
    local female = g == "girl" or g == "female" or g == true
    t[0x1D] = time * 0x40 + level
    t[0x1E] = (female and 0x80 or 0) + loc
  else
    putBE(t, 0x1D, mon.caughtData or 0, 2)
  end
  t[0x1F] = mon.level or 1
  t[0x20] = encodeStatus(mon)
  local stats = mon.stats or {}
  putBE(t, 0x22, mon.isEgg and 0 or (mon.hp or 0), 2)
  putBE(t, 0x24, mon.maxHp or stats.hp or 0, 2)
  putBE(t, 0x26, stats.attack or 0, 2); putBE(t, 0x28, stats.defense or 0, 2)
  putBE(t, 0x2A, stats.speed or 0, 2); putBE(t, 0x2C, stats.specialAttack or 0, 2)
  putBE(t, 0x2E, stats.specialDefense or 0, 2)
  return toString(t, STRUCT)
end

-- 48 bytes -> the fields of an engine mon record (no derived fields)
function Codec2.unpackMon(env, s)
  local cw = env.cw
  local t = fromString(s, STRUCT)
  local moves = {}
  for i = 0, 3 do
    local id = named(cw.moves, t[2 + i])
    if id then
      local b = t[0x17 + i]
      moves[#moves + 1] = { id = id, pp = b % 64, ppUps = math.floor(b / 64) % 4 }
    end
  end
  local hi, lo = t[0x15], t[0x16]
  local atk, def, spd, spc = math.floor(hi / 16), hi % 16, math.floor(lo / 16), lo % 16
  local mon = {
    species = named(cw.pokemon, t[0]),
    item = named(cw.items, t[1]),
    moves = moves,
    otId = be(t, 0x06, 2),
    experience = be(t, 0x08, 3),
    statExp = { hp = be(t, 0x0B, 2), attack = be(t, 0x0D, 2), defense = be(t, 0x0F, 2),
                speed = be(t, 0x11, 2), special = be(t, 0x13, 2) },
    dvs = { attack = atk, defense = def, speed = spd, special = spc,
            hp = (atk % 2) * 8 + (def % 2) * 4 + (spd % 2) * 2 + (spc % 2) },
    happiness = t[0x1B],
    pokerus = t[0x1C],
    level = t[0x1F],
    hp = be(t, 0x22, 2),
    maxHp = be(t, 0x24, 2),
  }
  mon.stats = { hp = mon.maxHp, attack = be(t, 0x26, 2), defense = be(t, 0x28, 2),
                speed = be(t, 0x2A, 2), specialAttack = be(t, 0x2C, 2),
                specialDefense = be(t, 0x2E, 2) }
  mon.status, mon.statusTurns = decodeStatus(t[0x20])
  if env.crystal then
    mon.caughtTime = math.floor(t[0x1D] / 0x40)
    mon.caughtLevel = t[0x1D] % 0x40
    mon.caughtLocation = t[0x1E] % 0x80
    mon.caughtByGender = t[0x1E] >= 0x80 and "girl" or "boy"
  else
    mon.caughtData = be(t, 0x1D, 2)
  end
  return mon
end

-- ------------------------------------------------------------------
-- stats the way the cart (and the Python client) compute them:
-- floor(min(255, ceil(sqrt(statExp))) / 4) -- gsc_trading_data_utils.py:213
-- ------------------------------------------------------------------

local function statExpBonus(x)
  local v = math.ceil(math.sqrt(x or 0))
  if v >= 0x100 then v = 0xFF end
  return math.floor(v / 4)
end

local function calcStat(base, dv, statExp, level, isHp)
  local v = math.floor(((base + dv) * 2 + statExpBonus(statExp)) * level / 100)
  return v + (isHp and (level + 10) or 5)
end

-- recompute the stats bytes of a struct for its species and level, and shift
-- the current HP by the change in max HP (GSCTradingPokémonInfo.update_stats)
local function updateStats(env, t)
  local species = named(env.cw.pokemon, t[0])
  local def = env.data.pokemon[species]
  if not def or not def.baseStats then return end
  local b = def.baseStats
  local hi, lo = t[0x15], t[0x16]
  local atk, dfn, spd, spc = math.floor(hi / 16), hi % 16, math.floor(lo / 16), lo % 16
  local hpDv = (atk % 2) * 8 + (dfn % 2) * 4 + (spd % 2) * 2 + (spc % 2)
  local level = t[0x1F]
  local oldMax, oldCur = be(t, 0x24, 2), be(t, 0x22, 2)
  local newMax = calcStat(b.hp, hpDv, be(t, 0x0B, 2), level, true)
  putBE(t, 0x24, newMax, 2)
  putBE(t, 0x26, calcStat(b.attack, atk, be(t, 0x0D, 2), level), 2)
  putBE(t, 0x28, calcStat(b.defense, dfn, be(t, 0x0F, 2), level), 2)
  putBE(t, 0x2A, calcStat(b.speed, spd, be(t, 0x11, 2), level), 2)
  putBE(t, 0x2C, calcStat(b.specialAttack, spc, be(t, 0x13, 2), level), 2)
  putBE(t, 0x2E, calcStat(b.specialDefense, spc, be(t, 0x13, 2), level), 2)
  putBE(t, 0x22, math.min(math.max(0, oldCur + newMax - oldMax), newMax), 2)
end

-- ------------------------------------------------------------------
-- trade evolution on wire bytes (gsc_trading_data_utils.py evolve_mon):
-- a TRADE row fires unless the mon holds an Everstone; a row that names an
-- item needs that item and consumes it; a name that was the species name
-- becomes the new species name; stats are recomputed; moves the new species
-- learns at this level go into free slots with base PP.  Returns the new
-- species id when it evolved.
-- ------------------------------------------------------------------

-- two names equal as the cart compares them: byte for byte up to the $50
function Codec2.sameText(a, b)
  for k = 1, math.max(#a, #b) do
    local x, y = a:byte(k) or TERMINATOR, b:byte(k) or TERMINATOR
    if x ~= y then return false end
    if x == TERMINATOR then return true end
  end
  return true
end

function Codec2.tradeEvolution(env, species, itemIndex)
  local def = env.data.pokemon[species]
  if not def then return nil end
  for _, row in ipairs(def.evolutions or {}) do
    if row.method == "EVOLVE_TRADE" then
      if itemIndex == EVERSTONE then return nil end
      if row.item == nil then return row.into, false end
      if itemIndex ~= 0 and env.cw.items[itemIndex] == row.item then return row.into, true end
    end
  end
  return nil
end

function Codec2.evolveWire(env, w)
  if w.egg then return nil end
  local t = fromString(w.struct, STRUCT)
  local species = named(env.cw.pokemon, t[0])
  local into, consume = Codec2.tradeEvolution(env, species, t[1])
  if not into then return nil end
  if consume then t[1] = 0 end
  -- not nicknamed: the name matches the species name up to its terminator
  -- (the cart's UpdateSpeciesNameIfNotNicknamed, the client's is_nicknamed)
  if Codec2.sameText(w.nick, Codec2.name(env, speciesName(env, species))) then
    w.nick = Codec2.name(env, speciesName(env, into))
  end
  t[0] = index(env.cw.pokemonIndex, into, "species")
  updateStats(env, t)
  local def = env.data.pokemon[into]
  for _, row in ipairs(def.levelMoves or {}) do
    if row.level == t[0x1F] then
      local mi = index(env.cw.moveIndex, row.move, "move")
      local has, free = false, nil
      for i = 0, 3 do
        if t[2 + i] == mi then has = true end
        if t[2 + i] == 0 and free == nil then free = i end
      end
      if not has and free then
        t[2 + free] = mi
        t[0x17 + free] = (env.data.moves[row.move] and env.data.moves[row.move].pp) or 0
      end
    end
  end
  w.struct = toString(t, STRUCT)
  return into
end

-- ------------------------------------------------------------------
-- wire mons and wire parties
-- ------------------------------------------------------------------

-- mail: the 47-byte mailmsg split as the link sends it -- the message
-- (33 bytes) and the metadata (bytes 0x21-0x2E: author, nationality on
-- Crystal, author ID, species, item)
local function mailBytes(env, entry)
  local msg, meta = buf(MAIL_MSG, 0), buf(MAIL_META, 0)
  if type(entry) ~= "table" then return toString(msg, MAIL_MSG), toString(meta, MAIL_META) end
  local body = tostring(entry.message or "")
  local codes
  if body:find("\n", 1, true) then
    codes = Codec2.encodeText(env, body, MAIL_MSG, true)
  else
    local raw = Codec2.encodeText(env, body, MAIL_MSG)
    codes = {}
    for k = 1, math.min(#raw, 16) do codes[k] = raw[k] end
    if #raw >= 16 then
      codes[17] = 0x4E
      for k = 17, #raw do codes[k + 1] = raw[k] end
    end
  end
  for k = 0, MAIL_MSG - 1 do msg[k] = codes[k + 1] or TERMINATOR end
  if #codes < 16 then msg[16] = 0x4E end
  local authorLen = env.crystal and 8 or 10
  local author = Codec2.encodeText(env, tostring(entry.author or ""), authorLen)
  for k = 0, authorLen - 1 do meta[k] = author[k + 1] or TERMINATOR end
  if env.crystal then putBE(meta, 0x08, tonumber(entry.nationality) or 0, 2) end
  putBE(meta, 0x0A, tonumber(entry.authorId) or 0, 2)
  meta[0x0C] = entry.species and index(env.cw.pokemonIndex, entry.species, "mail species") or 0
  meta[0x0D] = entry.type and index(env.cw.itemIndex, entry.type, "mail item") or 0
  return toString(msg, MAIL_MSG), toString(meta, MAIL_META)
end

local function mailEntry(env, msg, meta)
  local item = meta:byte(0x0E)
  if not MAIL_ITEMS[item] then return nil end
  local authorLen = env.crystal and 8 or 10
  local m = msg
  local message
  local lineEnd = nil
  for k = 1, 16 do
    local c = m:byte(k)
    if c == TERMINATOR or c == 0x4E then lineEnd = k; break end
  end
  if lineEnd == nil and m:byte(17) == 0x4E then
    message = Codec2.decodeText(env, m, 0, 16, true) .. Codec2.decodeText(env, m, 17, 16, true)
  else
    message = Codec2.decodeText(env, m, 0, MAIL_MSG, true)
  end
  local entry = {
    type = named(env.cw.items, item),
    message = message,
    author = Codec2.decodeText(env, meta, 0, authorLen),
    authorId = meta:byte(0x0B) * 256 + meta:byte(0x0C),
    species = named(env.cw.pokemon, meta:byte(0x0D)),
  }
  if env.crystal then entry.nationality = meta:byte(0x09) * 256 + meta:byte(0x0A) end
  return entry
end
Codec2.mailEntry = mailEntry

-- engine mon (+ its party mail entry) -> wire mon
function Codec2.wireMon(env, mon, mail)
  local w = {
    struct = Codec2.packMon(env, mon),
    ot = Codec2.name(env, mon.ot or "?", 7),
    egg = mon.isEgg and true or false,
  }
  if w.egg then
    w.nick = Codec2.name(env, "EGG")
  else
    w.nick = Codec2.name(env, mon.nickname or speciesName(env, mon.species))
  end
  if Codec2.holdsMail(w) then
    w.mail, w.meta = mailBytes(env, mail)
  else
    w.mail, w.meta = string.rep("\0", MAIL_MSG), string.rep("\0", MAIL_META)
  end
  return w
end

function Codec2.holdsMail(w)
  return MAIL_ITEMS[w.struct:byte(2)] == true
end

-- wire mon -> engine mon record, built through the engine's own Mon.new so
-- the derived fields (types, gender, shininess, Unown letter) are the
-- engine's, then the cart's own values laid over it
function Codec2.engineMon(env, w)
  local f = Codec2.unpackMon(env, w.struct)
  local mon = env.Mon.new(env.data, f.species, math.max(1, f.level or 1), {
    dvs = f.dvs, statExp = f.statExp, moves = f.moves, item = f.item,
    happiness = f.happiness, pokerus = f.pokerus,
    caughtLevel = f.caughtLevel, caughtTime = f.caughtTime,
    caughtLocation = f.caughtLocation, caughtByGender = f.caughtByGender,
  }) or { species = f.species }
  for _, k in ipairs({ "experience", "otId", "hp", "maxHp", "stats", "status",
                       "statusTurns", "caughtData", "level", "moves", "item" }) do
    mon[k] = f[k]
  end
  mon.ot = Codec2.decodeText(env, w.ot, 0, NAME)
  if w.egg then
    mon.isEgg = true
    mon.eggSteps = f.happiness
    mon.happiness = 0x78
    mon.nickname = nil
  else
    local nick = Codec2.decodeText(env, w.nick, 0, NAME)
    if nick ~= speciesName(env, mon.species) then mon.nickname = nick else mon.nickname = nil end
  end
  return mon, (Codec2.holdsMail(w) and mailEntry(env, w.mail, w.meta)) or nil
end

-- ------------------------------------------------------------------
-- finding an offered mon in our copy of the offerer's party, the way the
-- Python client does it (gsc_trading.py get_chosen_mon -> search_for_mon,
-- GSCTradingPokémonInfo.is_equal): the struct outside moves and PP, the
-- moves and PP as a set, then -- strong pass only -- OT, nickname and, for
-- a mail holder, the letter.  A strong match anywhere wins over a weak one.
-- The trade then uses OUR copy: CHC2's bytes only say which mon is meant.
-- ------------------------------------------------------------------

local SAME_RANGES = { { 1, 2 }, { 7, 0x17 }, { 0x1C, STRUCT } }  -- 1-based, inclusive

local function movesAndPp(struct)
  local list = {}
  for i = 0, 3 do list[#list + 1] = struct:byte(3 + i) * 256 + struct:byte(0x18 + i) end
  table.sort(list)
  return table.concat(list, ",")
end

function Codec2.sameMon(a, b, weak)
  if (a.egg and true or false) ~= (b.egg and true or false) then return false end
  for _, r in ipairs(SAME_RANGES) do
    if a.struct:sub(r[1], r[2]) ~= b.struct:sub(r[1], r[2]) then return false end
  end
  if movesAndPp(a.struct) ~= movesAndPp(b.struct) then return false end
  if weak then return true end
  if not (Codec2.sameText(a.ot, b.ot) and Codec2.sameText(a.nick, b.nick)) then return false end
  if Codec2.holdsMail(a) then
    return Codec2.sameText(a.mail, b.mail) and Codec2.sameText(a.meta, b.meta)
  end
  return true
end

-- index (1-based) of `w` in `mons`, or nil
function Codec2.findMon(mons, w)
  for i, m in ipairs(mons or {}) do
    if Codec2.sameMon(w, m, false) then return i end
  end
  for i, m in ipairs(mons or {}) do
    if Codec2.sameMon(w, m, true) then return i end
  end
  return nil
end

-- CHC2's mon: struct, OT, nickname, mail message, mail metadata, egg flag
function Codec2.single(w)
  return w.struct .. w.ot .. w.nick .. w.mail .. w.meta .. string.char(w.egg and EGG_FLAG or 0)
end

function Codec2.fromSingle(s)
  if type(s) ~= "string" or #s < 0x76 then return nil end
  return {
    struct = s:sub(1, STRUCT),
    ot = s:sub(0x31, 0x3B),
    nick = s:sub(0x3C, 0x46),
    mail = s:sub(0x47, 0x67),
    meta = s:sub(0x68, 0x75),
    egg = s:byte(0x76) == EGG_FLAG,
  }
end

-- MVS2: the four moves and four PP bytes of a mon
function Codec2.moves(w)
  return w.struct:sub(3, 6) .. w.struct:sub(0x18, 0x1B)
end

function Codec2.applyMoves(w, mvs)
  if type(mvs) ~= "string" or #mvs < 8 then return end
  w.struct = w.struct:sub(1, 2) .. mvs:sub(1, 4) .. w.struct:sub(7, 0x17)
    .. mvs:sub(5, 8) .. w.struct:sub(0x1C)
end

-- ------------------------------------------------------------------
-- sections
-- ------------------------------------------------------------------

-- wire party -> section 1, section 2 (patch list), section 3 (mail)
-- party: { name (11 bytes), id, mons = { wire mons } }
function Codec2.sections(party)
  local t = buf(Codec2.SEC1, 0)
  put(t, 0, party.name)
  local n = #party.mons
  t[0x0B] = n
  for i = 1, PARTY do
    local w = party.mons[i]
    t[0x0B + i] = w and (w.egg and EGG or w.struct:byte(1)) or TERM
  end
  t[0x12] = TERM
  putBE(t, ID_AT, party.id or 0, 2)
  for i = 1, n do
    local w = party.mons[i]
    put(t, STRUCTS_AT + (i - 1) * STRUCT, w.struct)
    put(t, OTS_AT + (i - 1) * NAME, w.ot)
    put(t, NICKS_AT + (i - 1) * NAME, w.nick)
  end
  -- the patch list: every $FE in the trainer ID and structs is sent as $FF
  -- and its position listed (Link_PrepPartyData_Gen2 / create_patches_data)
  local p = buf(Codec2.SEC2, 0)
  local w = 7
  for part = 0, 1 do
    local base = ID_AT + part * PATCH_PART
    local len = part == 0 and PATCH_PART or (PATCH_SPAN - PATCH_PART)
    for j = 0, len - 1 do
      if t[base + j] == NO_DATA then
        t[base + j] = TERM
        p[w] = j + 1; w = w + 1
      end
    end
    p[w] = TERM; w = w + 1
  end
  -- mail: messages carry $FE as $21; the metadata has its own patch list
  local m = buf(Codec2.SEC3, 0)
  for i = 1, n do
    local mon = party.mons[i]
    if Codec2.holdsMail(mon) then
      for k = 1, MAIL_MSG do
        local c = mon.mail:byte(k)
        m[(i - 1) * MAIL_MSG + k - 1] = (c == NO_DATA) and MAIL_REPLACEMENT or c
      end
      put(m, META_AT + (i - 1) * MAIL_META, mon.meta)
    end
  end
  local k = MAIL_PATCH_AT
  for j = 0, MAIL_PATCH_SPAN - 1 do
    if m[META_AT + j] == NO_DATA then
      m[META_AT + j] = TERM
      m[k] = j + 1; k = k + 1
    end
  end
  m[k] = TERM
  return toString(t, Codec2.SEC1), toString(p, Codec2.SEC2), toString(m, Codec2.SEC3)
end

-- the cart's "no mail" section (gsc_trading_data_utils.py no_mail_section.bin)
function Codec2.noMail()
  local m = buf(Codec2.SEC3, 0)
  m[MAIL_PATCH_AT] = TERM
  return toString(m, Codec2.SEC3)
end

-- does a section 1 (as received or as sent) hold mail?  The trade sends the
-- mail section exactly when either side's does (party_has_mail).
function Codec2.sectionHasMail(sec1)
  if type(sec1) ~= "string" or #sec1 < Codec2.SEC1 then return false end
  local n = math.min(math.max(sec1:byte(0x0C), 1), PARTY)
  for i = 0, n - 1 do
    if MAIL_ITEMS[sec1:byte(STRUCTS_AT + i * STRUCT + 2)] then return true end
  end
  return false
end

-- section 1 + 2 (+ 3) as received -> wire party, or nil and why
function Codec2.parseSections(sec1, sec2, sec3)
  if type(sec1) ~= "string" or #sec1 < Codec2.SEC1 then return nil, "the party data was cut short" end
  local t = fromString(sec1, Codec2.SEC1)
  -- a stray $FE is read as $FF before the patch list puts the real ones back
  -- (gsc_trading.py prevent_no_input, apply_patches)
  for i = ID_AT, ID_AT + PATCH_SPAN - 1 do
    if t[i] == NO_DATA then t[i] = TERM end
  end
  if type(sec2) == "string" then
    local part, i = 0, 8
    while i <= #sec2 and part < 2 do
      local c = sec2:byte(i)
      i = i + 1
      if c == TERM then
        part = part + 1
      elseif c ~= 0 then
        local len = part == 0 and PATCH_PART or (PATCH_SPAN - PATCH_PART)
        if c <= len then t[ID_AT + part * PATCH_PART + c - 1] = NO_DATA end
      end
    end
  end
  local count = t[0x0B]
  if count < 1 or count > PARTY then return nil, ("a party of %d"):format(count) end
  local s = toString(t, Codec2.SEC1)
  local mail = type(sec3) == "string" and #sec3 >= Codec2.SEC3 and fromString(sec3, Codec2.SEC3) or nil
  if mail then
    for i = META_AT, META_AT + MAIL_PATCH_SPAN - 1 do
      if mail[i] == NO_DATA then mail[i] = TERM end
    end
    local i = MAIL_PATCH_AT
    while i < Codec2.SEC3 do
      local c = mail[i]
      i = i + 1
      if c == TERM or c == 0 then break end
      if c <= MAIL_PATCH_SPAN then mail[META_AT + c - 1] = NO_DATA end
    end
  end
  local party = { name = s:sub(1, NAME), id = t[ID_AT] * 256 + t[ID_AT + 1], mons = {} }
  for i = 1, count do
    local at = STRUCTS_AT + (i - 1) * STRUCT
    local w = {
      struct = s:sub(at + 1, at + STRUCT),
      ot = s:sub(OTS_AT + (i - 1) * NAME + 1, OTS_AT + i * NAME),
      nick = s:sub(NICKS_AT + (i - 1) * NAME + 1, NICKS_AT + i * NAME),
      egg = t[0x0B + i] == EGG,
      mail = string.rep("\0", MAIL_MSG),
      meta = string.rep("\0", MAIL_META),
    }
    if mail and MAIL_ITEMS[w.struct:byte(2)] then
      local msg = {}
      for k = 0, MAIL_MSG - 1 do
        local c = mail[(i - 1) * MAIL_MSG + k]
        msg[k + 1] = string.char(c == MAIL_REPLACEMENT and NO_DATA or c)
      end
      w.mail = table.concat(msg)
      local meta = {}
      for k = 0, MAIL_META - 1 do meta[k + 1] = string.char(mail[META_AT + (i - 1) * MAIL_META + k]) end
      w.meta = table.concat(meta)
    end
    party.mons[i] = w
  end
  return party
end

-- ------------------------------------------------------------------
-- a trade, on both wire parties (gsc_trading_data_utils.py trade_mon +
-- reorder_party, then evolve_mon on the received mon): the given mon leaves
-- its slot, the rest close up, the received mon goes to the END
-- ------------------------------------------------------------------

function Codec2.trade(env, party, givenSlot, received)
  local mons = party.mons
  local given = table.remove(mons, givenSlot)
  local w = {}
  for k, v in pairs(received) do w[k] = v end
  mons[#mons + 1] = w
  local into = Codec2.evolveWire(env, w)
  return given, w, into
end

return Codec2
