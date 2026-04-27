# build-win64.ps1
#
# Build LiteRT and LiteRT-LM from source for Windows x64 and stage all
# artifacts into the ino_lite_rt_ue plugin under
# Source/ThirdParty/LiteRT/{Win64,Public}.
#
# Step order:
#   1. setup.ps1                              (preflight + overlay)
#   2. bazelisk build //litert/c:libLiteRt    (in vendor/LiteRT)
#   3. bazelisk build //ino:LiteRtLm          (in vendor/LiteRT-LM)
#   4. Stage everything to Source/ThirdParty/LiteRT/

$ErrorActionPreference = "Stop"

$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceDir    = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$LiteRtSubDir    = Join-Path $WorkspaceDir "vendor\LiteRT"
$LiteRtLmSubDir  = Join-Path $WorkspaceDir "vendor\LiteRT-LM"
$PluginDir       = (Resolve-Path (Join-Path $WorkspaceDir "..")).Path

#---------------------------------------------------------------------
# 1. Run setup
#---------------------------------------------------------------------
& (Join-Path $ScriptDir "setup.ps1")
if ($LASTEXITCODE -ne 0) { throw "setup.ps1 failed" }

# Clear ANDROID_NDK_HOME for both child Bazel processes (does not touch user env)
$env:ANDROID_NDK_HOME = ""

#---------------------------------------------------------------------
# 2. Build LiteRT  (//litert/c:libLiteRt)
#---------------------------------------------------------------------
# Separate output base / disk cache from LiteRT-LM — different Bazel
# workspace, can't share state.
$LiteRtOutputBase = "C:/b/ino-litert"
$LiteRtDiskCache  = "C:/b/ino-litert-cache"

if (-not (Test-Path $LiteRtOutputBase)) {
    New-Item -ItemType Directory -Path $LiteRtOutputBase -Force | Out-Null
}

Write-Host ""
Write-Host "=== Bazel build: LiteRT ===" -ForegroundColor Cyan
Write-Host "Working dir:  $LiteRtSubDir"
Write-Host "Output base:  $LiteRtOutputBase"
Write-Host "Disk cache:   $LiteRtDiskCache"
Write-Host "Target:       //litert/c:libLiteRt"
Write-Host ""

Push-Location $LiteRtSubDir
try {
    & bazelisk --output_base=$LiteRtOutputBase `
        build //litert/c:libLiteRt `
        --disk_cache=$LiteRtDiskCache `
        --verbose_failures
    if ($LASTEXITCODE -ne 0) {
        throw "LiteRT bazelisk build failed (exit code $LASTEXITCODE)"
    }
} finally {
    Pop-Location
}

#---------------------------------------------------------------------
# 3. Build LiteRT-LM  (//ino:LiteRtLm)
#---------------------------------------------------------------------
# Match upstream CI (.github/workflows/ci-build-win.yml:117) as closely as
# possible:
#
#   - Short --output_base to keep intermediate paths under Windows MAX_PATH
#     (upstream uses D:/w-<hash>/; we use C:/b/ino-litert-lm)
#   - --disk_cache for persistent action caching across workspaces and expunges
#   - Do NOT pass --config=windows explicitly — upstream's .bazelrc has
#     'build --enable_platform_specific_config' which auto-applies the windows
#     config on Windows. Passing it ourselves causes duplicate-expansion warnings.
#   - --build_tag_filters=-nowindows to exclude any targets upstream marks as
#     non-Windows (parity with upstream CI's behavior)

$LiteRtLmOutputBase = "C:/b/ino-litert-lm"
$LiteRtLmDiskCache  = "C:/b/ino-litert-lm-cache"

Write-Host ""
Write-Host "=== Bazel build: LiteRT-LM ===" -ForegroundColor Cyan
Write-Host "Working dir:  $LiteRtLmSubDir"
Write-Host "Output base:  $LiteRtLmOutputBase"
Write-Host "Disk cache:   $LiteRtLmDiskCache"
Write-Host "Target:       //ino:LiteRtLm"
Write-Host ""

Push-Location $LiteRtLmSubDir
try {
    & bazelisk --output_base=$LiteRtLmOutputBase `
        build //ino:LiteRtLm `
        --disk_cache=$LiteRtLmDiskCache `
        --build_tag_filters=-nowindows `
        --define=litert_link_capi_so=true `
        --define=resolve_symbols_in_exec=false `
        --verbose_failures
    if ($LASTEXITCODE -ne 0) {
        throw "LiteRT-LM bazelisk build failed (exit code $LASTEXITCODE)"
    }
} finally {
    Pop-Location
}

