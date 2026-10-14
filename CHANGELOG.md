# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

## 0.3.0

### Added

- **Gold, Silver and Crystal.** The Pokémon Center 2F Trade Center desk
  opens a GB-Link room (pokemon.gblink.io's *Gen 2* rooms). The cart's own
  receptionist script runs; the mod fills in its cable steps
  (`WaitForLinkedFriend`, the link checks, `TradeCenter`, `CloseLink`) and
  brings the table: both parties, STATS, TRADE, the confirm, then the
  engine's Gen 2 trade animation, trade evolution (Everstone and held-item
  rules) and the autosave. Mail travels with its Pokémon.
- The Gen 2 online trade protocol (`/link2/`): party, patch list and mail
  sections in sync or buffered mode, CHC2 / ACP2 / ASK2 / SUC2 / MVS2.

### Changed

- An offered Pokémon is looked up in this side's copy of the other party
  (strong match, then a match that ignores OT and nickname, as the Python
  client does it), and that copy is what trades. An offer that matches
  nothing is declined. Seen live: the Python client, re-reading its own
  cart over BGB's link, offered a mon with a mangled OT and nickname. Red,
  Blue and Yellow get the same protection.
- A CANCEL from either side ends the trade menu for both, as on the carts.
  If the other client lets its player pick again anyway, the pick is
  answered with CANCEL while the link lingers.

### Tested

- Live, Gold in gen1recomp against a Gold cart in BGB at the Trade Center,
  both in the real game window and headless: ONIX holding a Metal Coat
  arrived as STEELIX (item used), MACHOKE arrived on the cart as MACHAMP,
  and offering the fresh STEELIX back for the cart's HAUNTER worked. Both
  saves pass PKHeX's checks (`tests/e2e/`).

## 0.2.0

### Added

- `wss://` servers, through the engine's TLS dialer (`love.system.tls*`) on
  the builds that have one: official Windows builds and Android. Elsewhere a
  `wss://` `SERVER` stops at a message asking for `ws://` instead of failing
  to connect. Tested live: one player over `wss://`, one over `ws://`, same
  room, a full trade.

### Tested

- Live trades against real Blue and Yellow carts in BGB, and against a real
  Gold cart through the Time Capsule, all checked with PKHeX on both sides
  (`tests/e2e/`). The Time Capsule's held item <-> catch-rate conversion
  matches PKHeX's.

## 0.1.2

### Fixed

- The room-number screen offers the last room you dialled again. Mod
  storage only keeps data-only tables, and the room was written as a plain
  string, so the write was refused and every visit started at 00000.
  `tests/ingame_test.lua` now checks that a second visit gets the room
  back.

## 0.1.1

### Fixed

- Text on the CABLE CLUB and room-number screens no longer runs off the
  right edge ("Game Boy or emulator", "Link Trade on").

### Changed

- `exports.version` comes from the manifest, so it always matches the
  release.
- README: the tested emulator route (BGB with Lorenzooone's PokemonGB
  client), the room-number controls, and the Cable Club's place upstairs in
  newer engine builds.

### Tested

- A live trade between Pokémon Red in BGB and gen1recomp passed in both
  directions: trade evolutions, OT/ID, DVs, stat exp, moves, nickname and
  catch-rate byte all kept, and both saves pass PKHeX's checks
  (`tests/e2e/`).

## 0.1.0

### Added

- GB-LINK ONLINE at the Cable Club receptionist, next to the LAN cable.
- The Pokemon GB online trade protocol 4.1 (Gen 1): room pairing, version
  and buffered/sync agreement, SNG1 section sync, FLL1 buffered data,
  CHC1 / ACP1 / ASK1 / SUC1 / MVS1, several trades per visit.
- `SERVER` mod option.
