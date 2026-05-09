#!/usr/bin/env bash
# setup.sh
#
# One-time setup for the LiteRT-LM Bazel build workspace on macOS hosts:
#   1. Verifies toolchain prerequisites (bazelisk, git, Xcode CLT)
#   2. Ensures the LiteRT-LM submodule is initialized
#   3. Copies LiteRT/overlay/* into vendor/LiteRT-LM/
#   4. Updates the submodule's .git/info/exclude so overlay + bazel artifacts
#      don't show as dirty
#
# Idempotent: safe to run repeatedly.
#
# Companion to setup.ps1 (Windows host). Build hosts:
#   macOS  -> setup.sh   (this file) + build-macos.sh / build-ios.sh
#   Windows -> setup.ps1                + build-win64.ps1 / build-android.ps1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OVERLAY_DIR="${WORKSPACE_DIR}/overlay"
SUBMODULE_DIR="${WORKSPACE_DIR}/vendor/LiteRT-LM"
PLUGIN_DIR="$(cd "${WORKSPACE_DIR}/.." && pwd)"

# ANSI colour helpers (mirroring the PowerShell Write-Host -ForegroundColor calls)
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

echo -e "${CYAN}=== LiteRT-LM Bazel workspace setup ===${RESET}"
echo "Plugin dir:    ${PLUGIN_DIR}"
echo "Workspace dir: ${WORKSPACE_DIR}"
echo "Submodule dir: ${SUBMODULE_DIR}"
echo ""

#---------------------------------------------------------------------
# 1. Preflight
#---------------------------------------------------------------------
echo -e "${YELLOW}--- Preflight ---${RESET}"

check_cmd() {
    local name="$1"
    local hint="$2"
    if ! command -v "${name}" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: ${name} not found on PATH. ${hint}${RESET}" >&2
        exit 1
    fi
    echo "  [OK] ${name} -> $(command -v "${name}")"
}

check_cmd bazelisk "Install via: brew install bazelisk"
check_cmd git "Install via: xcode-select --install or brew install git"

# Xcode Command Line Tools provide clang, ld, install_name_tool, otool, etc.
# Bazel's apple_support rules use xcrun to find them, which requires a
# selectable developer dir. xcode-select -p prints the active developer dir
# and exits non-zero if none is configured.
if ! xcode-select -p >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Xcode Command Line Tools not configured.${RESET}" >&2
    echo -e "${RED}       Run: xcode-select --install${RESET}" >&2
    exit 1
fi
echo "  [OK] Xcode developer dir -> $(xcode-select -p)"

# install_name_tool is part of Xcode CLT but verify explicitly — build-ios.sh
# depends on it for framework wrapping.
check_cmd install_name_tool "Should ship with Xcode CLT — try: xcode-select --install"
check_cmd otool             "Should ship with Xcode CLT — try: xcode-select --install"

echo ""

#---------------------------------------------------------------------
# 2. Submodule initialization
#---------------------------------------------------------------------
echo -e "${YELLOW}--- Submodule ---${RESET}"

if [[ ! -e "${SUBMODULE_DIR}/.git" ]]; then
    echo "Submodule not initialized, running 'git submodule update --init --recursive'..."
    (cd "${PLUGIN_DIR}" && git submodule update --init --recursive)
fi

submodule_head="$(git -C "${SUBMODULE_DIR}" rev-parse --short HEAD)"
echo "  [OK] Submodule at ${submodule_head}"
echo ""

#---------------------------------------------------------------------
# 3. Apply overlay (copy overlay/* into submodule)
#---------------------------------------------------------------------
echo -e "${YELLOW}--- Overlay ---${RESET}"

declare -a OVERLAY_TOP_PATHS=()

if [[ -d "${OVERLAY_DIR}" ]]; then
    # Walk every regular file under overlay/ and copy preserving structure.
    while IFS= read -r -d '' src; do
        rel="${src#${OVERLAY_DIR}/}"
        dst="${SUBMODULE_DIR}/${rel}"
        mkdir -p "$(dirname "${dst}")"
        cp -f "${src}" "${dst}"
        echo "  [COPY] ${rel}"

        top="${rel%%/*}"
        # Track first-segment overlay paths for the exclude file below.
        # (POSIX bash: dedupe with a linear scan since associative arrays
        # are bash-4-only and macOS ships bash 3.x.)
        already=0
        for existing in "${OVERLAY_TOP_PATHS[@]+"${OVERLAY_TOP_PATHS[@]}"}"; do
            if [[ "${existing}" == "${top}" ]]; then
                already=1
                break
            fi
        done
        if [[ ${already} -eq 0 ]]; then
            OVERLAY_TOP_PATHS+=("${top}")
        fi
    done < <(find "${OVERLAY_DIR}" -type f -print0)
else
    echo -e "${YELLOW}WARNING: Overlay directory not found: ${OVERLAY_DIR}${RESET}"
fi

echo ""

#---------------------------------------------------------------------
# 4. Update submodule's .git/info/exclude
#---------------------------------------------------------------------
echo -e "${YELLOW}--- Submodule exclude list ---${RESET}"

# A submodule's .git is a *file* pointing at <parent>/.git/modules/<path>/.
# Resolve the real .git dir via git itself, identical to setup.ps1.
git_dir="$(git -C "${SUBMODULE_DIR}" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ -z "${git_dir}" ]]; then
    echo -e "${YELLOW}WARNING: Could not resolve submodule git dir; skipping exclude update${RESET}"
else
    echo "  .git dir: ${git_dir}"
    info_dir="${git_dir}/info"
    mkdir -p "${info_dir}"
    exclude_file="${info_dir}/exclude"
    touch "${exclude_file}"

    # Build the same set of exclude entries as setup.ps1: every overlay
    # top-level dir + Bazel artifacts + user bazelrc files.
    declare -a EXCLUDE_ENTRIES=()
    for p in "${OVERLAY_TOP_PATHS[@]+"${OVERLAY_TOP_PATHS[@]}"}"; do
        EXCLUDE_ENTRIES+=("/${p}/")
    done
    EXCLUDE_ENTRIES+=("/bazel-*")
    EXCLUDE_ENTRIES+=("/user.bazelrc")
    EXCLUDE_ENTRIES+=("/.bazelrc.user")

    for entry in "${EXCLUDE_ENTRIES[@]}"; do
        if grep -Fxq "${entry}" "${exclude_file}"; then
            echo "  [OK]  ${entry} (already present)"
        else
            echo "${entry}" >> "${exclude_file}"
            echo "  [ADD] ${entry}"
        fi
    done
fi

echo ""
echo -e "${GREEN}=== Setup complete ===${RESET}"
