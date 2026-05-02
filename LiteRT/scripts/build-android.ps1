# build-android.ps1
#
# Build libLiteRtLm.so from source for Android (arm64-v8a or x86_64) and
# stage all artifacts into the ino_lite_rt_ue plugin under Source/ThirdParty/.
#
# Usage:
#   .\build-android.ps1                    # default: arm64-v8a (real devices)
#   .\build-android.ps1 -Arch arm64-v8a    # explicit arm64
#   .\build-android.ps1 -Arch x86_64       # emulators / x86 Chromebooks
#
# Step order:
#   1. NDK r28.x preflight (auto-detect under %LOCALAPPDATA%\Android\Sdk\ndk\)
#   2. setup.ps1                              (preflight + overlay)
#   3. bazelisk build //ino:LiteRtLm  --config=android_<arch>
#   4. Stage everything to Source/ThirdParty/{Android/<arch>, Public}
#
# LiteRT itself is NOT built — same as Win64, we use the prebuilt .so files
# Google ships inside LiteRT-LM's prebuilt/android_<arch>/ folder. Note that
# upstream's --dynamic_mode=off statically links LiteRT core into the
# monolithic libLiteRtLm.so on Android, so unlike Win64 there is no
# separate libLiteRt.so or matching import library.
#
# LiteRT headers (litert/c/*.h, litert/c/internal/*.h, litert/build_common/
# config/*.h) are read from Bazel's external-fetch of the LiteRT repo
# (vendor/LiteRT-LM/bazel-litert-lm/external/litert/), pinned by
# WORKSPACE's LITERT_REF. No separate vendor/LiteRT submodule is needed.

param(
    [ValidateSet("arm64-v8a", "x86_64")]
    [string]$Arch = "arm64-v8a"
)

$ErrorActionPreference = "Stop"

# Map our -Arch to the upstream Bazel config name and the prebuilt subdir.
# Upstream uses "android_arm64" / "android_x86_64" for the Bazel config
# and "android_arm64" / "android_x86_64" for the prebuilt subdirectories.
switch ($Arch) {
    "arm64-v8a" {
        $BazelConfig    = "android_arm64"
        $PrebuiltSubDir = "android_arm64"
    }
    "x86_64" {
        $BazelConfig    = "android_x86_64"
        $PrebuiltSubDir = "android_x86_64"
    }
}

$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceDir   = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$LiteRtLmSubDir = Join-Path $WorkspaceDir "vendor\LiteRT-LM"
# LiteRT headers come from Bazel's external-fetch copy of LiteRT, pulled
# automatically via vendor/LiteRT-LM/WORKSPACE's LITERT_REF when Bazel
# builds //ino:LiteRtLm. The bazel-litert-lm/ symlink is a Bazel
# convenience that resolves to <output_base>/external/litert. Using it
# instead of a separate vendor/LiteRT submodule guarantees the staged
# headers can never drift out of sync with the .so the same Bazel run
# produced — both come from the single SHA pinned in WORKSPACE.
$LiteRtSubDir   = Join-Path $LiteRtLmSubDir "bazel-litert-lm\external\litert"
$PluginDir      = (Resolve-Path (Join-Path $WorkspaceDir "..")).Path

#---------------------------------------------------------------------
# 1. Preflight: locate an Android NDK r28.x
#---------------------------------------------------------------------
# LiteRT-LM's Bazel config requires NDK r28b or newer. We deliberately
# pin to the r28 series (highest r28.x available) — that's what upstream
# develops and tests against. r29 and r30 *might* work but they're newer
# than upstream's tested range and ship newer Clang versions with
# stricter checks; sticking to r28.x avoids surprises.
#
# We auto-detect the newest r28.x installed under
# %LOCALAPPDATA%\Android\Sdk\ndk\ and point ANDROID_NDK_HOME at it for
# this build's child Bazel invocation only. The user's env is NOT modified.
#
# Note: UE 5.7 itself uses NDK 27.2.12479018. We intentionally do NOT
# use that for Bazel because it is too old for LiteRT-LM. The two
# NDKs coexist fine under Sdk\ndk\ as separate subdirectories.
$NdkBaseDir = Join-Path $env:LOCALAPPDATA "Android\Sdk\ndk"
if (-not (Test-Path $NdkBaseDir)) {
    throw "Android NDK base directory not found: $NdkBaseDir. Install the Android SDK via Android Studio first."
}

