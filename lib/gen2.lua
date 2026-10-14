-- GB-Link online trades on Gold, Silver and Crystal: the Pokémon Center 2F
-- Trade Center desk opens a GB-Link room instead of waiting for a cable.
--
-- The desk is the cart's own script (pokecrystal maps/Pokecenter2F.asm),
-- run by the engine's script VM; every cable step in it is a special that
-- the engine stubs as "nobody is plugged in".  This replaces those
-- specials, and only those:
--
--   SetBitsForLinkTradeRequest     this is the trade desk (the battle and
--   SetBitsForBattleRequest        Time Capsule desks keep "your friend is
--   SetBitsForTimeCapsuleRequest   not ready")
--   WaitForLinkedFriend            the room number screen; TRUE once paired
--   CheckLinkTimeout_Receptionist  TRUE while the link is up, and the
--                                  wOtherPlayerLinkMode byte the script
--                                  reads next is made non-zero (a Gen 2
--                                  partner, not the Time Capsule)
--   CheckBothSelectedSameRoom      TRUE: the room only pairs /link2/ games
--   TradeCenter                    the table (lib/tradecenter2.lua)
--   CloseLink                      the link closes
--   WaitForOtherPlayerToExit
--
-- Everything between them -- the save, "Please come in", the walk to the
-- door, the room itself, the walk back out -- is the cart's script as the
-- engine already runs it.  Specials.merge refuses a name twice, so thin
-- trampolines are merged once and look the real handlers up on every call;
-- a hot reload swaps the handlers, not the trampolines.

return function(ctx)
  local mod, log, now = ctx.mod, ctx.log, ctx.now
  local Proto, Ws, Session = ctx.Proto, ctx.Ws, ctx.Session
  local Codec2, Link2, Party2 = ctx.Codec2, ctx.Link2, ctx.Party2
  local TradeCenter2 = ctx.TradeCenter2

  local Specials = require("src.script.gen2.Specials")
  local GameVersion = require("src.core.GameVersion")
  local Gen2Save = require("src.save_convert.Gen2Save")
  local Gen2Layout = require("src.save_convert.Gen2Layout")
  local Mon = require("src.battle.gen2.Mon")
  local Mail = require("src.core.gen2.Mail")
  local Evolution = require("src.core.gen2.Evolution")
  local Chrome = require("src.ui.gen2.Chrome")
  local CodeEntry = require("src.link.CodeEntry")
  local Font = require("src.render.Font")
  local Strings = require("src.core.Strings")

  local P2 = Proto.forGen(2)
  local TRUE, FALSE = 1, 0

  -- wOtherPlayerLinkMode: the byte the desk reads (readmem) after the
  -- timeout check -- 0 means "linked to the Time Capsule"
  local function linkModeAddress()
    return GameVersion.get() == "crystal" and 0xCF51 or 0xCE51
  end

  local function envFor(game)
    return {
      data = game.data,
      cw = Gen2Save.crosswalks(game.data),
      charmap = Gen2Layout.charmap,
      Mon = Mon,
      crystal = GameVersion.get() == "crystal",
    }
  end

  -- one desk visit at a time: { desk, link }
  local state = Specials._gblinkState or {}
  Specials._gblinkState = state

  local function closeLink(why)
    local link = state.link
    state.link = nil
    if link and not link.closed then
      log("closing the link (%s)", why)
      link:close()
    end
  end

  -- ------------------------------------------------------------------
  -- the room number screen, then "Linking..." until the other game answers
  -- ------------------------------------------------------------------

  local RoomScreen = {}
  RoomScreen.__index = RoomScreen
  RoomScreen.isOpaque = true
  function RoomScreen:wantsFillScale() return true end

  function RoomScreen.new(game, onDone)
    local ok, saved = pcall(mod.storage.read, mod.storage, game, "room")
    local last = ok and type(saved) == "table" and saved.room
    local seed = type(last) == "string" and last:match("^%d%d%d%d%d$") or "00000"
    local code = CodeEntry.fromText(seed, { length = ctx.ROOM_LENGTH, charset = "0123456789" })
    code.pos = 1
    return setmetatable({ game = game, onDone = onDone, stage = "code", code = code }, RoomScreen)
  end

  function RoomScreen:finish(link)
    if self.finished then return end
    self.finished = true
    if self.game.stack:top() == self then self.game.stack:pop() end
    if not link and self.link then self.link:close() end
    self.onDone(link)
  end

  function RoomScreen:message(text)
    self.stage, self.text = "message", text
  end

  function RoomScreen:connect()
    local okSocket, socket = pcall(require, "socket")
    if not okSocket or type(socket) ~= "table" then
      return self:message(Strings("This build has no\nnetwork library."))
    end
    local room = CodeEntry.text(self.code)
    pcall(mod.storage.write, mod.storage, self.game, "room", { room = room })
    local server = ctx.server()
    local tls = Ws.tlsFrom(love.system)
    if server:match("^wss://") and not tls then
      return self:message(Strings("This build can't\nuse wss://. Set\nSERVER to ws://."))
    end
    local ws = Ws.new(server .. "/" .. P2.ROOM .. "/" .. room,
                      { socket = socket, tls = tls, now = now, random = love.math.random })
    local session = Session.new({ conn = ws, Proto = P2, now = now, rng = love.math.random,
                                  log = log, needMail = Link2.needMail })
    local link = Link2.new({ game = self.game, env = envFor(self.game), Codec2 = Codec2,
                             session = session, Mail = Mail, log = log })
    link.room = room
    self.link = link
    ctx.track(link)
    self.room = room
    self.stage = "linking"
  end

  function RoomScreen:update()
    local input = self.game.input
    if self.stage == "code" then
      if input:wasPressed("b") then return self:finish(nil) end
      if input:wasPressed("up") then CodeEntry.up(self.code)
      elseif input:wasPressed("down") then CodeEntry.down(self.code)
      elseif input:wasPressed("left") then CodeEntry.left(self.code)
      elseif input:wasPressed("right") then CodeEntry.right(self.code)
      elseif input:wasPressed("a") then self:connect() end
    elseif self.stage == "linking" then
      local link = self.link
      if input:wasPressed("b") then return self:finish(nil) end
      if link.error then return self:message(link.error) end
      -- paired, versions agreed and the mode settled: the other game is at
      -- its desk too.  The party goes out when we sit at the table.
      local status = link:status()
      if status == "ready" then return self:finish(link) end
    elseif self.stage == "message" then
      if input:wasPressed("a") or input:wasPressed("b") then self:finish(nil) end
    end
  end

  local STATUS = {
    connecting = { "Calling the trade", "server..." },
    waiting = { "Waiting for the", "other player..." },
    paired = { "Linked! Checking", "the other game..." },
    negotiating = { "Linked! Checking", "the other game..." },
  }

  function RoomScreen:draw()
    Chrome.clear()
    Chrome.textbox(0, 0, 18, 16)
    Chrome.print(Strings("GB-LINK ONLINE"), 2, 2)
    if self.stage == "code" then
      Chrome.print(Strings("ROOM NUMBER"), 2, 5)
      for i = 1, ctx.ROOM_LENGTH do
        local ch = CodeEntry.charAt(self.code, i)
        if i == self.code.pos then
          Chrome.printInverted(ch, 7 + i, 7, Chrome.DEFAULT_BOX_PALETTE)
          love.graphics.setColor(0, 0, 0, 1)
          Font.drawCode(Chrome.DOWN_ARROW, (7 + i) * 8, 6 * 8)
        else
          Chrome.print(ch, 7 + i, 7)
        end
      end
      Chrome.print(Strings("Both players enter"), 1, 9)
      Chrome.print(Strings("the same number."), 1, 11)
      Chrome.print("pokemon.gblink.io:", 1, 13)
      Chrome.print(Strings("Gen 2, Link Trade"), 1, 15)
    elseif self.stage == "linking" then
      Chrome.print(Strings("ROOM %s", self.room or ""), 2, 5)
      local lines = STATUS[self.link:status()] or { "Linking..." }
      for i, line in ipairs(lines) do Chrome.print(Strings(line), 2, 7 + (i - 1) * 2) end
      Chrome.print(Strings("B:cancel"), 2, 16)
    elseif self.stage == "message" then
      local row = 5
      for line in tostring(self.text or ""):gmatch("[^\n]+") do
        for _, part in ipairs(Chrome.wrap(line, 17)) do
          Chrome.print(part, 1, row)
          row = row + 2
        end
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- ------------------------------------------------------------------
  -- the specials
  -- ------------------------------------------------------------------

  local function hooks(vm) return (vm and vm.specials) or {} end
  local function gameOf(vm)
    local h = hooks(vm)
    return ctx.game() or (h.game and h.game())
  end

  local impl = {}

  impl.SetBitsForLinkTradeRequest = function() state.desk = "trade" end
  impl.SetBitsForBattleRequest = function() state.desk = "battle" end
  impl.SetBitsForTimeCapsuleRequest = function() state.desk = "capsule" end

  impl.WaitForLinkedFriend = function(vm)
    local desk = state.desk
    state.desk = nil
    local game = gameOf(vm)
    if desk ~= "trade" or not (game and game.stack) then
      vm.scriptVar = FALSE
      return
    end
    closeLink("a new desk visit")
    vm.scriptVar = Specials.block(vm, function(done)
      game.stack:push(RoomScreen.new(game, function(link)
        state.link = link
        done(link and TRUE or FALSE)
      end))
    end) or FALSE
  end

  impl.CheckLinkTimeout_Receptionist = function(vm)
    local link = state.link
    local alive = link and not link.closed and not link.error
    if alive then
      vm.mem = vm.mem or {}
      vm.mem[linkModeAddress()] = 1
    end
    vm.scriptVar = alive and TRUE or FALSE
  end

  impl.CheckBothSelectedSameRoom = function(vm)
    if vm.mem then vm.mem[linkModeAddress()] = nil end
    local link = state.link
    vm.scriptVar = (link and not link.closed and not link.error) and TRUE or FALSE
  end

  impl.TradeCenter = function(vm)
    local game = gameOf(vm)
    if not (game and game.stack) then return end
    local link = state.link
    Specials.block(vm, function(done)
      local screen = TradeCenter2.new({
        game = game, link = link, env = link and link.env or envFor(game),
        Codec2 = Codec2, Party2 = Party2, Mail = Mail, Evolution = Evolution,
        log = log,
        onDone = function() done(true) end,
      })
      game.stack:push(screen)
    end)
  end

  impl.CloseLink = function() closeLink("CloseLink") end
  impl.WaitForOtherPlayerToExit = function() closeLink("left the room") end

  -- what the engine's stubs answer, for when the mod's handlers are gone
  local STUB = {
    SetBitsForLinkTradeRequest = nil, SetBitsForBattleRequest = nil,
    SetBitsForTimeCapsuleRequest = nil, WaitForLinkedFriend = FALSE,
    CheckLinkTimeout_Receptionist = TRUE, CheckBothSelectedSameRoom = FALSE,
    TradeCenter = nil, CloseLink = nil, WaitForOtherPlayerToExit = nil,
  }
  local NAMES = {
    "SetBitsForLinkTradeRequest", "SetBitsForBattleRequest", "SetBitsForTimeCapsuleRequest",
    "WaitForLinkedFriend", "CheckLinkTimeout_Receptionist", "CheckBothSelectedSameRoom",
    "TradeCenter", "CloseLink", "WaitForOtherPlayerToExit",
  }

  Specials._gblinkImpl = impl
  if not Specials._gblinkMerged then
    local trampolines = {}
    for _, name in ipairs(NAMES) do
      trampolines[name] = function(vm)
        local fn = Specials._gblinkImpl and Specials._gblinkImpl[name]
        if fn then return fn(vm) end
        if STUB[name] ~= nil then vm.scriptVar = STUB[name] end
      end
    end
    local ok, err = pcall(Specials.merge, trampolines, "mod:gblink")
    if ok then
      Specials._gblinkMerged = true
    else
      log("could not take over the Trade Center desk: %s", tostring(err))
      return false
    end
  end
  return true
end
