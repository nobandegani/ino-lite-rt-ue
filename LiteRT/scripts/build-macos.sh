#!/usr/bin/env bash
# build-macos.sh
#
# Build LiteRT-LM from source for macOS arm64 (Apple Silicon) and stage all
# artifacts into the InoLiteRT plugin under Source/ThirdParty/{Mac,Public}.
#
# LiteRT itself is NOT built from source — we use the prebuilt libLiteRt.dylib
# Google ships inside the LiteRT-LM submodule (prebuilt/macos_arm64/). Same
# rationale as build-win64.ps1: the prebuilt's exported C API is identical
# to a from-source build, and a Bazel build of LiteRT itself adds 30+ minutes
# for zero gain.
#
# LiteRT headers (litert/c/*.h, litert/c/internal/*.h, litert/build_common/
# config/*.h) come from Bazel's external-fetch of the LiteRT repo
# (vendor/LiteRT-LM/bazel-litert-lm/external/litert/), pinned by WORKSPACE's
# LITERT_REF.
#
# Step order:
#   1. setup.sh                                       (preflight + overlay)
#   2. bazelisk build //ino:LiteRtLm --config=macos_arm64
#   3. Stage everything to Source/ThirdParty/{Mac,Public}/
#
# Mac arm64 only: upstream LiteRT-LM does not ship macos_x86_64 prebuilts and
# upstream's .bazelrc only has a darwin_arm64 target config. Apple Silicon
# (M1+) is the supported Mac architecture for this plugin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LITERT_LM_SUBDIR="${WORKSPACE_DIR}/vendor/LiteRT-LM"
# LiteRT headers come from Bazel's external-fetch of the LiteRT repo, pulled
# automatically via vendor/LiteRT-LM/WORKSPACE's LITERT_REF when Bazel builds
# //ino:LiteRtLm. The bazel-litert-lm/ symlink resolves to
# <output_base>/external/litert. Using it instead of a separate vendor/LiteRT
# submodule guarantees the staged headers can never drift out of sync with
# the dylib the same Bazel run produced — both come from the SHA pinned in
# WORKSPACE.
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
    echo -e "${RED}ERROR: build-macos.sh must run on a macOS host (got ${host_uname}).${RESET}" >&2
    exit 1
fi
if [[ "${host_arch}" != "arm64" ]]; then
    # Cross-compiling x86_64-host -> arm64-target via Rosetta would work in
    # theory, but upstream's Bazel cache layout assumes the host arch
    # matches the target arch for the macos_arm64 config. Bail with a
    # clear error rather than producing a confusing failure deep in Bazel.
    echo -e "${RED}ERROR: build-macos.sh only supports Apple Silicon hosts (got ${host_arch}).${RESET}" >&2
    echo -e "${RED}       Intel Mac hosts are not supported because upstream LiteRT-LM does${RESET}" >&2
    echo -e "${RED}       not ship macos_x86_64 prebuilts and the bazelrc has no x86_64 config.${RESET}" >&2
    exit 1
fi

#---------------------------------------------------------------------
# 1. Run setup
#---------------------------------------------------------------------
"${SCRIPT_DIR}/setup.sh"

#---------------------------------------------------------------------
# 2. Bazel build LiteRT-LM (//ino:LiteRtLm)
#---------------------------------------------------------------------
# Match the dynamic-linking pattern of build-win64.ps1:
#   --define=litert_link_capi_so=true       LiteRtLm.dylib imports from libLiteRt.dylib
#   --define=resolve_symbols_in_exec=false  symbols come from the dylib, not the host exec
#
# Both of these are also what upstream's ci-build-mac.yml passes for its
# "Run bazel build on MacOS with dynamic linking" job. The default macOS
# build statically links LiteRT into a single binary; we want the split so
# the prebuilt accelerator dylibs (which dlopen libLiteRt.dylib internally)
# share one LiteRT instance with our LiteRtLm.dylib.
#
# --build_tag_filters=-no_mac excludes targets upstream marks as
# Mac-incompatible (parity with their CI's behaviour).
#
# Per-config disk cache so different host platforms don't thrash each other:
#   ~/.cache/ino-mac/      macOS arm64
#   ~/.cache/ino-ios-*/    iOS variants (managed by build-ios.sh)
BAZEL_OUTPUT_BASE="${HOME}/.cache/ino-mac/output"
BAZEL_DISK_CACHE="${HOME}/.cache/ino-mac/disk"
mkdir -p "${BAZEL_OUTPUT_BASE}" "${BAZEL_DISK_CACHE}"

echo ""
echo -e "${CYAN}=== Bazel build: LiteRT-LM (macOS arm64) ===${RESET}"
echo "Working dir:  ${LITERT_LM_SUBDIR}"
echo "Output base:  ${BAZEL_OUTPUT_BASE}"
echo "Disk cache:   ${BAZEL_DISK_CACHE}"
echo "Target:       //ino:LiteRtLm"
echo ""

