[CmdletBinding()]
param(
    [string]$AlicornRoot = $env:ALICORN_ROOT,
    [string]$CaliberRoot = $env:CALIBER_ROOT,
    [switch]$DevDeps
)

$ErrorActionPreference = 'Stop'
$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HasOverride = [bool]$AlicornRoot -or [bool]$CaliberRoot
if ($DevDeps -and -not $HasOverride) { throw '-DevDeps requires an ALICORN_ROOT and/or CALIBER_ROOT override.' }

$Arguments = @('sync', '--project-root', $ScopeRoot)
if ($AlicornRoot) { $Arguments += @('--override', "alicorn=$AlicornRoot") }
if ($CaliberRoot) { $Arguments += @('--override', "caliber=$CaliberRoot") }
if ($DevDeps) { $Arguments += '--allow-dirty-overrides' }
$Output = & (Join-Path $PSScriptRoot 'caliber.ps1') @Arguments
if ($LASTEXITCODE -ne 0) { throw "Caliber dependency sync failed with exit code $LASTEXITCODE." }
$Output | ForEach-Object { Write-Host $_ }

function Get-DependencyRoot([string]$Name, [string]$Override) {
    if ($Override) {
        $Path = (& git -C $Override rev-parse --show-toplevel | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Cannot resolve $Name override '$Override'." }
        return (Resolve-Path -LiteralPath $Path).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $ScopeRoot ".deps\$Name")).Path
}

$AlicornPath = Get-DependencyRoot -Name 'alicorn' -Override $AlicornRoot
$CaliberPath = Get-DependencyRoot -Name 'caliber' -Override $CaliberRoot
[pscustomobject]@{
    AlicornRoot = $AlicornPath
    CaliberRoot = $CaliberPath
    AlicornRevision = (& git -C $AlicornPath rev-parse HEAD).Trim()
    CaliberRevision = (& git -C $CaliberPath rev-parse HEAD).Trim()
    DevDeps = [bool]$DevDeps
}
