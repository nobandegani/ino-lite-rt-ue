# clean.ps1
#
# Wipe the Bazel build cache for both build workspaces. Use when you want
# to force a full cold rebuild (e.g. after tooling changes, corrupted cache).
#
# Runs 'bazelisk clean --expunge' inside both submodules, where the
# bazel-* symlinks and output artifacts actually live.

$ErrorActionPreference = "Stop"

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path

$Workspaces = @(
    @{ Name = "LiteRT-LM"; Submodule = "vendor\LiteRT-LM"; OutputBase = "C:/b/ino-litert-lm" }
    @{ Name = "LiteRT";    Submodule = "vendor\LiteRT";    OutputBase = "C:/b/ino-litert" }
)

foreach ($ws in $Workspaces) {
    $submoduleDir = Join-Path $WorkspaceDir $ws.Submodule

    Write-Host ""
    Write-Host "=== Cleaning $($ws.Name) ===" -ForegroundColor Cyan

    if (-not (Test-Path $submoduleDir)) {
        Write-Warning "Submodule not initialized: $submoduleDir (skipping)"
        continue
    }

    Push-Location $submoduleDir
    try {
        Write-Host "Running 'bazelisk --output_base=$($ws.OutputBase) clean --expunge'..." `
                   -ForegroundColor Yellow
        & bazelisk --output_base=$ws.OutputBase clean --expunge
        if ($LASTEXITCODE -ne 0) {
            throw "$($ws.Name) bazelisk clean failed (exit code $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "=== Clean complete ===" -ForegroundColor Green