# Pick the newest installed NDK in the r28.x series (e.g. 28.0.x, 28.1.x,
# 28.2.x). Reject r29+ even if installed — see comment block above.
$NdkCandidates = Get-ChildItem $NdkBaseDir -Directory |
    Where-Object { $_.Name -match '^28\.' } |
    Sort-Object -Descending @{Expression = { [version]$_.Name }}

if ($NdkCandidates.Count -eq 0) {
    Write-Host ""
    Write-Host "No Android NDK r28.x found under $NdkBaseDir." -ForegroundColor Red
    Write-Host "Installed NDK versions:" -ForegroundColor Yellow
    Get-ChildItem $NdkBaseDir -Directory | ForEach-Object { Write-Host "  $($_.Name)" }
    Write-Host ""
    Write-Host "Install NDK r28.x via Android Studio:" -ForegroundColor Yellow
    Write-Host "  Tools -> SDK Manager -> SDK Tools -> NDK (Side by side)" -ForegroundColor Yellow
    Write-Host "  check 'Show Package Details', select an r28.x version, Apply." -ForegroundColor Yellow
    throw "Android NDK r28.x required but not installed"
}

$AndroidNdkHome = $NdkCandidates[0].FullName

# CRITICAL: Bazel's rules_android_ndk has a Windows path-slash bug
# (bazelbuild/rules_android_ndk@rules.bzl:106-116): it concatenates
# ndk_path + "/" + subdir, then tries to strip ndk_path from the
# output of str(ctx.path(...)) — but str() returns forward slashes
# while ndk_path has backslashes, so the strip fails and Bazel sees
# an absolute path like "C:/Users/.../AndroidVersion.txt" as a
# symlink destination and errors with "Cannot write outside of the
# repository directory for path ...".
#
# Fix: pass ANDROID_NDK_HOME with forward slashes. Bazel's path
# handling treats forward slashes consistently across platforms, so
# the string comparison in rules_android_ndk works correctly.
$AndroidNdkHome = $AndroidNdkHome.Replace('\', '/')

Write-Host ""
Write-Host "=== Android build preflight ===" -ForegroundColor Cyan
Write-Host "  Architecture:     $Arch"
Write-Host "  Bazel config:     --config=$BazelConfig"
Write-Host "  ANDROID_NDK_HOME: $AndroidNdkHome"
$env:ANDROID_NDK_HOME = $AndroidNdkHome

#---------------------------------------------------------------------
# 2. Run setup (idempotent — same overlay as Win64)
#---------------------------------------------------------------------
& (Join-Path $ScriptDir "setup.ps1")
if ($LASTEXITCODE -ne 0) { throw "setup.ps1 failed" }

#---------------------------------------------------------------------
# 3. Bazel build LiteRT-LM (Android <arch>)
#---------------------------------------------------------------------
# Android build configuration. INTENTIONALLY DIVERGES from Win64 on two
# defines — see comments below.
#
#   --config=android_<arch>  — picks the appropriate Android toolchain
#                              via upstream's .bazelrc. All Android
#                              configs inherit build:android, which sets
#                              --dynamic_mode=off (force-statics every
#                              transitive dep into the final .so) and
#                              --noenable_platform_specific_config (so
#                              the host build:windows config is NOT
#                              auto-applied — we replay the host MSVC
#                              flags manually below).
#
# NOT passed on Android (unlike Win64):
#
#   --define=litert_link_capi_so=true — DELIBERATELY OMITTED. On Windows
#     this splits LiteRT core into a separate libLiteRt.dll so the
#     prebuilt GPU accelerators and our LiteRtLm.dll share one LiteRT
#     instance. On Android upstream's --dynamic_mode=off forces static
#     linking, so no separate libLiteRt.so is actually produced — but
#     the define still drives select() branches in the dep graph to
#     reference a dynamic libLiteRt.so that doesn't exist. The result
#     is a libLiteRtLm.so with a phantom DT_NEEDED(libLiteRt.so) that
#     causes the Android dynamic linker to abort() during dlopen with
#     no recoverable error — which manifests as the app crashing at
#     launch. Verify the build is clean with:
#         llvm-readelf -d libLiteRtLm.so | grep NEEDED
#     should show ONLY system libs (libdl, liblog, libm, libc) plus
#     libGemmaModelConstraintProvider.so, and NOT libLiteRt.so.
#
#   --define=resolve_symbols_in_exec=false — DELIBERATELY OMITTED. This
#     only makes sense alongside litert_link_capi_so=true's dynamic
#     split. For our monolithic Android .so the default
#     (resolve_symbols_in_exec=true) is correct.

# Per-architecture output base + disk cache so different ABI builds
# don't thrash the same Bazel action cache.
#
# Naming scheme: C:/b/ino-<platform>-<arch>
#   ino-a-a64    Android arm64-v8a
#   ino-a-x64    Android x86_64
#   ino-w-x64    Windows x86_64       (set in build-win64.ps1)
#
# Short names are mandatory on Windows due to MAX_PATH (260 chars).
# Cross-compile builds put host outputs under
# bazel-out/x64_windows-opt-exec-ST-<hash>/bin/... which is ~25 chars
# longer than the Win64 native bazel-out/x64_windows-opt/bin/...
# Combined with Rust proc-macro intermediate filenames (~220 chars,
# e.g. macro_rules_attribute_proc_macro-...-cgu.0.rcgu.o), only a
# very short output base prefix keeps total paths under 260 chars.
$ShortArch = switch ($Arch) {
    "arm64-v8a" { "a64" }
    "x86_64"    { "x64" }
}
$BazelOutputBase = "C:/b/ino-a-$ShortArch"
$BazelDiskCache  = "C:/b/ino-a-$ShortArch-cache"

Write-Host ""
Write-Host "=== Bazel build: LiteRT-LM (Android $Arch) ===" -ForegroundColor Cyan
Write-Host "Working dir:  $LiteRtLmSubDir"
Write-Host "Output base:  $BazelOutputBase"
Write-Host "Disk cache:   $BazelDiskCache"
Write-Host "Target:       //ino:LiteRtLm"
Write-Host ""

Push-Location $LiteRtLmSubDir
try {
    # Cross-compiling Android from Windows — upstream's build:android
    # sets --noenable_platform_specific_config which disables the
    # automatic build:windows flags on the host. We manually replay
    # the subset of host-only flags that are needed to compile the
    # protobuf / flatbuffers / abseil host tools on MSVC.
    #
    # Each flag below corresponds to one in upstream's build:windows
    # in LiteRT-LM/.bazelrc. Flags that affect TARGET compilation
    # (Android via clang) are deliberately NOT included here —
    # build:android handles those.
    #
    #   --host_cxxopt=/std:c++20 — MSVC syntax for C++20 (build:android
    #     sets --host_cxxopt=-std=c++20 which MSVC ignores with a
    #     D9002 warning, breaking absl's C++17-minimum check).
    #   --define=protobuf_allow_msvc=true — protobuf refuses to
    #     compile on MSVC+Bazel without this.
    #   --shell_executable — build:android falls back to WSL's bash
    #     at C:\Windows\System32\bash.exe which can't handle Windows
    #     paths in genrule $f variables; use Git Bash like Windows
    #     builds do.
    #   --host_copt=/W0 — suppress noisy host warnings.
    #   --host_copt=/Zc:__cplusplus — make __cplusplus macro reflect
    #     the actual standard (MSVC defaults to 199711L without this).
    #   --host_copt=/D_USE_MATH_DEFINES — M_PI etc.
    #   --host_copt=-D_ENABLE_EXTENDED_ALIGNED_STORAGE — avoid
    #     libc++ aligned_storage deprecation warnings.
    #   --host_copt=-DWIN32_LEAN_AND_MEAN --host_copt=-DNOGDI —
    #     slim down windows.h to avoid name collisions.
    #   --host_copt=/Zc:preprocessor — conforming preprocessor mode
    #     (required by some absl / protobuf macros).
    #   --host_copt=/Iexternal/com_google_protobuf/src — adds protobuf's
    #     own source dir to the host include path. Without this, the
    #     protobuf "bootstrap" build (which compiles .pb.cc files for
    #     descriptor.proto / java_features.proto / etc.) fails with
    #     "Cannot open include file: 'google/protobuf/compiler/java/
    #     java_features.pb.h'" — the generated .pb.h is at
    #     bazel-out/.../external/com_google_protobuf/src/... and the
    #     #include uses google/protobuf/... so the flag points the
    #     compiler at the right strip prefix.
    & bazelisk --output_base=$BazelOutputBase `
        build //ino:LiteRtLm `
        --config=$BazelConfig `
        --disk_cache=$BazelDiskCache `
        --define=protobuf_allow_msvc=true `
        --host_cxxopt=/std:c++20 `
        --shell_executable="C:/Program Files/Git/bin/bash.exe" `
        --host_copt=/W0 `
        --host_copt=/Zc:__cplusplus `
        --host_copt=/D_USE_MATH_DEFINES `
        --host_copt=-D_ENABLE_EXTENDED_ALIGNED_STORAGE `
        --host_copt=-DWIN32_LEAN_AND_MEAN `
        --host_copt=-DNOGDI `
        --host_copt=/Zc:preprocessor `
        --host_copt=/Iexternal/com_google_protobuf/src `
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
# Per-architecture .so destination, shared headers (same engine.h /
# litert/c headers across all architectures):
#   Source/ThirdParty/Android/<arch>/         All .so files for this ABI
#   Source/ThirdParty/Public/litert/c/         LiteRT C API headers
#   Source/ThirdParty/Public/litert/c/internal/  internal headers
#   Source/ThirdParty/Public/litert/lm/        LiteRT-LM C API header
#
# UE's Android packaging picks up native .so files via the
# RuntimeDependencies + UPL XML registered in the InoLiteRT module's
# Build.cs. The APK builder copies them into the APK's lib/<arch>/
# directory where Android's dynamic linker picks them up.
Write-Host ""
Write-Host "=== Staging artifacts ===" -ForegroundColor Cyan

$ArchDst          = Join-Path $PluginDir "Source\ThirdParty\Android\$Arch"
$LiteRtHdrDst     = Join-Path $PluginDir "Source\ThirdParty\Public\litert\c"
$LiteRtIntHdrDst  = Join-Path $LiteRtHdrDst "internal"
$LiteRtLmHdrDst   = Join-Path $PluginDir "Source\ThirdParty\Public\litert\lm"
$LiteRtBuildHdrDst = Join-Path $PluginDir "Source\ThirdParty\Public\litert\build_common"

foreach ($d in @($ArchDst, $LiteRtHdrDst, $LiteRtIntHdrDst, $LiteRtLmHdrDst, $LiteRtBuildHdrDst)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# --- Our Bazel-built libLiteRtLm.so ---
# Bazel's cc_binary(linkshared=1) produces the .so with the prefix "lib"
# automatically on non-Windows platforms.
$LiteRtLmBazelBin = Join-Path $LiteRtLmSubDir "bazel-bin\ino"
$SoSrcCandidates = @(
    (Join-Path $LiteRtLmBazelBin "libLiteRtLm.so"),
    (Join-Path $LiteRtLmBazelBin "LiteRtLm.so"),
    (Join-Path $LiteRtLmBazelBin "libino_LiteRtLm.so")
)
$SoSrc = $null
foreach ($c in $SoSrcCandidates) {
    if (Test-Path $c) { $SoSrc = $c; break }
}
if (-not $SoSrc) {
    Write-Warning "libLiteRtLm.so not found. Inspecting bazel-bin/ino for actual outputs:"
    Get-ChildItem $LiteRtLmBazelBin 2>$null | ForEach-Object { Write-Host "  $($_.Name)" }
    throw "libLiteRtLm.so not produced by Bazel"
}
Copy-Item -Path $SoSrc -Destination (Join-Path $ArchDst "libLiteRtLm.so") -Force
Write-Host "  [STAGE] libLiteRtLm.so (from $(Split-Path $SoSrc -Leaf)) -> $ArchDst"

# --- Prebuilt GPU accelerator + constraint provider .so files ---
# From upstream's vendor/LiteRT-LM/prebuilt/android_<arch>/. These are
# dynamically loaded by the LiteRT engine at runtime (via dlopen with
# SharedLibrary::Load).
#
# Android has TWO GPU accelerator paths:
#   WebGPU (via Dawn)     — newer, modern GPUs (Adreno, Mali)
#   OpenCL                — broader compatibility, older GPUs
# Ship both so the LiteRT engine can pick whichever works on the
# target device.
#
# Status of backend="gpu" on Android: UNTESTED on the current pin
# (commit 4dbbf937, post-v0.10.2). Earlier docs claimed it was broken
# because the prebuilt accelerator .so files had DT_NEEDED(libLiteRt.so)
# entries that couldn't resolve — but inspection of the current
# prebuilts shows they only need system libs (libdl, liblog, libm,
# libc, libEGL, libGLESv3). So the original blocker is gone. Whether
# GPU actually works end-to-end on a real device hasn't been verified;
# treat as a smoke test target.
$AndroidPrebuiltDir = Join-Path $LiteRtLmSubDir "prebuilt\$PrebuiltSubDir"
$AndroidPrebuiltSoFiles = @(
    "libGemmaModelConstraintProvider.so",
    "libLiteRtGpuAccelerator.so",
    "libLiteRtOpenClAccelerator.so",
    "libLiteRtTopKOpenClSampler.so",
    "libLiteRtTopKWebGpuSampler.so",
    "libLiteRtWebGpuAccelerator.so"
)
foreach ($so in $AndroidPrebuiltSoFiles) {
    $src = Join-Path $AndroidPrebuiltDir $so
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $ArchDst $so) -Force
        Write-Host "  [STAGE] $so -> $ArchDst"
    } else {
        Write-Warning "Prebuilt not found: $src"
    }
}

# --- Headers: LiteRT C API ---
# Same files as Win64 stages — re-staged here so an Android-only build
# also lands a complete header set. Idempotent if Win64 already ran.
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

# --- Header: LiteRT build_config.h (feature-toggle gate) ---
# Same rationale as build-win64.ps1: litert_common.h:20 includes
# <litert/build_common/build_config.h>, which upstream generates at
# Bazel-build time by selecting one of litert/build_common/config/
# build_config_*.h. We copy the matching variant directly.
#
# Variant choice: build_config_gpu.h — defines LITERT_DISABLE_NPU and
# leaves GPU enabled. Matches what InoLiteRT actually ships on Android
# (libLiteRtGpuAccelerator.so + libLiteRtOpenClAccelerator.so +
# libLiteRtWebGpuAccelerator.so + samplers, no NPU accelerators). Both
# arm64-v8a and x86_64 ship the same GPU-enabled / NPU-disabled set,
# so the same header is correct for both.
$buildConfigSrc = Join-Path $LiteRtSubDir "litert\build_common\config\build_config_gpu.h"
if (Test-Path $buildConfigSrc) {
    Copy-Item -Path $buildConfigSrc -Destination (Join-Path $LiteRtBuildHdrDst "build_config.h") -Force
    Write-Host "  [STAGE] litert/build_common/build_config.h (from build_config_gpu.h) -> $LiteRtBuildHdrDst"
} else {
    Write-Warning "Expected header not found at $buildConfigSrc"
}

Write-Host ""
Write-Host "=== Android $Arch build complete ===" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1. Rebuild the UE project for Android (Package -> Android)"
Write-Host "  2. Install APK on device / emulator"
Write-Host "  3. Test with backend=cpu first; backend=gpu is untested on this pin (see notes above)"
