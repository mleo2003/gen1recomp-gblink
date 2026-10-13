-- Gen 1 party <-> the bytes a Red/Blue/Yellow cart puts on the link cable.
--
-- pokered engine/link/cable_club.asm CableClub_DoBattleOrTradeAgain sends
-- three blocks, each through Serial_ExchangeBytes:
--
--   random numbers  SERIAL_RN_PREAMBLE_LENGTH (7) x $FD + 10 bytes < $FD
--   player data     SERIAL_PREAMBLE_LENGTH (6) x $FD, then wPlayerName (11),
--                   wPartyCount (1), wPartySpecies (6 + $FF), wPartyMons
--                   (6 x 44), wPartyMonOT (6 x 11), wPartyMonNicks (6 x 11)
--                   and 3 trailing bytes of whatever follows in WRAM
--   patch list      3 x $FD, 7 x $00, then the patch offsets (200 bytes)
--
-- $FE (SERIAL_NO_DATA_BYTE) is what a slow slave answers when the master
-- clocks before it has loaded its next byte, so the receiver drops every $FE
-- it reads.  A real $FE inside wPartyMons would be lost the same way, which is
-- what the patch list is for: the sender rewrites each one to $FF and records
-- its 1-based offset, part 1 covering offsets 1..252 and part 2 the remaining
-- 12, each part closed by $FF.
--
-- Pure Lua over a { data, cw, charmap, Stats, Growth } environment, so the
-- headless tests drive it with the real imported tables.

local bit = require("bit")

local Codec = {}

local NAME_LENGTH = 11
local PARTY_LENGTH = 6
local MON_LENGTH = 44
local TRAINER_NAME_MAX = 7

local PREAMBLE = 0xFD
local NO_DATA = 0xFE
local TERMINATOR = 0xFF

Codec.PREAMBLE = PREAMBLE
Codec.NO_DATA = NO_DATA
Codec.PLAYER_PREAMBLE = 6
Codec.RN_PREAMBLE = 7
Codec.RN_COUNT = 10
Codec.RN_LENGTH = 17
-- SERIAL_PREAMBLE_LENGTH + NAME_LENGTH + 1 + PARTY_LENGTH + 1
--   + (PARTYMON_STRUCT_LENGTH + NAME_LENGTH * 2) * PARTY_LENGTH + 3
Codec.PLAYER_LENGTH = 6 + NAME_LENGTH + 1 + PARTY_LENGTH + 1
  + (MON_LENGTH + NAME_LENGTH * 2) * PARTY_LENGTH + 3
Codec.PATCH_LENGTH = 200
-- the part of the player block the receiver copies (name through nicknames)
Codec.PAYLOAD_LENGTH = NAME_LENGTH + 1 + PARTY_LENGTH + 1
  + (MON_LENGTH + NAME_LENGTH * 2) * PARTY_LENGTH

local MONS_AT = NAME_LENGTH + 1 + PARTY_LENGTH + 1      -- 19
local OT_AT = MONS_AT + MON_LENGTH * PARTY_LENGTH       -- 283
local NICK_AT = OT_AT + NAME_LENGTH * PARTY_LENGTH      -- 349
local MONS_SPAN = MON_LENGTH * PARTY_LENGTH             -- 264
local PATCH_PART = 0xFC                                 -- 252 offsets per part

-- pokered constants/type_constants.asm
local TYPE_INDEX = {
  NORMAL = 0, FIGHTING = 1, FLYING = 2, POISON = 3, GROUND = 4, ROCK = 5,
  BIRD = 6, BUG = 7, GHOST = 8, FIRE = 20, WATER = 21, GRASS = 22,
  ELECTRIC = 23, PSYCHIC_TYPE = 24, ICE = 25, DRAGON = 26,
}

-- constants/battle_constants.asm: bits 0-2 sleep counter, 3 PSN, 4 BRN,
-- 5 FRZ, 6 PAR
local STATUS_BIT = { PSN = 3, BRN = 4, FRZ = 5, PAR = 6 }
local STATUS_ORDER = { "PSN", "BRN", "FRZ", "PAR" }

local STAT_KEYS = { "hp", "attack", "defense", "speed", "special" }

-- ------------------------------------------------------------------
-- byte buffers: a 0-based array of numbers, flattened to a string at the end
-- ------------------------------------------------------------------

local function newBuf(n, fill)
  local b = {}
  for i = 0, n - 1 do b[i] = fill or 0 end
  b.n = n
  return b
end

