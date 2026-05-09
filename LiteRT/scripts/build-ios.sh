#!/usr/bin/env bash
# build-ios.sh
#
# Build LiteRT-LM from source for iOS (arm64 device or arm64 simulator) and
# stage all artifacts into the InoLiteRT plugin under
# Source/ThirdParty/{IOS/<arch>, Public}.
#
# Usage:
#   ./build-ios.sh                  # default: arm64 device
#   ./build-ios.sh --arch arm64     # explicit device build
#   ./build-ios.sh --arch sim_arm64 # Apple Silicon simulator build
#
# WHY .framework WRAPPING:
#   Apple's App Store rejects apps that load arbitrary .dylibs at runtime.
#   Dynamic libraries must be embedded as .framework bundles inside the
#   .app's Frameworks/ directory and code-signed with the app's identity.
#   This script wraps each upstream .dylib into a proper .framework layout
#   and fixes up install_names so the iOS dynamic loader can resolve them
#   from @rpath/<Name>.framework/<Name>.
#
#   UE's iOS toolchain consumes these via PublicAdditionalFrameworks in
#   Build.cs (with bCopyFramework=true), which embeds + signs them at
#   packaging time.
#
# Step order:
#   1. setup.sh                                           (preflight + overlay)
#   2. bazelisk build //ino:LiteRtLm --config=ios_<arch>  (host: macOS arm64)
#   3. Wrap each .dylib into <Name>.framework/<Name> + Info.plist
#   4. Fix install_names to @rpath/<Name>.framework/<Name>
#   5. Zip each .framework so UE's Framework class can consume it
#   6. Stage everything to Source/ThirdParty/IOS/<arch>/

set -euo pipefail

#---------------------------------------------------------------------
# Argument parsing: --arch arm64 (device, default) or --arch sim_arm64
#---------------------------------------------------------------------
ARCH="arm64"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --arch=*)
            ARCH="${1#--arch=}"
            shift
            ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

case "${ARCH}" in
    arm64)
        BAZEL_CONFIG="ios_arm64"
        PREBUILT_SUBDIR="ios_arm64"
        SHORT_ARCH="i64"
        ;;
    sim_arm64)
        BAZEL_CONFIG="ios_sim_arm64"
        PREBUILT_SUBDIR="ios_sim_arm64"
        SHORT_ARCH="is64"
        ;;
    *)
        echo "ERROR: --arch must be 'arm64' or 'sim_arm64' (got: ${ARCH})" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LITERT_LM_SUBDIR="${WORKSPACE_DIR}/vendor/LiteRT-LM"
# LiteRT headers come from Bazel's external-fetch (same as build-macos.sh /
# build-win64.ps1) — the LITERT_REF SHA in WORKSPACE is the single source
# of truth for both binaries and headers.
LITERT_SUBDIR="${LITERT_LM_SUBDIR}/bazel-litert-lm/external/litert"
PLUGIN_DIR="$(cd "${WORKSPACE_DIR}/.." && pwd)"

CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

#---------------------------------------------------------------------
# 0. Host preflight: must be macOS arm64
#---------------------------------------------------------------------
host_uname="$(uname -s)"
host_arch="$(uname -m)"
if [[ "${host_uname}" != "Darwin" ]]; then
    echo -e "${RED}ERROR: build-ios.sh must run on a macOS host (got ${host_uname}).${RESET}" >&2
    exit 1
fi
if [[ "${host_arch}" != "arm64" ]]; then
    # Apple Silicon host required — same rationale as build-macos.sh, plus
    # iOS Simulator builds for sim_arm64 need an arm64 host because Bazel's
    # apple_support config runs the simulator slice through the host's
    # XCRun toolchain which on Intel hosts produces x86_64 sim binaries
    # (the wrong arch for the ios_sim_arm64 config).
    echo -e "${RED}ERROR: build-ios.sh only supports Apple Silicon hosts (got ${host_arch}).${RESET}" >&2
    exit 1
fi

#---------------------------------------------------------------------
# 1. Run setup
#---------------------------------------------------------------------
"${SCRIPT_DIR}/setup.sh"

