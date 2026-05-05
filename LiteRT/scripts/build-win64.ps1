# build-win64.ps1
#
# Build LiteRT-LM from source for Windows x64 and stage all artifacts into
# the InoLiteRT plugin under Source/ThirdParty/{Win64,Public}.
#
# LiteRT itself is NOT built from source — we use the prebuilt libLiteRt.dll
# Google ships inside the LiteRT-LM submodule (prebuilt/windows_x86_64/)
# and synthesize the matching libLiteRt.lib import library from the DLL's
# actual export table via dumpbin + lib.exe. That skips a 30+ minute
# Bazel build for zero loss in the public C API surface (exports are
# identical to a from-source build).
#
# LiteRT headers (litert/c/*.h, litert/c/internal/*.h, litert/build_common/
# config/*.h) are read from Bazel's external-fetch of the LiteRT repo —
# vendor/LiteRT-LM/bazel-litert-lm/external/litert/ — pinned by
# WORKSPACE's LITERT_REF. No separate vendor/LiteRT submodule is needed:
# the WORKSPACE pin is the single source of truth for both DLL and headers.
#
# Step order:
#   1. setup.ps1                              (preflight + overlay)
#   2. bazelisk build //ino:LiteRtLm          (in vendor/LiteRT-LM)
#   3. Stage everything to Source/ThirdParty/

$ErrorActionPreference = "Stop"

$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceDir    = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$LiteRtLmSubDir  = Join-Path $WorkspaceDir "vendor\LiteRT-LM"
# LiteRT headers come from Bazel's external-fetch copy of LiteRT, pulled
# automatically via vendor/LiteRT-LM/WORKSPACE's LITERT_REF when Bazel
# builds //ino:LiteRtLm. The bazel-litert-lm/ symlink is a Bazel
# convenience that resolves to <output_base>/external/litert. Using it
# instead of a separate vendor/LiteRT submodule guarantees the staged
# headers can never drift out of sync with the DLL the same Bazel run
# produced — both come from the single SHA pinned in WORKSPACE.
$LiteRtSubDir    = Join-Path $LiteRtLmSubDir "bazel-litert-lm\external\litert"
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

$Win64Dst         = Join-Path $PluginDir "Source\ThirdParty\Win64"
$LiteRtHdrDst     = Join-Path $PluginDir "Source\ThirdParty\Public\litert\c"
$LiteRtIntHdrDst  = Join-Path $LiteRtHdrDst "internal"
$LiteRtOptHdrDst  = Join-Path $LiteRtHdrDst "options"
$LiteRtLmHdrDst   = Join-Path $PluginDir "Source\ThirdParty\Public\litert\lm"
$LiteRtBuildHdrDst = Join-Path $PluginDir "Source\ThirdParty\Public\litert\build_common"