# Clear ANDROID_NDK_HOME for this child process only (parity with
# build-win64.ps1's behaviour: avoid androidndk rules trying to symlink into
# a host NDK install when none is needed).
ANDROID_NDK_HOME=""
export ANDROID_NDK_HOME

(
    cd "${LITERT_LM_SUBDIR}"
    bazelisk --output_base="${BAZEL_OUTPUT_BASE}" \
        build //ino:LiteRtLm \
        --config=macos_arm64 \
        --disk_cache="${BAZEL_DISK_CACHE}" \
        --build_tag_filters=-no_mac \
        --define=litert_link_capi_so=true \
        --define=resolve_symbols_in_exec=false \
        --verbose_failures
)

#---------------------------------------------------------------------
# 3. Stage all artifacts into Source/ThirdParty/
#---------------------------------------------------------------------
# Single destination tree:
#   Source/ThirdParty/Mac/                      All dylibs
#   Source/ThirdParty/Public/litert/c/          LiteRT C API headers (shared
#   Source/ThirdParty/Public/litert/c/internal/   with Win64/Android/iOS — re-
#   Source/ThirdParty/Public/litert/c/options/    staged here is idempotent)
#   Source/ThirdParty/Public/litert/lm/         LiteRT-LM C API header
#   Source/ThirdParty/Public/litert/build_common/  build_config.h
echo ""
echo -e "${CYAN}=== Staging artifacts ===${RESET}"

MAC_DST="${PLUGIN_DIR}/Source/ThirdParty/Mac"
LITERT_HDR_DST="${PLUGIN_DIR}/Source/ThirdParty/Public/litert/c"
LITERT_INT_HDR_DST="${LITERT_HDR_DST}/internal"
LITERT_OPT_HDR_DST="${LITERT_HDR_DST}/options"
LITERT_LM_HDR_DST="${PLUGIN_DIR}/Source/ThirdParty/Public/litert/lm"
LITERT_BUILD_HDR_DST="${PLUGIN_DIR}/Source/ThirdParty/Public/litert/build_common"

mkdir -p "${MAC_DST}" "${LITERT_HDR_DST}" "${LITERT_INT_HDR_DST}" \
         "${LITERT_OPT_HDR_DST}" "${LITERT_LM_HDR_DST}" "${LITERT_BUILD_HDR_DST}"

#---------------------------------------------------------------------
# 3a. Our Bazel-built libLiteRtLm.dylib
#---------------------------------------------------------------------
# Bazel's cc_binary(linkshared=1) produces the .dylib with the lib prefix
# automatically on Apple platforms.
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
cp -f "${so_src}" "${MAC_DST}/libLiteRtLm.dylib"
echo "  [STAGE] libLiteRtLm.dylib (from $(basename "${so_src}")) -> ${MAC_DST}"

#---------------------------------------------------------------------
# 3b. Upstream prebuilt dylibs from prebuilt/macos_arm64/
#---------------------------------------------------------------------
# We ship every prebuilt dylib in this directory. The Metal accelerators are
# the preferred GPU path on Apple platforms (Apple Silicon's tile-based
# renderer architecture matches Metal's command-buffer model directly);
# WebGPU on Mac goes through Dawn which translates to Metal anyway, so we
# include both to give the LiteRT engine a choice at runtime.
MACOS_PREBUILT_DIR="${LITERT_LM_SUBDIR}/prebuilt/macos_arm64"
MACOS_PREBUILTS=(
    "libLiteRt.dylib"                       # LiteRT core (matches our litert_link_capi_so build)
    "libGemmaModelConstraintProvider.dylib" # required sibling (constrained decoding for Gemma)
    "libLiteRtMetalAccelerator.dylib"       # Metal GPU backend (preferred on Apple)
    "libLiteRtTopKMetalSampler.dylib"       # Metal-side top-K sampling
    "libLiteRtWebGpuAccelerator.dylib"      # WebGPU GPU backend (Dawn -> Metal)
    "libLiteRtTopKWebGpuSampler.dylib"      # WebGPU-side top-K sampling
)
for dylib in "${MACOS_PREBUILTS[@]}"; do
    src="${MACOS_PREBUILT_DIR}/${dylib}"
    if [[ -f "${src}" ]]; then
        cp -f "${src}" "${MAC_DST}/${dylib}"
        echo "  [STAGE] ${dylib} (prebuilt) -> ${MAC_DST}"
    else
        echo -e "${YELLOW}WARNING: prebuilt not found: ${src}${RESET}" >&2
    fi
done

