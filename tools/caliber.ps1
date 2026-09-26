[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CaliberArguments)

$ErrorActionPreference = 'Stop'
$ScopeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$CaliberCli = $env:CALIBER_CLI
if (-not $CaliberCli) {
    $onPath = Get-Command caliber -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) { $CaliberCli = $onPath.Source }
}

if (-not $CaliberCli) {
    $Git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $Git) { throw 'Git is required to bootstrap Caliber. Install Git and retry.' }
    $Cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $Cargo) { throw 'Cargo is required to bootstrap Caliber. Install Rust/Cargo and retry.' }

    $Revision = (Get-Content -Raw -LiteralPath (Join-Path $ScopeRoot '.caliber-cli-revision')).Trim()
    if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Malformed Caliber CLI bootstrap revision.' }
    $Repository = if ($env:CALIBER_CLI_REPOSITORY) { $env:CALIBER_CLI_REPOSITORY } else { 'https://github.com/samanshaiza004/caliber.git' }
    $ToolsRoot = Join-Path $ScopeRoot '.tools'
    $SourceRoot = Join-Path $ToolsRoot 'caliber-cli-source'
    New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        New-Item -ItemType Directory -Path $SourceRoot | Out-Null
        & $Git.Source -C $SourceRoot init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the Caliber CLI bootstrap checkout.' }
        & $Git.Source -C $SourceRoot remote add origin $Repository
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the Caliber CLI bootstrap remote.' }
    } else {
        $Origin = (& $Git.Source -C $SourceRoot remote get-url origin 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $Origin -ne $Repository) { throw "Caliber CLI bootstrap origin mismatch at $SourceRoot; inspect it instead of replacing it." }
        $Dirty = (& $Git.Source -C $SourceRoot status --porcelain --untracked-files=all | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Caliber CLI bootstrap checkout.' }
        if ($Dirty) { throw "Caliber CLI bootstrap checkout is dirty at $SourceRoot; it was left untouched." }
    }

    & $Git.Source -C $SourceRoot cat-file -e "$Revision^{commit}" 2>$null
    $HasCommit = $LASTEXITCODE -eq 0
    if (-not $HasCommit) {
        & $Git.Source -C $SourceRoot fetch --quiet origin $Revision
        $FetchCode = $LASTEXITCODE
        & $Git.Source -C $SourceRoot cat-file -e "$Revision^{commit}" 2>$null
        $HasCommit = $LASTEXITCODE -eq 0
        if (-not $HasCommit -and $FetchCode -ne 0) {
            & $Git.Source -C $SourceRoot fetch --quiet origin main
            & $Git.Source -C $SourceRoot cat-file -e "$Revision^{commit}" 2>$null
            $HasCommit = $LASTEXITCODE -eq 0
        }
    }
    if (-not $HasCommit) { throw "Pinned Caliber CLI commit is unavailable from ${Repository}: ${Revision}" }
    $HeadOutput = & $Git.Source -C $SourceRoot rev-parse --verify HEAD 2>$null
    $Head = if ($LASTEXITCODE -eq 0) { ($HeadOutput | Out-String).Trim() } else { '' }
    if ($Head -ne $Revision) {
        & $Git.Source -C $SourceRoot checkout --quiet --detach $Revision
        if ($LASTEXITCODE -ne 0) { throw 'Could not check out the pinned Caliber CLI source.' }
    }

    & $Cargo.Source build --locked --release --manifest-path (Join-Path $SourceRoot 'Cargo.toml') -p caliber --bin caliber
    if ($LASTEXITCODE -ne 0) { throw 'Building the pinned Caliber CLI failed.' }
    $CaliberCli = Join-Path $SourceRoot 'target\release\caliber.exe'
    if (-not (Test-Path -LiteralPath $CaliberCli -PathType Leaf)) { throw "Caliber CLI binary was not produced: $CaliberCli" }
}

& $CaliberCli @CaliberArguments
if ($LASTEXITCODE -ne 0) { throw "Caliber CLI exited with code $LASTEXITCODE." }
