# clean.ps1
#
# Wipe the Bazel build caches for both the Win64 and Android cross-compile
# of LiteRT-LM. Use when you want to force a full cold rebuild (e.g. after
# tooling changes, corrupted cache).
#
# Runs 'bazelisk clean --expunge' inside vendor/LiteRT-LM/ once per
# output base — the bazel-* symlinks and output artifacts actually live
# under the output base, but the workspace itself is the submodule.
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

$OutputBases = @(
    @{ Name = "Windows x86_64";     Base = "C:/b/ino-w-x64" }
    @{ Name = "Android arm64-v8a";  Base = "C:/b/ino-a-a64" }
    @{ Name = "Android x86_64";     Base = "C:/b/ino-a-x64" }
)

foreach ($ob in $OutputBases) {
    Write-Host ""
    Write-Host "=== Cleaning LiteRT-LM ($($ob.Name)) ===" -ForegroundColor Cyan

    if (-not (Test-Path $ob.Base)) {
        Write-Host "  (output base $($ob.Base) does not exist — nothing to clean)"
        continue
    }

    Push-Location $SubmoduleDir
    try {
        # PowerShell argument-mode quirk: in `--output_base=$ob.Base` the
        # parser treats `$ob` as the variable and `.Base` as literal text,
        # which would silently expand to a bogus path. The subexpression
        # `$($ob.Base)` forces actual member access. Same shape as the
        # Write-Host line above.
        $base = $ob.Base
        Write-Host "Running 'bazelisk --output_base=$base clean --expunge'..." `
                   -ForegroundColor Yellow
        & bazelisk "--output_base=$base" clean --expunge
        if ($LASTEXITCODE -ne 0) {
            throw "$($ob.Name) bazelisk clean failed (exit code $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "=== Clean complete ===" -ForegroundColor Green
