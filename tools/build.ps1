param(
    [string]$Odin = $env:ALICORN_ODIN,
    [string]$Go = $env:SCOPE_GO,
    [string]$AlicornRoot = $env:ALICORN_ROOT,
    [string]$CaliberRoot = $env:CALIBER_ROOT
)

$ErrorActionPreference = 'Stop'
$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $AlicornRoot) { $AlicornRoot = Join-Path $ScopeRoot '..\alicorn' }
if (-not $CaliberRoot) { $CaliberRoot = Join-Path $ScopeRoot '..\caliber' }
$AlicornRoot = (Resolve-Path $AlicornRoot).Path
$CaliberRoot = (Resolve-Path $CaliberRoot).Path

$lock = Get-Content -Raw (Join-Path $ScopeRoot 'dependencies.lock.json') | ConvertFrom-Json
foreach ($dependency in @(@{ name='Alicorn'; path=$AlicornRoot; revision=$lock.alicorn.revision }, @{ name='Caliber'; path=$CaliberRoot; revision=$lock.caliber.revision })) {
    $actual = (& git -C $dependency.path rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $dependency.revision) {
        throw "$($dependency.name) checkout must be at pinned revision $($dependency.revision); found $actual"
    }
}
if (-not (Select-String -Quiet -Path (Join-Path $CaliberRoot 'crates\caliber-ffi\src\lib.rs') -Pattern 'context_wait_wake|context_stop_wake_waiters')) {
    throw 'Caliber wake ABI changes are missing. Apply the Scope Phase 1 wake patch before building.'
}

if (-not $Odin) { $Odin = 'odin' }
if ([IO.Path]::IsPathRooted($Odin)) {
    if (-not (Test-Path -LiteralPath $Odin -PathType Leaf)) { throw "Odin executable not found: $Odin" }
} else {
    $odinCommand = Get-Command $Odin -ErrorAction SilentlyContinue
    if (-not $odinCommand) { throw "Odin executable not found: $Odin" }
    $Odin = $odinCommand.Source
}

if (-not $Go) {
    $go64 = 'C:\Program Files\Go\bin\go.exe'
    if (Test-Path -LiteralPath $go64 -PathType Leaf) { $Go = $go64 }
    else { $Go = 'go' }
}
if ([IO.Path]::IsPathRooted($Go)) {
    if (-not (Test-Path -LiteralPath $Go -PathType Leaf)) { throw "Go executable not found: $Go" }
} else {
    $goCommand = Get-Command $Go -ErrorAction SilentlyContinue
    if (-not $goCommand) { throw "Go executable not found: $Go" }
    $Go = $goCommand.Source
}
$goArch = (& $Go env GOARCH).Trim()
if ($LASTEXITCODE -ne 0 -or $goArch -ne 'amd64') { throw "Scope requires 64-bit Go/cgo on Windows; selected GOARCH=$goArch" }

$out = Join-Path $ScopeRoot 'out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$oldCgo = $env:CGO_ENABLED
$oldCache = $env:GOCACHE
$oldTelemetry = $env:GOTELEMETRY
try {
    $env:CGO_ENABLED = '1'
    $env:GOCACHE = Join-Path $out 'go-cache'
    $env:GOTELEMETRY = 'off'
    & cargo build --release --manifest-path (Join-Path $CaliberRoot 'Cargo.toml') -p caliber-ffi
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $Go build -buildmode=c-shared -o (Join-Path $out 'scope_backend.dll') ./backend/bridge
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $Odin build . -out:(Join-Path $out 'alicorn-scope.exe')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $caliberDll = Join-Path $CaliberRoot 'target\release\caliber_ffi.dll'
    if (-not (Test-Path -LiteralPath $caliberDll -PathType Leaf)) { throw "Caliber DLL not found: $caliberDll" }
    Copy-Item -LiteralPath $caliberDll -Destination (Join-Path $out 'caliber_ffi.dll') -Force
    $odinRoot = Split-Path -Parent $Odin
    $sdlDll = Join-Path $odinRoot 'vendor\sdl3\SDL3.dll'
    if (-not (Test-Path -LiteralPath $sdlDll -PathType Leaf)) { throw "SDL3.dll was not found at $sdlDll" }
    Copy-Item -LiteralPath $sdlDll -Destination (Join-Path $out 'SDL3.dll') -Force
} finally {
    $env:CGO_ENABLED = $oldCgo
    $env:GOCACHE = $oldCache
    $env:GOTELEMETRY = $oldTelemetry
}
