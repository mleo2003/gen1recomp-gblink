# Live trade test: emulator ↔ gen1recomp, checked with PKHeX

A real Pokémon Red cartridge image in BGB trades with gen1recomp over the
public trade server. Both saves are then read with PKHeX.Core and checked.

```
BGB (Pokémon Red) ⇄ PokemonGB client ⇄ pokemon-gb-online-trades server ⇄ gen1recomp + gblink
       Windows        (BGB link, TCP)                (ws://)                  any desktop
```

## What it showed (2026-10-13)

| Run | Emulator side | gen1recomp side | Result |
|---|---|---|---|
| Lorenzooone client + headless `recomp_headless.lua` | BGB 1.6.6, Red (USA) | engine + mod, no window | PASS both sides |
| Lorenzooone client + the real game window | BGB 1.6.6, Red (USA) | LÖVE 11.5, release zip 0.1.0 | PASS both sides |
| Lorenzooone client + headless | BGB 1.6.6, Blue (USA) | Blue | PASS both sides |
| Lorenzooone client + headless | BGB 1.6.6, Yellow (USA) | Yellow | PASS both sides |
| Lorenzooone client + headless, Time Capsule | BGB 1.6.6, Gold (USA) | Red | PASS both sides |
| two copies of the mod, one over `wss://` (engine TLS dialer, macOS build) | — | Red | trade completed |

In the Time Capsule run, Gold's HAUNTER (holding a BERRY) went to
gen1recomp's Red and arrived as GENGAR with catch-rate byte 173, and RECOMP's
MACHOKE arrived on the Gold cart as MACHAMP holding item 0xB4: both exactly
what PKHeX's own Gen 1 <-> Gen 2 conversion predicts, and both legal.

In each Gen 1 run, EMU's KADABRA "SPOONY" went to gen1recomp and arrived as
ALAKAZAM, and RECOMP's MACHOKE arrived on the cartridge as MACHAMP. In both
directions the OT, ID, DVs, stat exp, EXP, moves, PP, nickname and catch-rate
byte were kept, and PKHeX rates each arrival legal. The untouched party slots
were byte-for-byte unchanged, and each arrival was filed at the end of the
party, as the cartridge does it.

## The pieces

