<#
.SYNOPSIS
  Runs AIMod's tests headlessly: the unit tests (-Unit) or the AIPlay
  scenario with a real player (default).

.DESCRIPTION
  The Steam build of Factorio refuses to start its GUI outside of Steam, but
  headless modes work. The script copies the mod into a temp work folder
  (your %APPDATA%\Factorio saves, settings and mod list are never touched),
  appends a test entry point to the copy's control.lua and starts
  `factorio --test-scenario AIMod/AIPlay` (headless, with a player).

  -Unit: tests/unit_runner.lua runs tests/unit/*_test.lua on the first tick,
    with the bot switched off. Takes a few seconds.
  default: tests/scenario_test.lua lets the bot play, once per map seed,
    until it completes its goals or -Ticks pass, and prints its progress.

  Exit code is 0 when everything passed, 1 otherwise.

  Runs on Windows PowerShell 5.1 (Steam build, the default -Factorio) and on
  PowerShell 7 elsewhere, e.g. Linux with the headless server build from
  factorio.com (pass -Factorio or set FACTORIO); CI does the latter, see
  .github/workflows/tests.yml.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1 -Unit
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1 -Seed "1234567,42,987654,2024" -Brief
.EXAMPLE
  pwsh tools/run-headless.ps1 -Factorio ~/factorio/bin/x64/factorio -Unit
#>
param(
  # run the unit tests instead of playing the scenario
  [switch]$Unit,
  # comma separated, one run per seed; same seed = same map, so runs are
  # comparable (a string because `powershell -File` can't pass arrays)
  [string]$Seed = "1234567",
  # give up after this many ticks (60 per second of game time)
  [int]$Ticks = 36000,
  # the game's bin/x64/factorio(.exe); default: $env:FACTORIO, else the Steam
  # install on Windows
  [string]$Factorio = $env:FACTORIO,
  [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) "aimod-headless"),
  # print every goal transition instead of the first/last few
  [switch]$Full,
  # one result line per seed; with -Unit only failures and the summary
  [switch]$Brief,
  # every tick, before the bot runs, move the player's selection onto some
  # other nearby entity (like a mouse moving over things) and fail if the
  # character mines anything the bot didn't target
  [switch]$CursorNoise,
  # the first time the bot is about to mine, fill every empty slot of its
  # inventory with stone bricks; it has to put them away to go on
  [switch]$FullInventory
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $Factorio) {
  if (-not $onWindows) { throw "Pass -Factorio <path to bin/x64/factorio> or set FACTORIO" }
  $Factorio = "C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe"
}
if (-not (Test-Path -LiteralPath $Factorio -PathType Leaf)) { throw "Factorio executable not found: $Factorio" }
$Factorio = (Resolve-Path -LiteralPath $Factorio).Path
# config.ini below points read-data at bin/x64/../../data, as in every build
$gameData = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Factorio))) "data"

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

# top-level entries that aren't part of the mod (.claude holds other worktrees)
$notMod = @(".git", ".github", ".claude", ".vscode", "tools", "PR_NOTES.md", "PLAN.md")
Get-ChildItem -LiteralPath $repo -Force |
  Where-Object { $notMod -notcontains $_.Name -and $_.Extension -ne ".zip" } |
  ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $modCopy -Recurse -Force }
$entryPoint = if ($Unit) { "tests/unit_runner" } else { "tests/scenario_test" }
Add-Content -Path (Join-Path $modCopy "control.lua") -Value "`r`nrequire '$entryPoint'" -Encoding Ascii

$cfg = Join-Path $WorkDir "config.ini"
@"
[path]
read-data=__PATH__executable__/../../data
write-data=$($data -replace '\\', '/')
"@ | Set-Content -Encoding Ascii $cfg
# Only base and AIMod. The headless server build also ships the expansion mods
# (space-age, quality, ...) and would enable them unless they are listed as off.
$modList = @(@{ name = "base"; enabled = $true }, @{ name = "AIMod"; enabled = $true })
Get-ChildItem -LiteralPath $gameData -Directory |
  Where-Object { $_.Name -ne "base" -and $_.Name -ne "core" -and (Test-Path (Join-Path $_.FullName "info.json")) } |
  ForEach-Object { $modList += @{ name = $_.Name; enabled = $false } }
ConvertTo-Json -Depth 3 @{ mods = $modList } | Set-Content -Encoding Ascii (Join-Path $mods "mod-list.json")

$testPrefix = '^\s*[\d.]+ Script @__AIMod__/tests/scenario_test\.lua:\d+: \[test\] '
$errorPattern = '^\s*[\d.]+ Error|non-recoverable|Error while running'
$botLogPath = Join-Path (Join-Path $data "script-output") "output.log"
$failed = 0

# On GitHub Actions: failures become annotations, results go to the job summary.
$inActions = $env:GITHUB_ACTIONS -eq "true"
function Write-Annotation([string]$title, [string]$message) {
  if (-not $inActions) { return }
  $t = $title -replace '%', '%25' -replace ',', '%2C' -replace ':', '%3A'
  $m = $message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
  Write-Host "::error title=${t}::$m"
}
function Write-JobSummary([string[]]$lines) {
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $lines -Encoding UTF8 }
}

# --- unit tests ----------------------------------------------------------------
if ($Unit) {
  $runLog = Join-Path $WorkDir "unit.log"
  $all = @("--config", "`"$cfg`"", "--mod-directory", "`"$mods`"",
    "--test-scenario", "AIMod/AIPlay", "--test-ticks", "600")
  $p = Start-Process -FilePath $Factorio -ArgumentList $all -NoNewWindow -Wait -PassThru -RedirectStandardOutput $runLog
  $lines = @(Get-Content $runLog -Encoding UTF8)

  # "[unit] ..." lines; a failure's traceback follows on lines without a timestamp
  $unitPrefix = '^\s*[\d.]+ Script @__AIMod__/[^:]+:\d+: \[unit\] '
  $results = New-Object System.Collections.Generic.List[string]
  $inEntry = $false
  foreach ($line in $lines) {
    if ($line -match $unitPrefix) { $results.Add(($line -replace $unitPrefix, '')); $inEntry = $true }
    elseif ($inEntry -and $line -notmatch '^\s*[\d.]+ ') { $results[$results.Count - 1] += "`n" + $line }
    else { $inEntry = $false }
  }
  foreach ($entry in $results) {
    if ($entry -match '^FAIL') { Write-Host $entry -ForegroundColor Red }
    elseif ($entry -match '^SUMMARY') { }
    elseif (-not $Brief) { Write-Host $entry -ForegroundColor DarkGray }
  }

  $summary = $results | Where-Object { $_ -match '^SUMMARY' } | Select-Object -First 1
  $errors = @($lines | Where-Object { $_ -match $errorPattern })
  if ($p.ExitCode -ne 0 -or $errors.Count -gt 0 -or -not $summary) {
    if ($summary) { Write-Host $summary -ForegroundColor Red }
    else {
      Write-Host "Unit tests did not run to the end (exit $($p.ExitCode))" -ForegroundColor Red
      if ($errors.Count -gt 0) { $errors | Select-Object -First 10 } else { $lines | Select-Object -Last 20 }
    }
    foreach ($entry in $results) { if ($entry -match '^FAIL') { Write-Annotation "unit test" $entry } }
    if (-not $summary) { Write-Annotation "unit tests" "did not run to the end (exit $($p.ExitCode))" }
    Write-JobSummary @("### Unit tests", "", "FAILED: $(if ($summary) { $summary } else { "did not run to the end" })", "")
    exit 1
  }
  Write-Host $summary -ForegroundColor Green
  Write-JobSummary @("### Unit tests", "", $summary, "")
  exit 0
}

$runs = New-Object System.Collections.Generic.List[object]
foreach ($s in ($Seed -split ',' | ForEach-Object { [uint32]$_.Trim() })) {
  $runLog = Join-Path $WorkDir "run-$s.log"
  if (Test-Path $botLogPath) { [System.IO.File]::Delete($botLogPath) } # see the 8.3 note above
  if (-not $Brief) { Write-Host "== seed $s, up to $Ticks ticks ($([math]::Round($Ticks / 60)) s of game time)" -ForegroundColor Cyan }

  $all = @("--config", "`"$cfg`"", "--mod-directory", "`"$mods`"",
    "--test-scenario", "AIMod/AIPlay", "--test-ticks", "$Ticks", "--map-gen-seed", "$s")
  $flags = @()
  if ($CursorNoise) { $flags += "cursor-noise" }
  if ($FullInventory) { $flags += "full-inventory" }
  if ($flags) { $all += @("--test-arg", ($flags -join ",")) }
  $p = Start-Process -FilePath $Factorio -ArgumentList $all -NoNewWindow -Wait -PassThru -RedirectStandardOutput $runLog
  $lines = @(Get-Content $runLog -Encoding UTF8)
  $test = @($lines | Where-Object { $_ -match $testPrefix } | ForEach-Object { $_ -replace $testPrefix, '' })
  $errors = @($lines | Where-Object { $_ -match $errorPattern })
  $completed = $test | Where-Object { $_ -match '^COMPLETED' } | Select-Object -First 1

  if (-not $Brief) {
    $transitions = @($test | Where-Object { $_ -match ' goal -> ' })
    Write-Host "-- goal transitions ($($transitions.Count) logged)" -ForegroundColor Cyan
    if ($Full -or $transitions.Count -le 60) { $transitions }
    else {
      $transitions | Select-Object -First 30
      "   ... $($transitions.Count - 60) more ..."
      $transitions | Select-Object -Last 30
    }
    Write-Host "-- snapshots and events" -ForegroundColor Cyan
    $test | Where-Object { $_ -notmatch ' goal -> ' }
    Write-Host "-- bot output.log (most frequent lines)" -ForegroundColor Cyan
    $botLog = @(if (Test-Path $botLogPath) { Get-Content $botLogPath -Encoding UTF8 })
    "$($botLog.Count) lines"
    $botLog | Group-Object | Sort-Object Count -Descending | Select-Object -First 12 |
      ForEach-Object { "{0,7} x {1}" -f $_.Count, $_.Name }
  }

  if ($p.ExitCode -ne 0 -or $errors.Count -gt 0) {
    $failed++
    Write-Host "seed ${s}: FAILED (exit $($p.ExitCode))" -ForegroundColor Red
    $explained = @($test | Where-Object { $_ -match 'STORAGE PROBLEM|^GAVE UP|^UNINTENDED|^MINED THE WRONG|^cursor noise|^FULL INVENTORY|^full inventory|^DIED' })
    $explained
    $errors | Select-Object -First 10
    if ($errors.Count -eq 0 -and $explained.Count -eq 0) { $lines | Select-Object -Last 15 }
    $why = @($explained + $errors + "exit code $($p.ExitCode)")[0]
    $runs.Add([pscustomobject]@{ Seed = $s; Result = "FAILED: $why"; Ticks = $null })
  } elseif ($completed) {
    $extra = @($test | Where-Object { $_ -match '^cursor noise|^full inventory' })
    Write-Host ((@("seed ${s}: OK, $completed") + $extra) -join "; ") -ForegroundColor Green
    $ticksTaken = if ($completed -match 't=(\d+)') { [int]$Matches[1] } else { $null }
    $runs.Add([pscustomobject]@{ Seed = $s; Result = "OK"; Ticks = $ticksTaken })
  } else {
    $failed++
    $last = $test | Where-Object { $_ -match ' pos=' } | Select-Object -Last 1
    Write-Host "seed ${s}: NOT COMPLETED within $Ticks ticks; last snapshot: $last" -ForegroundColor Yellow
    $runs.Add([pscustomobject]@{ Seed = $s; Result = "NOT COMPLETED within $Ticks ticks"; Ticks = $null })
  }
}

# total ticks over the seeds is what PLAN.md compares against its baseline
$ok = @($runs | Where-Object { $_.Result -eq "OK" })
$total = ($ok | Measure-Object -Property Ticks -Sum).Sum
$mode = "scenario"
if ($CursorNoise) { $mode += " -CursorNoise" }
if ($FullInventory) { $mode += " -FullInventory" }
$tally = "$($ok.Count) of $($runs.Count) seeds completed, $(if ($total) { $total } else { 0 }) ticks in total"
if ($runs.Count -gt 1) { Write-Host $tally -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" }) }
foreach ($r in $runs) { if ($r.Result -ne "OK") { Write-Annotation "$mode seed $($r.Seed)" $r.Result } }
Write-JobSummary (@("### $mode", "", $tally, "", "| seed | result | ticks |", "|---:|---|---:|") +
  @($runs | ForEach-Object { "| $($_.Seed) | $($_.Result -replace '\|', '/') | $($_.Ticks) |" }) + "")

if (-not $Brief) { Write-Host "Full logs: $WorkDir" }
if ($failed -gt 0) { exit 1 }
