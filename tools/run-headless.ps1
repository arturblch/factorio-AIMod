<#
.SYNOPSIS
  Runs AIMod headlessly with tests/harness.lua and prints a summary.

.DESCRIPTION
  The Steam build of Factorio refuses to start its GUI outside of Steam, but
  headless modes work. This script:
    1. copies the mod into a temp work folder (your %APPDATA%\Factorio saves,
       settings and mod list are never touched),
    2. appends `require 'tests/harness'` to the copy's control.lua,
    3. creates a map with --create (the harness sets the bot up in on_init),
    4. loads that save with --benchmark and runs it for -Ticks ticks,
    5. prints the [harness] log lines and the bot's own output.log summary.
  Exit code is 1 when Factorio failed or logged an error.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1 -Ticks 72000 -Full
#>
param(
  [int]$Ticks = 18000,
  # same seed = same map, so runs are comparable; pass another one to test other terrain
  [uint32]$Seed = 1234567,
  [string]$Factorio = "C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe",
  [string]$WorkDir = (Join-Path $env:TEMP "aimod-headless"),
  # print every goal transition instead of the first/last few
  [switch]$Full
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

# --- fresh work folder (plain copies only, so deleting it is safe) ----------
if (Test-Path $WorkDir) {
  $links = Get-ChildItem $WorkDir -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue
  if ($links) { throw "$WorkDir contains junctions/symlinks, refusing to delete it: $($links[0].FullName)" }
  # .NET instead of Remove-Item: PowerShell 5.1 chokes on 8.3 short paths
  # such as C:\Users\ANNAPC~1 that %TEMP% often contains
  [System.IO.Directory]::Delete($WorkDir, $true)
}
$mods = Join-Path $WorkDir "mods"
$data = Join-Path $WorkDir "data"
$modCopy = Join-Path $mods "AIMod"
New-Item -ItemType Directory -Force $modCopy, $data | Out-Null

robocopy $repo $modCopy /E /XD .git .vscode tools /XF PR_NOTES.md *.zip /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }
Add-Content -Path (Join-Path $modCopy "control.lua") -Value "`r`nrequire 'tests/harness'" -Encoding Ascii

$cfg = Join-Path $WorkDir "config.ini"
@"
[path]
read-data=__PATH__executable__/../../data
write-data=$($data -replace '\\', '/')
"@ | Set-Content -Encoding Ascii $cfg
'{"mods":[{"name":"base","enabled":true},{"name":"AIMod","enabled":true}]}' |
  Set-Content -Encoding Ascii (Join-Path $mods "mod-list.json")

function Invoke-Factorio([string[]]$FactorioArgs, [string]$OutFile) {
  $all = @("--config", "`"$cfg`"", "--mod-directory", "`"$mods`"") + $FactorioArgs
  $p = Start-Process -FilePath $Factorio -ArgumentList $all -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $OutFile
  return $p.ExitCode
}

function Get-Lines([string]$File) {
  if (Test-Path $File) { return @(Get-Content $File -Encoding UTF8) } else { return @() }
}

$harnessPrefix = '^\s*[\d.]+ Script @__AIMod__/tests/harness\.lua:\d+: \[harness\] '
$errorPattern = '^\s*[\d.]+ Error|non-recoverable|Error while running'

# --- 1. create the map ------------------------------------------------------
$save = Join-Path $data "saves\harness.zip"
$createLog = Join-Path $WorkDir "create.log"
Write-Host "== create map" -ForegroundColor Cyan
$createExit = Invoke-Factorio @("--create", "`"$save`"", "--map-gen-seed", "$Seed") $createLog
$createLines = Get-Lines $createLog
$createLines | Where-Object { $_ -match $harnessPrefix } | ForEach-Object { $_ -replace $harnessPrefix, '' }
$createErrors = @($createLines | Where-Object { $_ -match $errorPattern })
if ($createExit -ne 0 -or $createErrors.Count -gt 0) {
  Write-Host "Map creation failed (exit $createExit):" -ForegroundColor Red
  $createLines | Select-Object -Last 25
  exit 1
}

# --- 2. load it and run ------------------------------------------------------
$runLog = Join-Path $WorkDir "run.log"
Write-Host "== run $Ticks ticks ($([math]::Round($Ticks / 60)) s of game time)" -ForegroundColor Cyan
$runExit = Invoke-Factorio @("--benchmark", "`"$save`"", "--benchmark-ticks", "$Ticks", "--benchmark-runs", "1") $runLog
$runLines = Get-Lines $runLog

$harness = @($runLines | Where-Object { $_ -match $harnessPrefix } | ForEach-Object { $_ -replace $harnessPrefix, '' })
$transitions = @($harness | Where-Object { $_ -match ' goal -> ' })
$other = @($harness | Where-Object { $_ -notmatch ' goal -> ' })

Write-Host "-- goal transitions ($($transitions.Count) logged)" -ForegroundColor Cyan
if ($Full -or $transitions.Count -le 60) {
  $transitions
} else {
  $transitions | Select-Object -First 30
  "   ... $($transitions.Count - 60) more ..."
  $transitions | Select-Object -Last 30
}
Write-Host "-- snapshots and events" -ForegroundColor Cyan
$other

Write-Host "-- bot output.log (most frequent lines)" -ForegroundColor Cyan
$botLog = Get-Lines (Join-Path $data "script-output\output.log")
"$($botLog.Count) lines"
$botLog | Group-Object | Sort-Object Count -Descending | Select-Object -First 12 |
  ForEach-Object { "{0,7} x {1}" -f $_.Count, $_.Name }

$runErrors = @($runLines | Where-Object { $_ -match $errorPattern })
$perf = $runLines | Where-Object { $_ -match 'Performed \d+ updates' }
Write-Host "-- result" -ForegroundColor Cyan
if ($perf) { $perf.Trim() }
if ($runExit -ne 0 -or $runErrors.Count -gt 0) {
  Write-Host "FAILED (exit $runExit)" -ForegroundColor Red
  $runErrors | Select-Object -First 10
  if ($runErrors.Count -eq 0) { $runLines | Select-Object -Last 25 }
  exit 1
}
if ($harness -match '^COMPLETED') { Write-Host "OK: bot completed its goals" -ForegroundColor Green }
else { Write-Host "OK: no errors, goals not completed yet" -ForegroundColor Yellow }
Write-Host "Full logs: $WorkDir"
