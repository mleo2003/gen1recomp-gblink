-- gen1recomp's side of a live trade, without a window: the real engine,
-- this mod's main.lua, real luasocket and the real trade server. Text boxes
-- and the trade animation are skipped, everything else (LinkState's Trade
-- Center, trade evolution, filing the mon, the autosave) is the engine's own.
--
--   POKEPORT_DATA_DIR=<red data/generated> LUA_CPATH='<luasocket>/?.so;;' \
--     luajit <mod>/tests/e2e/recomp_headless.lua <slot.lua> <room> <out dir> [give slot] [server]
--
-- It walks up to the Cable Club receptionist, picks GB-LINK ONLINE, dials
-- <room>, trades party slot <give> (default 2) once, then cancels and ends
-- the link. After the autosave it writes <out>/recomp_after.lua and
-- <out>/recomp_after.sav for savecheck.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local slotPath, room, out = arg[1], arg[2], arg[3]
local give = tonumber(arg[4] or "2")
local server = arg[5]
assert(slotPath and room and out, "usage: recomp_headless.lua <slot.lua> <room> <out dir> [give slot] [server]")
local here = (arg[0] or ""):match("^(.*)/tests/e2e/[^/]+$") or "mods/gblink"

local socket = require("socket")
love.timer.getTime = socket.gettime
local t0 = socket.gettime()
local function log(fmt, ...)
  io.write(("[%6.1f] " .. fmt .. "\n"):format(socket.gettime() - t0, ...))
  io.flush()
end

local Data = require("src.core.Data")
Data:load()
local SaveSerializer = require("src.core.SaveSerializer")
local SaveConvert = require("src.save_convert.SaveConvert")

-- the screens LinkState pushes: text boxes and the trade animation finish at once
package.loaded["src.render.TextBox"] = {
  new = function(_, text, onDone) return { isTextBox = true, text = text, onDone = onDone } end,
  soundOpts = function() return nil end,
}
local Screens = require("src.ui.Screens")
Screens.push = function(_, id, ...)
  local opts = select(1, ...)
  log("screen %s", id)
  if id == "TradeAnim" and type(opts) == "table" and opts.onDone then opts.onDone() end
end

-- trade evolution: the engine's text-only path (love.image is what selects
-- the animated one), then its own learn-move check and the re-save after it
local Evolution = require("src.pokemon.Evolution")
local realEvolve = Evolution.evolve
Evolution.evolve = function(...)
  local newImageData = love.image and love.image.newImageData
  if love.image then love.image.newImageData = nil end
  local ok, err = pcall(realEvolve, ...)
  if love.image then love.image.newImageData = newImageData end
  if not ok then error(err, 0) end
  log("evolution done")
end

local T = require("tests.modkit")
local LinkState = require("src.link.LinkState")
local Overworld = require("src.world.OverworldController")
local CodeEntry = require("src.link.CodeEntry")
local Runtime = require("src.mods.Runtime")

local f = assert(io.open(slotPath, "rb"))
local save = assert(SaveSerializer.decode(f:read("*a")))
f:close()

-- stand in for the receptionist's YES-and-save dialog: she opens the link
local opened
Overworld._gblinkReceptionist = function(ow, onDone)
  opened = LinkState.new(ow.game)
  ow.game.stack:push(opened)
  if onDone then onDone() end
end