#---------------------------------------------------------------------
# 2. Bazel build LiteRT-LM (//ino:LiteRtLm)
#---------------------------------------------------------------------
# iOS configs from upstream's .bazelrc:
#   build:ios            --apple_platform_type=ios
#                        --copt=-fembed-bitcode
#                        --copt=-Wno-c++11-narrowing
#                        --ios_minimum_os=13.0
#                        --noenable_platform_specific_config
#                        --copt=-w
#                        --cxxopt=-std=c++20
#                        --define=with_xla_support=false
#                        --copt=-DABSL_FLAGS_STRIP_NAMES=0
#   build:ios_arm64      inherits ios + --cpu=ios_arm64
#                        --platforms=@build_bazel_apple_support//platforms:ios_arm64
#   build:ios_sim_arm64  inherits ios + --cpu=ios_sim_arm64
#                        --platforms=@build_bazel_apple_support//platforms:ios_sim_arm64
#
# Both --define=litert_link_capi_so=true and --define=resolve_symbols_in_exec=false
# are passed for parity with the Win64 / macOS dynamic-linking pattern: our
# LiteRtLm.dylib imports from libLiteRt.dylib at runtime, sharing one
# LiteRT instance with the prebuilt accelerator dylibs.
#
# Per-arch disk + output base — separate from macOS's so the two builds don't
# thrash each other's caches:
#   ~/.cache/ino-ios-i64/   iOS arm64 device
#   ~/.cache/ino-ios-is64/  iOS arm64 simulator
BAZEL_OUTPUT_BASE="${HOME}/.cache/ino-ios-${SHORT_ARCH}/output"
BAZEL_DISK_CACHE="${HOME}/.cache/ino-ios-${SHORT_ARCH}/disk"
mkdir -p "${BAZEL_OUTPUT_BASE}" "${BAZEL_DISK_CACHE}"

echo ""
echo -e "${CYAN}=== Bazel build: LiteRT-LM (iOS ${ARCH}) ===${RESET}"
echo "Working dir:  ${LITERT_LM_SUBDIR}"
echo "Output base:  ${BAZEL_OUTPUT_BASE}"
echo "Disk cache:   ${BAZEL_DISK_CACHE}"
echo "Bazel config: --config=${BAZEL_CONFIG}"
echo "Target:       //ino:LiteRtLm"
echo ""

# Same parity reason as macOS/Windows: don't accidentally wire ANDROID_NDK_HOME
# into the iOS build's androidndk repo rules.
ANDROID_NDK_HOME=""
export ANDROID_NDK_HOME

# The simulator build needs --build_tag_filters to skip Mac-only targets
# (per upstream ci-build-mac.yml). For device builds the tag filter is
# harmless because no targets in our dep graph have those tags.
(
    cd "${LITERT_LM_SUBDIR}"
    bazelisk --output_base="${BAZEL_OUTPUT_BASE}" \
        build //ino:LiteRtLm \
        --config="${BAZEL_CONFIG}" \
        --disk_cache="${BAZEL_DISK_CACHE}" \
        --build_tag_filters=-requires-mac-inputs:hard,-no_mac \
        --define=litert_link_capi_so=true \
        --define=resolve_symbols_in_exec=false \
        --verbose_failures
)

#---------------------------------------------------------------------
# 3. Stage artifacts: collect dylibs into a temp dir for framework wrapping
#---------------------------------------------------------------------
echo ""
echo -e "${CYAN}=== Staging artifacts ===${RESET}"

ARCH_DST="${PLUGIN_DIR}/Source/ThirdParty/IOS/${ARCH}"
LITERT_HDR_DST="${PLUGIN_DIR}/Source/ThirdParty/Public/litert/c"
LITERT_INT_HDR_DST="${LITERT_HDR_DST}/internal"
LITERT_OPT_HDR_DST="${LITERT_HDR_DST}/options"
LITERT_LM_HDR_DST="${PLUGIN_DIR}/Source/ThirdParty/Public/litert/lm"
LITERT_BUILD_HDR_DST="${PLUGIN_DIR}/Source/ThirdParty/Public/litert/build_common"

mkdir -p "${ARCH_DST}" "${LITERT_HDR_DST}" "${LITERT_INT_HDR_DST}" \
         "${LITERT_OPT_HDR_DST}" "${LITERT_LM_HDR_DST}" "${LITERT_BUILD_HDR_DST}"

