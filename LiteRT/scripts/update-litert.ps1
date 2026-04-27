# update-litert.ps1
#
# Bump the LiteRT-LM submodule to a new revision and rebuild.
#
# The revision can be any git ref the submodule's remote knows about:
#   - a tag                (e.g. v0.11.0)
#   - a full commit SHA    (e.g. 4dbbf9375f52ad9738b80c9c1a12d671a0f5ffb6)
#   - a short SHA          (e.g. 4dbbf937)
#   - a branch name        (e.g. main)
#
# Whatever you pass in, the resolved 40-char commit SHA is what gets written
# to LITERT_LM_TAG. We pin to commits, not moving refs.
#
# Usage:
#   .\update-litert.ps1 v0.11.0
#   .\update-litert.ps1 4dbbf9375f52ad9738b80c9c1a12d671a0f5ffb6
#   .\update-litert.ps1 main

param(
    [Parameter(Mandatory=$true)]
    [string]$Ref
)

$ErrorActionPreference = "Stop"

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$SubmoduleDir = Join-Path $WorkspaceDir "vendor\LiteRT-LM"

Write-Host "=== Updating LiteRT-LM to $Ref ===" -ForegroundColor Cyan

Push-Location $SubmoduleDir
try {
    # Fetch tags AND commits — the requested ref might be either.
    git fetch --tags origin
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }

    git checkout $Ref
    if ($LASTEXITCODE -ne 0) {
        throw "git checkout $Ref failed (does the tag / branch / SHA exist on origin?)"
    }

    # Resolve to a 40-char SHA — that's what we record, regardless of whether
    # the caller passed a tag, branch, or short SHA.
    $newSha = (git rev-parse HEAD).Trim()
    Write-Host "Resolved SHA: $newSha"
} finally {
    Pop-Location
}

# Update the plain-text pin file. We always write the resolved SHA so the
# pin is to an immutable commit, not a moving ref.
Set-Content -Path (Join-Path $WorkspaceDir "LITERT_LM_TAG") `
            -Value "$newSha`n" -NoNewline:$false

Write-Host ""
Write-Host "=== Rebuilding (Win64) ===" -ForegroundColor Cyan
& (Join-Path $ScriptDir "build-win64.ps1")
if ($LASTEXITCODE -ne 0) { throw "Win64 rebuild failed" }

Write-Host ""
Write-Host "=== Update complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Run build-android-arm64.ps1 to rebuild Android too (this script"
Write-Host "     only rebuilds Win64; Android is a separate invocation so dev"
Write-Host "     machines without an NDK can still bump the pin)."
Write-Host "  2. Verify the plugin still loads the new DLL in UE."
Write-Host "  3. Commit:  git add LiteRT/vendor/LiteRT-LM LiteRT/LITERT_LM_TAG"
