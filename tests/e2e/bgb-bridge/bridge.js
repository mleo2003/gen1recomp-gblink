// Run GB-Link's open-source web client (github.com/GB-Link/gb-pokemon-web)
// against the BGB emulator without the GB-Link BGB desktop app:
//
//   node bridge.js <path to a gb-pokemon-web checkout> [port]
//   then open http://127.0.0.1:<port>/?from=gblink-bgb
//
// It serves the checkout with shim.js injected into every page, and relays
// shim.js's WebSocket (/bgb) to BGB's link port over TCP. Only local
// addresses are allowed, like the desktop app.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');
const { WebSocketServer } = require('ws');

const root = path.resolve(process.argv[2] || 'gb-pokemon-web');
const port = Number(process.argv[3] || process.env.PORT || 8090);
const shim = fs.readFileSync(path.join(__dirname, 'shim.js'));
const LOCAL = new Set(['127.0.0.1', 'localhost', '::1']);
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.ico': 'image/x-icon', '.svg': 'image/svg+xml',
  '.bin': 'application/octet-stream', '.gb': 'application/octet-stream', '.wasm': 'application/wasm',
};

function log(...args) { console.log(new Date().toISOString(), ...args); }

// BGB paces itself on timestamps: it keeps asking the other side for its
// time (sync3 with b2=0) and waits for each answer, so its speed is bounded
// by that round trip (its manual asks for under 1 ms of link lag). Through
// the page every answer crosses page <-> WebSocket <-> here <-> TCP and BGB
// crawls. So, exactly like the reference client (PokemonGB_Online_Trades_and
// _Battles utilities/bgb_link_cable_server.py: "say we are exactly in
// sync"), the bridge answers BGB's syncs itself, sends one every 15 ms, and
// stamps every packet it writes to BGB with "BGB's last time + real time
// since". Version, status, joypad and the transfers themselves (sync1,
// sync2, sync3 with b2=1) still pass between BGB and the page untouched.
// Measured on Windows 11: BGB at about 2/3 speed in the overworld, slower
// while the game polls the link. (Giving BGB a lead, or answering only some
// of its syncs, measured slower still.)
// BGB_LOCAL_SYNC=0 turns this off and makes the bridge a plain pipe.
const LOCAL_SYNC = process.env.BGB_LOCAL_SYNC !== '0';
// BGB_TAP=1 logs every packet except timestamp syncs, and a count of those every 5 s
const TAP = process.env.BGB_TAP === '1';
const NAMES = { 1: 'version', 101: 'joypad', 104: 'sync1', 105: 'sync2', 106: 'sync3', 108: 'status', 109: 'bye' };
function tap(dir, p, counts) {
  if (!TAP) return;
  const key = `${dir} ${NAMES[p[0]] || p[0]}${p[0] === 106 ? (p[1] ? '/1' : '/0') : ''}`;
  counts[key] = (counts[key] || 0) + 1;
  if (p[0] === 106 && p[1] === 0) return;
  log(`${dir} ${NAMES[p[0]] || p[0]} b2=${p[1].toString(16)} b3=${p[2].toString(16)} b4=${p[3].toString(16)} ts=${p.readUInt32LE(4)}`);
}
const TICKS_PER_MS = (1 << 21) / 1000;
const nowMs = () => Number(process.hrtime.bigint()) / 1e6;

function packet(b1, b2, b3, b4, ts) {
  const p = Buffer.alloc(8);
  p[0] = b1; p[1] = b2; p[2] = b3; p[3] = b4;
  p.writeUInt32LE(ts >>> 0, 4);
  return p;
}

// Splits a byte stream into the protocol's fixed 8-byte packets.
function framer(onPacket) {
  let pending = Buffer.alloc(0);
  return (chunk) => {
    pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
    let i = 0;
    for (; i + 8 <= pending.length; i += 8) onPacket(pending.subarray(i, i + 8));
    pending = pending.subarray(i);
  };
}

function pacer(toBgb, counts) {
  let last = 0, at = 0, answered = 0, timer = null, statsTimer = null;
  const stamp = () => (last + Math.round((nowMs() - at) * TICKS_PER_MS)) & 0x7FFFFFFF;
  return {
    // a packet from BGB: returns it if it is for the page, null if answered here
    fromBgb(p) {
      const ts = p.readUInt32LE(4);
      if (ts !== 0) { last = ts & 0x7FFFFFFF; at = nowMs(); }
      if (p[0] === 106 && p[1] === 0) {
        answered++;
        toBgb(packet(106, p[1], p[2], p[3], stamp()));
        return null;
      }
      return p;
    },
    // a packet from the page, restamped on this side's clock
    fromPage(p) {
      if (last !== 0 && p.readUInt32LE(4) !== 0) {
        p = Buffer.from(p);
        p.writeUInt32LE(stamp() >>> 0, 4);
      }
      return p;
    },
    start() {
      timer = setInterval(() => { if (last !== 0) toBgb(packet(106, 0, 0, 0, stamp())); }, 15);
      if (TAP) statsTimer = setInterval(() => log('counts', JSON.stringify(counts), 'bgb ts', last), 5000);
    },
    stop() {
      if (timer) clearInterval(timer);
      if (statsTimer) clearInterval(statsTimer);
      timer = statsTimer = null;
      return answered;
    },
  };
}

