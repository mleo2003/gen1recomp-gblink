-- The engine's own Cable Club trade screen, played against a GB-Link peer.
--
-- src/link/LinkState.lua already draws the Trade Center, runs the pick /
-- STATS / TRADE / confirm flow, plays TradeAnim, evolves trade evolutions and
-- autosaves -- all against a peer that speaks Protocol.TradeSession JSON
-- (hello, party, pick, confirm, bye).  LinkState.newFromSession adopts any
-- transport with update/poll/send/close, so this is one: it plays that peer
-- and turns each message into what lib/link.lua does on the network.
--
--   engine -> here                 here -> network
--   hello                          mirrored straight back: same engine and
--                                  fingerprint, so the verdict is "full"
--   party (first opening)          nothing; the far party already arrived
--   party (opening after a trade)  our MVS1, then wait for the far side to
--                                  sit down again
--   pick {index}                   CHC1 for slot index - 1
--   confirm {ok}                   ACP1 $62 / $61
--   bye                            CHC1 $6F, or ACP1 $61 at the confirm
--
--   network -> here                here -> engine
--   the far party                  party {mons}
--   CHC1 slot / $6F                pick {index} / bye
--   ACP1                           confirm {ok}
--
-- One Bridge per LinkState: when LinkState unwinds it closes this, the
-- current menu iteration is cancelled on the network, and the Link carries
-- on for main.lua's TRADE AGAIN / END LINK prompt.

local Bridge = {}
Bridge.__index = Bridge

-- opts: link, Protocol (src.link.Protocol, for LinkState's own party),
-- onClose(bridge)
function Bridge.new(opts)
  local self = setmetatable({
    link = opts.link,
    Protocol = opts.Protocol,
    onClose = opts.onClose,
    inbox = {},
    paired = true,
    closed = false,
    error = nil,
    opened = false,
    awaitingRound = false,
    state = nil,       -- the LinkState, set by main.lua once it exists
  }, Bridge)
  opts.link.listener = self
  return self
end

function Bridge:push(msg)
  self.inbox[#self.inbox + 1] = msg
end

function Bridge:partyMessage()
  local mons = {}
  for i, mon in ipairs(self.link.theirParty or {}) do mons[i] = mon end
  return { type = "party", mons = mons }
end

function Bridge:send(msg)
  if self.closed or type(msg) ~= "table" then return nil end
  local kind = msg.type
  local link = self.link
  if kind == "hello" then
    local mirror = {}
    for k, v in pairs(msg) do mirror[k] = v end
    mirror.name = link.theirName or "TRAINER"
    mirror.mode = nil
    self:push(mirror)
    if link.roundOpen then
      self:push(self:partyMessage())
    else
      self.awaitingRound = true
    end
  elseif kind == "party" then
    if not self.opened then
      self.opened = true
    else
      -- LinkState:beginRound after a trade (and after its evolution)
      link:engineRound()
      if link.roundOpen then self:push(self:partyMessage()) else self.awaitingRound = true end
    end
  elseif kind == "pick" then
    local index = tonumber(msg.index)
    if index then link:choose(index - 1) end
  elseif kind == "confirm" then
    link:accept(msg.ok == true)
  elseif kind == "bye" then
    link:cancel()
  end
  return true
end

-- a fresher copy of the mon the far player just offered replaces LinkState's
-- rebuilt one, so the mon that lands is byte-for-byte the one they gave
function Bridge:refreshTheirMon(slot, mon)
  local ls = self.state
  local t = ls and ls.trade
  if not (t and t.theirParty and t.theirParty[slot + 1] and mon) then return end
  local fresh = self.Protocol.unpackMon(t.data, mon, { strict = t.strict })
  if fresh then t.theirParty[slot + 1] = fresh end
end

function Bridge:onLink(ev)
  local kind = ev.type
  if kind == "round" or kind == "party" then
    if self.awaitingRound then
      self.awaitingRound = false
      self:push(self:partyMessage())
    end
  elseif kind == "theirPick" then
    self:refreshTheirMon(ev.slot, ev.mon)
    self:push({ type = "pick", index = ev.slot + 1 })
  elseif kind == "theirStop" then
    -- they chose CANCEL: LinkState leaves on bye, and our side of this
    -- iteration becomes CANCEL too unless a pick already went out
    self.link:cancel()
    self:push({ type = "bye" })
  elseif kind == "theirAccept" then
    self:push({ type = "confirm", ok = ev.ok })
  elseif kind == "ended" then
    self:push({ type = "bye" })
  elseif kind == "error" then
    self.error = ev.message
  end
end

function Bridge:update()
  if self.closed then return end
  if self.link.error and not self.error then self.error = self.link.error end
  if self.link.closed and not self.error then self.closed = true end
end

function Bridge:poll()
  local out = self.inbox
  self.inbox = {}
  return out
end

function Bridge:close()
  if self.closed and self.handedBack then return end
  self.closed = true
  self.handedBack = true
  -- whatever this screen left open on the network is a CANCEL now
  self.link:cancel()
  if self.link.listener == self then self.link.listener = nil end
  if self.onClose then self.onClose(self) end
end

return Bridge
