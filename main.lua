-- GB-Link online trades at the Cable Club.
--
-- The receptionist's link gains a second door: next to the LAN cable, a room
-- on the Pokémon GB online trade server that pokemon.gblink.io (a real Game
-- Boy on a GB-Link adapter, or BGB) and Lorenzooone's PokemonGB Online
-- Trades client both use.  Both players type the same five-digit room; the
-- trade itself runs on the engine's own Trade Center screen.
--
--   lib/ws.lua       WebSocket client: ws:// over luasocket, wss:// over the
--                    engine's TLS dialer where the game has one
--   lib/proto.lua    S/G framing, SNG1 windows, the message table
--   lib/session.lua  the online trade protocol, one side of it
--   lib/codec.lua    party <-> the cart's 0x1A2-byte block and patch list
--   lib/link.lua     one Cable Club visit: session + both parties
--   lib/bridge.lua   LinkState's transport, played against the Link

return function(mod)
  local function lib(name)
    local source = assert(mod:read("lib/" .. name .. ".lua"))
    return assert(load(source, "@gblink/lib/" .. name .. ".lua"))()
  end
  local Codec, Proto, Ws = lib("codec"), lib("proto"), lib("ws")
  local Session, Link, Bridge = lib("session"), lib("link"), lib("bridge")

  local DEFAULT_SERVER = "ws://pokemon-gb-online-trades.herokuapp.com"
  local ROOM_LENGTH = 5
  local LINGER_SECONDS = 90

  mod.options:define({
    { key = "server", label = "SERVER", type = "text",
      default = DEFAULT_SERVER, maxLen = 96 },
  })

  local LinkState = require("src.link.LinkState")
  local Protocol = require("src.link.Protocol")
  local CodeEntry = require("src.link.CodeEntry")
  local Font = require("src.render.Font")
  local TextBox = require("src.render.TextBox")
  local Strings = require("src.core.Strings")
  local GenSave = require("src.save_convert.GenSave")
  local Overworld = require("src.world.OverworldController")

  local CURSOR = 0xED

  local function now()
    return (love and love.timer and love.timer.getTime()) or os.clock()
  end

  local function envFor(game)
    return {
      data = game.data,
      cw = GenSave.crosswalks(game.data),
      charmap = require("src.save_convert.data.charmap"),
      Stats = require("src.pokemon.Stats"),
      Growth = require("src.pokemon.Growth"),
    }
  end

  local function log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    print("[gblink] " .. (ok and line or tostring(fmt)))
  end

  -- ------------------------------------------------------------------
  -- every live Link is pumped once per logic step, whatever screen is on
  -- top: the server pings, and the far player keeps sending while a text
  -- box or the trade animation owns the screen
  -- ------------------------------------------------------------------

  local live = {}
  local active = nil -- the Link whose trades land in this party

  local function track(link) live[#live + 1] = link end

  local function onStack(game, state)
    local states = game and game.stack and game.stack.states
    if not states then return true end
    for _, s in ipairs(states) do
      if s == state then return true end
    end
    return false
  end

  mod.hooks:wrap("input.step", function(nextStep, game, dt)
    for i = #live, 1, -1 do
      local link = live[i]
      local ok, err = pcall(link.update, link)
      if not ok then link:fail(tostring(err)) end
      -- a link whose screen is gone (Game:breakLink unwinds the whole
      -- stack after an engine error) has nobody left to finish it
      local orphaned = not link.lingering and link.owner and not onStack(game, link.owner)
      local done = link.closed or orphaned
        or (link.lingering and (link.ended or link.error or now() > link.lingerUntil))
      if done then
        link:close()
        table.remove(live, i)
        if active == link then active = nil end
      end
    end
    return nextStep(game, dt)
  end)

  mod.events:on("trade.completed", function(ev)
    if active and active.game and ev then Link.fileAtEnd(active.game.save.party, ev.received) end
  end)

  mod.events:on("pokemon.received", function(ev)
    if ev then Link.land(ev.mon) end
  end)

  -- ------------------------------------------------------------------
  -- the screen
  -- ------------------------------------------------------------------

  local GbLink = {}
  GbLink.__index = GbLink
  GbLink.isOpaque = true

  local function drawTitle(text)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, 160, 144)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(text, 8, 6)
  end

  local function drawLines(lines, x, y)
    for i, line in ipairs(lines) do Font.draw(line, x, y + (i - 1) * 12) end
  end

  -- stage "door": LAN or online, in place of the plain LAN screen
  function GbLink.door(game, realNew)
    return setmetatable({ game = game, realNew = realNew, stage = "door", index = 1 }, GbLink)
  end

  function GbLink:pop()
    if self.link and not self.link.lingering then self.link:close() end
    if self.game.stack:top() == self then self.game.stack:pop() end
  end

  function GbLink:roomEntry()
    -- mod storage holds data-only tables, so the room rides in { room = "12345" }
    local ok, saved = pcall(mod.storage.read, mod.storage, self.game, "room")
    local last = ok and type(saved) == "table" and saved.room
    local seed = type(last) == "string" and last:match("^%d%d%d%d%d$") or "00000"
    local entry = CodeEntry.fromText(seed, { length = ROOM_LENGTH, charset = "0123456789" })
    entry.pos = 1
    return entry
  end

  function GbLink:connect()
    -- luasocket is required here, not at load: a host without it (the
    -- headless validator, a console port) still loads the mod and says why
    local okSocket, socket = pcall(require, "socket")
    if not okSocket or type(socket) ~= "table" then
      self:message(Strings("This build has no\nnetwork library."))
      return
    end
    local room = CodeEntry.text(self.code)
    pcall(mod.storage.write, mod.storage, self.game, "room", { room = room })
    local server = tostring(mod.options:get("server") or DEFAULT_SERVER):gsub("/+$", "")
    -- wss:// needs the engine's TLS dialer (official Windows builds, Android)
    local tls = Ws.tlsFrom(love.system)
    if server:match("^wss://") and not tls then
      self:message(Strings("This build of the game\ncan't use wss://.\nSet SERVER to ws://."))
      return
    end
    local ws = Ws.new(server .. "/link1/" .. room, { socket = socket, tls = tls, now = now,
                                                     random = love.math.random })
    local session = Session.new({ conn = ws, Proto = Proto, now = now,
                                  rng = love.math.random, log = log })
    local link = Link.new({ game = self.game, env = envFor(self.game), Codec = Codec,
                            session = session, log = log })
    if not link:prepare() then
      self:message(link.error)
      return
    end
    self.room = room
    self.link = link
    link.owner = self
    track(link)
    self.stage = "linking"
  end

  function GbLink:message(text)
    self.stage = "message"
    self.text = text
  end

  function GbLink:openTrade()
    local link = self.link
    self.tradeClosed = false
    local bridge = Bridge.new({ link = link, Protocol = Protocol,
                                onClose = function() self.tradeClosed = true end })
    active = link
    local ls = LinkState.newFromSession(self.game, bridge, "trade", true)
    bridge.state = ls
    self.stage = "trading"
    self.game.stack:push(ls)
  end

  function GbLink:update()
    local input = self.game.input
    if self.stage == "door" then
      if input:wasPressed("up") or input:wasPressed("down") then
        self.index = self.index == 1 and 2 or 1
      elseif input:wasPressed("b") then
        self:pop()
      elseif input:wasPressed("a") then
        if self.index == 1 then
          local game = self.game
          game.stack:pop()
          game.stack:push(self.realNew(game))
        else
          self.code = self:roomEntry()
          self.stage = "code"
        end
      end

    elseif self.stage == "code" then
      if input:wasPressed("b") then self:pop() return end
      if input:wasPressed("up") then CodeEntry.up(self.code)
      elseif input:wasPressed("down") then CodeEntry.down(self.code)
      elseif input:wasPressed("left") then CodeEntry.left(self.code)
      elseif input:wasPressed("right") then CodeEntry.right(self.code)
      elseif input:wasPressed("a") then self:connect() end

    elseif self.stage == "linking" then
      local link = self.link
      if input:wasPressed("b") then self:pop() return end
      if link.error then self:message(link.error)
      elseif link.ready then self:openTrade() end

    elseif self.stage == "trading" then
      -- back on top: LinkState has unwound
      local link = self.link
      if not self.tradeClosed then return end
      if active == link then active = nil end
      if link.error then self:message(link.error)
      elseif link.ended then self:message(Strings("The other player\nleft the table."))
      else
        self.stage = "again"
        self.index = 1
      end

    elseif self.stage == "again" then
      local link = self.link
      if link.error then self:message(link.error) return end
      if link.ended then self:message(Strings("The other player\nleft the table.")) return end
      if input:wasPressed("up") or input:wasPressed("down") then
        self.index = self.index == 1 and 2 or 1
      elseif input:wasPressed("a") and self.index == 1 then
        link:resume()
        self:openTrade()
      elseif input:wasPressed("b") or input:wasPressed("a") then
        -- answer CANCEL in the background until the far player leaves too
        link:leave()
        link.lingering = true
        link.lingerUntil = now() + LINGER_SECONDS
        self:pop()
      end

    elseif self.stage == "message" then
      if input:wasPressed("a") or input:wasPressed("b") then self:pop() end
    end
  end

  local STATUS = {
    connecting = { "Calling the trade", "server..." },
    waiting = { "Waiting for the", "other player..." },
    paired = { "Linked! Checking", "the other game..." },
    negotiating = { "Linked! Checking", "the other game..." },
    ready = { "Linked! Waiting for", "the other player to", "sit at the table..." },
  }

  function GbLink:draw()
    if self.stage == "door" then
      drawTitle(Strings("CABLE CLUB"))
      Font.draw(Strings("LAN CABLE"), 32, 48)
      Font.draw(Strings("GB-LINK ONLINE"), 32, 68)
      Font.drawCode(CURSOR, 24, self.index == 1 and 48 or 68)
      -- 19 characters fit after the 8 px margin (the screen is 160 px)
      drawLines({ Strings("Online: trade with"), Strings("a Game Boy or an"),
                  Strings("emulator through"), "pokemon.gblink.io" }, 8, 92)

    elseif self.stage == "code" then
      drawTitle(Strings("GB-LINK ONLINE"))
      Font.draw(Strings("ROOM NUMBER"), 16, 32)
      for i = 1, ROOM_LENGTH do
        local x = 56 + (i - 1) * 8
        Font.draw(CodeEntry.charAt(self.code, i), x, 52)
        if i == self.code.pos then Font.drawCode(0xEE, x, 64) end
      end
      drawLines({ Strings("Both players enter"), Strings("the same number."),
                  "pokemon.gblink.io:", Strings("Gen 1, Link Trade") }, 8, 80)
      Font.draw(Strings("A: link  B: back"), 8, 132)

    elseif self.stage == "linking" then
      drawTitle(Strings("ROOM %s", self.room or ""))
      local status, progress = self.link:status()
      local lines = STATUS[status]
      if status == "exchanging" and progress then
        lines = { Strings("Exchanging data..."),
                  ("%d/%d"):format(progress.done or 0, progress.total or 0) }
      end
      drawLines(lines or { Strings("Linking...") }, 8, 48)
      Font.draw(Strings("B: cancel"), 8, 132)

    elseif self.stage == "again" then
      drawTitle(Strings("ROOM %s", self.room or ""))
      Font.draw(Strings("TRADE AGAIN"), 32, 48)
      Font.draw(Strings("END LINK"), 32, 68)
      Font.drawCode(CURSOR, 24, self.index == 1 and 48 or 68)

    elseif self.stage == "message" or self.stage == "trading" then
      drawTitle(Strings("GB-LINK ONLINE"))
      local lines = {}
      for line in tostring(self.text or ""):gmatch("[^\n]+") do
        -- wrap at the screen's 18 characters
        while #line > 18 do
          local cut = line:sub(1, 18):match("^.*() ") or 19
          lines[#lines + 1] = line:sub(1, cut - 1)
          line = line:sub(cut):gsub("^ ", "")
        end
        lines[#lines + 1] = line
      end
      drawLines(lines, 8, 40)
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- ------------------------------------------------------------------
  -- the receptionist: after YES and the save she opens the link with
  -- LinkState.new; while she is talking that one call gets the door screen
  -- (the originals are kept on the engine tables so a hot reload wraps the
  -- real ones again, not its own last wrapper)
  -- ------------------------------------------------------------------

  LinkState._gblinkNew = LinkState._gblinkNew or LinkState.new
  Overworld._gblinkReceptionist = Overworld._gblinkReceptionist or Overworld.cableClubReceptionist
  local realNew = LinkState._gblinkNew
  local realReceptionist = Overworld._gblinkReceptionist
  local atDesk = false

  Overworld.cableClubReceptionist = function(ow, onDone)
    atDesk = true
    return realReceptionist(ow, function(...)
      atDesk = false
      if onDone then return onDone(...) end
    end)
  end

  LinkState.new = function(game, ...)
    if atDesk then
      atDesk = false
      return GbLink.door(game, realNew)
    end
    return realNew(game, ...)
  end

  mod.exports.version = mod.version  -- the manifest's, which the release stamps
end
