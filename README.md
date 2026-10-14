# GB-Link Online Trades

Trade Pokémon with a real Game Boy (on a GB-Link adapter), an emulator (BGB)
or another copy of this game, over the internet, in the same five-digit rooms
that [pokemon.gblink.io](https://pokemon.gblink.io) uses: at the Cable Club in
Red, Blue and Yellow, and at the Pokémon Center 2F Trade Center in Gold,
Silver and Crystal.

**Persona: the Bridge Builder.** On Red/Blue/Yellow the engine already has a
full Trade Center (pick, STATS, confirm, the trade animation, trade
evolutions, the autosave); this mod gives it a different kind of peer. On
Gold/Silver/Crystal the engine runs the cart's own receptionist script but
stubs every cable step, so the mod fills those steps in and brings the table
screen, built from the engine's own Gen 2 screens. It changes no game rules.

A mod for the [Pokemon Gen 1 Recompilation Project](https://github.com/bryanthaboi/gen1recomp)
by BOIS CLUB GAMES, LLC.

## Install

1. Download `gblink-<version>.zip` from this repo's
   [Releases](https://github.com/mleo2003/gen1recomp-gblink/releases/latest).
2. In the game's launcher: **MODS > Import mod .zip**, pick the file, and
   enable **GB-Link Online Trades**.

The manifest names this repo, so the MODS panel offers **Update** when a
new release is out.

## Use

### Red, Blue, Yellow

At any Pokémon Center, talk to the Cable Club receptionist, say YES to the
save, then pick **GB-LINK ONLINE** and enter a room number (Up/Down change
a digit, Left/Right move between digits). Both players must type the same
number. Newer engine builds move the receptionist upstairs: take the stairs
next to the old desk.

When both players are in, the other player sits at the Trade Center table and
this game opens its own Trade Center screen. Several trades can happen in one
visit. **B** at the trade menu cancels. **END LINK** answers CANCEL until the
other player leaves too.

### Gold, Silver, Crystal

Go upstairs in any Pokémon Center and talk to the **Trade Center**
receptionist (the left-hand desk). Answer YES, and instead of waiting for a
cable she opens **GB-LINK ONLINE**: enter the room number and press A. Once
the other game answers, the cart's own script carries on: the save,
"Please come in", the walk to the room. Sit at the empty stool, face the
table and press A.

The table works like the cart's: your party on top, theirs below, CANCEL
under them. A on one of yours offers STATS or TRADE; A on one of theirs shows
its STATS. Received Pokémon go to the end of your party with their mail,
trade-evolve (Everstone and held-item rules included) and the game saves
after every trade. CANCEL (or the other player's) ends the visit; walking
out closes the link.

The Colosseum and Time Capsule desks still say your friend is not ready.

### The other player

- **Real Game Boy:** go to pokemon.gblink.io, choose the generation that
  matches (*Gen 1* for Red/Blue/Yellow, *Gen 2* for Gold/Silver/Crystal) and
  *Link Trade*, connect the GB-Link adapter, enter the **same room number**,
  and talk to the receptionist on the cartridge.
- **Emulator (BGB):** run [Lorenzooone's PokemonGB client](https://github.com/Lorenzooone/PokemonGB_Online_Trades_and_Battles)
  as BGB's link partner: `python emulator_trade_battle.py -g 1 -t 2P -r <room> -efc`
  (`-g 2` for Gold/Silver/Crystal), then start BGB with
  `-connect 127.0.0.1:8765` (or BGB's Link > Connect). GB-Link's BGB desktop
  app does the same through pokemon.gblink.io, but its download was
  unavailable when this was written.
- **Python client with a real Game Boy:** the same client's `usb_trade_battle.py`
  with a GB-Link adapter, link trade, the matching generation, the same room.
- **This game:** both players pick GB-LINK ONLINE and type the same room.
- **A Gold/Silver/Crystal cart with Red/Blue/Yellow here:** the cart uses its
  Time Capsule desk and pokemon.gblink.io's *Gen 1* rooms; this game uses the
  Cable Club as above.

## Develop

Link a clone into the engine's `mods/` folder (the loader follows symlinks)
and run the tests from the engine root:

```sh
git clone https://github.com/mleo2003/gen1recomp-gblink
ln -s "$PWD/gen1recomp-gblink" <engine>/mods/gblink
cd <engine>
export POKEPORT_DATA_DIR=<your imported red data/generated>
python3 tools/modkit.py validate mods/gblink --base imported
luajit mods/gblink/tests/ws_test.lua            # the WebSocket client
luajit mods/gblink/tests/gblink_test.lua        # the mod through the loader
luajit mods/gblink/tests/online_trade_test.lua  # trades vs. the web/Python clients and itself
luajit mods/gblink/tests/ingame_test.lua        # a whole Cable Club visit through main.lua
export GOLD_CACHE=<your imported gold cache dir>
luajit mods/gblink/tests/gen2_test.lua          # Gen 2 codec, mail, evolutions, two Gen 2 stacks trading
luajit mods/gblink/tests/gen2_ingame_test.lua   # the Gold desk's specials and the table, through main.lua
```

The protocol tests run on a simulated clock. A fake trade server
(`tests/fake_relay.lua`) adds latency and jitter, and `tests/fake_peer.lua`
models the far player's client and Game Boy.

`tests/e2e/` is a live test: a real cartridge in BGB trades with this game
over the real server, and both saves are then checked with PKHeX. It has
passed both ways against Red (in the real game window and headless), Blue,
Yellow, Gold through the Time Capsule, and Gold to Gold at the Trade Center
(in the real game window and headless, including offering back a mon that
had just trade-evolved). See `tests/e2e/README.md`.

Releases are automatic: bump `version` in `manifest.json` (and
`CHANGELOG.md`) and push to `main`. `.github/workflows/release.yml` packs
`gblink-<version>.zip` (without `tests/`) and publishes it.

## How it works

| Piece | Where | Reference |
|---|---|---|
| WebSocket client (ws:// over luasocket, wss:// over the engine's TLS dialer) | `lib/ws.lua` | RFC 6455 |
| `S`/`G` framing, SNG1 windows | `lib/proto.lua` | `high_level_listener.py`, `gsc_trading.py` |
| The trade protocol, one side | `lib/session.lua` | `gsc_trading.py` `player_trade` / `do_trade` |
| Party ↔ the cart's 0x1A2-byte block and patch list | `lib/codec.lua` | pokered `engine/link/cable_club.asm` |
| Both parties across a visit | `lib/link.lua` | `trade_mon`, `evolution_procedure` |
| LinkState's transport | `lib/bridge.lua` | `LinkState.newFromSession` |
| Gen 2 party ↔ the cart's sections (party, patch list, mail) | `lib/codec2.lua` | pokecrystal `engine/link/link.asm`, `gsc_trading_data_utils.py` |
| Both Gen 2 parties across a visit | `lib/link2.lua` | `trade_mon`, `evolve_mon`, `search_for_mon` |
| A received mon into the engine's party | `lib/party2.lua` | the cart's trade tail |
| The Gold/Silver/Crystal desk and table | `lib/gen2.lua`, `lib/tradecenter2.lua` | pokecrystal `maps/Pokecenter2F.asm` |

The trade server only forwards messages. Each client drives its own Game Boy
and sends the other client:

1. The party block, in **sync** mode as 8-byte SNG1 windows that track the
   far Game Boy byte by byte, or in **buffered** mode as one FLL1. This game
   adopts whichever mode the other player chose, so nobody is asked to switch.
2. A pick (CHC1), a yes/no (ACP1), then ASK1 and SUC1 to close a trade.
3. One MVS1 per later round. No party is re-sent after a trade: both sides
   rebuild it the way the cartridge does, with the traded mon at the **end**
   of the party. That is why a mon received here is moved to the end too.

On Red/Blue/Yellow the engine's own `LinkState` runs the Trade Center.
`lib/bridge.lua` answers its `hello` with a mirror image, so the compatibility
verdict is "full". It then translates `party`/`pick`/`confirm`/`bye` to and
from the messages above.

Gen 2 is the same flow with "2" messages, a mail section that goes across
only when either party holds mail, and a 0x76-byte CHC2. Both sides keep a
byte-exact copy of the other's party. An offered mon is looked up in that
copy (the way the Python client does it), and the copy is what trades, so a
far side that sends garbled bytes for its own mon cannot plant them here. An
offer that matches nothing in the copy is declined.

## Limits

- **wss:// only where the game has TLS.** LÖVE's luasocket has no TLS. The
  engine adds a TLS dialer on official Windows builds and on Android, and the
  mod uses it for a `wss://` `SERVER`. Elsewhere (macOS, Linux, handhelds) use
  `ws://`. The public server answers both, and the default `SERVER` is plain
  `ws://` so it works everywhere.
- **Latency.** The protocol aborts a trade if a byte is 0.8 s late. That is
  comfortable up to roughly 300 ms each way and fails past about 350 ms. This
  limit belongs to the protocol and applies to any two clients.
- **Crystal** is covered by the automated tests (its receptionist, mail
  layout and link-mode byte); the live cart tests were run with Gold.
  Silver uses Gold's code paths.
- **The Time Capsule desk** in gen1recomp's Gold/Silver/Crystal is not
  offered (a Gold *cart* can still reach Red/Blue/Yellow here through its
  own Time Capsule).
- **No battles.** The Colosseum uses a different room type and is not offered.
- **FireRed/LeafGreen.** A GBA cannot link-trade with Red/Blue. On
  pokemon.gblink.io, Gen 3 trading runs Lorenzooone's *Pokemon-Gen3-to-Gen-X*
  multiboot program on the GBA in separate Gen 3 rooms. That program can also
  play the part of a Gen 1 cartridge over a GB link cable, which would make it
  a peer here. That combination is untested.
- **Celio** (celio.gblink.io, and the mGBA Lua script that goes with it) is
  the Gen 3 real-time link relay. It carries GBA multiplayer serial, not
  this protocol.

## Credits and license

- [Lorenzooone](https://github.com/Lorenzooone/PokemonGB_Online_Trades_and_Battles):
  the online trade protocol and the server this mod talks to (MIT).
- [GB-Link](https://gblink.io): pokemon.gblink.io and the GB-Link adapter.
- [pret/pokered](https://github.com/pret/pokered): the Cable Club routines
  the party data format comes from.

This mod's code is released under the [MIT License](LICENSE). It contains
no ROM data. It is not affiliated with GB-Link, Nintendo, Creatures Inc. or
GAME FREAK inc.; Pokémon and related names are their property.
