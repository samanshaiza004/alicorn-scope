[CmdletBinding()]
param(
    [string]$AlicornRoot = $env:ALICORN_ROOT,
    [string]$CaliberRoot = $env:CALIBER_ROOT,
    [switch]$DevDeps
)

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ can promote a native program's non-zero exit code to a
# terminating error. Git probes below intentionally use non-zero codes (for
# example, cat-file when a pinned commit has not been fetched yet), so keep
# exit-code handling explicit throughout this resolver.
$PSNativeCommandUseErrorActionPreference = $false
$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LockPath = Join-Path $ScopeRoot 'dependencies.lock.json'
$Lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json
if (-not $AlicornRoot -and $env:ALICORN_ROOT) { $AlicornRoot = $env:ALICORN_ROOT }
if (-not $CaliberRoot -and $env:CALIBER_ROOT) { $CaliberRoot = $env:CALIBER_ROOT }
if (-not $DevDeps -and $env:SCOPE_DEV_DEPS -match '^(1|true|yes)$') { $DevDeps = $true }

$HasOverride = [bool]$AlicornRoot -or [bool]$CaliberRoot
if ($DevDeps -and -not $HasOverride) {
    throw '-DevDeps only applies with -AlicornRoot and/or -CaliberRoot (or their environment variables).'
}

function Invoke-ScopeGit {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$GitArguments,
        [Parameter(Mandatory)][string]$Purpose
    )

    $output = & git -C $Path @GitArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        throw "Git failed while $Purpose in '$Path'.`n$details"
    }
    return (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
}

function Get-ScopeGitRoot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Dependency checkout does not exist: $Path"
    }
    $candidate = (Resolve-Path -LiteralPath $Path).Path
    $gitRoot = Invoke-ScopeGit -Path $candidate -GitArguments @('rev-parse', '--show-toplevel') -Purpose 'locating repository root'
    return (Resolve-Path -LiteralPath $gitRoot).Path
}

function Get-ScopeDirtyStatus {
    param([Parameter(Mandatory)][string]$Path)
    return Invoke-ScopeGit -Path $Path -GitArguments @('status', '--porcelain', '--untracked-files=all') -Purpose 'checking for local edits'
}

function Resolve-ScopeOverride {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][bool]$AllowDevelopment
    )

    $root = Get-ScopeGitRoot -Path $Path
    $actual = Invoke-ScopeGit -Path $root -GitArguments @('rev-parse', 'HEAD') -Purpose 'reading the override revision'
    $dirty = Get-ScopeDirtyStatus -Path $root
    if (-not $AllowDevelopment -and $actual -ne $Revision) {
        throw @"
$Name override does not match dependencies.lock.json.
Expected: $Revision
Found:    $actual

Use the Scope-managed pinned checkout, or pass -DevDeps to intentionally test a local revision.
The override checkout is never changed by Scope.
"@
    }
    if (-not $AllowDevelopment -and $dirty) {
        throw @"
$Name override has uncommitted or untracked changes, so it does not exactly match the lockfile revision.
Use -DevDeps to explicitly allow this local working tree. Scope will not modify it.
"@
    }

    if ($AllowDevelopment) {
        $dirtyLabel = if ($dirty) { ' (working tree dirty)' } else { '' }
        Write-Host "WARNING: development dependency override is not lockfile-reproducible."
        Write-Host "  $Name expected $Revision; using $actual$dirtyLabel"
    } else {
        Write-Host "  $Name pinned override ready: $($actual.Substring(0, 7))"
    }
    return $root
}

