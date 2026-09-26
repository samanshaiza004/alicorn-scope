[CmdletBinding()]
param(
    [string]$Odin = $env:ALICORN_ODIN,
    [string]$Go = $env:SCOPE_GO,
    [string]$AlicornRoot = $env:ALICORN_ROOT,
    [string]$CaliberRoot = $env:CALIBER_ROOT,
    [switch]$DevDeps
)

$ErrorActionPreference = 'Stop'
$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Resolve-ScopeTool {
    param([Parameter(Mandatory)][string]$Name, [string]$Requested)
    $commandName = if ($Requested) { $Requested } else { $Name }
    if ([IO.Path]::IsPathRooted($commandName)) {
        if (-not (Test-Path -LiteralPath $commandName -PathType Leaf)) { throw "$Name executable not found: $commandName" }
        return (Resolve-Path -LiteralPath $commandName).Path
    }
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    if (-not $command) { throw "$Name was not found. Install it and ensure it is on PATH, then rerun tools/run.ps1." }
    return $command.Source
}

$Git = Resolve-ScopeTool -Name 'Git'
$Cargo = Resolve-ScopeTool -Name 'Cargo'
$Odin = Resolve-ScopeTool -Name 'Odin' -Requested $Odin
if (-not $Go) {
    $go64 = 'C:\Program Files\Go\bin\go.exe'
    if (Test-Path -LiteralPath $go64 -PathType Leaf) { $Go = $go64 } else { $Go = 'go' }
}
$Go = Resolve-ScopeTool -Name 'Go' -Requested $Go
$goArch = (& $Go env GOARCH).Trim()
if ($LASTEXITCODE -ne 0 -or $goArch -ne 'amd64') {
    throw "Scope needs 64-bit Go/cgo on Windows; '$Go' reports GOARCH=$goArch. Install 64-bit Go or set SCOPE_GO to its go.exe."
}

$bootstrap = Join-Path $PSScriptRoot 'bootstrap.ps1'
$resolved = & $bootstrap -AlicornRoot $AlicornRoot -CaliberRoot $CaliberRoot -DevDeps:$DevDeps
if (-not $resolved -or -not $resolved.AlicornRoot -or -not $resolved.CaliberRoot) {
    throw 'Dependency bootstrap did not return both Alicorn and Caliber roots.'
}
$AlicornRoot = $resolved.AlicornRoot
$CaliberRoot = $resolved.CaliberRoot

$caliberHeader = Join-Path $CaliberRoot 'include\caliber.h'
if (-not (Test-Path -LiteralPath $caliberHeader -PathType Leaf) -or
    -not (Select-String -Quiet -Path $caliberHeader -Pattern 'context_wait_wake|context_stop_wake_waiters')) {
    throw 'The resolved Caliber checkout is missing the blocking wake ABI required by Scope.'
}

$out = Join-Path $ScopeRoot 'out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$oldCgo = $env:CGO_ENABLED
$oldCgoCFlags = $env:CGO_CFLAGS
$oldCache = $env:GOCACHE
$oldTelemetry = $env:GOTELEMETRY
Push-Location $ScopeRoot
try {
    $env:CGO_ENABLED = '1'
    $includePath = ($CaliberRoot.Replace('\', '/') + '/include')
    $env:CGO_CFLAGS = (($oldCgoCFlags + ' -I' + $includePath).Trim())
    $env:GOCACHE = Join-Path $out 'go-cache'
    $env:GOTELEMETRY = 'off'

    Write-Host 'Building Caliber FFI...'
    & $Cargo build --release --manifest-path (Join-Path $CaliberRoot 'Cargo.toml') -p caliber-ffi
    if ($LASTEXITCODE -ne 0) { throw "Caliber build failed with exit code $LASTEXITCODE." }

    Write-Host 'Building Scope Go backend...'
    & $Go build -buildmode=c-shared -o (Join-Path $out 'scope_backend.dll') ./backend/bridge
    if ($LASTEXITCODE -ne 0) { throw "Scope backend build failed with exit code $LASTEXITCODE." }

    Write-Host 'Building Alicorn Scope...'
    $collection = "-collection:alicorn=$AlicornRoot"
    & $Odin build . $collection "-out:$(Join-Path $out 'alicorn-scope.exe')"
    if ($LASTEXITCODE -ne 0) { throw "Alicorn Scope build failed with exit code $LASTEXITCODE." }

    $caliberDll = Join-Path $CaliberRoot 'target\release\caliber_ffi.dll'
    if (-not (Test-Path -LiteralPath $caliberDll -PathType Leaf)) { throw "Caliber DLL not found: $caliberDll" }
    Copy-Item -LiteralPath $caliberDll -Destination (Join-Path $out 'caliber_ffi.dll') -Force
    $odinRoot = Split-Path -Parent $Odin
    $sdlDll = Join-Path $odinRoot 'vendor\sdl3\SDL3.dll'
    if (-not (Test-Path -LiteralPath $sdlDll -PathType Leaf)) { throw "SDL3.dll was not found in the Odin distribution at $sdlDll" }
    Copy-Item -LiteralPath $sdlDll -Destination (Join-Path $out 'SDL3.dll') -Force
    Write-Host "Build complete: $(Join-Path $out 'alicorn-scope.exe')"
} finally {
    Pop-Location
    if ($null -eq $oldCgo) { Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue } else { $env:CGO_ENABLED = $oldCgo }
    if ($null -eq $oldCgoCFlags) { Remove-Item Env:CGO_CFLAGS -ErrorAction SilentlyContinue } else { $env:CGO_CFLAGS = $oldCgoCFlags }
    if ($null -eq $oldCache) { Remove-Item Env:GOCACHE -ErrorAction SilentlyContinue } else { $env:GOCACHE = $oldCache }
    if ($null -eq $oldTelemetry) { Remove-Item Env:GOTELEMETRY -ErrorAction SilentlyContinue } else { $env:GOTELEMETRY = $oldTelemetry }
}