| File | What it does |
|---|---|
| `gen_saves.lua` | Writes two test saves standing at Viridian's Cable Club: `emu_red.sav` (a cartridge save for BGB) and `recomp_slot1.lua` (a gen1recomp slot), plus `recomp_before.sav` for checking. It round-trips both through the engine's importer. |
| `gen_saves_gsc.lua` | A Gold/Silver/Crystal cartridge save standing at the Time Capsule receptionist (Pokémon Center 2F, 13,4) with the capsule open and a Time-Capsule-legal party. Gold/Silver mons come out PKHeX-legal; Crystal ones lack caught data, so PKHeX flags them. |
| `savecheck/` | Uses PKHeX.Core 26.8.26 (.NET 10). `show` lists a Gen 1 or Gen 2 save; `trade mine_before mine_after theirs_before` checks a trade from one side, across generations too (held item <-> catch rate checked against PKHeX's conversion). |
| `recomp_headless.lua` | gen1recomp's side without a window: the engine, `main.lua`, real luasocket and the real server. It trades one slot and writes `recomp_after.sav`. |
| `play.sh` | Runs the real game window under a separate LÖVE identity. |
| `windows/start-emulator.ps1` | Starts Lorenzooone's client and BGB linked to it, in a given room. |
| `bgb-bridge/` | GB-Link's own web client (gb-pokemon-web) driving BGB, without the GB-Link BGB desktop app. See the caveat below. |

## Setting up

**Saves.** Run from the engine root:

```sh
POKEPORT_DATA_DIR=<cache>/data/generated luajit <mod>/tests/e2e/gen_saves.lua <out dir> [red|blue|yellow]
luajit <mod>/tests/e2e/gen_saves_gsc.lua <gold cache> <out dir> gold      # Time Capsule test
```

`recomp_headless.lua` reads the game from the slot it is given, so pointing
`POKEPORT_DATA_DIR` at the Blue or Yellow cache and handing it that game's
slot runs gen1recomp's Blue or Yellow.

**Emulator machine (Windows).** Use `C:\gblink-test`:

- `bgb\`: [BGB](https://bgb.bircd.org/) 1.6.x (`bgbw64.zip`).
- `roms\red.gb`: your own ROM. Add `roms\red.sav`, which is `emu_red.sav` renamed.
- `PokemonGB_Online_Trades_and_Battles\`: a clone of
  [Lorenzooone's client](https://github.com/Lorenzooone/PokemonGB_Online_Trades_and_Battles).
- `pyenv\`: `py -3.12 -m venv pyenv` then `pyenv\Scripts\pip install -r <client>\requirements_local.txt`.
- `dotnet\`: the .NET 10 SDK, via `dotnet-install.ps1 -Channel 10.0 -InstallDir C:\gblink-test\dotnet`.
  Then build `savecheck` with `dotnet build -c Release`, and run it as
  `dotnet savecheck.dll …` with `DOTNET_ROOT` set to that folder.

**gen1recomp machine.** Install LÖVE 11.5 and use `play.sh`; its header
lists the one-time setup. The engine import cache is versioned, so a cache
built by an older engine is refused ("ROM REQUIRED"). Re-import it with
`POKEPORT_IMPORT_ROM=<rom> tests/e2e/play.sh <engine>`.

## A trade, by hand

1. **Emulator.** Run `start-emulator.ps1 -Room 12345`. In BGB, choose
   CONTINUE and talk to the Cable Club receptionist (the right-hand desk).
   Answer YES to the save, pick TRADE CENTER, then face the table and
   press A.
   BGB's default keys are the arrows for the D-pad, `S` for A, `A` for B
   and Enter for Start.
2. **gen1recomp.** Run `tests/e2e/play.sh <engine>`.
   - This engine build moves the Cable Club upstairs: take the new stairs
     next to the old desk and talk to the right-hand receptionist.
   - Save, then pick **GB-LINK ONLINE**. Enter the same room (Up/Down change
     a digit, Left/Right move between digits) and press A.
3. **Both sides.** Pick a Pokémon and TRADE, then confirm. Afterwards, B or
   CANCEL ends the link.
4. **Close BGB** (its window, not the process), so it writes `red.sav`. The
   game already saved after the trade.
5. **Check both sides.** First export gen1recomp's slot to a cartridge save:

   ```sh
   RED_CACHE=<identity>/red luajit tools/save_convert/convert.lua export <identity>/saves/red/slot1.lua recomp_after.sav red
   ```

   Then run the trade check on each side:

   ```sh
   savecheck trade emu_before.sav    emu_after.sav    recomp_before.sav
   savecheck trade recomp_before.sav recomp_after.sav emu_before.sav
   ```

   A pass ends with `PASS` and exit code 0.

## Caveats found along the way

- **Gold asks to overwrite the save.** At the Time Capsule's save prompt a
  generated Gold save gets "There is already a save file. Is it OK to
  overwrite?" (answer YES). The generator writes the main copy only, so the
  cart sees a different file in its backup slot. Harmless for the test.
- **Time Capsule order.** The receptionist checks the party, links ("Please
  wait."), asks to save, then says "Please come in." Inside, walk to the empty
  stool (two right, three up) and face the table (Left), then press A.

- **No GB-Link BGB app.** gblink.io/bgb points at a GitHub releases page
  that returns 404 (checked 2026-10-13).
  - `bgb-bridge/` stands in for the app: `shim.js` provides the page's
    `window.gblinkBGB`, and `bridge.js` relays it to BGB.
  - It works, but BGB only runs while each of its timestamp pings is
    answered, and every answer crosses the browser. In the link loops BGB
    ran at about 9–68% speed.
  - At the slow end the web client began a section on a stray `0xFE` byte,
    which shifted every later section. gen1recomp then read the party one
    block late ("a party of 0") and stopped. A real cartridge on the far end
    would have received the same garbage.
  - **For emulator tests, use Lorenzooone's client.** It talks to BGB
    directly over TCP and kept the game near full speed.
- **Edge throttling.** Edge (or Chrome) throttles a covered window's timers.
  `bridge.js` users should start the browser with
  `--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling`.
- **BGB stops listening.** BGB started with `-listen` doesn't listen again
  once a link drops. Restart it, or start it with `-connect` toward a side
  that listens.
