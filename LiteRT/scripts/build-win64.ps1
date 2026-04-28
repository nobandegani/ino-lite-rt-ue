# build-win64.ps1
#
# Build LiteRT-LM from source for Windows x64 and stage all artifacts into
# the ino_lite_rt_ue plugin under Source/ThirdParty/{Win64,Public}.
#
# LiteRT itself is NOT built from source — we use the prebuilt libLiteRt.dll
# Google ships inside the LiteRT-LM submodule (prebuilt/windows_x86_64/) and
# generate the matching libLiteRt.lib import library from the .def file in
# the LiteRT submodule via lib.exe. That skips a 30+ minute Bazel build for
# zero loss in the public C API surface (exports are identical to a
# from-source build).
#
# Step order:
#   1. setup.ps1                              (preflight + overlay)
#   2. bazelisk build //ino:LiteRtLm          (in vendor/LiteRT-LM)
#   3. Stage everything to Source/ThirdParty/

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

#---------------------------------------------------------------------
# 2. Bazel build LiteRT-LM  (//ino:LiteRtLm)
#---------------------------------------------------------------------
# Match upstream CI (.github/workflows/ci-build-win.yml:117) as closely as
# possible:
#
#   - Short --output_base to keep intermediate paths under Windows MAX_PATH
#     (upstream uses D:/w-<hash>/; we use C:/b/ino-w-x64)
#   - --disk_cache for persistent action caching across workspaces and expunges
#   - Do NOT pass --config=windows explicitly — upstream's .bazelrc has
#     'build --enable_platform_specific_config' which auto-applies the windows
#     config on Windows. Passing it ourselves causes duplicate-expansion warnings.
#   - --build_tag_filters=-nowindows to exclude any targets upstream marks as
#     non-Windows (parity with upstream CI's behavior)
#   - Clear ANDROID_NDK_HOME for the invocation — upstream's CI does this to
#     avoid androidndk rules trying to create symlinks in a host NDK install.
#     Only affects this child process; user's global env is untouched.

$LiteRtLmOutputBase = "C:/b/ino-w-x64"
$LiteRtLmDiskCache  = "C:/b/ino-w-x64-cache"

Write-Host ""
Write-Host "=== Bazel build: LiteRT-LM ===" -ForegroundColor Cyan
Write-Host "Working dir:  $LiteRtLmSubDir"
Write-Host "Output base:  $LiteRtLmOutputBase"
Write-Host "Disk cache:   $LiteRtLmDiskCache"
Write-Host "Target:       //ino:LiteRtLm"
Write-Host ""

# Clear ANDROID_NDK_HOME for this child process only (does not touch user env)
$env:ANDROID_NDK_HOME = ""

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
# 3. Stage all artifacts into Source/ThirdParty/
#---------------------------------------------------------------------
# Single destination tree for all artifacts:
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

# --- LiteRT: copy prebuilt DLL + generate matching .lib via lib.exe ---
#
# We don't build LiteRT from source. Instead we ship the prebuilt
# libLiteRt.dll from LiteRT-LM's submodule and synthesize the matching
# import library from the DLL's actual export table.
#
# We INTENTIONALLY do not use vendor/LiteRT/litert/c/windows_exported_symbols.def
# for this — that file is a curated subset (~230 symbols) maintained by Google
# for their internal binaries' link needs, not the full DLL surface
# (~424 symbols). Generating an import lib from the DLL's exports directly
# guarantees consumer code can link against everything the DLL provides.
$LiteRtPrebuiltDll = Join-Path $LiteRtLmSubDir "prebuilt\windows_x86_64\libLiteRt.dll"
if (-not (Test-Path $LiteRtPrebuiltDll)) {
    throw "Expected prebuilt libLiteRt.dll not found at $LiteRtPrebuiltDll"
}
$StagedLiteRtDll = Join-Path $Win64Dst "libLiteRt.dll"
Copy-Item -Path $LiteRtPrebuiltDll -Destination $StagedLiteRtDll -Force
Write-Host "  [STAGE] libLiteRt.dll (prebuilt)      -> $Win64Dst"

# Locate lib.exe and dumpbin.exe under MSVC. BAZEL_VC points at <VS install>/VC;
# both tools live under Tools/MSVC/<version>/bin/Hostx64/x64/. Multiple MSVC
# versions can coexist — pick the newest one.
if (-not $env:BAZEL_VC) {
    throw "BAZEL_VC not set — required to locate lib.exe. See setup.ps1 preflight."
}
$MsvcRoot = Join-Path $env:BAZEL_VC "Tools\MSVC"
$MsvcBinDir = $null
Get-ChildItem -Path $MsvcRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object @{Expression = {[version]$_.Name}} -Descending |
    ForEach-Object {
        $candidate = Join-Path $_.FullName "bin\Hostx64\x64"
        if ((-not $MsvcBinDir) -and (Test-Path (Join-Path $candidate "lib.exe"))) {
            $script:MsvcBinDir = $candidate
        }
    }
if (-not $MsvcBinDir) {
    throw "MSVC bin\Hostx64\x64 not found under $MsvcRoot. Is the C++ workload installed?"
}
$LibExe = Join-Path $MsvcBinDir "lib.exe"
$DumpbinExe = Join-Path $MsvcBinDir "dumpbin.exe"
if (-not (Test-Path $DumpbinExe)) {
    throw "dumpbin.exe not found at $DumpbinExe"
}

# Extract every export from the DLL using dumpbin. The output table looks like:
#     ordinal hint RVA      name
#           1    0 00027400 LiteRtAddCustomOpKernelOption
#           2    1 00027410 LiteRtAddEnvironmentOptions
#           ...
# Match lines with "<digits> <hex> <hex> <name>" and capture column 4.
Write-Host "  Reading exports from libLiteRt.dll via dumpbin..."
$dumpOut = & $DumpbinExe /exports $StagedLiteRtDll 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "dumpbin failed reading exports (exit code $LASTEXITCODE)"
}
$dllExports = @()
foreach ($line in $dumpOut) {
    if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$') {
        $dllExports += $Matches[1]
    }
}
if ($dllExports.Count -eq 0) {
    throw "dumpbin produced no exports — output unexpected, can't generate .lib"
}
Write-Host "  Found $($dllExports.Count) exports"

# Write a complete .def to the intermediate dir, then run lib.exe against it.
$IntermediateDir = Join-Path $PluginDir "Intermediate\LiteRT"
if (-not (Test-Path $IntermediateDir)) {
    New-Item -ItemType Directory -Path $IntermediateDir -Force | Out-Null
}
$FullDefFile = Join-Path $IntermediateDir "libLiteRt_full.def"
$defLines = @("EXPORTS") + ($dllExports | ForEach-Object { "  $_" })
Set-Content -Path $FullDefFile -Value $defLines -Encoding ASCII

$LiteRtLib = Join-Path $Win64Dst "libLiteRt.lib"
# /name: tells lib.exe which DLL the import records bind to (our .def has no
# LIBRARY directive). /machine:x64 matches our DLL's architecture.
& $LibExe "/def:$FullDefFile" "/name:libLiteRt.dll" "/machine:x64" "/out:$LiteRtLib"
if ($LASTEXITCODE -ne 0) {
    throw "lib.exe failed generating libLiteRt.lib (exit code $LASTEXITCODE)"
}
Write-Host "  [STAGE] libLiteRt.lib ($($dllExports.Count) imports synthesized from DLL exports) -> $Win64Dst"

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

# LiteRtLm import lib (Bazel may name it .if.lib, .dll.if.lib, or .lib)
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

# GPU accelerator prebuilt DLLs from LiteRT-LM submodule.
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