foreach ($d in @($Win64Dst, $LiteRtHdrDst, $LiteRtIntHdrDst, $LiteRtOptHdrDst, $LiteRtLmHdrDst, $LiteRtBuildHdrDst)) {
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
# We INTENTIONALLY do not use upstream's
# litert/c/windows_exported_symbols.def — that file is a curated subset
# (~230 symbols) maintained by Google for their internal binaries' link
# needs, not the full DLL surface (~424 symbols). Generating an import
# lib from the DLL's exports directly guarantees consumer code can link
# against everything the DLL provides.
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

# DirectX Shader Compiler (DXC) — required by the Dawn-based WebGPU
# accelerators above. They internally call LoadLibraryA("dxcompiler.dll")
# and ("dxil.dll") during D3D12 device init to translate WGSL → HLSL →
# DXIL. The editor process incidentally has these loaded (UE bundles
# them under Engine/Binaries/ThirdParty/ShaderConductor/), so PIE works
# without us doing anything; packaged builds have no such ride-along,
# so DXC must be explicitly staged into the plugin tree and pre-loaded
# at module startup. See InoLiteRT.cpp's StartupModule.
#
# Source: UE engine's ShaderConductor copy. Same DLL Microsoft ships
# under MIT (https://github.com/microsoft/DirectXShaderCompiler) — we
# just reuse the engine's already-tested-with-D3D12 copy instead of
# pinning our own DirectXShaderCompiler release.
#
# Engine root resolution: $env:UE_ROOT first, then a couple of common
# install paths. Override with `$env:UE_ROOT = "..."` in the calling
# shell if neither matches.
$UeRoot = $env:UE_ROOT
if (-not $UeRoot -or -not (Test-Path $UeRoot)) {
    $UeCandidates = @(
        "C:\Inoland\Epic Games\UE_5.7",
        "C:\Program Files\Epic Games\UE_5.7"
    )
    foreach ($c in $UeCandidates) {
        if (Test-Path $c) { $UeRoot = $c; break }
    }
}
if (-not $UeRoot) {
    throw "UE engine root not found. Set `$env:UE_ROOT to your UE 5.7 install dir before re-running."
}
$DxcSrcDir = Join-Path $UeRoot "Engine\Binaries\ThirdParty\ShaderConductor\Win64"
foreach ($dll in @("dxcompiler.dll", "dxil.dll")) {
    $src = Join-Path $DxcSrcDir $dll
    if (-not (Test-Path $src)) {
        throw "DXC required by WebGPU GPU backend not found at $src. Engine install may be incomplete."
    }
    Copy-Item -Path $src -Destination (Join-Path $Win64Dst $dll) -Force
    Write-Host "  [STAGE] $dll (from UE ShaderConductor) -> $Win64Dst"
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

# --- Headers: LiteRT C API per-vendor options ---
# Per-vendor accelerator option struct definitions: cpu, gpu, qualcomm,
# mediatek, samsung, intel_openvino, google_tensor, runtime, compiler,
# webnn. Their .cc compiles into libLiteRt.dll, so the symbols are
# available; staging the headers lets consumers #include
# "litert/c/options/litert_<vendor>_options.h" to construct typed
# option structs.
$liteRtOptionsSrc = Join-Path $LiteRtSubDir "litert\c\options"
if (Test-Path $liteRtOptionsSrc) {
    Get-ChildItem -Path $liteRtOptionsSrc -Filter "*.h" -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $LiteRtOptHdrDst $_.Name) -Force
    }
    Write-Host "  [STAGE] litert/c/options/*.h ($((Get-ChildItem $LiteRtOptHdrDst -Filter *.h).Count) files) -> $LiteRtOptHdrDst"
}

# --- Header: LiteRT-LM C API (engine.h) ---
$lmHeader = Join-Path $LiteRtLmSubDir "c\engine.h"
if (Test-Path $lmHeader) {
    Copy-Item -Path $lmHeader -Destination (Join-Path $LiteRtLmHdrDst "engine.h") -Force
    Write-Host "  [STAGE] litert/lm/engine.h -> $LiteRtLmHdrDst"
} else {
    Write-Warning "Expected header not found at $lmHeader"
}

# --- Header: LiteRT build_config.h (feature-toggle gate) ---
# litert/c/litert_common.h:20 includes <litert/build_common/build_config.h>,
# which upstream generates at Bazel-build time by selecting one of
# litert/build_common/config/build_config_*.h based on the configured
# feature set. We don't run that generator step (the configured Bazel build
# produces the .dll/.so but doesn't write this header into a path we stage),
# so we instead copy the matching variant directly.
#
# Variant choice: build_config_gpu.h — defines LITERT_DISABLE_NPU and
# leaves GPU enabled, matching what InoLiteRT actually ships on Win64
# (libLiteRtWebGpuAccelerator.dll, libLiteRtTopKWebGpuSampler.dll, no NPU
# accelerators). The cpu_only variant would also disable LITERT_HAS_GPU
# checks consumers may rely on; the gpu_npu / npu variants include NPU
# code paths that aren't built into our DLLs.
$buildConfigSrc = Join-Path $LiteRtSubDir "litert\build_common\config\build_config_gpu.h"
if (Test-Path $buildConfigSrc) {
    Copy-Item -Path $buildConfigSrc -Destination (Join-Path $LiteRtBuildHdrDst "build_config.h") -Force
    Write-Host "  [STAGE] litert/build_common/build_config.h (from build_config_gpu.h) -> $LiteRtBuildHdrDst"
} else {
    Write-Warning "Expected header not found at $buildConfigSrc"
}

Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
