// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

#pragma once

#include "Modules/ModuleManager.h"
#include "Logging/LogMacros.h"

DECLARE_LOG_CATEGORY_EXTERN(LogInoLiteRT, Log, All);

/**
 * InoLiteRT runtime module.
 *
 * Pre-loads the LiteRT + LiteRT-LM runtime libraries at StartupModule so the
 * rest of the plugin (and consumer modules) can call into the C APIs through
 * UBT's delay-load trampolines (Windows) or dyld's @rpath resolution (macOS).
 *
 * --- Windows (.dll) ---
 *
 * Seven DLLs are loaded on Windows in this exact order:
 *   1. dxcompiler.dll                       DirectX Shader Compiler (Dawn dep)
 *   2. dxil.dll                             DXIL signing helper (Dawn dep)
 *   3. libGemmaModelConstraintProvider.dll  no deps; required sibling of LiteRtLm.dll
 *   4. libLiteRt.dll                        LiteRT core; LiteRtLm + GPU DLLs depend on it
 *   5. LiteRtLm.dll                         our Bazel-built LLM runtime
 *   6. libLiteRtWebGpuAccelerator.dll       WebGPU -> D3D12 GPU accelerator
 *   7. libLiteRtTopKWebGpuSampler.dll       GPU-side top-K sampling
 *
 * Order matters: with --define=litert_link_capi_so=true, LiteRtLm.dll
 * dynamically imports from libLiteRt.dll. If LiteRtLm is loaded before
 * libLiteRt, Windows fails the load with GetLastError=126 ("missing import").
 *
 * dxcompiler.dll + dxil.dll go first because the WebGPU accelerator DLLs
 * call LoadLibraryA("dxcompiler.dll") / ("dxil.dll") internally during
 * D3D12 device init (Dawn translates WGSL -> HLSL -> DXIL at runtime).
 * Pre-loading by full absolute path puts our staged copies into the
 * process module table; subsequent filename lookups inside the WebGPU
 * prebuilt then resolve to our copies.
 *
 * --- macOS (.dylib) ---
 *
 * Same load order as Windows minus DXC/DXIL (they're DirectX-only):
 *   1. libGemmaModelConstraintProvider.dylib
 *   2. libLiteRt.dylib
 *   3. libLiteRtLm.dylib
 *   4. libLiteRtMetalAccelerator.dylib  (preferred GPU on Apple Silicon)
 *   5. libLiteRtTopKMetalSampler.dylib
 *   6. libLiteRtWebGpuAccelerator.dylib (Dawn -> Metal, alternative path)
 *   7. libLiteRtTopKWebGpuSampler.dylib
 *
 * On Mac, dyld would auto-resolve LC_LOAD_DYLIB entries at launch, but we
 * pre-load by full path here for the same reason as Windows: a hard
 * Log/Error signal that staging is correct, in both editor and packaged
 * builds. Failure to pre-load is non-fatal — the smoke test below will
 * fail if any sibling is genuinely missing.
 *
 * --- iOS (.framework) ---
 *
 * Frameworks are embedded into MyApp.app/Frameworks/ at packaging time
 * (UE's IOSToolChain handles unzipping + signing). dyld resolves their
 * @rpath/<Name>.framework/<Name> install_names automatically at app launch
 * via LC_LOAD_DYLIB entries; no FPlatformProcess::GetDllHandle calls are
 * needed or possible (iOS has no equivalent of LoadLibraryA / dlopen for
 * arbitrary paths in submitted apps). StartupModule on iOS only runs the
 * smoke test.
 *
 * --- Android (.so) ---
 *
 * .so loading is handled by the dynamic linker plus the UPL XML's
 * <soLoadLibrary> directives — no per-DLL work for StartupModule beyond
 * the smoke test.
 *
 * --- Lazy model loading ---
 *
 * This module does NOT block on model loading — that happens lazily in
 * the consumer subsystems. Loading a multi-GB Gemma 4 model from
 * StartupModule would freeze the editor for seconds.
 */
class FInoLiteRTModule : public IModuleInterface
{
public:
	//~ IModuleInterface
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;
	//~ End of IModuleInterface

private:
	/** Handle to dxcompiler.dll (Windows-only: DXC, required by Dawn / WebGPU GPU backend). */
	void* DxCompilerHandle              = nullptr;

	/** Handle to dxil.dll (Windows-only: DXIL signing helper, Dawn / WebGPU GPU backend). */
	void* DxilHandle                    = nullptr;

	/** Handle to libGemmaModelConstraintProvider.{dll,dylib}. Windows + Mac. */
	void* GemmaConstraintProviderHandle = nullptr;

	/** Handle to libLiteRt.{dll,dylib}. Windows + Mac. */
	void* LiteRtHandle                  = nullptr;

	/** Handle to LiteRtLm.{dll,dylib}. Windows + Mac. */
	void* LiteRtLmHandle                = nullptr;

	/** Handle to libLiteRtMetalAccelerator.dylib (Mac-only: Metal GPU backend). */
	void* MetalAcceleratorHandle        = nullptr;

	/** Handle to libLiteRtTopKMetalSampler.dylib (Mac-only: Metal-side top-K sampling). */
	void* TopKMetalSamplerHandle        = nullptr;

	/** Handle to libLiteRtWebGpuAccelerator.{dll,dylib}. Windows + Mac. */
	void* WebGpuAcceleratorHandle       = nullptr;

	/** Handle to libLiteRtTopKWebGpuSampler.{dll,dylib}. Windows + Mac. */
	void* TopKWebGpuSamplerHandle       = nullptr;
};