function Resolve-ScopeManagedDependency {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$ManagedPath,
        [Parameter(Mandatory)][string]$ManagedRoot
    )

    if (-not (Test-Path -LiteralPath $ManagedPath)) {
        Write-Host "  ${Name}: cloning into $ManagedPath"
        $cloneOutput = & git clone --quiet $Repository $ManagedPath 2>&1
        $cloneExit = $LASTEXITCODE
        if ($cloneExit -ne 0) {
            $details = ($cloneOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine
            throw "$Name clone failed.`n$details"
        }
    }

    $root = Get-ScopeGitRoot -Path $ManagedPath
    $managedPrefix = $ManagedRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $root.StartsWith($managedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name managed checkout resolves outside Scope's .deps directory: $root"
    }

    $origin = Invoke-ScopeGit -Path $root -GitArguments @('remote', 'get-url', 'origin') -Purpose 'checking the managed dependency origin'
    if ($origin -ne $Repository) {
        throw @"
The managed $Name checkout has a different origin.
Expected: $Repository
Found:    $origin
Scope will not repurpose or overwrite it. Move the checkout aside, then rerun bootstrap.
"@
    }

    $dirty = Get-ScopeDirtyStatus -Path $root
    if ($dirty) {
        throw @"
The managed $Name checkout contains local changes:
$dirty

Scope leaves edited dependencies untouched. Commit/stash your work or remove this managed checkout explicitly, then rerun.
"@
    }

    $actual = Invoke-ScopeGit -Path $root -GitArguments @('rev-parse', 'HEAD') -Purpose 'reading the managed dependency revision'
    if ($actual -ne $Revision) {
        Write-Host "  ${Name}: resolving pinned revision $($Revision.Substring(0, 7))"
        $objectSpec = "$Revision^{commit}"
        & git -C $root cat-file -e $objectSpec 2>$null
        $hasCommit = $LASTEXITCODE -eq 0
        if (-not $hasCommit) {
            $fetchOutput = & git -C $root fetch --quiet origin 2>&1
            if ($LASTEXITCODE -ne 0) {
                $details = ($fetchOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine
                throw "$Name fetch failed.`n$details"
            }
            & git -C $root cat-file -e $objectSpec 2>$null
            $hasCommit = $LASTEXITCODE -eq 0
        }
        if (-not $hasCommit) {
            $fetchOutput = & git -C $root fetch --quiet origin $Revision 2>&1
            if ($LASTEXITCODE -ne 0) {
                $details = ($fetchOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine
                throw "$Name could not fetch locked commit $Revision.`n$details"
            }
        }

        $checkoutOutput = & git -C $root checkout --quiet --detach $Revision 2>&1
        if ($LASTEXITCODE -ne 0) {
            $details = ($checkoutOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine
            throw "$Name could not check out locked commit $Revision.`n$details"
        }
    }

    $actual = Invoke-ScopeGit -Path $root -GitArguments @('rev-parse', 'HEAD') -Purpose 'verifying the managed dependency revision'
    if ($actual -ne $Revision) { throw "$Name resolved to $actual instead of locked revision $Revision." }
    Write-Host "  $Name ready: $($Revision.Substring(0, 7))"
    return $root
}

function Resolve-ScopeDependency {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Revision,
        [string]$OverridePath,
        [Parameter(Mandatory)][string]$ManagedRoot,
        [Parameter(Mandatory)][bool]$AllowDevelopment
    )

    if ($Revision -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        throw "The locked $Name revision is not a full Git object ID: $Revision"
    }
    if ($OverridePath) {
        return Resolve-ScopeOverride -Name $Name -Path $OverridePath -Revision $Revision -AllowDevelopment:$AllowDevelopment
    }
    $managedPath = Join-Path $ManagedRoot ($Name.ToLowerInvariant())
    return Resolve-ScopeManagedDependency -Name $Name -Repository $Repository -Revision $Revision -ManagedPath $managedPath -ManagedRoot $ManagedRoot
}

$OverridesSupplied = [bool]$AlicornRoot -or [bool]$CaliberRoot
$ManagedRoot = Join-Path $ScopeRoot '.deps'
New-Item -ItemType Directory -Force -Path $ManagedRoot | Out-Null
$ManagedRoot = (Resolve-Path -LiteralPath $ManagedRoot).Path
$ScopePrefix = $ScopeRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $ManagedRoot.StartsWith($ScopePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Scope's .deps directory resolves outside the repository: $ManagedRoot"
}

Write-Host 'Scope dependencies:'
$resolvedAlicorn = Resolve-ScopeDependency -Name 'Alicorn' -Repository $Lock.alicorn.repository -Revision $Lock.alicorn.revision -OverridePath $AlicornRoot -ManagedRoot $ManagedRoot -AllowDevelopment:$DevDeps
$resolvedCaliber = Resolve-ScopeDependency -Name 'Caliber' -Repository $Lock.caliber.repository -Revision $Lock.caliber.revision -OverridePath $CaliberRoot -ManagedRoot $ManagedRoot -AllowDevelopment:$DevDeps

[pscustomobject]@{
    AlicornRoot = $resolvedAlicorn
    CaliberRoot = $resolvedCaliber
    AlicornRevision = $Lock.alicorn.revision
    CaliberRevision = $Lock.caliber.revision
    DevDeps = [bool]$DevDeps
}
