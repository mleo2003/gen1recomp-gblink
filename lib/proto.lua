-- The wire format of the Pokémon GB online trade server that
-- pokemon.gblink.io and Lorenzooone's PokemonGB_Online_Trades_and_Battles
-- (MIT) both speak: utilities/high_level_listener.py, rby_trading.py and
-- gsc_trading.py there are the reference this follows.
--
--   SEND  'S' TYPE(4) LEN(2, big-endian) DATA     store-and-forward
--   GET   'G' TYPE(4)                             "resend your latest TYPE"
--
-- Every message rides a binary WebSocket frame; the server answers G VES1
-- and G RAN1 itself, drops anything whose TYPE or LEN is not in the table
-- below, and forwards the rest to the other player in the room.

local bit = require("bit")

local Proto = {}

-- rby_trading.py RBYTradingClientTransfers.possible_transfers
Proto.LENGTHS = {
  FLL1 = { [0x271] = true },          -- random 10 + party 0x1A2 + patches 0xC5
  SNG1 = { [32] = true, [7] = true },  -- 8 x 4-byte sync entries (7 = pre-4.0)
  POL1 = { [0x43] = true, [2] = true },
  MVS1 = { [10] = true },             -- counter, species, 4 moves, 4 PP
  CHC1 = { [0x44] = true, [2] = true }, -- counter, choice, 66-byte mon | stop
  ACP1 = { [2] = true },
  SUC1 = { [2] = true },
  BUF1 = { [2] = true },
  NEG1 = { [2] = true },
  VEC1 = { [6] = true },
  VES1 = { [6] = true },
  RAN1 = { [10] = true },
  ASK1 = { [2] = true },
}

-- gsc_trading.py GSCTradingClient / rby_trading.py RBYTrading
Proto.BUFFERED = 0x85
Proto.SYNC = 0x12
Proto.NEED_DATA = 0x72
Proto.NO_NEED_DATA = 0x43
Proto.SUCCESS = 0x91
Proto.FIRST_INDEX = 0x60
Proto.STOP = 0x6F
Proto.DECLINE = 0x61
Proto.ACCEPT = 0x62
Proto.VERSION = { 4, 0, 1, 0, 0, 0 } -- trading_version.py 4.1.0, LE16 x3

-- section lengths and the sync window shape (gsc_trading.py *_new)
Proto.SECTION_LENGTHS = { [0] = 0x0A, [1] = 0x1A2, [2] = 0xC5 }
Proto.WINDOW = 8
Proto.MARKER = 0xFFFF

local function bytes(t)
  local out = {}
  for i = 1, #t do out[i] = string.char(bit.band(t[i], 0xFF)) end
  return table.concat(out)
end

Proto.bytes = bytes

function Proto.send(kind, data)
  if type(data) == "table" then data = bytes(data) end
  data = data or ""
  return "S" .. kind .. string.char(bit.rshift(#data, 8), bit.band(#data, 0xFF)) .. data
end

function Proto.get(kind)
  return "G" .. kind
end

-- returns { req = "S"|"G", kind = "TYPE", data = string } or nil
function Proto.decode(msg, lengths)
  if type(msg) ~= "string" or #msg < 5 then return nil end
  local req, kind = msg:sub(1, 1), msg:sub(2, 5)
  if not kind:match("^[%w]+$") then return nil end
  if req == "G" then return { req = "G", kind = kind } end
  if req ~= "S" or #msg < 7 then return nil end
  local n = msg:byte(6) * 256 + msg:byte(7)
  if #msg < 7 + n then return nil end
  lengths = lengths or Proto.LENGTHS
  local allowed = lengths[kind]
  if not allowed or not allowed[n] then return nil end
  return { req = "S", kind = kind, data = msg:sub(8, 7 + n) }
end

-- ------------------------------------------------------------------
-- SNG1 windows (gsc_trading.py write_sync_data_new / read_sync_data_new):
--   byte0 = (pos >> 8 & 1) | (filler_len & 0x3F) << 1 | is_filler << 7
--   byte1 = pos & 0xFF   byte2 = value   byte3 = section
-- a 9-bit position of 0x1FF is the "this section starts here" marker
-- ------------------------------------------------------------------

function Proto.encodeWindow(entries)
  local out = {}
  for i = 1, Proto.WINDOW do
    local e = entries[i] or entries[#entries]
    local pos = e.pos == Proto.MARKER and 0x1FF or e.pos
    out[#out + 1] = string.char(
      bit.band(bit.rshift(pos, 8), 1), bit.band(pos, 0xFF),
      bit.band(e.value or 0, 0xFF), bit.band(e.section or 0, 0xFF))
  end
  return table.concat(out)
end

function Proto.markerWindow(section)
  local e = {}
  for i = 1, Proto.WINDOW do e[i] = { pos = Proto.MARKER, value = 0xFF, section = section } end
  return Proto.encodeWindow(e)
end

-- eight consecutive positions of `data` (a string) from `start`
function Proto.dataWindow(section, data, start)
  local e = {}
  local last = #data - 1
  start = math.max(0, math.min(start, math.max(0, last - Proto.WINDOW + 1)))
  for i = 1, Proto.WINDOW do
    local pos = math.min(start + i - 1, last)
    e[i] = { pos = pos, value = data:byte(pos + 1) or 0, section = section }
  end
  return Proto.encodeWindow(e)
end

function Proto.decodeWindow(s)
  if type(s) ~= "string" or #s < Proto.WINDOW * 4 then return nil end
  local out = {}
  for i = 0, Proto.WINDOW - 1 do
    local b0, b1, b2, b3 = s:byte(i * 4 + 1, i * 4 + 4)
    local pos = bit.lshift(bit.band(b0, 1), 8) + b1
    local entry = { pos = pos, value = b2, section = b3,
                    filler = bit.rshift(b0, 7) == 1,
                    fillerLen = bit.band(bit.rshift(b0, 1), 0x3F) }
    if pos == 0x1FF then
      entry.pos, entry.filler, entry.fillerLen = Proto.MARKER, false, 0
    end
    out[i + 1] = entry
  end
  return out
end

return Proto
