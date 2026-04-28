// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

#pragma once

  #include "Modules/ModuleManager.h"
#include "Logging/LogMacros.h"

DECLARE_LOG_CATEGORY_EXTERN(LogInoLiteRT, Log, All);

/**
 * ino_lite_rt_ue runtime module.
 *
 * Pre-loads the LiteRT + LiteRT-LM runtime DLLs at StartupModule so the rest
 * of the plugin (and consumer modules) can call into the C APIs through
 * UBT's delay-load trampolines.
 *
 * Five DLLs are loaded on Windows in this exact order:
 *   1. libGemmaModelConstraintProvider.dll  no deps; required sibling of LiteRtLm.dll
 *   2. libLiteRt.dll                        LiteRT core; LiteRtLm + GPU DLLs depend on it
 *   3. LiteRtLm.dll                         our Bazel-built LLM runtime
 *   4. libLiteRtWebGpuAccelerator.dll       WebGPU → D3D12 GPU accelerator
 *   5. libLiteRtTopKWebGpuSampler.dll       GPU-side top-K sampling
 *
 * Order matters: with --define=litert_link_capi_so=true, LiteRtLm.dll
 * dynamically imports from libLiteRt.dll. If LiteRtLm is loaded before
 * libLiteRt, Windows fails the load with GetLastError=126 ("missing import").
 *
 * The two GPU DLLs are pre-loaded with full absolute paths so when the
 * LiteRT engine internally calls LoadLibraryA() with just the filename
 * (e.g. "libLiteRtWebGpuAccelerator.dll"), Windows finds the already-
 * loaded module rather than searching the executable directory (which is
 * UE's Engine/Binaries/Win64/, not our plugin's dir).
 *
 * This module does NOT block on model loading — that happens lazily in
 * the consumer subsystems (not yet ported here). Loading a multi-GB
 * Gemma 4 model from StartupModule would freeze the editor for seconds.
 *
 * On Android, .so loading is handled by the dynamic linker plus the
 * UPL XML's <soLoadLibrary> directives — no per-DLL work for StartupModule
 * beyond the smoke test.
 */
class Fino_lite_rt_ueModule : public IModuleInterface
{
public:
	//~ IModuleInterface
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;
	//~ End of IModuleInterface

private:
	/** Handle to libGemmaModelConstraintProvider.dll. Nullptr if load failed. */
	void* GemmaConstraintProviderHandle = nullptr;

	/** Handle to libLiteRt.dll. Nullptr if load failed. */
	void* LiteRtHandle                  = nullptr;

	/** Handle to LiteRtLm.dll. Nullptr if load failed. */
	void* LiteRtLmHandle                = nullptr;

	/** Handle to libLiteRtWebGpuAccelerator.dll (GPU accelerator, on-demand). */
	void* WebGpuAcceleratorHandle       = nullptr;

	/** Handle to libLiteRtTopKWebGpuSampler.dll (GPU sampler, on-demand). */
	void* TopKWebGpuSamplerHandle       = nullptr;
};
