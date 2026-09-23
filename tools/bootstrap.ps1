[CmdletBinding()]
param(
    [string]$AlicornRoot = $env:ALICORN_ROOT,
    [string]$CaliberRoot = $env:CALIBER_ROOT,
    [switch]$DevDeps
)

$ErrorActionPreference = 'Stop'
$resolved = & (Join-Path $PSScriptRoot 'dependencies.ps1') -AlicornRoot $AlicornRoot -CaliberRoot $CaliberRoot -DevDeps:$DevDeps
Write-Host "Ready: Alicorn $($resolved.AlicornRevision.Substring(0, 7)); Caliber $($resolved.CaliberRevision.Substring(0, 7))"
return $resolved
