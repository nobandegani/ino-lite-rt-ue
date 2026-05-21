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
# Source: Microsoft's official DirectXShaderCompiler GitHub release at
# the EXACT version upstream LiteRT-LM pins for its Bazel build —
# vendor/LiteRT-LM/WORKSPACE has:
#
#     http_archive(
#         name = "directx_shader_compiler",
#         url = "https://github.com/microsoft/DirectXShaderCompiler/
#                releases/download/v1.9.2602/dxc_2026_02_20.zip",
#         sha256 = "a1e89031...4151e",
#     )
#
# Why NOT reuse UE's bundled ShaderConductor DXC (the previous behavior):
#   UE 5.7's ShaderConductor copy reports FileVersion 3.7.0 and is an
#   Epic Games-signed Microsoft fork; upstream LiteRT-LM's WebGPU
#   accelerator was built and tested against MS official DXC v1.9.2602
#   (Feb 2026). Empirically, shipping UE's DXC produced correct GPU
#   output in editor PIE (where UE's RHI/ShaderConductor pre-loads the
#   engine copy first) but **runaway non-terminating output in packaged
#   Shipping builds** (where our staged copy is the only one in the
#   process). Aligning with upstream's pinned DXC makes the binary
#   surface match the WebGPU accelerator's tested configuration in
#   both editor and package, removing the editor/package divergence.
#
# Why download instead of consuming the Bazel-fetched copy:
#   `bazelisk fetch @directx_shader_compiler//...` doesn't populate the
#   external repo because nothing under //ino:LiteRtLm transitively
#   depends on it (the WebGPU accelerator is consumed as a prebuilt,
#   not built from source). Downloading the pinned zip directly here
#   keeps the staging step self-contained and gives us SHA256
#   verification independent of Bazel state.
#
# Idempotent: cached zip in $CacheDir is reused on subsequent runs
# (matching the InoOnnx setup-onnxruntime.ps1 download pattern). To
# force a re-download, delete $CacheDir/dxc-v1.9.2602.zip.
$DxcVersion        = "v1.9.2602"        # mirrors WORKSPACE's url tag
$DxcDateStamp      = "2026_02_20"       # mirrors WORKSPACE's url filename
$DxcSha256Expected = "a1e89031421cf3c1fca6627766ab3020ca4f962ac7e2caa7fab2b33a8436151e"
$DxcUrl            = "https://github.com/microsoft/DirectXShaderCompiler/releases/download/$DxcVersion/dxc_$DxcDateStamp.zip"

$CacheDir   = Join-Path $WorkspaceDir ".cache"
$DxcZipPath = Join-Path $CacheDir "dxc-$DxcVersion.zip"
$DxcExtractDir = Join-Path $CacheDir "dxc-$DxcVersion-extract"

if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

# Download (or reuse cached) zip
if (Test-Path $DxcZipPath) {
    Write-Host "  [CACHED] DXC $DxcVersion zip ($([math]::Round((Get-Item $DxcZipPath).Length / 1MB, 1)) MB)"
} else {
    Write-Host "  [DOWNLOAD] DXC $DxcVersion (Microsoft official release pinned by LiteRT-LM WORKSPACE)"
    Write-Host "             $DxcUrl"
    Invoke-WebRequest -Uri $DxcUrl -OutFile $DxcZipPath -UseBasicParsing
    Write-Host "             -> $DxcZipPath ($([math]::Round((Get-Item $DxcZipPath).Length / 1MB, 1)) MB)"
}

# Verify SHA256 against WORKSPACE pin — same value Bazel checks against
# when http_archive resolves @directx_shader_compiler. Mismatch means
# the download was corrupted, MITM'd, or the upstream tag was retagged.
$DxcSha256Actual = (Get-FileHash -Algorithm SHA256 -Path $DxcZipPath).Hash.ToLower()
if ($DxcSha256Actual -ne $DxcSha256Expected) {
    Remove-Item -Path $DxcZipPath -Force
    throw ("DXC zip SHA256 mismatch:`n" +
           "  expected (WORKSPACE pin): $DxcSha256Expected`n" +
           "  actual:                   $DxcSha256Actual`n" +
           "Cached file deleted. Re-run to retry the download.")
}
Write-Host "  [VERIFY] DXC zip SHA256 matches WORKSPACE pin"

