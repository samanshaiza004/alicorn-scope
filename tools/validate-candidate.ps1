param()

$ErrorActionPreference = 'Stop'
$ScopeRoot = $env:CALIBER_PROJECT_ROOT
if (-not $ScopeRoot) { throw 'CALIBER_PROJECT_ROOT was not supplied by Caliber.' }
$Candidate = $env:CALIBER_CANDIDATE_ROOT
if (-not $Candidate) { throw 'CALIBER_CANDIDATE_ROOT was not supplied by Caliber.' }

$AlicornRoot = if ($env:CALIBER_DEPENDENCY -eq 'alicorn') { $Candidate } else { Join-Path $ScopeRoot '.deps\alicorn' }
$CaliberRoot = if ($env:CALIBER_DEPENDENCY -eq 'caliber') { $Candidate } else { Join-Path $ScopeRoot '.deps\caliber' }
& (Join-Path $ScopeRoot 'tools\build.ps1') -AlicornRoot $AlicornRoot -CaliberRoot $CaliberRoot -DevDeps
if ($LASTEXITCODE -ne 0) { throw "Scope candidate build failed with exit code $LASTEXITCODE." }