# Wipe any pre-existing .framework / .framework.zip artifacts in the dest
# so re-runs after upstream pin changes don't leave stale per-symbol diffs
# inside an old framework directory.
find "${ARCH_DST}" -maxdepth 1 -name '*.framework' -type d -exec rm -rf {} + 2>/dev/null || true
find "${ARCH_DST}" -maxdepth 1 -name '*.framework.zip' -type f -delete 2>/dev/null || true

# Temp staging dir for raw dylibs before framework wrapping.
TMP_STAGE="$(mktemp -d -t inolitert-ios.XXXXXX)"
trap 'rm -rf "${TMP_STAGE}"' EXIT

#---------------------------------------------------------------------
# 3a. Our Bazel-built libLiteRtLm.dylib
#---------------------------------------------------------------------
LITE_RT_LM_BAZEL_BIN="${LITERT_LM_SUBDIR}/bazel-bin/ino"
so_src=""
for candidate in libLiteRtLm.dylib LiteRtLm.dylib libLiteRtLm.so; do
    if [[ -f "${LITE_RT_LM_BAZEL_BIN}/${candidate}" ]]; then
        so_src="${LITE_RT_LM_BAZEL_BIN}/${candidate}"
        break
    fi
done
if [[ -z "${so_src}" ]]; then
    echo -e "${YELLOW}WARNING: libLiteRtLm.dylib not found. Inspecting bazel-bin/ino:${RESET}" >&2
    ls -l "${LITE_RT_LM_BAZEL_BIN}" 2>/dev/null || true
    echo -e "${RED}ERROR: libLiteRtLm.dylib not produced by Bazel${RESET}" >&2
    exit 1
fi
cp -f "${so_src}" "${TMP_STAGE}/libLiteRtLm.dylib"
echo "  [STAGE] libLiteRtLm.dylib (from $(basename "${so_src}")) -> tmp"

#---------------------------------------------------------------------
# 3b. Upstream prebuilt dylibs from prebuilt/ios_<arch>/
#---------------------------------------------------------------------
# Note iOS device and simulator have different prebuilt sets:
#   ios_arm64/      libLiteRt.dylib + Metal accel + Metal top-K + Gemma
#   ios_sim_arm64/  libLiteRt.dylib + Metal accel + Gemma  (no top-K Metal)
# WebGPU prebuilts are NOT shipped on iOS — Apple platforms use Metal directly.
IOS_PREBUILT_DIR="${LITERT_LM_SUBDIR}/prebuilt/${PREBUILT_SUBDIR}"
IOS_PREBUILTS=(
    "libLiteRt.dylib"
    "libGemmaModelConstraintProvider.dylib"
    "libLiteRtMetalAccelerator.dylib"
    "libLiteRtTopKMetalSampler.dylib"
)
for dylib in "${IOS_PREBUILTS[@]}"; do
    src="${IOS_PREBUILT_DIR}/${dylib}"
    if [[ -f "${src}" ]]; then
        cp -f "${src}" "${TMP_STAGE}/${dylib}"
        echo "  [STAGE] ${dylib} (prebuilt) -> tmp"
    else
        # ios_sim_arm64 legitimately omits libLiteRtTopKMetalSampler — log
        # info, not warning, since it's not an error.
        echo "  [SKIP]  ${dylib} (not present in ${PREBUILT_SUBDIR}/, expected for some sim builds)"
    fi
done

#---------------------------------------------------------------------
# 3c. Wrap each .dylib into a .framework bundle
#---------------------------------------------------------------------
# Layout produced per dylib:
#   <Name>.framework/
#     <Name>          <- renamed binary, no "lib" prefix, no ".dylib"
#     Info.plist      <- minimal CFBundle metadata
#
# The framework name is derived by stripping the leading "lib" and trailing
# ".dylib" from the source filename:
#
#   libLiteRt.dylib                       -> LiteRt.framework/LiteRt
#   libLiteRtLm.dylib                     -> LiteRtLm.framework/LiteRtLm
#   libLiteRtMetalAccelerator.dylib       -> LiteRtMetalAccelerator.framework/...
#   libLiteRtTopKMetalSampler.dylib       -> LiteRtTopKMetalSampler.framework/...
#   libGemmaModelConstraintProvider.dylib -> GemmaModelConstraintProvider.framework/...
#
# Apple's framework naming convention is alphanumeric only (the binary name
# inside the .framework must match CFBundleExecutable in Info.plist and
# becomes the CFBundleIdentifier suffix).
echo ""
echo -e "${YELLOW}--- Framework wrapping ---${RESET}"

