param(
  [string]$Kernel = $env:JJBOX_KERNEL,
  [string]$Out = "",
  [string]$Go = "go",
  [string]$Arch = "arm64",
  [string]$Tags = "libbox,with_quic,with_wireguard,with_utls,with_clash_api"
)

# Cross-builds the proxy-only macOS helper from the same Go host source used on
# Windows. The helper is a normal Mach-O binary; the macOS app spawns it and
# talks line-delimited JSON over a short Unix socket.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $Root "build\macos_helper\jjbox-core-helper" }
if (-not $Kernel) { throw "Pass -Kernel <path> or set JJBOX_KERNEL" }
$Kernel = (Resolve-Path -LiteralPath $Kernel).Path
if (-not (Test-Path -LiteralPath (Join-Path $Kernel "experimental\libbox"))) {
  throw "Kernel at $Kernel has no experimental/libbox"
}
$goCmd = Get-Command $Go -ErrorAction SilentlyContinue
if (-not $goCmd) { throw "Go toolchain not found: $Go" }

$Work = Join-Path $Root "build\macos_helper_src"
if (Test-Path -LiteralPath $Work) { Remove-Item -Recurse -Force -LiteralPath $Work }
New-Item -ItemType Directory -Force -Path $Work, (Split-Path -Parent $Out) | Out-Null
Get-ChildItem -LiteralPath (Join-Path $Root "windows\core_host") -Filter "*.go" -File |
  Where-Object { $_.Name -notlike "*_test.go" } |
  ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Work }

$kernelMod = Get-Content -LiteralPath (Join-Path $Kernel "go.mod")
$replaces = $kernelMod | Where-Object { $_ -like "replace *" }
$header = @(
  "module github.com/piggycat/jiejiebox/corehost",
  "",
  "go 1.25.5",
  "",
  "require github.com/sagernet/sing-box v0.0.0",
  "require golang.org/x/sys v0.49.0",
  "",
  "replace github.com/sagernet/sing-box => $Kernel",
  ""
)
[System.IO.File]::WriteAllText(
  (Join-Path $Work "go.mod"),
  ((($header + $replaces) -join "`n") + "`n"),
  (New-Object System.Text.UTF8Encoding($false))
)

Push-Location $Work
try {
  $env:GOTOOLCHAIN = "local"
  $env:GOFLAGS = "-mod=mod"
  $env:CGO_ENABLED = "0"
  $env:GOOS = "darwin"
  $env:GOARCH = $Arch
  & $goCmd.Source build -trimpath -buildvcs=false -tags $Tags -o $Out .
  if ($LASTEXITCODE -ne 0) { throw "go build darwin/$Arch failed with exit $LASTEXITCODE" }
} finally {
  Remove-Item Env:\GOOS, Env:\GOARCH, Env:\CGO_ENABLED -ErrorAction SilentlyContinue
  Pop-Location
}
Write-Host "built: $Out"
Write-Host ("kernel: {0} @ {1}" -f $Kernel, (git -C $Kernel rev-parse HEAD))
