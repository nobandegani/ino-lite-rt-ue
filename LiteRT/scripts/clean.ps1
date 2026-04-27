# clean.ps1
#
# Wipe the Bazel build cache for the LiteRT-LM workspace. Use when you want
# to force a full cold rebuild (e.g. after tooling changes, corrupted cache).
#
# Runs 'bazelisk clean --expunge' inside vendor/LiteRT-LM/, where the
# bazel-* symlinks and output artifacts actually live.
#
# (LiteRT itself is not built from source — its libLiteRt.dll comes from
# LiteRT-LM's prebuilt and the matching .lib is synthesized via lib.exe.
# So there's no LiteRT Bazel cache to clean.)

$ErrorActionPreference = "Stop"

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$SubmoduleDir = Join-Path $WorkspaceDir "vendor\LiteRT-LM"

if (-not (Test-Path $SubmoduleDir)) {
    Write-Warning "Submodule not initialized: $SubmoduleDir"
    exit 0
}

$BazelOutputBase = "C:/b/ino-litert-lm"

Push-Location $SubmoduleDir
try {
    Write-Host "Running 'bazelisk --output_base=$BazelOutputBase clean --expunge'..." -ForegroundColor Yellow
    & bazelisk --output_base=$BazelOutputBase clean --expunge
    if ($LASTEXITCODE -ne 0) {
        throw "bazelisk clean failed (exit code $LASTEXITCODE)"
    }
} finally {
    Pop-Location
}

Write-Host "=== Clean complete ===" -ForegroundColor Green