const server = http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://local').pathname);
  if (p === '/gblink-bgb-shim.js') {
    res.writeHead(200, { 'content-type': TYPES['.js'], 'cache-control': 'no-store' });
    return res.end(shim);
  }
  if (p.endsWith('/')) p += 'index.html';
  const file = path.join(root, p);
  if (!file.startsWith(root + path.sep)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, body) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    if (path.extname(file) === '.html') {
      body = Buffer.from(body.toString('utf8').replace(/<head[^>]*>/i,
        (m) => `${m}\n<script src="/gblink-bgb-shim.js"></script>`));
    }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(body);
  });
});

const wss = new WebSocketServer({ server, path: '/bgb' });
wss.on('connection', (ws) => {
  let sock = null;
  let listener = null;
  let rx = 0, tx = 0;
  const status = (st) => {
    log('status', JSON.stringify(st));
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ type: 'status', ...st }));
  };
  let pace = null;
  let fromPage = null;
  const drop = () => {
    if (pace) { log(`answered ${pace.stop()} timestamp syncs locally`); pace = null; }
    if (sock) { sock.removeAllListeners(); sock.destroy(); sock = null; log(`closed (bgb->page ${rx} B, page->bgb ${tx} B)`); }
    if (listener) { listener.close(); listener = null; }
  };
  const attach = (s) => {
    sock = s;
    s.setNoDelay(true);
    if (LOCAL_SYNC) {
      const counts = {};
      pace = pacer((p) => { if (sock === s) { tap('bridge->bgb', p, counts); s.write(p); } }, counts);
      pace.start();
      const fromBgb = framer((p) => {
        tap('bgb->', p, counts);
        const out = pace.fromBgb(p);
        if (out) { rx += 8; if (ws.readyState === ws.OPEN) ws.send(Buffer.from(out)); }
      });
      fromPage = framer((p) => { tx += 8; const q = pace.fromPage(p); tap('page->bgb', q, counts); s.write(q); });
      s.on('data', fromBgb);
    } else {
      fromPage = (d) => { tx += d.length; s.write(d); };
      s.on('data', (d) => { rx += d.length; if (ws.readyState === ws.OPEN) ws.send(d); });
    }
    s.on('error', (e) => log('tcp error', e.code));
    s.on('close', () => {
      if (sock !== s) return;
      sock = null;
      if (pace) { log(`answered ${pace.stop()} timestamp syncs locally`); pace = null; }
      log(`bgb closed (bgb->page ${rx} B, page->bgb ${tx} B)`);
      status({ state: 'idle', reason: 'peer-closed' });
    });
    status({ state: 'connected' });
  };

  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      if (sock && fromPage) fromPage(data);
      return;
    }
    const msg = JSON.parse(data.toString());
    if (msg.op === 'close') return drop();
    if (sock || listener) return status({ state: 'idle', reason: 'busy' });
    if (msg.op === 'connect') {
      if (!LOCAL.has(msg.host)) return status({ state: 'idle', reason: 'not-allowed' });
      status({ state: 'connecting' });
      const s = net.connect({ host: msg.host, port: msg.port });
      const timer = setTimeout(() => { s.destroy(); status({ state: 'idle', reason: 'timeout' }); }, 5000);
      s.once('connect', () => { clearTimeout(timer); attach(s); });
      s.once('error', (e) => {
        clearTimeout(timer);
        if (sock !== s) status({ state: 'idle', reason: e.code === 'ECONNREFUSED' ? 'refused' : 'error', detail: e.code });
      });
    } else if (msg.op === 'listen') {
      listener = net.createServer((s) => {
        if (sock) return s.destroy();
        listener.close();
        listener = null;
        attach(s);
      });
      listener.once('error', (e) => {
        listener = null;
        status({ state: 'idle', reason: e.code === 'EADDRINUSE' ? 'addr-in-use' : 'error', detail: e.code });
      });
      listener.listen(msg.port, '127.0.0.1', () => status({ state: 'listening' }));
    }
  });
  ws.on('close', drop);
});

server.listen(port, '127.0.0.1', () => log(`serving ${root} at http://127.0.0.1:${port}/?from=gblink-bgb` +
  (LOCAL_SYNC ? ' (answering BGB timestamp syncs locally)' : ' (plain pipe)')));
