-- A Gen 2 link trade landing in the engine's party, filed the way the cart
-- files it (pokecrystal engine/link/link.asm, the trade's tail): the given
-- mon leaves its slot and its letter goes with it (Mail.removeSlot), the
-- rest close up, and the received mon -- with its letter -- goes on the END,
-- where the peer's model of our party expects it.  Seen and caught are set
-- for it.  Whether it then evolves is returned, not done: the trade screen
-- plays the evolution through the engine's own Gen2EvolutionAnim, which
-- writes the evolved record back into the slot and teaches its new moves.

local Party2 = {}

-- opts: env (lib/codec2.lua env), Codec2, save, Mail (src.core.gen2.Mail),
-- Evolution (src.core.gen2.Evolution)
-- ourSlot is 0-based; received is the wire mon as it arrived (pre-evolution)
-- returns { given, mon, index, entry, mail }
function Party2.receive(opts, ourSlot, received)
  local save, Mail, Evolution = opts.save, opts.Mail, opts.Evolution
  local party = save.party
  local slot = ourSlot + 1
  local given = table.remove(party, slot)
  if Mail then Mail.removeSlot(save, slot) end
  local mon, mail = opts.Codec2.engineMon(opts.env, received)
  party[#party + 1] = mon
  local index = #party
  if Mail then
    if mail then Mail.set(save, index, mail) else Mail.clear(save, index) end
  end
  Evolution.markPokedex(save, mon.species)
  -- engine/link/link.asm sets wForceEvolution and runs EvolvePokemon with
  -- wLinkMode on: an Everstone or a missing required item is the only "no"
  local entry = nil
  if not mon.isEgg then entry = Evolution.checkMon(opts.env.data, mon, { link = true }) end
  return { given = given, mon = mon, index = index, entry = entry, mail = mail }
end

-- the evolution without a screen (tests, a headless run): Evolution.apply,
-- the pokedex, and the moves the new species learns at this level into free
-- slots (a full set keeps its moves, as if the player said no)
function Party2.evolveNow(opts, landed)
  local Evolution, Mon = opts.Evolution, opts.env.Mon
  if not landed.entry then return nil end
  local data = opts.env.data
  local evolved = Evolution.apply(data, landed.mon, landed.entry)
  if not evolved then return nil end
  opts.save.party[landed.index] = evolved
  Evolution.markPokedex(opts.save, evolved.species)
  for _, moveId in ipairs(Evolution.learnedOnEvolve(data, evolved.species, evolved.level, evolved)) do
    Mon.learnMove(evolved, moveId, data)
  end
  return evolved
end

return Party2
