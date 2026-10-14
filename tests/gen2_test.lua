-- Gen 2 (Gold/Silver/Crystal): lib/codec2.lua against the engine's own Gen 2
-- data, and two copies of the Gen 2 protocol stack (lib/session.lua on
-- Proto.forGen(2) + lib/link2.lua) trading through tests/fake_relay.lua on a
-- simulated clock -- sync and buffered, with and without mail.
--
--   GOLD_CACHE=<imported gold cache dir> luajit mods/gblink/tests/gen2_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "mods/gblink"
local cache = assert(os.getenv("GOLD_CACHE"), "set GOLD_CACHE to an imported Gold cache directory")

local T = require("tests.modkit")
local GameVersion = require("src.core.GameVersion")
GameVersion.set("gold")
local SaveConvert = require("src.save_convert.SaveConvert")
local Gen2Save = require("src.save_convert.Gen2Save")
local Gen2Layout = require("src.save_convert.Gen2Layout")
local Mon = require("src.battle.gen2.Mon")
local Mail = require("src.core.gen2.Mail")

local data = assert(SaveConvert.gen2DataFromDir(cache), "no Gen 2 tables under " .. cache)
local Proto = dofile(here .. "/lib/proto.lua")
local P2 = Proto.forGen(2)
local Codec2 = dofile(here .. "/lib/codec2.lua")
local Session = dofile(here .. "/lib/session.lua")
local Link2 = dofile(here .. "/lib/link2.lua")
local FakeRelay = dofile(here .. "/tests/fake_relay.lua")

local env = { data = data, cw = Gen2Save.crosswalks(data), charmap = Gen2Layout.charmap,
              Mon = Mon, crystal = false }

local function mon(species, level, opts)
  opts = opts or {}
  local m = assert(Mon.new(data, species, level, {
    item = opts.item, nickname = opts.nickname, dvs = opts.dvs, statExp = opts.statExp,
    moves = opts.moves,
  }))
  m.ot, m.otId = opts.ot or "GOLD", opts.otId or 1234
  return m
end

-- ------------------------------------------------------------------
-- codec
-- ------------------------------------------------------------------

