# GB-Link Online Trades

Trade Pokémon at the Cable Club with a real Game Boy (on a GB-Link adapter), an
emulator (BGB) or another copy of this game, over the internet, in the same
five-digit rooms that [pokemon.gblink.io](https://pokemon.gblink.io) uses.

**Persona: the Bridge Builder.** The engine already has a full Trade Center
(pick, STATS, confirm, the trade animation, trade evolutions, the autosave).
This mod gives it a different kind of peer and changes no game rules.

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

At any Pokémon Center, talk to the Cable Club receptionist, say YES to the
save, then pick **GB-LINK ONLINE** and enter a room number (Up/Down change
a digit, Left/Right move between digits). Both players must type the same
number. Newer engine builds move the receptionist upstairs: take the stairs
next to the old desk.

The other player:

- **Real Game Boy:** go to pokemon.gblink.io, choose *Gen 1* and *Link Trade*,
  connect the GB-Link adapter, enter the **same room number**, and talk to the
  Cable Club receptionist on the cartridge.
- **Emulator (BGB):** run [Lorenzooone's PokemonGB client](https://github.com/Lorenzooone/PokemonGB_Online_Trades_and_Battles)
  as BGB's link partner: `python emulator_trade_battle.py -g 1 -t 2P -r <room> -efc`,
  then start BGB with `-connect 127.0.0.1:8765` (or BGB's Link > Connect).
  GB-Link's BGB desktop app does the same through pokemon.gblink.io, but its
  download was unavailable when this was written.
- **Python client with a real Game Boy:** the same client's `usb_trade_battle.py`
  with a GB-Link adapter, link trade, Gen 1, the same room.
- **This game:** both players pick GB-LINK ONLINE and type the same room.

When both players are in, the other player sits at the Trade Center table and
this game opens its own Trade Center screen. Several trades can happen in one
visit. **B** at the trade menu cancels. **END LINK** answers CANCEL until the
other player leaves too.

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
```

The protocol tests run on a simulated clock. A fake trade server
(`tests/fake_relay.lua`) adds latency and jitter, and `tests/fake_peer.lua`
models the far player's client and Game Boy.

`tests/e2e/` is a live test: a real cartridge in BGB trades with this game
over the real server, and both saves are then checked with PKHeX. It has
passed both ways against Red (in the real game window and headless), Blue,
Yellow, and Gold through the Time Capsule (trade evolutions, OT/ID, DVs,
stat exp, moves, nickname, catch-rate byte, and the Time Capsule's held item
<-> catch rate conversion). See `tests/e2e/README.md`.

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

The trade server only forwards messages. Each client drives its own Game Boy
and sends the other client:

1. The party block, in **sync** mode as 8-byte SNG1 windows that track the
   far Game Boy byte by byte, or in **buffered** mode as one FLL1. This game
   adopts whichever mode the other player chose, so nobody is asked to switch.
2. A pick (CHC1), a yes/no (ACP1), then ASK1 and SUC1 to close a trade.
3. One MVS1 per later round. No party is re-sent after a trade: both sides
   rebuild it the way the cartridge does, with the traded mon at the **end**
   of the party. That is why a mon received here is moved to the end too.

The engine's own `LinkState` runs the Trade Center. `lib/bridge.lua` answers
its `hello` with a mirror image, so the compatibility verdict is "full". It
then translates `party`/`pick`/`confirm`/`bye` to and from the messages above.

## Limits

- **wss:// only where the game has TLS.** LÖVE's luasocket has no TLS. The
  engine adds a TLS dialer on official Windows builds and on Android, and the
  mod uses it for a `wss://` `SERVER`. Elsewhere (macOS, Linux, handhelds) use
  `ws://`. The public server answers both, and the default `SERVER` is plain
  `ws://` so it works everywhere.
- **Latency.** The protocol aborts a trade if a byte is 0.8 s late. That is
  comfortable up to roughly 300 ms each way and fails past about 350 ms. This
  limit belongs to the protocol and applies to any two clients.
- **Gen 1 games only.** The mod runs in gen1recomp's Red, Blue and Yellow.
  Gold/Silver/Crystal *cartridges* trade with it through their Time Capsule
  (tested: Gold in BGB). gen1recomp's own Gold/Silver/Crystal mode has no
  Cable Club yet, so the mod does not load there.
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
