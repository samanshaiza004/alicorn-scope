[CmdletBinding()]
param(
    [string]$Trace = '',
    [switch]$Smoke,
    [switch]$Help,
    [string]$Odin = $env:ALICORN_ODIN,
    [string]$Go = $env:SCOPE_GO,
    [string]$AlicornRoot = $env:ALICORN_ROOT,
    [string]$CaliberRoot = $env:CALIBER_ROOT,
    [switch]$DevDeps
)

$ErrorActionPreference = 'Stop'
if ($Trace -and (Test-Path -LiteralPath $Trace -PathType Leaf)) {
    $Trace = (Resolve-Path -LiteralPath $Trace).Path
}
$buildArguments = @{ Odin = $Odin; Go = $Go; AlicornRoot = $AlicornRoot; CaliberRoot = $CaliberRoot; DevDeps = $DevDeps }
& (Join-Path $PSScriptRoot 'build.ps1') @buildArguments

$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $ScopeRoot 'out\alicorn-scope.exe'
$appArguments = @()
if ($Help) { $appArguments += '--help' }
if ($Smoke) { $appArguments += '--smoke' }
if ($Trace) { $appArguments += $Trace }
Push-Location (Join-Path $ScopeRoot 'out')
try {
    & $exe @appArguments
    if ($LASTEXITCODE -ne 0) { throw "Alicorn Scope exited with code $LASTEXITCODE." }
} finally {
    Pop-Location
}
