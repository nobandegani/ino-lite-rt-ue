// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

#include "InoLiteRT.h"

#include "HAL/PlatformProcess.h"
#include "Interfaces/IPluginManager.h"
#include "Misc/Paths.h"
#include "Modules/ModuleManager.h"

// LiteRT-LM C API — staged into Source/ThirdParty/Public/litert/lm/ by
// LiteRT/scripts/build-win64.ps1. Used here only for the trivial
// litert_lm_set_min_log_level() startup smoke test. Substantial calls
// happen in consumer subsystems (ported in later phases).
//
// Gated to platforms where the runtime DLL/.so actually ships — on
// iOS/Linux/macOS we have no library to link against, so even an
// unused reference to litert_lm_set_min_log_level would break linking.
#if PLATFORM_WINDOWS || PLATFORM_ANDROID
#include "litert/lm/engine.h"
#endif

DEFINE_LOG_CATEGORY(LogInoLiteRT);

#define LOCTEXT_NAMESPACE "FInoLiteRTModule"

namespace
{
	/**
	 * Resolve the absolute path to a runtime DLL staged alongside the plugin.
	 * Returns an empty string on unsupported platforms.
	 */
	FString ResolveStagedDllPath(const TCHAR* DllFileName)
	{
		const TSharedPtr<IPlugin> Plugin =
			IPluginManager::Get().FindPlugin(TEXT("InoLiteRT"));
		if (!Plugin.IsValid())
		{
			return FString();
		}

		const FString BaseDir = Plugin->GetBaseDir();

#if PLATFORM_WINDOWS
		// All Win64 artifacts (DLLs + import libs) live under
		// Source/ThirdParty/Win64/ in the consolidated layout.
		return FPaths::Combine(BaseDir, TEXT("Source/ThirdParty/Win64"), DllFileName);
#else
		// iOS / Linux / macOS not yet implemented.
		// Returning empty causes GetDllHandle() to no-op gracefully.
		return FString();
#endif
	}

	/**
	 * Load a staged runtime DLL by filename. Logs on success and failure.
	 *
	 * Unlike the stock UE "Third Party Library" plugin template, this does
	 * NOT show a blocking MessageDialog on failure — that dialog pops up
	 * every editor start if a single DLL is missing, which is hostile during
	 * development. An error log is sufficient.
	 */
	void* LoadStagedDll(const TCHAR* DllFileName)
	{
		const FString Path = ResolveStagedDllPath(DllFileName);
		if (Path.IsEmpty())
		{
			UE_LOG(LogInoLiteRT, Warning,
				TEXT("InoLiteRT: not loading %s (unsupported platform)"),
				DllFileName);
			return nullptr;
		}

		void* Handle = FPlatformProcess::GetDllHandle(*Path);
		if (Handle)
		{
			UE_LOG(LogInoLiteRT, Log,
				TEXT("InoLiteRT: loaded %s from %s"),
				DllFileName, *Path);
		}
		else
		{
			UE_LOG(LogInoLiteRT, Error,
				TEXT("InoLiteRT: failed to load %s from %s. Did you run "
					 "Plugins/InoLiteRT/LiteRT/scripts/build-win64.ps1?"),
				DllFileName, *Path);
		}
		return Handle;
	}
}

