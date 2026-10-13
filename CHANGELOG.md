# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

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