#---------------------------------------------------------------------
# 4. Stage all artifacts into Source/ThirdParty/
#---------------------------------------------------------------------
# Single destination tree for all artifacts from both builds:
#   Source/ThirdParty/Win64/                  All DLLs + import libs
#   Source/ThirdParty/Public/litert/c/         LiteRT C API headers
#   Source/ThirdParty/Public/litert/c/internal/  internal headers
#   Source/ThirdParty/Public/litert/lm/        LiteRT-LM C API header
Write-Host ""
Write-Host "=== Staging artifacts ===" -ForegroundColor Cyan

$Win64Dst        = Join-Path $PluginDir "Source\ThirdParty\Win64"
$LiteRtHdrDst    = Join-Path $PluginDir "Source\ThirdParty\Public\litert\c"
$LiteRtIntHdrDst = Join-Path $LiteRtHdrDst "internal"
$LiteRtLmHdrDst  = Join-Path $PluginDir "Source\ThirdParty\Public\litert\lm"

foreach ($d in @($Win64Dst, $LiteRtHdrDst, $LiteRtIntHdrDst, $LiteRtLmHdrDst)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# --- LiteRT outputs (we built libLiteRt.dll ourselves; ignore the prebuilt) ---
$LiteRtBazelBin = Join-Path $LiteRtSubDir "bazel-bin\litert\c"

$liteRtDll = Join-Path $LiteRtBazelBin "libLiteRt.dll"
if (-not (Test-Path $liteRtDll)) {
    Write-Warning "Expected libLiteRt.dll not at $liteRtDll. Listing bazel-bin/litert/c:"
    Get-ChildItem $LiteRtBazelBin 2>$null | ForEach-Object { Write-Host "  $($_.Name)" }
    throw "libLiteRt.dll not produced by Bazel"
}
Copy-Item -Path $liteRtDll -Destination (Join-Path $Win64Dst "libLiteRt.dll") -Force
Write-Host "  [STAGE] libLiteRt.dll (from-source)  -> $Win64Dst"

# Import library — Bazel can name it differently depending on toolchain
$liteRtLibCandidates = @("libLiteRt.if.lib", "libLiteRt.dll.if.lib", "libLiteRt.lib")
$liteRtLibSrc = $null
foreach ($c in $liteRtLibCandidates) {
    $p = Join-Path $LiteRtBazelBin $c
    if (Test-Path $p) { $liteRtLibSrc = $p; break }
}
if (-not $liteRtLibSrc) {
    Write-Warning "libLiteRt import lib not found under any expected name in $LiteRtBazelBin"
    Get-ChildItem $LiteRtBazelBin | ForEach-Object { Write-Host "  $($_.Name)" }
} else {
    Copy-Item -Path $liteRtLibSrc -Destination (Join-Path $Win64Dst "libLiteRt.lib") -Force
    Write-Host "  [STAGE] $(Split-Path $liteRtLibSrc -Leaf) -> $Win64Dst\libLiteRt.lib"
}

# --- LiteRT-LM outputs ---
$LiteRtLmBazelBin = Join-Path $LiteRtLmSubDir "bazel-bin\ino"

# LiteRtLm.dll
$dllSrc = Join-Path $LiteRtLmBazelBin "LiteRtLm.dll"
if (-not (Test-Path $dllSrc)) {
    Write-Warning "Expected LiteRtLm.dll not at $dllSrc. Listing bazel-bin/ino:"
    Get-ChildItem $LiteRtLmBazelBin 2>$null | ForEach-Object { Write-Host "  $($_.Name)" }
    throw "LiteRtLm.dll not produced by Bazel"
}
Copy-Item -Path $dllSrc -Destination (Join-Path $Win64Dst "LiteRtLm.dll") -Force
Write-Host "  [STAGE] LiteRtLm.dll                  -> $Win64Dst"

# LiteRtLm import lib
$lmLibCandidates = @("LiteRtLm.if.lib", "LiteRtLm.dll.if.lib", "LiteRtLm.lib")
$lmLibSrc = $null
foreach ($c in $lmLibCandidates) {
    $p = Join-Path $LiteRtLmBazelBin $c
    if (Test-Path $p) { $lmLibSrc = $p; break }
}
if (-not $lmLibSrc) {
    Write-Warning "LiteRtLm import lib not found in $LiteRtLmBazelBin"
} else {
    Copy-Item -Path $lmLibSrc -Destination (Join-Path $Win64Dst "LiteRtLm.lib") -Force
    Write-Host "  [STAGE] $(Split-Path $lmLibSrc -Leaf) -> $Win64Dst\LiteRtLm.lib"
}

# libGemmaModelConstraintProvider.dll (LiteRT-LM upstream prebuilt, Bazel
# symlinks it into bazel-bin/ino as a data dep — we copy the resolved
# target).
$gemmaSrc = Join-Path $LiteRtLmBazelBin "libGemmaModelConstraintProvider.dll"
if (Test-Path $gemmaSrc) {
    Copy-Item -Path $gemmaSrc -Destination (Join-Path $Win64Dst "libGemmaModelConstraintProvider.dll") -Force
    Write-Host "  [STAGE] libGemmaModelConstraintProvider.dll -> $Win64Dst"
} else {
    throw "libGemmaModelConstraintProvider.dll not found at $gemmaSrc"
}

# GPU accelerator prebuilt DLLs from LiteRT-LM submodule (we deliberately
# do NOT copy libLiteRt.dll from prebuilt/ — we use the one we just built
# above from the LiteRT submodule).
$LiteRtLmPrebuilt = Join-Path $LiteRtLmSubDir "prebuilt\windows_x86_64"
$AcceleratorDlls = @(
    "libLiteRtWebGpuAccelerator.dll",
    "libLiteRtTopKWebGpuSampler.dll"
)
foreach ($dll in $AcceleratorDlls) {
    $src = Join-Path $LiteRtLmPrebuilt $dll
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $Win64Dst $dll) -Force
        Write-Host "  [STAGE] $dll -> $Win64Dst"
    } else {
        Write-Warning "GPU prebuilt not found: $src (GPU backend will not be available)"
    }
}

