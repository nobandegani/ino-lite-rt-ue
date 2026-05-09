#!/usr/bin/env bash
# clean.sh
#
# Wipe the Bazel build caches for the macOS + iOS builds of LiteRT-LM.
# Use when you want to force a full cold rebuild (e.g. after tooling
# changes, corrupted cache).
#
# Runs 'bazelisk clean --expunge' inside vendor/LiteRT-LM/ once per
# output base — the bazel-* symlinks and output artifacts actually live
# under the output base, but the workspace itself is the submodule.
#
# Companion to clean.ps1 (Windows host). Each script only knows about
# the output bases its sibling build scripts produce; running both on
# the same machine (rare — Mac and Windows hosts are separate) is safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUBMODULE_DIR="${WORKSPACE_DIR}/vendor/LiteRT-LM"

CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
RESET='\033[0m'

if [[ ! -d "${SUBMODULE_DIR}" ]]; then
    echo "Submodule not initialized: ${SUBMODULE_DIR}"
    exit 0
fi

# Same naming scheme as build-macos.sh / build-ios.sh:
#   ~/.cache/ino-mac/output           macOS arm64
#   ~/.cache/ino-ios-i64/output       iOS arm64 device
#   ~/.cache/ino-ios-is64/output      iOS arm64 simulator
declare -a OUTPUT_NAMES=(
    "macOS arm64"
    "iOS arm64 device"
    "iOS arm64 simulator"
)
declare -a OUTPUT_BASES=(
    "${HOME}/.cache/ino-mac/output"
    "${HOME}/.cache/ino-ios-i64/output"
    "${HOME}/.cache/ino-ios-is64/output"
)

for i in "${!OUTPUT_BASES[@]}"; do
    name="${OUTPUT_NAMES[$i]}"
    base="${OUTPUT_BASES[$i]}"

    echo ""
    echo -e "${CYAN}=== Cleaning LiteRT-LM (${name}) ===${RESET}"

    if [[ ! -d "${base}" ]]; then
        echo "  (output base ${base} does not exist — nothing to clean)"
        continue
    fi

    echo -e "${YELLOW}Running 'bazelisk --output_base=${base} clean --expunge'...${RESET}"
    (cd "${SUBMODULE_DIR}" && bazelisk "--output_base=${base}" clean --expunge)
done

echo ""
echo -e "${GREEN}=== Clean complete ===${RESET}"
