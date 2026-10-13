// Stands in for the GB-Link BGB desktop app: provides window.gblinkBGB, the
// raw TCP pipe that pokemon.gblink.io's src/services/BgbConnection.js
// drives, over a WebSocket to bridge.js, which holds the TCP connection to
// BGB's link port. Loaded by bridge.js ahead of the page's own scripts.
(function () {
  'use strict';
  const listeners = { data: new Set(), status: new Set() };
  let ws = null;
  let opening = null;
  let state = { state: 'idle' };

  function on(kind, cb) {
    listeners[kind].add(cb);
    return () => listeners[kind].delete(cb);
  }

  function emitStatus(st) {
    state = st;
    for (const cb of [...listeners.status]) {
      try { cb(st); } catch (e) { console.error('gblinkBGB status listener', e); }
    }
  }

  function open() {
    if (ws && ws.readyState === WebSocket.OPEN) return Promise.resolve(ws);
    if (opening) return opening;
    opening = new Promise((resolve, reject) => {
      const sock = new WebSocket(`ws://${location.host}/bgb`);
      sock.binaryType = 'arraybuffer';
      sock.onopen = () => { ws = sock; opening = null; resolve(sock); };
      sock.onerror = () => { opening = null; reject(new Error('bridge.js is not reachable')); };
      sock.onclose = () => {
        if (ws === sock) ws = null;
        if (state.state !== 'idle') emitStatus({ state: 'idle', reason: 'reset', detail: 'bridge closed' });
      };
      sock.onmessage = (ev) => {
        if (typeof ev.data === 'string') {
          const msg = JSON.parse(ev.data);
          if (msg.type === 'status') emitStatus({ state: msg.state, reason: msg.reason, detail: msg.detail });
          return;
        }
        const bytes = new Uint8Array(ev.data);
        for (const cb of [...listeners.data]) {
          try { cb(bytes); } catch (e) { console.error('gblinkBGB data listener', e); }
        }
      };
    });
    return opening;
  }

  // Send one control op and resolve with the first status that settles it.
  function request(op, settled) {
    return open().then((sock) => new Promise((resolve) => {
      const off = on('status', (st) => {
        if (settled.includes(st.state) || st.state === 'idle') { off(); resolve(st); }
      });
      sock.send(JSON.stringify(op));
    })).catch((err) => {
      const st = { state: 'idle', reason: 'bridge', detail: err.message };
      emitStatus(st);
      return st;
    });
  }

  window.gblinkBGB = {
    version: 1,
    getState: async () => state,
    connect: ({ host, port }) => request({ op: 'connect', host, port }, ['connected']),
    listen: ({ port }) => request({ op: 'listen', port }, ['listening']),
    close: async () => {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ op: 'close' }));
      if (state.state !== 'idle') emitStatus({ state: 'idle', reason: 'closed' });
      return state;
    },
    send: (bytes) => {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
    },
    onData: (cb) => on('data', cb),
    onStatus: (cb) => on('status', cb),
  };
  console.log('gblinkBGB shim loaded (bridge.js)');
})();