# --- Headers: LiteRT C API ---
Get-ChildItem -Path (Join-Path $LiteRtSubDir "litert\c") -Filter "*.h" -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $LiteRtHdrDst $_.Name) -Force
}
Write-Host "  [STAGE] litert/c/*.h ($((Get-ChildItem $LiteRtHdrDst -Filter *.h).Count) files) -> $LiteRtHdrDst"

# --- Headers: LiteRT C API internal ---
$liteRtInternalSrc = Join-Path $LiteRtSubDir "litert\c\internal"
if (Test-Path $liteRtInternalSrc) {
    Get-ChildItem -Path $liteRtInternalSrc -Filter "*.h" -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $LiteRtIntHdrDst $_.Name) -Force
    }
    Write-Host "  [STAGE] litert/c/internal/*.h ($((Get-ChildItem $LiteRtIntHdrDst -Filter *.h).Count) files) -> $LiteRtIntHdrDst"
}

# --- Header: LiteRT-LM C API (engine.h) ---
$lmHeader = Join-Path $LiteRtLmSubDir "c\engine.h"
if (Test-Path $lmHeader) {
    Copy-Item -Path $lmHeader -Destination (Join-Path $LiteRtLmHdrDst "engine.h") -Force
    Write-Host "  [STAGE] litert/lm/engine.h -> $LiteRtLmHdrDst"
} else {
    Write-Warning "Expected header not found at $lmHeader"
}

Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
