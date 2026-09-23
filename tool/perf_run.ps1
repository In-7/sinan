# Performance baseline: fixtures -> collect -> clean -> print numbers
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/perf_run.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/perf_run.ps1 -Db <sinan.db>
#
# Steps: (1) generate fixtures via test/perf/fixture_generator.dart
#        (2) flutter drive --profile, sampling sinan.exe peak working set from outside
#        (3) clean fixtures (self-verified)
#        (4) print frame numbers from build/*.timeline_summary.json
#
# WARNING: it really opens the app window and drives it with synthetic events
# (no headless mode on desktop - that is what makes frame numbers real).
#
# NOTE: this file is ASCII-only ON PURPOSE. Windows PowerShell 5.1 reads BOM-less
# files as ANSI, which turns Chinese comments into mojibake and breaks parsing.
# Chinese docs live in docs/perf_baseline.md.
param(
    [string]$Db = ''
)

$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..'))

$make = @('--dart-define=SINAN_FIXTURES=make')
$clean = @('--dart-define=SINAN_FIXTURES=clean')
if ($Db -ne '') {
    $make += "--dart-define=SINAN_DB=$Db"
    $clean += "--dart-define=SINAN_DB=$Db"
}

Write-Host '[1/4] generating fixtures...' -ForegroundColor Cyan
& flutter test test/perf/fixture_generator.dart @make
if ($LASTEXITCODE -ne 0) { throw 'fixture generation failed' }

Write-Host '[2/4] collecting (profile mode; the app window will open)...' -ForegroundColor Cyan
# `flutter drive` is required here because `flutter test` has no `--profile`
# (debug-only), and debug frame numbers are not comparable. The driver itself is
# a no-op: on desktop the integration_test reporting channel is broken
# ("plugin was not detected"), so the TEST writes build/perf/*.json itself.
$drive = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList '/c', 'flutter drive --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart --profile -d windows' `
    -PassThru -NoNewWindow

# Memory peak is sampled from OUTSIDE: on Windows Dart's ProcessInfo.currentRss
# always returns 0 (not implemented in the SDK, no exception thrown).
$peak = 0
while (-not $drive.HasExited) {
    $app = Get-Process -Name sinan -ErrorAction SilentlyContinue
    if ($app) {
        $ws = ($app | Measure-Object -Property WorkingSet64 -Maximum).Maximum
        if ($ws -gt $peak) { $peak = $ws }
    }
    Start-Sleep -Milliseconds 400
}
$driveExit = $drive.ExitCode

Write-Host '[3/4] cleaning fixtures...' -ForegroundColor Cyan
& flutter test test/perf/fixture_generator.dart @clean

Write-Host ''
Write-Host ('peak working set: {0:N1} MB' -f ($peak / 1MB)) -ForegroundColor Green
Write-Host ''
Write-Host '[4/4] scene numbers:' -ForegroundColor Cyan
$files = Get-ChildItem build/perf/*.json -ErrorAction SilentlyContinue
if (-not $files) {
    Write-Host '  no scene json found - collection probably failed (see output above)' -ForegroundColor Yellow
}
foreach ($f in $files) {
    $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
    Write-Host ('  {0,-18} build avg/p90/worst {1,5:N1}/{2,5:N1}/{3,5:N1} ms   raster avg/p90/worst {4,5:N1}/{5,5:N1}/{6,5:N1} ms   missed(build/raster) {7}/{8}   frames {9}' -f `
            $s.scene, `
        $s.build_avg_ms, $s.build_p90_ms, $s.build_worst_ms, `
        $s.raster_avg_ms, $s.raster_p90_ms, $s.raster_worst_ms, `
        $s.missed_frames_build, $s.missed_frames_raster, `
        $s.frames)
}
Write-Host ''
Write-Host "collect exit code: $driveExit"
Write-Host 'cold start: run "flutter run --profile --trace-startup" separately'
Write-Host 'NOTE: reuse the same machine/build mode when comparing across phases.'