dylib_to_framework_name() {
    local fname="$1"
    fname="${fname#lib}"     # strip leading "lib"
    fname="${fname%.dylib}"  # strip trailing ".dylib"
    echo "${fname}"
}

declare -a FRAMEWORK_NAMES=()
for dylib in "${TMP_STAGE}"/*.dylib; do
    [[ -f "${dylib}" ]] || continue
    base="$(basename "${dylib}")"
    fw_name="$(dylib_to_framework_name "${base}")"
    fw_dir="${ARCH_DST}/${fw_name}.framework"

    mkdir -p "${fw_dir}"
    cp -f "${dylib}" "${fw_dir}/${fw_name}"

    # Minimal Info.plist. iOS requires CFBundleExecutable, CFBundleIdentifier,
    # CFBundlePackageType, MinimumOSVersion. CFBundleIdentifier reverse-DNS
    # uses "com.inoland.<framework_name>" — just needs to be unique and
    # match the embedded codesign identity at packaging time. UE's iOS
    # toolchain re-signs the framework with the app's bundle ID anyway.
    cat > "${fw_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${fw_name}</string>
	<key>CFBundleIdentifier</key>
	<string>com.inoland.${fw_name}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${fw_name}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>13.0</string>
</dict>
</plist>
EOF

    FRAMEWORK_NAMES+=("${fw_name}")
    echo "  [WRAP] ${base} -> ${fw_name}.framework/${fw_name}"
done

#---------------------------------------------------------------------
# 3d. Fix install_names: @rpath/<Name>.framework/<Name>
#---------------------------------------------------------------------
# Two passes per binary:
#   1. install_name_tool -id  : set the framework's own LC_ID_DYLIB
#   2. install_name_tool -change: rewrite each LC_LOAD_DYLIB that points at
#      a sibling LiteRt*/Gemma* dylib to the framework form.
#
# Pre-build mapping table once: old_path -> new_path. otool -L line format:
#       <indent><path> (compatibility version <X>, current version <Y>)
echo ""
echo -e "${YELLOW}--- install_name fix-up ---${RESET}"

# Build a map of "every basename we wrap" -> "@rpath/<Name>.framework/<Name>"
declare -a SIBLING_BASES=()
declare -a SIBLING_NEW_PATHS=()
for dylib in "${TMP_STAGE}"/*.dylib; do
    [[ -f "${dylib}" ]] || continue
    base="$(basename "${dylib}")"
    fw_name="$(dylib_to_framework_name "${base}")"
    SIBLING_BASES+=("${base}")
    SIBLING_NEW_PATHS+=("@rpath/${fw_name}.framework/${fw_name}")
done

lookup_sibling() {
    local needle="$1"
    local i=0
    for b in "${SIBLING_BASES[@]}"; do
        if [[ "${b}" == "${needle}" ]]; then
            echo "${SIBLING_NEW_PATHS[$i]}"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

for fw_name in "${FRAMEWORK_NAMES[@]}"; do
    fw_bin="${ARCH_DST}/${fw_name}.framework/${fw_name}"
    [[ -f "${fw_bin}" ]] || continue

    # 1. Set this framework's own install_name.
    desired_id="@rpath/${fw_name}.framework/${fw_name}"
    current_id="$(otool -D "${fw_bin}" | tail -n1)"
    if [[ "${current_id}" != "${desired_id}" ]]; then
        install_name_tool -id "${desired_id}" "${fw_bin}"
        echo "  [FIX-ID]  ${fw_name}: '${current_id}' -> '${desired_id}'"
    fi

    # 2. Walk dep references; remap any sibling LiteRt*/Gemma* path.
    while IFS= read -r line; do
        dep="$(echo "${line}" | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//')"
        [[ -z "${dep}" ]] && continue
        [[ "${dep}" == "${desired_id}" ]] && continue
        [[ "${dep}" == "${current_id}" ]] && continue

        dep_base="$(basename "${dep}")"
        if new_path="$(lookup_sibling "${dep_base}")"; then
            if [[ "${dep}" != "${new_path}" ]]; then
                install_name_tool -change "${dep}" "${new_path}" "${fw_bin}"
                echo "  [FIX-DEP] ${fw_name}: '${dep}' -> '${new_path}'"
            fi
        fi
    done < <(otool -L "${fw_bin}" | tail -n +2)
done

