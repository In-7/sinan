<#
.SYNOPSIS
  Offline backup for the sinan repo: full git history + working tree + vendored-editor history.

.DESCRIPTION
  Why `git bundle` instead of copying the .git directory:
    - .git is thousands of tiny files: slow to copy, leaves a broken half-copy when the
      copy is interrupted, and tiny files are the first thing to rot on cloud or
      removable drives;
    - `git bundle` is one self-contained file holding every ref and tag, and it restores
      with a single `git clone <bundle> <dir>`.

  Three artifacts, all under -Target:
    1. repo/sinan-<timestamp>.bundle  full history (keeps the newest -KeepBundles files);
    2. worktree/                      working-tree mirror, INCLUDING uncommitted and
                                      untracked files (excludes rebuildable output);
    3. vendored-history/              history backup of the former nested repo that used
                                      to live at third_party/appflowy_editor.

  ASCII ONLY ON PURPOSE: Windows PowerShell 5.1 decodes a BOM-less file with the ANSI
  codepage (GBK on this machine), so any CJK text in this script breaks parsing with
  mojibake errors. Do not add non-ASCII characters here.

  The working-tree step uses robocopy /MIR so that deletions propagate, which is why the
  script refuses to run when -Target is inside the repo or is a drive root.

  git only protects against "I changed the wrong thing"; it does NOT protect against
  "the disk died". Point -Target at a SECOND physical disk, and pass -Cloud for one more
  copy inside a synced folder.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools/backup.ps1 -Target "E:\sinan-backups"
  powershell -ExecutionPolicy Bypass -File tools/backup.ps1 -Target "E:\sinan-backups" -Cloud "$env:USERPROFILE\OneDrive\sinan-backups"
#>
param(
  [string]$Repo = "D:\Asinan\sinan",
  [Parameter(Mandatory = $true)][string]$Target,
  [string[]]$VendoredBackups = @("$env:USERPROFILE\sinan-repo-backups"),
  [string]$Cloud = "",
  [int]$KeepBundles = 10
)

$ErrorActionPreference = "Stop"

# --- Path guards (before the log file, which lives under Target) ---
$fullTarget = [System.IO.Path]::GetFullPath($Target)
$fullRepo = [System.IO.Path]::GetFullPath($Repo)
if ($fullTarget -eq $fullRepo -or $fullRepo.StartsWith($fullTarget + [System.IO.Path]::DirectorySeparatorChar)) {
  throw "Refusing to run: -Target is inside the repo ($fullTarget)"
}
if ($fullTarget -eq [System.IO.Path]::GetPathRoot($fullTarget)) {
  throw "Refusing to run: -Target is a drive root ($fullTarget)"
}

New-Item -ItemType Directory -Force -Path $fullTarget | Out-Null
$logPath = Join-Path $fullTarget "backup.log"
function Write-Log([string]$Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Write-Host $line
  Add-Content -Path $logPath -Value $line -Encoding UTF8
}

Write-Log "Backup start: $fullRepo -> $fullTarget"

# --- 1) Full repo history as a single bundle (all refs and tags) ---
$repoDir = Join-Path $fullTarget "repo"
New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bundle = Join-Path $repoDir "sinan-$stamp.bundle"
git -C $fullRepo bundle create $bundle --all
if ($LASTEXITCODE -ne 0) { throw "git bundle failed (exit=$LASTEXITCODE)" }
Write-Log ("History bundle: {0} ({1} MB)" -f (Split-Path $bundle -Leaf), [math]::Round((Get-Item $bundle).Length / 1MB, 2))

# Keep only the newest -KeepBundles files (each bundle is a complete snapshot).
$old = Get-ChildItem (Join-Path $repoDir "sinan-*.bundle") |
  Sort-Object LastWriteTime -Descending |
  Select-Object -Skip $KeepBundles
foreach ($f in $old) {
  Remove-Item $f.FullName -Force
  Write-Log "Pruned old bundle: $($f.Name)"
}

# --- 2) Working tree mirror (uncommitted work included; .git and build output excluded) ---
$worktree = Join-Path $fullTarget "worktree"
robocopy $fullRepo $worktree /MIR /XD .git build .dart_tool .idea /XF *.log /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy (worktree) failed (exit=$LASTEXITCODE)" }
Write-Log "Working tree mirrored to $worktree"

# --- 3) Vendored editor: history of the former nested repo at third_party/appflowy_editor ---
if ($VendoredBackups.Count -gt 0) {
  $vendoredDir = Join-Path $fullTarget "vendored-history"
  New-Item -ItemType Directory -Force -Path $vendoredDir | Out-Null
  foreach ($src in $VendoredBackups) {
    if (-not (Test-Path $src)) { Write-Log "Skipped (missing): $src"; continue }
    robocopy $src $vendoredDir /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy (vendored history) failed (exit=$LASTEXITCODE)" }
    Write-Log "Vendored history mirrored from $src"
  }
}

# --- 4) Optional: one more copy inside a synced folder ---
if ($Cloud -ne "") {
  New-Item -ItemType Directory -Force -Path $Cloud | Out-Null
  robocopy $fullTarget $Cloud /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy (cloud) failed (exit=$LASTEXITCODE)" }
  Write-Log "Cloud copy written to $Cloud"
}

Write-Log "Backup finished (OK)"
