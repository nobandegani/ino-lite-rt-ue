// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.
// build_config.h — InoLiteRT platform-dispatch wrapper (NOT an upstream file).
//
// Template lives at LiteRT/scripts/build_config_wrapper.h; every platform
// build script (build-win64.ps1, build-android.ps1, build-macos.sh,
// build-ios.sh) stages this same file to
// Source/ThirdParty/Public/litert/build_common/build_config.h alongside
// BOTH upstream variant headers under build_common/config/.
//
// WHY A WRAPPER: litert/c/litert_common.h includes
// <litert/build_common/build_config.h> — the consumer-visible gate for the
// LITERT_HAS_* feature macros — and that header MUST match the
// configuration the shipped binaries were built with. All four platforms
// share one Public/ header tree, but they do NOT share one configuration:
//
//   - iOS:                  NPU compiled OUT. LiteRT-LM runtime/executor/BUILD
//                           force-adds LITERT_DISABLE_NPU under
//                           @platforms//os:ios, so the monolithic
//                           libLiteRtLm.dylib has no NPU executor. The
//                           matching variant is config/build_config_gpu.h
//                           (defines LITERT_DISABLE_NPU).
//   - Win64/Android/macOS:  upstream default "gpu,npu" (litert
//                           build_common/BUILD string_flag default). The
//                           matching variant is config/build_config_gpu_npu.h
//                           (defines no LITERT_DISABLE_* at all).
//
// Staging a single variant made the effective header depend on which
// platform script ran LAST (e.g. an iOS build after a Win64 build silently
// flipped Win64's consumer surface to NPU-disabled). This wrapper selects
// the correct variant per compile target instead, so staging is
// run-order-independent.

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE
// iOS device + simulator: NPU compiled out — matches the monolithic
// libLiteRtLm.dylib produced by build-ios.sh.
#include "litert/build_common/config/build_config_gpu.h"
#else
// Win64 / Android / macOS: upstream-default "gpu,npu" binaries.
#include "litert/build_common/config/build_config_gpu_npu.h"
#endif
