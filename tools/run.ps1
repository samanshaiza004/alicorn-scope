param(
    [string]$Trace = '',
    [switch]$Smoke,
    [string]$Odin = $env:ALICORN_ODIN,
    [string]$Go = $env:SCOPE_GO
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build.ps1') -Odin $Odin -Go $Go
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $ScopeRoot 'out\alicorn-scope.exe'
$args = @()
if ($Smoke) { $args += '--smoke' }
if ($Trace) { $args += $Trace }
Push-Location (Join-Path $ScopeRoot 'out')
try { & $exe @args; exit $LASTEXITCODE }
finally { Pop-Location }
