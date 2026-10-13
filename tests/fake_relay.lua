-- The trade server (Lorenzooone serving.py ProxyLinkServer / link_function),
-- in process and on a simulated clock: the first message registers a client
-- in its room, the second client pairs and both hear "CLIENT", G VES1 and
-- G RAN1 are answered by the server, anything else valid is forwarded, and
-- every hop takes `latency` seconds.
--
-- Endpoints have the lib/ws.lua shape (update/send/sendText/poll/close,
-- open/closed/error) so a Session runs on one unchanged.

local FakeRelay = {}
FakeRelay.__index = FakeRelay

local Endpoint = {}
Endpoint.__index = Endpoint

-- opts: Proto, now(), latency (s, one way), jitter (s), rng
function FakeRelay.new(opts)
  return setmetatable({
    Proto = opts.Proto,
    now = opts.now,
    latency = opts.latency or 0.05,
    jitter = opts.jitter or 0,
    rng = opts.rng or math.random,
    queue = {},     -- { at, to = "server"|endpoint, from, data, text }
    rooms = {},
    stats = { forwarded = 0, dropped = 0 },
  }, FakeRelay)
end

function FakeRelay:delay()
  return self.latency + (self.jitter > 0 and self.rng() * self.jitter or 0)
end

function FakeRelay:connect(path)
  local ep = setmetatable({
    relay = self, path = path, open = true, closed = false, error = nil,
    inbox = {}, registered = false, other = nil, lastAt = 0,
  }, Endpoint)
  return ep
end

-- keep one direction in order even with jitter
function FakeRelay:enqueue(item, lane)
  local at = self.now() + self:delay()
  if lane.lastAt and at < lane.lastAt then at = lane.lastAt end
  lane.lastAt = at
  item.at = at
  self.queue[#self.queue + 1] = item
end

function Endpoint:send(bytes)
  if self.closed then return false end
  self.relay:enqueue({ to = "server", from = self, data = bytes }, self)
  return true
end

function Endpoint:sendText(text) return self:send(text) end
function Endpoint:update() end

function Endpoint:poll()
  local out = self.inbox
  self.inbox = {}
  return out
end

function Endpoint:close()
  if self.closed then return end
  self.closed = true
  self.open = false
  local other = self.other
  if other and not other.closed then
    -- the server closes the peer when either side leaves
    self.relay:enqueue({ to = other, close = true }, self)
  end
end

function FakeRelay:deliver(ep, msg)
  if ep.closed then return end
  ep.inbox[#ep.inbox + 1] = msg
end

function FakeRelay:toClient(ep, msg)
  self:enqueue({ to = ep, msg = msg }, { lastAt = ep.downAt })
  ep.downAt = self.queue[#self.queue].at
end

function FakeRelay:server(from, data)
  local P = self.Proto
  if not from.registered then
    from.registered = true
    local room = self.rooms[from.path]
    if room and room ~= from and not room.closed then
      self.rooms[from.path] = nil
      room.other, from.other = from, room
      self:toClient(room, { text = "CLIENT" })
      self:toClient(from, { text = "CLIENT" })
    else
      self.rooms[from.path] = from
    end
    return
  end
  if not from.other then return end -- waiting: swallowed
  local msg = P.decode(data)
  if not msg then self.stats.dropped = self.stats.dropped + 1 return end
  if msg.req == "G" and msg.kind == "VES1" then
    self:toClient(from, { binary = P.send("VES1", P.VERSION) })
    return
  elseif msg.req == "G" and msg.kind == "RAN1" then
    local r = {}
    for i = 1, 10 do r[i] = math.random(0, 0xFC) end
    self:toClient(from, { binary = P.send("RAN1", r) })
    return
  end
  self.stats.forwarded = self.stats.forwarded + 1
  self:toClient(from.other, { binary = data })
end

function FakeRelay:tick()
  local t = self.now()
  local due, keep = {}, {}
  for _, item in ipairs(self.queue) do
    if item.at <= t then due[#due + 1] = item else keep[#keep + 1] = item end
  end
  self.queue = keep
  table.sort(due, function(a, b) return a.at < b.at end)
  for _, item in ipairs(due) do
    if item.to == "server" then
      if not item.from.closed then self:server(item.from, item.data) end
    elseif item.close then
      item.to.closed, item.to.open = true, false
    else
      self:deliver(item.to, item.msg)
    end
  end
end

return FakeRelay