do
  local m = mon("HAUNTER", 31, { item = "BERRY", nickname = "SPOOKY", otId = 0xFEFE,
                                 statExp = { hp = 0xFE, attack = 0xFEFE, defense = 3, speed = 4, special = 5 } })
  m.experience = 0xFE00FE
  local w = Codec2.wireMon(env, m, nil)
  T.eq(#w.struct, 48, "a party struct is 48 bytes")
  local party = { name = Codec2.name(env, "GOLD", 7), id = 0xFE01, mons = { w, Codec2.wireMon(env, mon("PIDGEY", 5), nil) } }
  local s1, s2, s3 = Codec2.sections(party)
  T.eq(#s1, 0x1BC, "section 1 is 0x1BC bytes")
  T.eq(#s2, 0xC5, "section 2 is 0xC5 bytes")
  T.eq(#s3, 0x181, "section 3 is 0x181 bytes")
  T.check(not s1:find("\254", 0x14, true) or s1:find("\254", 0x14, true) > 0x135,
          "no $FE left in the patched region (trainer ID + structs)")
  local back = assert(Codec2.parseSections(s1, s2, s3))
  T.eq(back.id, 0xFE01, "a $FE in the trainer ID survives the patch list")
  T.eq(back.mons[1].struct, w.struct, "a struct full of $FE survives the patch list byte for byte")
  T.eq(Codec2.decodeText(env, back.name, 0, 11), "GOLD", "the player name round-trips")
  local em = Codec2.engineMon(env, back.mons[1])
  T.eq(em.species, "HAUNTER", "engine mon: species")
  T.eq(em.item, "BERRY", "engine mon: held item")
  T.eq(em.nickname, "SPOOKY", "engine mon: nickname")
  T.eq(em.otId, 0xFEFE, "engine mon: OT ID")
  T.eq(em.experience, 0xFE00FE, "engine mon: experience")
  T.eq(em.statExp.attack, 0xFEFE, "engine mon: stat exp")
  T.eq(em.dvs.attack, m.dvs.attack, "engine mon: DVs")
  T.eq(#em.moves, #m.moves, "engine mon: moves")
  T.eq(Codec2.packMon(env, em), w.struct, "engine mon -> struct is the same 48 bytes")
  T.eq(Codec2.fromSingle(Codec2.single(w)).struct, w.struct, "CHC2's mon round-trips")
  T.eq(#Codec2.single(w), P2.MON_LENGTH, "CHC2's mon is 0x76 bytes")
  local p2 = assert(Codec2.parseSections(s1, s2, nil))
  T.eq(p2.mons[2].nick, party.mons[2].nick, "an unnamed mon keeps the species name")
end

do
  -- the cart's stat formula, ceil(sqrt(statExp)), and HP following max HP
  local w = Codec2.wireMon(env, mon("HAUNTER", 31, { statExp = { hp = 10, attack = 12, defense = 0, speed = 0, special = 0 } }), nil)
  local before = Codec2.unpackMon(env, w.struct)
  local into = Codec2.evolveWire(env, w)
  T.eq(into, "GENGAR", "Haunter trade-evolves into Gengar")
  local after = Codec2.unpackMon(env, w.struct)
  local b = data.pokemon.GENGAR.baseStats
  local function stat(base, dv, se, lvl, hp)
    local v = math.floor(((base + dv) * 2 + math.floor(math.min(255, math.ceil(math.sqrt(se))) / 4)) * lvl / 100)
    return v + (hp and lvl + 10 or 5)
  end
  T.eq(after.stats.attack, stat(b.attack, after.dvs.attack, 12, 31), "evolved attack uses ceil(sqrt(statExp))")
  T.eq(after.maxHp, stat(b.hp, after.dvs.hp, 10, 31, true), "evolved max HP")
  T.eq(after.hp, before.hp + after.maxHp - before.maxHp, "current HP moves by the max HP change")
  T.eq(Codec2.decodeText(env, w.nick, 0, 11), "GENGAR", "an unnamed mon takes the new species name")
  local onix = Codec2.wireMon(env, mon("ONIX", 30, { item = "METAL_COAT" }), nil)
  T.eq(Codec2.evolveWire(env, onix), "STEELIX", "Onix holding a Metal Coat becomes Steelix")
  T.eq(onix.struct:byte(2), 0, "and the Metal Coat is used up")
  T.eq(Codec2.evolveWire(env, Codec2.wireMon(env, mon("ONIX", 30), nil)), nil, "Onix without the item stays Onix")
  T.eq(Codec2.evolveWire(env, Codec2.wireMon(env, mon("HAUNTER", 31, { item = "EVERSTONE" }), nil)), nil,
       "an Everstone stops a trade evolution")
  local named = Codec2.wireMon(env, mon("HAUNTER", 31, { nickname = "BOO" }), nil)
  Codec2.evolveWire(env, named)
  T.eq(Codec2.decodeText(env, named.nick, 0, 11), "BOO", "a nickname survives evolution")
end

do
  -- mail rides section 3: messages with $FE as $21, metadata patch-listed
  local m = mon("PIDGEY", 10, { item = "FLOWER_MAIL" })
  local entry = Mail.entry("FLOWER_MAIL", "HELLO 8\nWORLD", "GOLD", 0xFEFE, "PIDGEY")
  local w = Codec2.wireMon(env, m, entry)
  T.check(Codec2.holdsMail(w), "a mail item makes a mail holder")
  local party = { name = Codec2.name(env, "GOLD", 7), id = 1, mons = { w } }
  local s1, s2, s3 = Codec2.sections(party)
  T.check(Codec2.sectionHasMail(s1), "section 1 says mail is coming")
  T.check(not s3:sub(1, 33):find("\254", 1, true), "no $FE in the mail message on the wire")
  local back = assert(Codec2.parseSections(s1, s2, s3))
  local _, got = Codec2.engineMon(env, back.mons[1])
  T.check(got ~= nil, "the received mon has its mail")
  T.eq(got and got.message, "HELLO 8\nWORLD", "the mail message ('8' is $FE) round-trips")
  T.eq(got and got.authorId, 0xFEFE, "a $FE in the author ID survives the mail patch list")
  T.eq(got and got.author, "GOLD", "the author round-trips")
  T.check(not Codec2.sectionHasMail(Codec2.sections({ name = party.name, id = 1, mons = { Codec2.wireMon(env, mon("PIDGEY", 10), nil) } })),
          "a party without mail sends no mail section")
end

-- ------------------------------------------------------------------
-- two Gen 2 games through the server
-- ------------------------------------------------------------------

local clock = 0
local function now() return clock end

local function player(relay, name, id, party, mails, plan, preferMode)
  local save = { player = { name = name, id = id }, party = party, mail = { party = mails or {} } }
  local game = { save = save, data = data }
  local ep = relay:connect("/link2/12345")
  local session = Session.new({ conn = ep, Proto = P2, now = now, rng = math.random,
                                needMail = Link2.needMail, preferMode = preferMode })
  if os.getenv("GEN2_DEBUG") and name == "GOLD" then
    local orig = session.onMessage
    session.onMessage = function(self2, m)
      if m.binary then
        local msg = P2.decode(m.binary)
        if not msg then print(("%.2f GOLD got undecodable %d bytes: %q"):format(clock, #m.binary, m.binary:sub(1, 7)))
        elseif msg.kind ~= "SNG2" then print(("%.2f GOLD got %s %s ctr=%s expect=%s"):format(clock, msg.req, msg.kind, msg.data and msg.data:byte(1) or "-", tostring(self2.expect))) end
      end
      return orig(self2, m)
    end
  end
  local link = Link2.new({ game = game, env = env, Codec2 = Codec2, session = session, Mail = Mail })
  assert(link:prepare(), link.error)
  local p = { name = name, link = link, game = game, plan = plan, round = 0, traded = {}, log = {} }
  link.listener = {
    onLink = function(_, ev)
      p.log[#p.log + 1] = ev.type
      if ev.type == "party" or ev.type == "round" then
        p.round = p.round + 1
        local pick = plan[p.round]
        if pick == "last" then pick = #game.save.party - 1 end
        if pick == "stop" then link:leave() link:choose(nil)
        elseif pick then link:choose(pick) end
      elseif ev.type == "theirPick" then
        p.theirPick = ev.mon
        p.mismatch = ev.mismatch
      elseif ev.type == "again" then
        -- a declined offer: like the web client, end the visit
        p.again = (p.again or 0) + 1
        link:leave()
        link:choose(nil)
      elseif ev.type == "theirStop" then
        link:leave()
      elseif ev.type == "traded" then
        p.traded[#p.traded + 1] = ev
        -- the engine side, in short: file the received mon at the end and
        -- let the engine's evolution run, then send our MVS2
        local save = game.save
        table.remove(save.party, ev.ourSlot + 1)
        local got = Codec2.engineMon(env, ev.received)
        save.party[#save.party + 1] = got
        p.pendingRound = clock + 0.5
      elseif ev.type == "error" then
        p.err = ev.message
      end
    end,
  }
  -- confirm every trade the moment the session asks
  function p:step()
    link:update()
    if link.session.status == "confirm" and link.session.pendingAccept == nil then link:accept(true) end
    if p.pendingRound and clock >= p.pendingRound then
      p.pendingRound = nil
      link:roundDone(game.save.party[#game.save.party])
    end
  end
  return p
end

local function run(label, opts)
  clock = 0
  math.randomseed(opts.seed or 1)
  local relay = FakeRelay.new({ Proto = P2, now = now, latency = 0.06 })
  local aMail, bMail = {}, {}
  local aParty = { mon("HAUNTER", 31, { ot = "GOLD", otId = 1111 }), mon("PIDGEY", 10, { ot = "GOLD", otId = 1111 }) }
  local bParty = { mon("MACHOKE", 32, { ot = "SILVER", otId = 2222 }), mon("ONIX", 30, { ot = "SILVER", otId = 2222, item = "METAL_COAT" }) }
  if opts.mail then
    aParty[2].item = "FLOWER_MAIL"
    aMail[2] = Mail.entry("FLOWER_MAIL", "HI THERE", "GOLD", 1111, "PIDGEY")
  end
  -- round 1: A's HAUNTER for B's ONIX (holding a Metal Coat); round 2:
  -- A's PIDGEY for B's MACHOKE; then both cancel
  local a = player(relay, "GOLD", 1111, aParty, aMail, opts.planA or { 0, 0, "stop" })
  local b = player(relay, "SILVER", 2222, bParty, bMail, opts.planB or { 1, 0, "stop" },
                   opts.buffered and "buffered" or nil)
  if opts.tamper then
    -- what B's client sends as its CHC2 is changed on the way out (the
    -- trade still comes from A's own copy of B's party)
    local send = b.link.session.sendCounter
    b.link.session.sendCounter = function(self2, kind, payload)
      if kind == P2.T.CHC and type(payload) == "string" and #payload > 2 then
        payload = opts.tamper(payload)
      end
      return send(self2, kind, payload)
    end
  end
  while clock < 120 do
    clock = clock + 1 / 60
    relay:tick()
    a:step(); b:step()
    if a.err or b.err then break end
    if a.link.ended and b.link.ended then break end
  end
  if os.getenv("GEN2_DEBUG") then
    for _, x in ipairs({ a, b }) do
      local ss = x.link.session
      print(label, x.name, "status", ss.status, "round", ss.round,
            "log", table.concat(x.log, ","), "clock", clock)
      local qs = {}
      for k, q in pairs(ss.queues) do qs[#qs + 1] = k .. "=" .. #q end
      local sd = {}
      for k, v in pairs(ss.sendDict) do if k ~= "SNG2" and k ~= "FLL2" then sd[#sd + 1] = k .. ":" .. v:byte(1) end end
      print("   expect", ss.expect, "ownCtr", ss.ownCtr, "queues", table.concat(qs, " "), "sent", table.concat(sd, " "))
    end
  end
  T.eq(a.err, nil, label .. ": A ran clean")
  T.eq(b.err, nil, label .. ": B ran clean")
  if opts.check then return opts.check(a, b, relay) end
  T.eq(#a.traded, 2, label .. ": two trades")
  T.check(a.link.ended and b.link.ended, label .. ": both ended")
  -- each side's model of the other matches the other's own, byte for byte
  for _, side in ipairs({ { a, b }, { b, a } }) do
    local me, them = side[1], side[2]
    local mine, model = me.link.ours.mons, them.link.theirs.mons
    T.eq(#model, #mine, label .. ": " .. them.name .. "'s model of " .. me.name .. " has the right size")
    for i = 1, #mine do
      T.eq(model[i].struct, mine[i].struct, label .. ": " .. them.name .. " models " .. me.name .. "'s slot " .. i .. " byte for byte")
    end
  end
  local aSpecies, bSpecies = {}, {}
  for i, m in ipairs(a.link.ours.mons) do aSpecies[i] = Codec2.unpackMon(env, m.struct).species end
  for i, m in ipairs(b.link.ours.mons) do bSpecies[i] = Codec2.unpackMon(env, m.struct).species end
  T.eq(table.concat(aSpecies, ","), "STEELIX,MACHAMP", label .. ": A ends with Steelix (Metal Coat used) and Machamp")
  T.eq(table.concat(bSpecies, ","), "GENGAR,PIDGEY", label .. ": B ends with Gengar and Pidgey")
  T.eq(a.link.session.mode, opts.buffered and "buffered" or "sync", label .. ": mode")
  if opts.mail then
    T.check(a.link.session.theirs[3] ~= nil, label .. ": the mail section was exchanged")
    local held = b.link.ours.mons[2]
    T.check(Codec2.holdsMail(held), label .. ": the PIDGEY arrived still holding its mail")
    local _, entry = Codec2.engineMon(env, held)
    T.eq(entry and entry.message, "HI THERE", label .. ": and the letter came with it")
  elseif not opts.buffered then
    T.eq(a.link.session.theirs[3], nil, label .. ": no mail section without mail")
  end
end

run("sync", { seed = 3 })
run("sync with mail", { seed = 5, mail = true })
run("buffered", { seed = 7, buffered = true })
run("buffered with mail", { seed = 9, buffered = true, mail = true })

-- CHC2 offsets: choice byte, then struct (48), OT (11), nickname (11), ...
local OT_AT, NICK_AT = 1 + 0x30, 1 + 0x30 + 11
local function overwrite(payload, at, bytes)
  return payload:sub(1, at) .. bytes .. payload:sub(at + #bytes + 1)
end

-- seen live: the Python client re-read its own cart over a slipping BGB
-- link after round 1 and offered HAUNTER as OT "??CART" + $FE, nickname
-- "?????HA" $FE "UNT" -- struct intact.  Round 2 here offers back what
-- arrived in round 1 (A's own HAUNTER, now a GENGAR), with B's OT and
-- nickname mangled the same way.
run("an offer with mangled text trades our copy", {
  seed = 11,
  planA = { 0, "last", "stop" },
  planB = { 1, "last", "stop" },
  tamper = function(payload)
    return overwrite(overwrite(payload, OT_AT, "\0\0\130\128\145\147\254"), NICK_AT, "\0\0\0\0\0\135\128\254\148\141\147")
  end,
  check = function(a, b)
    T.eq(#a.traded, 2, "mangled text: both trades went through")
    T.eq(a.mismatch, nil, "mangled text: the offer was still found (weak match)")
    local last = a.link.ours.mons[#a.link.ours.mons]
    local got = Codec2.engineMon(env, last)
    T.eq(got.species, "GENGAR", "mangled text: A got its HAUNTER back, evolved (offered back by B)")
    T.eq(got.ot, "GOLD", "mangled text: with its real OT, not the mangled one")
    T.eq(got.nickname, nil, "mangled text: and the species name, not the mangled one")
    for i, m in ipairs(b.link.ours.mons) do
      T.eq(a.link.theirs.mons[i].struct, m.struct, "mangled text: A's copy of B's slot " .. i .. " is still exact")
      T.check(Codec2.sameText(a.link.theirs.mons[i].nick, m.nick), "mangled text: and its nickname too")
    end
  end,
})

-- a CANCEL on one side ends the visit for both: the carts' menus close
run("one side cancels while the other picks", {
  seed = 17,
  planA = { 0 },
  planB = { "stop" },
  check = function(a, b)
    T.eq(#a.traded + #b.traded, 0, "one-sided cancel: no trade")
    T.check(a.link.ended and b.link.ended, "one-sided cancel: both left the table")
    T.eq(a.again, nil, "one-sided cancel: nobody was sent back to choosing")
  end,
})

-- the Python client hands a one-sided CANCEL to its Game Boy, whose player
-- may pick again: that pick reaches us and is answered with CANCEL
run("a pick after a one-sided cancel is answered with CANCEL", {
  seed = 19,
  planA = { "stop" },
  planB = { 0 },
  check = function(a, b, relay)
    T.check(a.link.ended and b.link.ended, "late pick: both menus ended")
    T.check(a.link.session.answering, "late pick: the cancelling side keeps answering")
    T.eq(a.link.session.sendDict.CHC2:byte(2), P2.STOP, "late pick: its last choice was CANCEL")
    -- B's player picks again; its client sends CHC2 and waits for ours
    local ses = b.link.session
    ses:sendCounter(P2.T.CHC, string.char(P2.FIRST_INDEX) .. Codec2.single(b.link.ours.mons[1]))
    local before = a.link.session.ownCtr
    for _ = 1, 120 do
      clock = clock + 1 / 60
      relay:tick()
      a:step(); b:step()
    end
    T.eq(a.link.session.ownCtr, (before + 1) % 256, "late pick: exactly one answer went out")
    T.eq(a.link.session.sendDict.CHC2:byte(2), P2.STOP, "late pick: and it was CANCEL")
  end,
})

run("an offer that is not in their party is declined", {
  seed = 13,
  planA = { 0, "stop" },
  planB = { 1, "stop" },
  tamper = function(payload)
    -- a different mon: its DVs changed
    local at = 1 + 0x15
    return overwrite(payload, at, string.char((payload:byte(at + 1) + 0x11) % 256))
  end,
  check = function(a, b)
    T.eq(#a.traded, 0, "unknown offer: no trade on A")
    T.eq(#b.traded, 0, "unknown offer: no trade on B")
    T.eq(a.mismatch, true, "unknown offer: A saw the mismatch")
    T.check(a.link.ended and b.link.ended, "unknown offer: both left the table")
    T.eq(#a.link.ours.mons, 2, "unknown offer: A's party is untouched")
  end,
})

T.finish("gblink gen2")
