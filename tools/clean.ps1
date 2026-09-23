[CmdletBinding()]
param(
    [switch]$Deps,
    [switch]$ForceDeps
)

$ErrorActionPreference = 'Stop'
$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($ForceDeps -and -not $Deps) { throw '-ForceDeps requires -Deps.' }

function Assert-ScopeChild {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to remove reparse point: $Path" }
    $actual = (Resolve-Path -LiteralPath $Path).Path
    if (-not [string]::Equals($actual, $Expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unexpected cleanup target '$actual' (expected '$Expected')."
    }
}

$dependencyTargets = @()
if ($Deps) {
    $deps = Join-Path $ScopeRoot '.deps'
    if (Test-Path -LiteralPath $deps) {
        Assert-ScopeChild -Path $deps -Expected $deps
        $dependencyTargets = @('alicorn', 'caliber') | ForEach-Object { Join-Path $deps $_ } | Where-Object { Test-Path -LiteralPath $_ }
        foreach ($target in $dependencyTargets) {
            Assert-ScopeChild -Path $target -Expected $target
            if (-not (Test-Path -LiteralPath (Join-Path $target '.git') -PathType Container)) {
                throw "Refusing to remove an unrecognized .deps entry: $target. Inspect and remove that path explicitly if it is disposable."
            }
            $repositoryRoot = & git -C $target rev-parse --show-toplevel 2>&1
            if ($LASTEXITCODE -ne 0 -or -not [string]::Equals((Resolve-Path -LiteralPath (($repositoryRoot | Select-Object -First 1))).Path, (Resolve-Path -LiteralPath $target).Path, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove a dependency path that is not its own Git repository: $target"
            }
            $status = & git -C $target status --porcelain --untracked-files=all 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Could not inspect managed dependency before cleanup: $target`n$($status -join [Environment]::NewLine)" }
            if ($status -and -not $ForceDeps) {
                throw "$target has local edits. Preserve them, or explicitly pass -ForceDeps to remove this managed checkout."
            }
        }
    }
}

# Validate every requested target before removing any of them.
$out = Join-Path $ScopeRoot 'out'
if (Test-Path -LiteralPath $out) { Assert-ScopeChild -Path $out -Expected $out }

if (Test-Path -LiteralPath $out) {
    Remove-Item -LiteralPath $out -Recurse -Force
    Write-Host "Removed generated output: $out"
}
foreach ($target in $dependencyTargets) {
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Host "Removed managed dependency: $target"
}
