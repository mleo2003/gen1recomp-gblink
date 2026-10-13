-- A luasocket stand-in whose TCP connections end at tests/fake_relay.lua:
-- it answers lib/ws.lua's HTTP upgrade with 101, unmasks the client's
-- frames into relay messages, and frames the relay's deliveries back, so
-- main.lua runs its own unmodified network path in a test.

local bit = require("bit")

local FakeSocket = {}

local function serverFrame(opcode, payload)
  local n = #payload
  local head = string.char(0x80 + opcode)
  if n < 126 then
    head = head .. string.char(n)
  else
    head = head .. string.char(126, bit.rshift(n, 8), bit.band(n, 0xFF))
  end
  return head .. payload
end

-- relay: tests/fake_relay.lua; now(): the simulated clock
function FakeSocket.new(relay, now)
  local M = {}
  M.connections = {}

  function M.tcp()
    local tcp = { rx = "", tx = "", upgraded = false }
    M.connections[#M.connections + 1] = tcp
    function tcp:settimeout() end
    function tcp:setoption() return true end
    function tcp:connect(host, port)
      self.host, self.port = host, port
      return 1
    end
    function tcp:close()
      if self.ep then self.ep:close() end
      self.closed = true
    end
    function tcp:send(s)
      if self.closed then return nil, "closed" end
      self.tx = self.tx .. s
      self:pumpOut()
      return #s
    end
    function tcp:pumpOut()
      if not self.upgraded then
        local headEnd = self.tx:find("\r\n\r\n", 1, true)
        if not headEnd then return end
        local path = self.tx:match("^GET ([^ ]+) HTTP")
        self.tx = self.tx:sub(headEnd + 4)
        self.upgraded = true
        self.path = path
        self.ep = relay:connect(path)
        self.rx = self.rx .. "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
          .. "Connection: Upgrade\r\n\r\n"
      end
      while #self.tx >= 2 do
        local b0, b1 = self.tx:byte(1, 2)
        local n = bit.band(b1, 0x7F)
        local p = 3
        if n == 126 then
          if #self.tx < 4 then return end
          n = self.tx:byte(3) * 256 + self.tx:byte(4)
          p = 5
        end
        if #self.tx < p + 3 + n then return end
        local mask = { self.tx:byte(p, p + 3) }
        p = p + 4
        local out = {}
        for k = 1, n do
          out[k] = string.char(bit.bxor(self.tx:byte(p + k - 1), mask[(k - 1) % 4 + 1]))
        end
        self.tx = self.tx:sub(p + n)
        local opcode = bit.band(b0, 0x0F)
        if opcode == 0x1 or opcode == 0x2 then
          self.ep:send(table.concat(out))
        elseif opcode == 0x8 then
          self.ep:close()
        end
      end
    end
    function tcp:receive()
      if self.ep then
        for _, m in ipairs(self.ep:poll()) do
          if m.text then self.rx = self.rx .. serverFrame(0x1, m.text)
          elseif m.binary then self.rx = self.rx .. serverFrame(0x2, m.binary) end
        end
        if self.ep.closed and #self.rx == 0 then return nil, "closed", "" end
      end
      local part = self.rx
      self.rx = ""
      return nil, "timeout", part
    end
    return tcp
  end

  function M.select(_, writable) return {}, writable end
  function M.gettime() return now() end
  return M
end

return FakeSocket