# Extract (always — cheap, ensures consistent layout, lets re-runs after
# accidental tree edits self-heal)
if (Test-Path $DxcExtractDir) {
    Remove-Item -Recurse -Force $DxcExtractDir
}
New-Item -ItemType Directory -Path $DxcExtractDir -Force | Out-Null
Expand-Archive -Path $DxcZipPath -DestinationPath $DxcExtractDir -Force

# Microsoft's release zip layout:
#   bin/x64/dxcompiler.dll
#   bin/x64/dxil.dll
#   bin/x86/...   (32-bit, ignored)
#   bin/arm64/... (Windows-ARM64, ignored)
#   inc/*.h
#   lib/x64/...
$DxcSrcDir = Join-Path $DxcExtractDir "bin\x64"
foreach ($dll in @("dxcompiler.dll", "dxil.dll")) {
    $src = Join-Path $DxcSrcDir $dll
    if (-not (Test-Path $src)) {
        throw "DXC bin/x64/$dll not found in extracted zip at $src — release layout may have changed."
    }
    Copy-Item -Path $src -Destination (Join-Path $Win64Dst $dll) -Force
    Write-Host "  [STAGE] $dll (DXC $DxcVersion, MS official) -> $Win64Dst"
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
# litert/c/litert_common.h includes <litert/build_common/build_config.h>;
# this header is the consumer-visible gate for LITERT_HAS_* feature
# macros and MUST match the configuration the shipped binaries were
# built with, or the UE C++ side will see a different feature surface
# than libLiteRt.dll / LiteRtLm.dll actually expose.
#
# Source of truth (litert @ d865fd82, litert/build_common/BUILD): the
# string_flag `build_include` defaults to "gpu,npu", and the
# build_config_header copy_file rule maps the default condition to
# config/build_config_gpu_npu.h. The upstream prebuilt libLiteRt.dll
# (prebuilt/windows_x86_64/) and our //c:engine build of LiteRtLm.dll
# are both produced with that default => NPU code paths compiled IN.
# build_config_gpu_npu.h defines neither LITERT_DISABLE_GPU nor
# LITERT_DISABLE_NPU, so on Win64 (litert/c/litert_common.h:155-165)
# it enables the WebGPU + Vulkan GPU defaults and the NPU buffer
# macros — matching the binaries. (The older build_config_gpu.h
# variant set LITERT_DISABLE_NPU, which under-reported the surface
# vs. the NPU-on binaries — a latent mismatch, now fixed.)
#
# GPU/NPU accelerators are NOT in the binary: litert
# build_common/special_rule.bzl litert_gpu_accelerator_deps() returns
# [] and LiteRtStaticLinkedAcceleratorGpuDef is permanently nullptr,
# so every accelerator is dlopen'd at runtime from the staged prebuilt
# .dll set (Win64 GPU == WebGPU/Dawn via DXC; there is no Vulkan
# accelerator lib anywhere in the tree). Functional NPU additionally
# needs a libLiteRtDispatch_* vendor lib (Qualcomm/Intel OpenVINO/…)
# which is vendor-SDK-gated and ships in NO prebuilt/ dir — the
# gpu_npu header makes the plugin NPU-ready, not NPU-functional.
$buildConfigSrc = Join-Path $LiteRtSubDir "litert\build_common\config\build_config_gpu_npu.h"
if (Test-Path $buildConfigSrc) {
    Copy-Item -Path $buildConfigSrc -Destination (Join-Path $LiteRtBuildHdrDst "build_config.h") -Force
    Write-Host "  [STAGE] litert/build_common/build_config.h (from build_config_gpu_npu.h) -> $LiteRtBuildHdrDst"
} else {
    Write-Warning "Expected header not found at $buildConfigSrc"
}

Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