local function toString(b)
  local parts = {}
  for i = 0, b.n - 1 do parts[#parts + 1] = string.char(b[i]) end
  return table.concat(parts)
end

local function u8(s, off) return s:byte(off + 1) or 0 end
local function u16(s, off) return u8(s, off) * 256 + u8(s, off + 1) end
local function u24(s, off)
  return u8(s, off) * 65536 + u8(s, off + 1) * 256 + u8(s, off + 2)
end

local function put8(b, off, v) b[off] = bit.band(math.floor(tonumber(v) or 0), 0xFF) end
local function put16(b, off, v)
  v = math.max(0, math.min(0xFFFF, math.floor(tonumber(v) or 0)))
  b[off] = bit.rshift(v, 8)
  b[off + 1] = bit.band(v, 0xFF)
end
local function put24(b, off, v)
  v = math.max(0, math.min(0xFFFFFF, math.floor(tonumber(v) or 0)))
  b[off] = bit.band(bit.rshift(v, 16), 0xFF)
  b[off + 1] = bit.band(bit.rshift(v, 8), 0xFF)
  b[off + 2] = bit.band(v, 0xFF)
end

-- ------------------------------------------------------------------
-- text
-- ------------------------------------------------------------------

local function encodeName(env, b, off, text, maxChars)
  local cm = env.charmap
  local limit = math.min(NAME_LENGTH - 1, maxChars or NAME_LENGTH - 1)
  text = tostring(text or "")
  local i, pos = 0, 1
  while i < limit and pos <= #text do
    local b0 = text:byte(pos)
    local clen = (b0 < 0x80 and 1) or (b0 < 0xE0 and 2) or (b0 < 0xF0 and 3) or 4
    local ch = text:sub(pos, pos + clen - 1)
    local code = cm.byToken[ch]
    -- a lower-case letter has no glyph of its own in the English font table
    -- the engine extracted; fold it before falling back to "?"
    if not code and clen == 1 then code = cm.byToken[ch:upper()] end
    b[off + i] = code or cm.byToken["?"] or 0xE6
    i, pos = i + 1, pos + clen
  end
  b[off + i] = 0x50
  for j = i + 1, NAME_LENGTH - 1 do b[off + j] = 0x50 end
end

local function decodeName(env, s, off)
  local out = {}
  for i = 0, NAME_LENGTH - 1 do
    local c = u8(s, off + i)
    if c == 0x50 then break end
    local glyph = env.charmap.byByte[c]
    -- control tokens ("<PK>", "<MN>") are legal name bytes; keep them as the
    -- engine's own decoder does so a re-export reproduces the byte
    out[#out + 1] = glyph or ("<$%02X>"):format(c)
  end
  return table.concat(out)
end

Codec.encodeName = encodeName
Codec.decodeName = decodeName

-- ------------------------------------------------------------------
-- one party_struct
-- ------------------------------------------------------------------

local function encodeStatus(status, sleepTurns)
  if status == "SLP" then
    return math.max(1, math.min(7, math.floor(tonumber(sleepTurns) or 1)))
  end
  if status and STATUS_BIT[status] then return bit.lshift(1, STATUS_BIT[status]) end
  return 0
end

local function decodeStatus(b)
  if bit.band(b, 7) > 0 then return "SLP", bit.band(b, 7) end
  for _, name in ipairs(STATUS_ORDER) do
    if bit.band(b, bit.lshift(1, STATUS_BIT[name])) ~= 0 then return name end
  end
  return nil
end

local function speciesName(env, species)
  local def = env.data.pokemon[species]
  return (def and def.name) or tostring(species)
end

-- mon is an engine party mon (src/pokemon/Pokemon.lua shape)
local function encodeMon(env, b, off, mon, otIdFallback)
  local cw, data = env.cw, env.data
  local def = data.pokemon[mon.species]
  local idx = cw.pokemonIndex[mon.species]
  if not def or not idx or idx == 0 then
    return nil, ("%s has no Gen 1 species index"):format(tostring(mon.species))
  end
  local level = math.max(1, math.min(100, math.floor(tonumber(mon.level) or 5)))
  local stats = mon.stats
  if type(stats) ~= "table" or type(stats.hp) ~= "number" then
    stats = env.Stats.calc(def, level, mon.dvs or {}, mon.statExp)
  end
  put8(b, off, idx)
  put16(b, off + 1, math.min(tonumber(mon.hp) or stats.hp, stats.hp))
  put8(b, off + 3, mon.boxLevel or level)
  put8(b, off + 4, mon.cartStatus or encodeStatus(mon.status, mon.sleepTurns))
  if type(mon.typeBytes) == "table" then
    put8(b, off + 5, mon.typeBytes[1] or 0)
    put8(b, off + 6, mon.typeBytes[2] or 0)
  else
    local t = def.types or {}
    put8(b, off + 5, TYPE_INDEX[t[1]] or 0)
    put8(b, off + 6, TYPE_INDEX[t[2] or t[1]] or 0)
  end
  -- the byte the cart stored, kept across the link (Gen 1 never rewrites it
  -- on evolution, and Gen 2 reads it as the held item)
  local carried = type(mon.extra) == "table" and type(mon.extra.gblink) == "table"
    and tonumber(mon.extra.gblink.catchRate)
  put8(b, off + 7, mon.catchRate or carried or def.catchRate or 0)
  local moves = mon.moves or {}
  for i = 0, 3 do
    local mv = moves[i + 1]
    local mIdx = mv and cw.movesIndex[mv.id] or 0
    put8(b, off + 8 + i, mIdx)
    if mIdx ~= 0 then
      put8(b, off + 29 + i, bit.bor(bit.lshift(bit.band(mv.ppUps or 0, 3), 6),
                                    bit.band(mv.pp or 0, 0x3F)))
    else
      put8(b, off + 29 + i, 0)
    end
  end
  put16(b, off + 12, mon.otId or otIdFallback or 0)
  put24(b, off + 14, mon.exp or env.Growth.expForLevel(def.growthRate, level))
  local se = mon.statExp or {}
  for k, key in ipairs(STAT_KEYS) do put16(b, off + 15 + 2 * k, se[key] or 0) end
  local dvs = mon.dvs or {}
  put8(b, off + 27, bit.bor(bit.lshift(bit.band(dvs.attack or 0, 0xF), 4),
                            bit.band(dvs.defense or 0, 0xF)))
  put8(b, off + 28, bit.bor(bit.lshift(bit.band(dvs.speed or 0, 0xF), 4),
                            bit.band(dvs.special or 0, 0xF)))
  put8(b, off + 33, level)
  for k, key in ipairs(STAT_KEYS) do put16(b, off + 32 + 2 * k, stats[key] or 0) end
  return idx
end

-- returns a Protocol.packMon-shaped table (what a peer puts on the JSON wire)
local function decodeMon(env, s, off)
  local cw = env.cw
  local species = cw.pokemonByIndex[u8(s, off)]
  if not species then
    return nil, ("species byte $%02X"):format(u8(s, off))
  end
  local moves = {}
  for i = 0, 3 do
    local mIdx = u8(s, off + 8 + i)
    if mIdx ~= 0 then
      local id = cw.movesByIndex[mIdx]
      if not id then return nil, ("move byte $%02X"):format(mIdx) end
      local ppb = u8(s, off + 29 + i)
      moves[#moves + 1] = { id = id, pp = bit.band(ppb, 0x3F), ppUps = bit.rshift(ppb, 6) }
    end
  end
  local status, sleepTurns = decodeStatus(u8(s, off + 4))
  local b0, b1 = u8(s, off + 27), u8(s, off + 28)
  local atk, def = bit.rshift(b0, 4), bit.band(b0, 0xF)
  local spe, spc = bit.rshift(b1, 4), bit.band(b1, 0xF)
  local statExp = {}
  for k, key in ipairs(STAT_KEYS) do statExp[key] = u16(s, off + 15 + 2 * k) end
  return {
    -- survives the engine's link sanitizer (Wire.plain) where a bare field
    -- would not; main.lua moves it onto the received mon
    extra = { gblink = { catchRate = u8(s, off + 7) } },
    species = species,
    level = u8(s, off + 33),
    exp = u24(s, off + 14),
    hp = u16(s, off + 1),
    status = status,
    sleepTurns = sleepTurns,
    dvs = {
      hp = bit.bor(bit.lshift(bit.band(atk, 1), 3), bit.lshift(bit.band(def, 1), 2),
                   bit.lshift(bit.band(spe, 1), 1), bit.band(spc, 1)),
      attack = atk, defense = def, speed = spe, special = spc,
    },
    statExp = statExp,
    moves = moves,
    otId = u16(s, off + 12),
  }
end

Codec.encodeMon = encodeMon
Codec.decodeMon = decodeMon

-- ------------------------------------------------------------------
-- the player data block and its patch list
-- ------------------------------------------------------------------

-- party: engine party mons; player: { name, id }.  Returns the 424-byte
-- block (preamble included, $FE already patched out) and the 200-byte patch
-- list, both as strings, or nil and a reason.  opts.raw skips the patching
-- (the block as it sits in WRAM before .patchPartyMonsLoop).
function Codec.encodePlayerBlock(env, player, party, opts)
  local b = newBuf(Codec.PLAYER_LENGTH, 0)
  for i = 0, Codec.PLAYER_PREAMBLE - 1 do b[i] = PREAMBLE end
  local base = Codec.PLAYER_PREAMBLE
  encodeName(env, b, base, player.name or "RED", TRAINER_NAME_MAX)
  local n = math.min(#party, PARTY_LENGTH)
  b[base + NAME_LENGTH] = n
  for i = 0, PARTY_LENGTH do b[base + NAME_LENGTH + 1 + i] = TERMINATOR end
  for i = 0, n - 1 do
    local mon = party[i + 1]
    local idx, why = encodeMon(env, b, base + MONS_AT + i * MON_LENGTH, mon, player.id)
    if not idx then return nil, why end
    b[base + NAME_LENGTH + 1 + i] = idx
    encodeName(env, b, base + OT_AT + i * NAME_LENGTH,
               mon.ot or player.name or "RED", TRAINER_NAME_MAX)
    encodeName(env, b, base + NICK_AT + i * NAME_LENGTH,
               mon.nickname or speciesName(env, mon.species))
  end

  if opts and opts.raw then return toString(b) end

  -- .patchPartyMonsLoop
  local patch = newBuf(Codec.PATCH_LENGTH, 0)
  patch[0], patch[1], patch[2] = PREAMBLE, PREAMBLE, PREAMBLE
  local w = 10
  local monsBase = base + MONS_AT
  for part = 0, 1 do
    local first = part * PATCH_PART
    local last = math.min(MONS_SPAN, first + PATCH_PART) - 1
    for o = first, last do
      if b[monsBase + o] == NO_DATA then
        b[monsBase + o] = TERMINATOR
        patch[w] = o - first + 1
        w = w + 1
      end
    end
    patch[w] = TERMINATOR
    w = w + 1
  end
  return toString(b), toString(patch)
end

-- ten random bytes below $FD behind the 7-byte preamble
function Codec.encodeRandomBlock(rng)
  local b = newBuf(Codec.RN_LENGTH, PREAMBLE)
  for i = Codec.RN_PREAMBLE, Codec.RN_LENGTH - 1 do
    local v
    repeat v = rng(0, 255) until v < PREAMBLE
    b[i] = v
  end
  return toString(b)
end

-- skip the leading $00/$FD/$FE run, then copy `count` bytes dropping every
-- $FE (.findStartOfEnemyNameLoop / .copyEnemyPartyLoop)
local function strip(s, count)
  local i = 1
  while i <= #s do
    local c = s:byte(i)
    if c ~= 0x00 and c ~= PREAMBLE and c ~= NO_DATA then break end
    i = i + 1
  end
  local out = {}
  while i <= #s and #out < count do
    local c = s:byte(i)
    if c ~= NO_DATA then out[#out + 1] = string.char(c) end
    i = i + 1
  end
  if #out < count then return nil end
  return table.concat(out)
end

Codec.strip = strip

-- rx: the raw received player block; rxPatch: the raw received patch list.
-- Returns { name, count, party = { packed mons with ot and nickname } } or
-- nil and a reason.
-- s: name .. nicknames (Codec.PAYLOAD_LENGTH bytes or more, $FE-patched),
-- patch: the patch list in any of its received shapes
local function unpatchAndDecode(env, s, patch)
  -- .unpatchEnemyMonsLoop
  local mons = {}
  for o = 0, MONS_SPAN - 1 do mons[o] = u8(s, MONS_AT + o) end
  local part, i = 0, 1
  patch = patch or ""
  while i <= #patch and part < 2 do
    local c = patch:byte(i)
    i = i + 1
    if c == TERMINATOR then
      part = part + 1
    elseif c ~= 0x00 and c ~= PREAMBLE and c ~= NO_DATA then
      local o = part * PATCH_PART + c - 1
      if o >= 0 and o < MONS_SPAN then mons[o] = NO_DATA end
    end
  end
  local monBytes = {}
  for o = 0, MONS_SPAN - 1 do monBytes[#monBytes + 1] = string.char(mons[o]) end
  s = s:sub(1, MONS_AT) .. table.concat(monBytes) .. s:sub(MONS_AT + MONS_SPAN + 1)

  local count = u8(s, NAME_LENGTH)
  if count < 1 or count > PARTY_LENGTH then
    return nil, ("a party of %d"):format(count)
  end
  local out = { name = decodeName(env, s, 0), count = count, party = {} }
  for k = 0, count - 1 do
    local mon, why = decodeMon(env, s, MONS_AT + k * MON_LENGTH)
    if not mon then return nil, ("slot %d: %s"):format(k + 1, why) end
    mon.ot = decodeName(env, s, OT_AT + k * NAME_LENGTH)
    local nick = decodeName(env, s, NICK_AT + k * NAME_LENGTH)
    -- a stored name equal to the species' standard name means "never
    -- nicknamed", which the engine spells as nil (GenSave #257)
    if nick ~= speciesName(env, mon.species) then mon.nickname = nick end
    out.party[#out.party + 1] = mon
  end
  return out
end

-- a block as a cart stores it after Serial_ExchangeBytes: leading
-- $00/$FD/$FE, and every later $FE dropped
function Codec.decodePlayerBlock(env, rx, rxPatch)
  local s = strip(rx, Codec.PAYLOAD_LENGTH)
  if not s then return nil, "the party data was cut short" end
  return unpatchAndDecode(env, s, rxPatch)
end

-- the online sections are positional: byte n of the other Game Boy's block
-- is position n, and a stray $FE is read as $FF before the patch list puts
-- the real ones back (gsc_trading.py prevent_no_input)
function Codec.decodeSections(env, sec1, sec2)
  if type(sec1) ~= "string" or #sec1 < Codec.PAYLOAD_LENGTH then
    return nil, "the party data was cut short"
  end
  local s = sec1:gsub("\254", "\255")
  return unpatchAndDecode(env, s, sec2)
end

-- the section 1 / section 2 bytes this side sends: the 424-byte block
-- without its 6-byte preamble (0x1A2 bytes) and the patch list without its
-- 3-byte one (0xC5 bytes)
function Codec.encodeSections(env, player, party)
  local block, patch = Codec.encodePlayerBlock(env, player, party)
  if not block then return nil, patch end
  return block:sub(Codec.PLAYER_PREAMBLE + 1), patch:sub(4)
end

-- CHC1's mon: the 44-byte party struct, OT name and nickname, unpatched
-- (rby_trading_data_utils.py single_mon_to_data)
function Codec.encodeSingle(env, player, mon)
  local b = newBuf(MON_LENGTH + 2 * NAME_LENGTH, 0)
  local idx, why = encodeMon(env, b, 0, mon, player.id)
  if not idx then return nil, why end
  encodeName(env, b, MON_LENGTH, mon.ot or player.name or "RED", TRAINER_NAME_MAX)
  encodeName(env, b, MON_LENGTH + NAME_LENGTH, mon.nickname or speciesName(env, mon.species))
  return toString(b)
end

function Codec.decodeSingle(env, s)
  if type(s) ~= "string" or #s < MON_LENGTH + 2 * NAME_LENGTH then
    return nil, "short mon"
  end
  local mon, why = decodeMon(env, s, 0)
  if not mon then return nil, why end
  mon.ot = decodeName(env, s, MON_LENGTH)
  local nick = decodeName(env, s, MON_LENGTH + NAME_LENGTH)
  if nick ~= speciesName(env, mon.species) then mon.nickname = nick end
  return mon
end

-- MVS1's payload: species, four moves, four PP of one mon
function Codec.encodeMoves(env, player, mon)
  local single, why = Codec.encodeSingle(env, player, mon)
  if not single then return nil, why end
  return single:sub(1, 1) .. single:sub(9, 12) .. single:sub(30, 33)
end

-- apply an MVS1 payload to a packed mon (the web and Python clients send
-- the species too, so a trade evolution on the far side shows up here)
function Codec.applyMoves(env, mon, mvs)
  if type(mvs) ~= "string" or #mvs < 9 then return false end
  local species = env.cw.pokemonByIndex[mvs:byte(1)]
  if species and species ~= mon.species then mon.species = species end
  local moves = {}
  for i = 0, 3 do
    local idx = mvs:byte(2 + i)
    local id = idx ~= 0 and env.cw.movesByIndex[idx] or nil
    if id then
      local ppb = mvs:byte(6 + i)
      moves[#moves + 1] = { id = id, pp = bit.band(ppb, 0x3F), ppUps = bit.rshift(ppb, 6) }
    end
  end
  if #moves > 0 then mon.moves = moves end
  return true
end

return Codec