local run = T.sdk.loadMod(here, { data = Data })
assert(#run.errors == 0, tostring(run.errors[1]))
if server then
  -- what the MODS panel does (ManagerState:setOption): the loader's option table
  run.loader.modOptions = run.loader.modOptions or {}
  run.loader.modOptions.gblink = run.loader.modOptions.gblink or {}
  run.loader.modOptions.gblink.server = server
end

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

local cache = (os.getenv("POKEPORT_DATA_DIR") or ""):gsub("/data/generated/?$", "")
local gameVersion = save.version or (save.meta and save.meta.version) or "red"
SaveConvert.setGen1DataStub(assert(SaveConvert.gen1DataFromDir(cache)), gameVersion)
local saves = 0
local game = {
  data = Data, stack = stack, save = save,
  input = { wasPressed = function(_, b)
    if presses[1] == b then table.remove(presses, 1) return true end
    return false
  end },
  writeSave = function()
    saves = saves + 1
    local fh = assert(io.open(out .. "/recomp_after.lua", "wb"))
    fh:write(SaveSerializer.encode(save))
    fh:close()
    local bytes, note = SaveConvert.exportSav(save, gameVersion)
    assert(bytes, note)
    fh = assert(io.open(out .. "/recomp_after.sav", "wb"))
    fh:write(bytes)
    fh:close()
    log("autosave #%d -> %s/recomp_after.sav", saves, out)
  end,
}
local overworld = { isOverworld = true }
stack:push(overworld)

local function partyLine()
  local names = {}
  for _, m in ipairs(save.party) do names[#names + 1] = (m.nickname or m.species) .. "/" .. tostring(m.ot) end
  return table.concat(names, ", ")
end
log("party before: %s", partyLine())

Overworld.cableClubReceptionist({ game = game })
assert(opened and opened.stage == "door", "the receptionist did not open the door screen")
presses = { "down", "a" }
opened:update(); opened:update()
assert(opened.stage == "code", "GB-LINK ONLINE did not ask for a room")
opened.code = CodeEntry.fromText(room, { length = 5, charset = "0123456789" })
presses = { "a" }
opened:update()
log("dialing room %s", room)

local last = {}
local function note(key, value, fmt)
  if value ~= last[key] then
    last[key] = value
    log(fmt, tostring(value))
  end
end

local traded, cancelled, round, lastTrade = 0, false, 0, nil
-- generous: someone has to walk the other cartridge to the receptionist
local deadline = socket.gettime() + tonumber(os.getenv("E2E_TIMEOUT") or "3600")
while socket.gettime() < deadline do
  Runtime.call("input.step", function() end, game, 1 / 60)
  local top = stack:top()
  if top == opened then
    note("door", opened.stage, "link screen: %s")
    if opened.link then note("status", opened.link.session.status, "session: %s") end
    if opened.stage == "again" then
      presses = { "down", "a" }            -- END LINK
    elseif opened.stage == "message" then
      log("message: %s", tostring(opened.text))
      -- what the other side's sections looked like, for a failed decode
      local ses = opened.link and opened.link.session
      for k = 1, 2 do
        local sec = ses and ses.theirs and ses.theirs[k]
        if sec and not last["dump" .. k] then
          last["dump" .. k] = true
          log("their section %d (%d bytes): %s", k, #sec, (sec:sub(1, 48):gsub(".", function(c) return ("%02x "):format(c:byte()) end)))
        end
      end
      presses = { "a" }
    end
    opened:update()
  elseif top and getmetatable(top) == LinkState then
    top:update(1 / 60)
    local t = top.trade
    note("ls", top.stage, "trade center: %s")
    if t then note("ts", t.stage, "trade: %s") end
    if top.stage == "trade" and t and t.stage == "picking" and lastTrade ~= t and t.theirParty then
      lastTrade = t
      round = round + 1
      local theirs = {}
      for _, m in ipairs(t.theirParty) do theirs[#theirs + 1] = (m.nickname or m.species) .. "/" .. tostring(m.ot) end
      log("their party: %s", table.concat(theirs, ", "))
      local ses = opened.link and opened.link.session
      local sec = ses and ses.theirs and ses.theirs[1]
      if sec and round == 1 then
        log("their section 1 starts: %s", (sec:sub(1, 24):gsub(".", function(c) return ("%02x "):format(c:byte()) end)))
      end
      if round == 1 then
        presses = {}
        for _ = 2, give do presses[#presses + 1] = "down" end
        presses[#presses + 1] = "a"; presses[#presses + 1] = "right"; presses[#presses + 1] = "a"
        log("offering slot %d (%s)", give, save.party[give].nickname or save.party[give].species)
      else
        presses = { "b" }
        cancelled = true
        log("cancelling")
      end
    elseif top.stage == "trade" and t and t.stage == "confirming" and top.confirmed == nil and #presses == 0 then
      presses = { "a" }
    end
  elseif top == overworld and opened and opened.stage ~= "door" and cancelled then
    break
  end
  if saves > traded then traded = saves; log("party after trade %d: %s", traded, partyLine()) end
  socket.sleep(1 / 60)
end
log("done: %d trade(s), party now %s", traded, partyLine())
run.release()
os.exit(traded > 0 and 0 or 1)
