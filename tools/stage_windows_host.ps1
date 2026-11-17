param(
  [string]$OutDir,
  [string]$HostExe,
  [switch]$Build,
  [string]$Kernel = $env:JJBOX_KERNEL,
  [string]$Go = "go"
)

# Stages the Windows core host next to the Flutter runner. The app's
# HostSupervisor looks for `core_host_libbox.exe` first, then `core_host.exe`,
# and starts it with --pipe/--data/--parent-pid; this script is the packaging
# step that puts the binary where the supervisor looks.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $Root "build\windows\host" }
if (-not $HostExe) { $HostExe = Join-Path $Root "windows\core_host\core_host_libbox.exe" }

if ($Build) {
  if (-not $Kernel) { throw "Pass -Kernel <path> or set JJBOX_KERNEL when using -Build" }
  & (Join-Path $PSScriptRoot "build_core_host_libbox.ps1") -Kernel $Kernel -Go $Go
  if ($LASTEXITCODE -ne 0) { throw "build_core_host_libbox.ps1 failed with exit $LASTEXITCODE" }
}
if (-not (Test-Path -LiteralPath $HostExe)) {
  throw "host binary not found: $HostExe (build it first or pass -Build -Kernel <path>)"
}

$selftest = & $HostExe --selftest 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "host selftest failed: $($selftest -join ' ')"
}
if (-not ($selftest -match "SELFTEST OK")) {
  throw "host selftest did not report OK: $($selftest -join ' ')"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$target = Join-Path $OutDir "core_host.exe"
Copy-Item -LiteralPath $HostExe -Destination $target -Force
$size = (Get-Item -LiteralPath $target).Length
$hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
Write-Host "staged: $target"
Write-Host ("source: {0}" -f (Resolve-Path -LiteralPath $HostExe).Path)
Write-Host ("bytes: {0}" -f $size)
Write-Host ("sha256: {0}" -f $hash)
Write-Host "The Flutter runner directory must contain core_host.exe next to the app executable."