void FInoLiteRTModule::StartupModule()
{
#if PLATFORM_WINDOWS
	// Load order is critical — each DLL must be in memory before any
	// DLL that imports from it:
	//
	//   1. libGemmaModelConstraintProvider.dll  (standalone, no deps)
	//   2. libLiteRt.dll                        (LiteRT core)
	//   3. LiteRtLm.dll                         (imports from libLiteRt.dll)
	//   4. libLiteRtWebGpuAccelerator.dll       (imports from libLiteRt.dll)
	//   5. libLiteRtTopKWebGpuSampler.dll       (imports from libLiteRt.dll)
	//
	// With --define=litert_link_capi_so=true, LiteRtLm.dll dynamically
	// links against libLiteRt.dll (instead of statically including it),
	// so libLiteRt.dll MUST be loaded before LiteRtLm.dll or Windows
	// will fail with "Missing import: libLiteRt.dll" (GetLastError=126).
	GemmaConstraintProviderHandle = LoadStagedDll(TEXT("libGemmaModelConstraintProvider.dll"));
	LiteRtHandle                  = LoadStagedDll(TEXT("libLiteRt.dll"));
	LiteRtLmHandle                = LoadStagedDll(TEXT("LiteRtLm.dll"));

	// GPU accelerator DLLs — pre-load so the LiteRT engine's internal
	// LoadLibraryA() can find them by filename. Windows searches
	// relative to the process executable (UE's Engine/Binaries/Win64/),
	// not the plugin's DLL directory; pre-loading by full path puts the
	// modules into the process's loaded-modules table, and subsequent
	// filename-only LoadLibraryA calls resolve to the cached entries.
	if (LiteRtHandle)
	{
		WebGpuAcceleratorHandle = LoadStagedDll(TEXT("libLiteRtWebGpuAccelerator.dll"));
		TopKWebGpuSamplerHandle = LoadStagedDll(TEXT("libLiteRtTopKWebGpuSampler.dll"));
	}

	const bool bCanCallLiteRtLm = (LiteRtLmHandle != nullptr);
#elif PLATFORM_ANDROID
	// On Android, .so files are loaded automatically by the dynamic linker
	// at process startup. Our libUnreal.so links against libLiteRtLm.so
	// via PublicAdditionalLibraries in the Build.cs Android branch, so
	// symbols resolve through the standard Android linker path — no
	// FPlatformProcess::GetDllHandle() calls needed. The UPL XML's
	// <soLoadLibrary> additionally asks the GameActivity Java side to
	// preload the libs (harmless but redundant given DT_NEEDED resolution).
	const bool bCanCallLiteRtLm = true;
#else
	// iOS / Linux / macOS: no LiteRT-LM library is shipped. The smoke
	// test would fail at link time (no symbol to resolve), so skip it.
	const bool bCanCallLiteRtLm = false;
#endif

	// --------------------------------------------------------------
	// Trivial startup smoke test: call one cheap C API function so we
	// know the LiteRT-LM library is loaded and callable. On Windows
	// this proves the delay-load trampolines and import lib wiring.
	// On Android this proves the linker resolved against our .so.
	// --------------------------------------------------------------
#if PLATFORM_WINDOWS || PLATFORM_ANDROID
	if (bCanCallLiteRtLm)
	{
		litert_lm_set_min_log_level(0);
		UE_LOG(LogInoLiteRT, Log,
			TEXT("InoLiteRT: smoke test passed — litert_lm_set_min_log_level(0) returned cleanly."));
	}
#endif
}

void FInoLiteRTModule::ShutdownModule()
{
#if PLATFORM_WINDOWS
	// Unload in reverse dependency order: GPU DLLs first (they import
	// from libLiteRt), then LiteRtLm, then libLiteRt, then constraint provider.
	if (TopKWebGpuSamplerHandle)
	{
		FPlatformProcess::FreeDllHandle(TopKWebGpuSamplerHandle);
		TopKWebGpuSamplerHandle = nullptr;
	}
	if (WebGpuAcceleratorHandle)
	{
		FPlatformProcess::FreeDllHandle(WebGpuAcceleratorHandle);
		WebGpuAcceleratorHandle = nullptr;
	}
	if (LiteRtLmHandle)
	{
		FPlatformProcess::FreeDllHandle(LiteRtLmHandle);
		LiteRtLmHandle = nullptr;
	}
	if (LiteRtHandle)
	{
		FPlatformProcess::FreeDllHandle(LiteRtHandle);
		LiteRtHandle = nullptr;
	}
	if (GemmaConstraintProviderHandle)
	{
		FPlatformProcess::FreeDllHandle(GemmaConstraintProviderHandle);
		GemmaConstraintProviderHandle = nullptr;
	}
#endif  // PLATFORM_WINDOWS

	// On Android / iOS / Linux / macOS: nothing to unload — shared
	// libraries are managed by the OS dynamic linker and freed at
	// process exit along with the rest of the game process.
}

#undef LOCTEXT_NAMESPACE

IMPLEMENT_MODULE(FInoLiteRTModule, InoLiteRT)
