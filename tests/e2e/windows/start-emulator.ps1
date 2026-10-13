# Start the emulator side of a live trade test on Windows: Lorenzooone's
# PokemonGB client as BGB's link partner in <Room>, then BGB connected to it.
#
#   powershell -ExecutionPolicy Bypass -File start-emulator.ps1 -Room 12345
#
# Expects the layout in tests/e2e/README.md (Root = C:\gblink-test):
#   bgb\bgb64.exe, roms\red.gb (+ red.sav), pyenv\ (venv with the client's
#   requirements_local.txt), PokemonGB_Online_Trades_and_Battles\
param(
  [Parameter(Mandatory = $true)][string]$Room,
  [string]$Root = "C:\gblink-test"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force "$Root\logs" | Out-Null
Get-Process bgb64 -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
  Where-Object { $_.CommandLine -like "*emulator_trade_battle*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# the client listens on localhost:8765 for BGB; -efc is its fast emulator link
Start-Process -FilePath "$Root\pyenv\Scripts\python.exe" `
  -WorkingDirectory "$Root\PokemonGB_Online_Trades_and_Battles" `
  -ArgumentList "-u emulator_trade_battle.py -g 1 -t 2P -r $Room -efc" `
  -RedirectStandardOutput "$Root\logs\py.log" -RedirectStandardError "$Root\logs\py.err"
Start-Sleep -Seconds 2
Start-Process -FilePath "$Root\bgb\bgb64.exe" -WorkingDirectory "$Root\bgb" `
  -ArgumentList "-rom `"$Root\roms\red.gb`" -connect 127.0.0.1:8765"
"Room $Room: BGB is linking to the PokemonGB client. Its log: $Root\logs\py.log"