#---------------------------------------------------------------------
# 3e. Code-signing — DEFERRED to UE's packaging pipeline
#---------------------------------------------------------------------
# UE's IOSToolChain.cs re-signs every embedded framework with the app's
# distribution identity at packaging time, so signing here would be wasted
# work (and the Bazel build host's signing identity wouldn't match the
# user's app provisioning anyway). We deliberately leave the framework
# binaries unsigned. UE handles it. To verify the signature was applied
# correctly post-package:
#     codesign -dvv MyApp.app/Frameworks/LiteRtLm.framework

#---------------------------------------------------------------------
# 3f. Zip each .framework so UE's Framework class can consume it
#---------------------------------------------------------------------
# UE 5.x Build.cs wires frameworks via:
#     PublicAdditionalFrameworks.Add(new Framework("Name", "<path>", null, true));
# where <path> is canonically a .zip of the framework. UE unzips at packaging
# time. (UE also accepts unzipped .framework dirs, but the .zip form has
# better cross-version compatibility.)
#
# We use ditto rather than zip(1): ditto preserves macOS extended attributes
# and signing metadata, the standard tool for framework packaging.
echo ""
echo -e "${YELLOW}--- Framework zipping ---${RESET}"
for fw_name in "${FRAMEWORK_NAMES[@]}"; do
    fw_dir="${ARCH_DST}/${fw_name}.framework"
    fw_zip="${ARCH_DST}/${fw_name}.framework.zip"
    [[ -d "${fw_dir}" ]] || continue
    (cd "${ARCH_DST}" && ditto -c -k --keepParent "${fw_name}.framework" "${fw_zip}")
    echo "  [ZIP] ${fw_name}.framework -> $(basename "${fw_zip}") ($(du -h "${fw_zip}" | cut -f1))"
done

#---------------------------------------------------------------------
# 3g. Headers (shared across all platforms — idempotent re-stage)
#---------------------------------------------------------------------
echo ""
echo -e "${YELLOW}--- Headers ---${RESET}"

stage_dir() {
    local label="$1"
    local src_dir="$2"
    local dst_dir="$3"
    if [[ ! -d "${src_dir}" ]]; then
        echo -e "${YELLOW}WARNING: ${label} source dir not found: ${src_dir}${RESET}" >&2
        return
    fi
    local count=0
    for h in "${src_dir}"/*.h; do
        [[ -f "${h}" ]] || continue
        cp -f "${h}" "${dst_dir}/$(basename "${h}")"
        count=$((count + 1))
    done
    echo "  [STAGE] ${label} (${count} files) -> ${dst_dir}"
}

stage_dir "litert/c/*.h"          "${LITERT_SUBDIR}/litert/c"          "${LITERT_HDR_DST}"
stage_dir "litert/c/internal/*.h" "${LITERT_SUBDIR}/litert/c/internal" "${LITERT_INT_HDR_DST}"
stage_dir "litert/c/options/*.h"  "${LITERT_SUBDIR}/litert/c/options"  "${LITERT_OPT_HDR_DST}"

lm_header="${LITERT_LM_SUBDIR}/c/engine.h"
if [[ -f "${lm_header}" ]]; then
    cp -f "${lm_header}" "${LITERT_LM_HDR_DST}/engine.h"
    echo "  [STAGE] litert/lm/engine.h -> ${LITERT_LM_HDR_DST}"
fi

build_config_src="${LITERT_SUBDIR}/litert/build_common/config/build_config_gpu.h"
if [[ -f "${build_config_src}" ]]; then
    cp -f "${build_config_src}" "${LITERT_BUILD_HDR_DST}/build_config.h"
    echo "  [STAGE] litert/build_common/build_config.h (from build_config_gpu.h) -> ${LITERT_BUILD_HDR_DST}"
fi

echo ""
echo -e "${GREEN}=== iOS ${ARCH} build complete ===${RESET}"
echo "Frameworks staged: ${ARCH_DST}/"
for fw_name in "${FRAMEWORK_NAMES[@]}"; do
    echo "  - ${fw_name}.framework + ${fw_name}.framework.zip"
done
echo ""
echo "Next steps:"
echo "  1. Build the UE project for IOS (Project Launcher -> iOS)"
echo "  2. Frameworks will be embedded into MyApp.app/Frameworks/ and signed"
echo "     with the app's distribution identity by UE's packaging step."
