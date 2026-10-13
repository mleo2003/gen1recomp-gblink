#!/usr/bin/env bash
# Run gen1recomp (the real game window) under a separate LÖVE identity, so a
# trade test never touches your own saves, options or mods.
#
#   tests/e2e/play.sh <engine checkout> [identity]
#
# The identity's folder is where LÖVE keeps it when run from source:
#   macOS   ~/Library/Application Support/LOVE/<identity>
#   Linux   ~/.local/share/love/<identity>
#   Windows %APPDATA%\LOVE\<identity>
# First time: import the ROM (POKEPORT_IMPORT_ROM, below), unzip the mod's
# release into <folder>/mods/gblink, enable it for Red (the MODS panel, or
# modsByVersion.red.gblink = true in <folder>/options.lua) and drop a save
# from gen_saves.lua in as <folder>/saves/red/slot1.lua.
set -euo pipefail
engine="${1:?usage: play.sh <engine checkout> [identity]}"
identity="${2:-pokemon-love2d-gblinktest}"
love_bin="$(command -v love || true)"
for app in "/Applications/love.app" "$HOME/Applications/love.app"; do
  [ -z "$love_bin" ] && [ -x "$app/Contents/MacOS/love" ] && love_bin="$app/Contents/MacOS/love"
done
[ -n "$love_bin" ] || { echo "LÖVE 11.5 not found (https://github.com/love2d/love/releases/tag/11.5)" >&2; exit 1; }
cd "$engine"
if [ -n "${POKEPORT_IMPORT_ROM:-}" ]; then
  # one-off: build this identity's ROM cache headlessly, then quit
  POKEPORT_IDENTITY="$identity" POKEPORT_IMPORT_ONLY=1 "$love_bin" .
  exit
fi
POKEPORT_IDENTITY="$identity" exec "$love_bin" .
