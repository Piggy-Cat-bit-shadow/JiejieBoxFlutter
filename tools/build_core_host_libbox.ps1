param(
  [string]$Kernel = $env:JJBOX_KERNEL,
  [string]$Out,
  [string]$Go = "go",
  [string]$Tags = "libbox,with_purego,with_quic,with_wireguard,with_utls,with_clash_api"
)

# Builds the Windows host with the real kernel linked. The committed module stays
# dependency-free; this script creates a throwaway module whose go.mod points at a
# read-only kernel checkout that already has B's flutter-api patch applied, copies in
# every kernel replace directive (fork pins), and builds with the libbox tag.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $Root "windows\core_host\core_host_libbox.exe" }
if (-not $Kernel) {
  throw "Pass -Kernel <path> or set JJBOX_KERNEL to a kernel checkout with B's patch applied"
}
$Kernel = (Resolve-Path -LiteralPath $Kernel).Path
if (-not (Test-Path -LiteralPath (Join-Path $Kernel "experimental\libbox"))) {
  throw "Kernel at $Kernel has no experimental/libbox; apply OUTPUT/B/P4/GO_BRANCH_DIFF.patch first"
}
$goCmd = Get-Command $Go -ErrorAction SilentlyContinue
if (-not $goCmd) { throw "Go toolchain not found: $Go" }

$Work = Join-Path $Root "build\core_host_libbox"
if (Test-Path -LiteralPath $Work) { Remove-Item -Recurse -Force -LiteralPath $Work }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
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
  "require github.com/Microsoft/go-winio v0.6.4",
  "require golang.org/x/sys v0.49.0",
  "",
  "replace github.com/sagernet/sing-box => $Kernel",
  ""
)
$content = (($header + $replaces) -join "`n") + "`n"
[System.IO.File]::WriteAllText((Join-Path $Work "go.mod"), $content, (New-Object System.Text.UTF8Encoding($false)))

Push-Location $Work
try {
  $env:GOTOOLCHAIN = "local"
  $env:GOFLAGS = "-mod=mod"
  & $goCmd.Source build -tags $Tags -o $Out .
  if ($LASTEXITCODE -ne 0) { throw "go build -tags libbox failed with exit $LASTEXITCODE" }
} finally {
  Pop-Location
}
Write-Host "built: $Out"
Write-Host ("kernel: {0} @ {1}" -f $Kernel, (git -C $Kernel rev-parse HEAD))
