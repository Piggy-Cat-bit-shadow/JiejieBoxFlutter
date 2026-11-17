param(
  [string]$Configuration = "Debug",
  [string]$BuildDir = "",
  [switch]$Install,
  [string]$CMake = ""
)

# Builds the full Windows app without relying on flutter_tools' Visual Studio
# component check. The Visual Studio 2022 generator is used directly; CMake can
# come from PATH, the Python user scripts directory, or -CMake.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $BuildDir) { $BuildDir = Join-Path $Root "build\windows_manual" }

if (-not $CMake) {
  $command = Get-Command cmake.exe -ErrorAction SilentlyContinue
  if ($command) {
    $CMake = $command.Source
  } else {
    $candidate = Join-Path $env:APPDATA "Python\Python312\Scripts\cmake.exe"
    if (Test-Path -LiteralPath $candidate) { $CMake = $candidate }
  }
}
if (-not $CMake -or -not (Test-Path -LiteralPath $CMake)) {
  throw "cmake.exe not found; install it (pip install cmake) or pass -CMake"
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
& $CMake -S (Join-Path $Root "windows") -B $BuildDir -G "Visual Studio 17 2022" -A x64
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

$target = if ($Install) { "INSTALL" } else { "jiejiebox_flutter" }
& $CMake --build $BuildDir --config $Configuration --target $target
if ($LASTEXITCODE -ne 0) { throw "cmake build failed: $LASTEXITCODE" }

$bundle = Join-Path $BuildDir "runner\$Configuration"
Write-Host "bundle: $bundle"
Write-Host "stage the linked host next to the app with:"
Write-Host "  tools\stage_windows_host.ps1 -OutDir `"$bundle`""
