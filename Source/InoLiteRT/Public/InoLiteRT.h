// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

#pragma once

#include "Modules/ModuleManager.h"
#include "Logging/LogMacros.h"

DECLARE_LOG_CATEGORY_EXTERN(LogInoLiteRT, Log, All);

/**
 * InoLiteRT runtime module.
 *
 * Pre-loads the LiteRT + LiteRT-LM runtime DLLs at StartupModule so the rest
 * of the plugin (and consumer modules) can call into the C APIs through
 * UBT's delay-load trampolines.
 *
 * Seven DLLs are loaded on Windows in this exact order:
 *   1. dxcompiler.dll                       DirectX Shader Compiler (Dawn dep)
 *   2. dxil.dll                             DXIL signing helper (Dawn dep)
 *   3. libGemmaModelConstraintProvider.dll  no deps; required sibling of LiteRtLm.dll
 *   4. libLiteRt.dll                        LiteRT core; LiteRtLm + GPU DLLs depend on it
 *   5. LiteRtLm.dll                         our Bazel-built LLM runtime
 *   6. libLiteRtWebGpuAccelerator.dll       WebGPU → D3D12 GPU accelerator
 *   7. libLiteRtTopKWebGpuSampler.dll       GPU-side top-K sampling
 *
 * Order matters: with --define=litert_link_capi_so=true, LiteRtLm.dll
 * dynamically imports from libLiteRt.dll. If LiteRtLm is loaded before
 * libLiteRt, Windows fails the load with GetLastError=126 ("missing import").
 *
 * dxcompiler.dll + dxil.dll go first because the WebGPU accelerator DLLs
 * call LoadLibraryA("dxcompiler.dll") / ("dxil.dll") internally during
 * D3D12 device init (Dawn translates WGSL → HLSL → DXIL at runtime).
 * Pre-loading by full absolute path puts our staged copies into the
 * process module table; subsequent filename lookups inside the WebGPU
 * prebuilt then resolve to our copies. The editor incidentally satisfies
 * this via its CEF3 / ShaderConductor preload; packaged builds need us
 * to do it explicitly.
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
class FInoLiteRTModule : public IModuleInterface
{
public:
	//~ IModuleInterface
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;
	//~ End of IModuleInterface

private:
	/** Handle to dxcompiler.dll (DXC, required by Dawn / WebGPU GPU backend). */
	void* DxCompilerHandle              = nullptr;

	/** Handle to dxil.dll (DXIL signing helper, Dawn / WebGPU GPU backend). */
	void* DxilHandle                    = nullptr;

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
