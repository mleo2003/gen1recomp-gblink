-- lib/ws.lua against a scripted luasocket TCP double: the upgrade request it
-- writes, the masking of what it sends, and its reading of what a server
-- sends (unmasked frames, 16-bit lengths, fragments, ping, close).
--
--   luajit mods/gblink/tests/ws_test.lua

local bit = require("bit")
local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "mods/gblink"
local Ws = dofile(here .. "/lib/ws.lua")

local failures = 0
local function check(cond, msg)
  if cond then print("ok   " .. msg) else failures = failures + 1; print("FAIL " .. msg) end
end

-- a TCP socket whose far end is this test: `wire` is what the client wrote,
-- `feed(s)` queues bytes for it to read, at most `chunk` per receive
local function fakeSocket(opts)
  opts = opts or {}
  local tcp = { wire = "", rx = "", closedByPeer = false, chunk = opts.chunk or 7 }
  function tcp:settimeout() end
  function tcp:setoption() return true end
  function tcp:connect() return opts.pending and nil or 1, opts.pending and "timeout" or nil end
  function tcp:send(s)
    self.wire = self.wire .. s
    return #s
  end
  function tcp:receive(n)
    if #self.rx == 0 then
      if self.closedByPeer then return nil, "closed", "" end
      return nil, "timeout", ""
    end
    local take = math.min(n, self.chunk, #self.rx)
    local part = self.rx:sub(1, take)
    self.rx = self.rx:sub(take + 1)
    return nil, "timeout", part
  end
  function tcp:close() self.closed = true end
  function tcp:feed(s) self.rx = self.rx .. s end
  local socket = { tcp = function() return tcp end, select = function(_, w) return {}, w end }
  return socket, tcp
end

-- read the client's frames back off the wire
local function readFrames(wire)
  local frames, i = {}, 1
  while i <= #wire do
    local b0, b1 = wire:byte(i, i + 1)
    local n = bit.band(b1, 0x7F)
    local masked = bit.band(b1, 0x80) ~= 0
    local p = i + 2
    if n == 126 then n = wire:byte(p) * 256 + wire:byte(p + 1); p = p + 2 end
    local mask = { wire:byte(p, p + 3) }
    p = p + 4
    local out = {}
    for k = 1, n do out[k] = string.char(bit.bxor(wire:byte(p + k - 1), mask[(k - 1) % 4 + 1])) end
    frames[#frames + 1] = { opcode = bit.band(b0, 0x0F), fin = bit.band(b0, 0x80) ~= 0,
                            masked = masked, payload = table.concat(out) }
    i = p + n
  end
  return frames
end

local function serverFrame(opcode, payload, fin)
  local n = #payload
  local head = string.char((fin == false and 0 or 0x80) + opcode)
  if n < 126 then head = head .. string.char(n)
  else head = head .. string.char(126, bit.rshift(n, 8), bit.band(n, 0xFF)) end
  return head .. payload
end

local t = 0
local function now() return t end

-- the double hands out a few bytes per receive, as a real socket may, so
-- a step of the game is several updates here
local function pump(ws, n) for _ = 1, n or 200 do ws:update() end end

-- ------------------------------------------------------------------
do
  local socket, tcp = fakeSocket()
  local ws = Ws.new("ws://example.test/link1/00042", { socket = socket, now = now })
  check(not ws.closed, "connects")
  ws:send("Sfirst")             -- queued until the upgrade is done
  ws:update()
  local req = tcp.wire
  check(req:match("^GET /link1/00042 HTTP/1%.1\r\n"), "requests the room path")
  check(req:find("\r\nHost: example.test\r\n", 1, true), "Host header without :80")
  check(req:find("\r\nUpgrade: websocket\r\n", 1, true) and req:find("\r\nConnection: Upgrade\r\n", 1, true),
        "asks for the upgrade")
  local key = req:match("Sec%-WebSocket%-Key: ([%w%+/=]+)\r\n")
  check(key and #key == 24, "a 16-byte base64 key")
  check(req:sub(-4) == "\r\n\r\n", "the request ends its headers")
  tcp.wire = ""
  tcp:feed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
  tcp:feed(serverFrame(0x1, "CLIENT"))
  pump(ws)
  check(ws.open, "open after 101")
  local frames = readFrames(tcp.wire)
  check(#frames == 1 and frames[1].opcode == 0x2 and frames[1].payload == "Sfirst" and frames[1].masked,
        "the queued message goes out masked, as binary")
  local msgs = ws:poll()
  check(#msgs == 1 and msgs[1].text == "CLIENT", "reads a text frame split across receives")

  tcp.wire = ""
  local big = string.rep("\171", 0x271 + 7)
  ws:send(big)
  pump(ws)
  frames = readFrames(tcp.wire)
  check(#frames == 1 and frames[1].payload == big, "a 632-byte message uses the 16-bit length and unmasks back")

  tcp:feed(serverFrame(0x2, string.rep("x", 300)))
  tcp:feed(serverFrame(0x2, "ab", false) .. serverFrame(0x0, "cd", false) .. serverFrame(0x0, "ef"))
  tcp:feed(serverFrame(0x9, "hi"))
  tcp.wire = ""
  pump(ws)
  msgs = ws:poll()
  check(#msgs == 2 and msgs[1].binary == string.rep("x", 300), "a 300-byte binary frame")
  check(msgs[2] and msgs[2].binary == "abcdef", "fragments are joined")
  frames = readFrames(tcp.wire)
  check(#frames == 1 and frames[1].opcode == 0xA and frames[1].payload == "hi", "a ping is answered with its payload")

  tcp.wire = ""
  tcp:feed(serverFrame(0x8, string.char(0x03, 0xE8)))
  pump(ws)
  check(ws.closed and ws.closeCode == 1000, "a close frame closes it")
  frames = readFrames(tcp.wire)
  check(#frames == 1 and frames[1].opcode == 0x8, "...and is echoed")
  check(ws.error == nil, "a clean close is not an error")
end

do
  local socket, tcp = fakeSocket()
  local ws = Ws.new("ws://example.test:8080/link1/12345", { socket = socket, now = now })
  ws:update()
  check(tcp.wire:find("\r\nHost: example.test:8080\r\n", 1, true), "Host header keeps a non-default port")
  tcp:feed("HTTP/1.1 404 Not Found\r\n\r\n")
  pump(ws)
  check(ws.closed and ws.error and ws.error:find("refused", 1, true), "a refused upgrade is an error")
end

do
  local socket = fakeSocket()
  local ws = Ws.new("wss://example.test/link1/12345", { socket = socket, now = now })
  check(ws.closed and ws.error and ws.error:find("TLS", 1, true), "wss:// is refused up front, with the reason")
end

do
  local socket, tcp = fakeSocket()
  local ws = Ws.new("ws://example.test/link1/12345", { socket = socket, now = now })
  ws:update()
  tcp:feed("HTTP/1.1 101 Switching Protocols\r\n\r\n")
  pump(ws)
  tcp.closedByPeer = true
  pump(ws)
  check(ws.closed and ws.error == nil, "the server hanging up closes it")
end

do
  local socket = fakeSocket()
  local ws = Ws.new("ws://example.test/x", { socket = socket, now = now })
  t = 100
  ws:update()
  check(ws.closed and ws.error and ws.error:find("upgrade", 1, true), "no answer to the upgrade times out")
  t = 0
end

check(Ws.base64("Man") == "TWFu" and Ws.base64("Ma") == "TWE=" and Ws.base64("M") == "TQ==",
      "base64 pads like RFC 4648")

print(failures == 0 and "gblink ws: all passed" or ("gblink ws: %d failures"):format(failures))
os.exit(failures == 0 and 0 or 1)
