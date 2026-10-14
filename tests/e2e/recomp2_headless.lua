-- gen1recomp's side of a live Gen 2 (Gold/Silver/Crystal) trade, without a
-- window: the engine's Gen 2 data, save codec, Mail and Evolution, this
-- mod's Gen 2 protocol stack (lib/session.lua on Proto.forGen(2),
-- lib/link2.lua, lib/codec2.lua, lib/party2.lua), real luasocket and the
-- real trade server.  The receptionist, the table and the screens are
-- skipped; what lands in the party, and how, is the mod's own code.
--
--   LUA_CPATH='<luasocket>/?.so;;' luajit <mod>/tests/e2e/recomp2_headless.lua \
--     <gen 2 cache dir> <slot.lua> <room> <out dir> [gives] [server]
--
-- <gives> is what to offer each round, comma separated: a 1-based party
-- slot, or "last" for the end of the party (the mon just received).  The
-- default "1,last" trades slot 1, then offers back whatever arrived --
-- which proves our model of our own party still matches the far side's
-- byte for byte after an evolution.  Whatever the far side offers is
-- accepted.  After the last round it cancels and waits for the far side to
-- leave too.  Every trade autosaves to <out>/recomp2_after.lua and
-- <out>/recomp2_after.sav (a cartridge save for savecheck).
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local cache, slotPath, room, out = arg[1], arg[2], arg[3], arg[4]
local gives = {}
for g in (arg[5] or "1,last"):gmatch("[^,]+") do gives[#gives + 1] = g end
local server = (arg[6] or "ws://pokemon-gb-online-trades.herokuapp.com"):gsub("/+$", "")
assert(cache and slotPath and room and out,
       "usage: recomp2_headless.lua <gen 2 cache dir> <slot.lua> <room> <out dir> [gives] [server]")
local here = (arg[0] or ""):match("^(.*)/tests/e2e/[^/]+$") or "mods/gblink"

local socket = require("socket")
love.timer.getTime = socket.gettime
local t0 = socket.gettime()
local function log(fmt, ...)
  io.write(("[%6.1f] " .. fmt .. "\n"):format(socket.gettime() - t0, ...))
  io.flush()
end

local SaveSerializer = require("src.core.SaveSerializer")
local f = assert(io.open(slotPath, "rb"))
local save = assert(SaveSerializer.decode(f:read("*a")))
f:close()
local game = save.version or (save.meta and save.meta.version) or "gold"

local GameVersion = require("src.core.GameVersion")
GameVersion.set(game)
local SaveConvert = require("src.save_convert.SaveConvert")
local Gen2Save = require("src.save_convert.Gen2Save")
local Gen2Layout = require("src.save_convert.Gen2Layout")
local Mon = require("src.battle.gen2.Mon")
local Mail = require("src.core.gen2.Mail")
local Evolution = require("src.core.gen2.Evolution")

local data = assert(SaveConvert.gen2DataFromDir(cache), "no Gen 2 tables under " .. cache)
SaveConvert.setGen2DataStub(data)

local function lib(name) return dofile(here .. "/lib/" .. name .. ".lua") end
local Proto, Ws, Session = lib("proto"), lib("ws"), lib("session")
local Codec2, Link2, Party2 = lib("codec2"), lib("link2"), lib("party2")
local P2 = Proto.forGen(2)

local env = { data = data, cw = Gen2Save.crosswalks(data), charmap = Gen2Layout.charmap,
              Mon = Mon, crystal = game == "crystal" }

local function partyLine(list)
  local names = {}
  for _, m in ipairs(list) do
    names[#names + 1] = (m.nickname or m.species) .. (m.item and ("@" .. m.item) or "")
  end
  return table.concat(names, ", ")
end

local function wireLine(party)
  local names = {}
  for _, w in ipairs(party.mons) do
    local m = Codec2.engineMon(env, w)
    names[#names + 1] = (m.nickname or m.species) .. (m.item and ("@" .. m.item) or "") .. "/" .. tostring(m.ot)
  end
  return table.concat(names, ", ")
end

local saves = 0
local function writeSave()
  saves = saves + 1
  local fh = assert(io.open(out .. "/recomp2_after.lua", "wb"))
  fh:write(SaveSerializer.encode(save))
  fh:close()
  local bytes, note = SaveConvert.exportSav(save, game)
  assert(bytes, note)
  fh = assert(io.open(out .. "/recomp2_after.sav", "wb"))
  fh:write(bytes)
  fh:close()
  log("autosave #%d -> %s/recomp2_after.sav", saves, out)
end

log("%s, party before: %s", game, partyLine(save.party))
local url = server .. "/" .. P2.ROOM .. "/" .. room
local ws = Ws.new(url, { socket = socket, now = socket.gettime, random = math.random })
math.randomseed(os.time())
local session = Session.new({
  conn = ws, Proto = P2, now = socket.gettime, rng = math.random,
  log = function(fmt, ...) log(fmt, ...) end,
  needMail = Link2.needMail,
})
local link = Link2.new({ game = { save = save }, env = env, Codec2 = Codec2, session = session,
                         Mail = Mail, log = log })
assert(link:prepare(), link.error)
log("dialing %s", url)

local round, done, failed = 0, false, nil
local function offer()
  round = round + 1
  local g = gives[round]
  if not g then
    log("round %d: CANCEL (no more to give)", round)
    link:choose(nil)
    return
  end
  local slot = g == "last" and #save.party or tonumber(g)
  local m = save.party[slot]
  log("round %d: offering slot %d (%s)", round, slot, m and (m.nickname or m.species) or "?")
  link:choose(slot - 1)
end

link.listener = {
  onLink = function(_, ev)
    local t = ev.type
    if t == "paired" then log("paired")
    elseif t == "mode" then log("mode: %s", tostring(ev.mode))
    elseif t == "party" then
      log("their party (%s): %s", tostring(link.theirName), wireLine(link.theirs))
      offer()
    elseif t == "theirPick" then
      local m = ev.mon and Codec2.engineMon(env, ev.mon)
      log("they offer slot %d (%s) -- accepting", ev.slot + 1, m and (m.nickname or m.species) or "?")
      link:accept(true)
    elseif t == "theirStop" then
      log("they cancelled")
    elseif t == "theirAccept" then
      log("they %s", ev.ok and "accept" or "decline")
    elseif t == "traded" then
      local landed = Party2.receive({ env = env, Codec2 = Codec2, save = save, Mail = Mail,
                                      Evolution = Evolution }, ev.ourSlot, ev.received)
      log("traded: gave %s, got %s", landed.given.nickname or landed.given.species,
          landed.mon.nickname or landed.mon.species)
      local evolved = Party2.evolveNow({ env = env, save = save, Evolution = Evolution }, landed)
      if evolved then log("  ...which evolved into %s (item now %s)", evolved.species, tostring(evolved.item)) end
      log("party now: %s", partyLine(save.party))
      writeSave()
      link:roundDone(save.party[landed.index])
    elseif t == "round" then
      log("they sat down again (round %d)", ev.round or 0)
      log("our model of their party: %s", wireLine(link.theirs))
      offer()
    elseif t == "again" then
      -- a decline or a one-sided CANCEL: like the web client, end the visit
      log("no trade this time; cancelling")
      link:choose(nil)
    elseif t == "ended" then
      log("both left the table")
      done = true
    elseif t == "error" then
      failed = ev.message
    end
  end,
}

local lastStatus
local deadline = socket.gettime() + tonumber(os.getenv("E2E_TIMEOUT") or "3600")
while not done and not failed and socket.gettime() < deadline do
  link:update()
  local status = link:status()
  if status ~= lastStatus then
    lastStatus = status
    log("session: %s", tostring(status))
  end
  socket.sleep(1 / 60)
end
link:close()
if failed then
  log("FAILED: %s", failed)
  os.exit(1)
end
if not done then
  log("timed out")
  os.exit(2)
end
log("party after: %s", partyLine(save.party))
os.exit(0)