#---------------------------------------------------------------------
# 3c. Verify install_names use @rpath/<name>.dylib
#---------------------------------------------------------------------
# UE's Mac packaging copies our staged dylibs into the .app's
# Contents/UE/<plugin>/Source/ThirdParty/Mac/ and adds @loader_path/ rpath
# entries in the consuming binary, so the dylibs' own LC_ID_DYLIB
# (install_name) needs to be @rpath-relative for the runtime loader to find
# them. Upstream prebuilts ship with @rpath install_names already; we
# verify and fix-up any that don't.
#
# We also remap inter-library references: if libLiteRtLm.dylib internally
# imports from /absolute/path/to/libLiteRt.dylib (a Bazel build-tree path
# that won't exist on end-user machines), rewrite it to @rpath/libLiteRt.dylib.
# Walking otool -L's output is the standard pattern.
echo ""
echo -e "${YELLOW}--- install_name fix-up ---${RESET}"

fix_install_names() {
    local dylib="$1"
    local base
    base="$(basename "${dylib}")"

    # 1. Set the dylib's own install_name to @rpath/<base>
    local current_id
    current_id="$(otool -D "${dylib}" | tail -n1)"
    local desired_id="@rpath/${base}"
    if [[ "${current_id}" != "${desired_id}" ]]; then
        install_name_tool -id "${desired_id}" "${dylib}"
        echo "  [FIX-ID] ${base}: '${current_id}' -> '${desired_id}'"
    fi

    # 2. Walk otool -L output, line format:
    #       <indent><path> (compatibility version <X>, current version <Y>)
    #    Rewrite any reference to a sibling LiteRT* dylib that uses an
    #    absolute path or bare filename to the canonical @rpath form.
    while IFS= read -r line; do
        # Strip the leading tab + trailing version annotation.
        local dep
        dep="$(echo "${line}" | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//')"
        [[ -z "${dep}" ]] && continue
        # Skip the dylib's own LC_ID_DYLIB line (first dep line is the
        # binary itself when otool -L shows it for a dylib).
        [[ "${dep}" == "${desired_id}" ]] && continue
        [[ "${dep}" == "${current_id}" ]] && continue

        local dep_base
        dep_base="$(basename "${dep}")"
        # Only remap our own LiteRT* / Gemma* siblings — leave system libs
        # (/usr/lib/libSystem.B.dylib, /System/Library/Frameworks/...) alone.
        case "${dep_base}" in
            libLiteRt*.dylib|libGemmaModelConstraintProvider.dylib)
                local desired_dep="@rpath/${dep_base}"
                if [[ "${dep}" != "${desired_dep}" ]]; then
                    install_name_tool -change "${dep}" "${desired_dep}" "${dylib}"
                    echo "  [FIX-DEP] ${base}: '${dep}' -> '${desired_dep}'"
                fi
                ;;
        esac
    done < <(otool -L "${dylib}" | tail -n +2)
}

for dylib in "${MAC_DST}"/*.dylib; do
    [[ -f "${dylib}" ]] || continue
    fix_install_names "${dylib}"
done

#---------------------------------------------------------------------
# 3d. Headers (shared with Win64/Android — same files, idempotent)
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

# LiteRT-LM C API (engine.h)
lm_header="${LITERT_LM_SUBDIR}/c/engine.h"
if [[ -f "${lm_header}" ]]; then
    cp -f "${lm_header}" "${LITERT_LM_HDR_DST}/engine.h"
    echo "  [STAGE] litert/lm/engine.h -> ${LITERT_LM_HDR_DST}"
else
    echo -e "${YELLOW}WARNING: expected header not found at ${lm_header}${RESET}" >&2
fi

# LiteRT build_config.h — same selection rationale as build-win64.ps1:
# build_config_gpu.h matches our shipped feature set (GPU enabled, NPU
# disabled). On Apple platforms the GPU path is Metal+WebGPU, but the gate
# header just controls LITERT_HAS_GPU / LITERT_DISABLE_NPU defines, not the
# specific accelerator backend.
build_config_src="${LITERT_SUBDIR}/litert/build_common/config/build_config_gpu.h"
if [[ -f "${build_config_src}" ]]; then
    cp -f "${build_config_src}" "${LITERT_BUILD_HDR_DST}/build_config.h"
    echo "  [STAGE] litert/build_common/build_config.h (from build_config_gpu.h) -> ${LITERT_BUILD_HDR_DST}"
else
    echo -e "${YELLOW}WARNING: expected header not found at ${build_config_src}${RESET}" >&2
fi

echo ""
echo -e "${GREEN}=== macOS arm64 build complete ===${RESET}"
echo "Next steps:"
echo "  1. Rebuild the UE project for Mac (Package -> Mac)"
echo "  2. Test with backend=cpu first; backend=gpu uses Metal on Apple Silicon"
