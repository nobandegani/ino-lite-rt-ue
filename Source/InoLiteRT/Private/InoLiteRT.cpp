// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

#include "InoLiteRT.h"

#include "HAL/PlatformProcess.h"
#include "Interfaces/IPluginManager.h"
#include "Misc/Paths.h"
#include "Modules/ModuleManager.h"

#if PLATFORM_WINDOWS
    // For GetModuleHandleW / GetModuleFileNameW — used to verify that
    // each DLL we asked Windows to load by full path actually got
    // mapped from THAT path, and not served from the loader's
    // base-name cache for a same-named DLL that some other module
    // (UE engine, another plugin) loaded earlier. Cache collisions
    // explain the editor-vs-package divergence we hit on dxcompiler.dll
    // — we want a hard log signal whenever it happens.
    #include "Windows/AllowWindowsPlatformTypes.h"
    #include <windows.h>
    #include "Windows/HideWindowsPlatformTypes.h"
#endif

// LiteRT-LM C API — staged into Source/ThirdParty/Public/litert/lm/ by
// the platform-specific build scripts. Used here only for the trivial
// litert_lm_set_min_log_level() startup smoke test. Substantial calls
// happen in consumer subsystems (ported in later phases).
//
// Gated to platforms where the runtime library actually ships. Linux is
// excluded — we don't have a build script wired for it yet, so even an
// unused reference to litert_lm_set_min_log_level would break linking.
#if PLATFORM_WINDOWS || PLATFORM_ANDROID || PLATFORM_MAC || PLATFORM_IOS
#include "litert/lm/engine.h"
#endif

DEFINE_LOG_CATEGORY(LogInoLiteRT);

#define LOCTEXT_NAMESPACE "FInoLiteRTModule"

namespace
{
	/**
	 * Resolve the absolute path to a runtime DLL staged alongside the plugin.
	 * Returns an empty string on unsupported platforms.
	 *
	 * Logs an Error (not a warning) when IPluginManager can't find us —
	 * that's an installation/cooking bug, not "this platform is unsupported".
	 */
	FString ResolveStagedDllPath(const TCHAR* DllFileName)
	{
		const TSharedPtr<IPlugin> Plugin =
			IPluginManager::Get().FindPlugin(TEXT("InoLiteRT"));
		if (!Plugin.IsValid())
		{
			UE_LOG(LogInoLiteRT, Error,
				TEXT("InoLiteRT: IPluginManager::FindPlugin(\"InoLiteRT\") returned null. ")
				TEXT("Cannot resolve staged DLL path for %s. The plugin descriptor "
					 "may be missing from the cooked build."),
				DllFileName);
			return FString();
		}

		const FString BaseDir = Plugin->GetBaseDir();

#if PLATFORM_WINDOWS
		// All Win64 artifacts (DLLs + import libs) live under
		// Source/ThirdParty/Win64/ in the consolidated layout.
		return FPaths::Combine(BaseDir, TEXT("Source/ThirdParty/Win64"), DllFileName);
#elif PLATFORM_MAC
		// Mac dylibs live under Source/ThirdParty/Mac/. Same flat layout
		// as Win64 — Apple Silicon (arm64) is the only supported macOS
		// arch so no per-arch subdir.
		return FPaths::Combine(BaseDir, TEXT("Source/ThirdParty/Mac"), DllFileName);
#else
		// iOS / Linux / Android: not addressable by file path. iOS uses
		// embedded .framework bundles resolved by dyld; Android uses .so
		// files resolved by the dynamic linker. Returning empty causes
		// GetDllHandle() to no-op gracefully — these platforms don't
		// invoke this helper anyway.
		return FString();
#endif
	}

#if PLATFORM_WINDOWS
	/**
	 * Windows-only: query Windows for the full on-disk path of an
	 * already-loaded DLL (by its base name). Returns a sentinel string
	 * if the DLL isn't loaded at all, or on API failure.
	 *
	 * Critical for verifying that our preloaded copies actually won
	 * the base-name cache race vs same-named DLLs that UE or other
	 * plugins may have loaded first. The most concrete failure mode
	 * we've hit: editor PIE pre-loads UE's Engine/Binaries/ThirdParty/
	 * ShaderConductor/Win64/dxcompiler.dll (different version than
	 * what upstream LiteRT-LM's WebGPU accelerator was tested against)
	 * before our PreLoadingScreen module starts, so our own
	 * GetDllHandle("...Plugins/InoLiteRT/.../dxcompiler.dll") returns
	 * a handle to UE's already-mapped copy, leaving Dawn talking to
	 * a different DXC than expected. We want a Warning log line for
	 * that situation so it shows up in the cooked log too.
	 */
	FString GetActualLoadedModulePath(const TCHAR* BaseName)
	{
		HMODULE Handle = GetModuleHandleW(BaseName);
		if (Handle == nullptr)
		{
			return FString(TEXT("(not loaded)"));
		}
		WCHAR PathBuf[MAX_PATH + 1] = {};
		const DWORD Len = GetModuleFileNameW(Handle, PathBuf, MAX_PATH);
		if (Len == 0 || Len >= MAX_PATH)
		{
			return FString(TEXT("(GetModuleFileName failed)"));
		}
		return FString(PathBuf);
	}

	/**
	 * Verify that a loaded DLL came from the path we expected. Logs at
	 * Log level on match, Warning on mismatch (someone else won the
	 * base-name cache race).
	 */
	void VerifyLoadedPath(const TCHAR* BaseName, const FString& ExpectedFullPath)
	{
		const FString ActualPath = GetActualLoadedModulePath(BaseName);

		// Windows paths are case-insensitive and may use mixed separators.
		// Normalise both sides to forward-slash lower-case for comparison.
		auto Normalize = [](const FString& In) -> FString
		{
			FString Out = In;
			Out.ReplaceInline(TEXT("\\"), TEXT("/"));
			return Out.ToLower();
		};

		if (Normalize(ActualPath) == Normalize(ExpectedFullPath))
		{
			UE_LOG(LogInoLiteRT, Log,
				TEXT("InoLiteRT: verified %s is loaded from %s"),
				BaseName, *ActualPath);
		}
		else
		{
			UE_LOG(LogInoLiteRT, Warning,
				TEXT("InoLiteRT: BASE-NAME CACHE COLLISION — %s loaded from %s, ")
				TEXT("but we wanted %s. Our preload didn't win the race (another module ")
				TEXT("loaded a different %s first). For dxcompiler.dll/dxil.dll this can ")
				TEXT("cause GPU shader-compile divergence between editor and packaged ")
				TEXT("builds (Dawn talks to a DXC version other than what the WebGPU ")
				TEXT("accelerator was built against)."),
				BaseName, *ActualPath, *ExpectedFullPath, BaseName);
		}
	}
#endif // PLATFORM_WINDOWS

	/**
	 * Load a staged runtime DLL by filename. Logs on success and failure.
	 * On Windows, additionally verifies that the resolved module path
	 * matches the staged path we asked for — a mismatch flags base-name
	 * cache collisions (see VerifyLoadedPath above).
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
#if PLATFORM_WINDOWS || PLATFORM_MAC
			// Win64 + Mac always return a non-empty path on success;
			// empty means IPluginManager failed — already logged as
			// Error in ResolveStagedDllPath. Don't double-log.
#else
			UE_LOG(LogInoLiteRT, Warning,
				TEXT("InoLiteRT: not loading %s (unsupported platform)"),
				DllFileName);
#endif
			return nullptr;
		}

		void* Handle = FPlatformProcess::GetDllHandle(*Path);
		if (Handle)
		{
			UE_LOG(LogInoLiteRT, Log,
				TEXT("InoLiteRT: loaded %s from %s"),
				DllFileName, *Path);
#if PLATFORM_WINDOWS
			VerifyLoadedPath(DllFileName, Path);
#endif
		}
		else
		{
			UE_LOG(LogInoLiteRT, Error,
				TEXT("InoLiteRT: failed to load %s from %s. Did you run "
					 "the matching script under Plugins/InoLiteRT/LiteRT/scripts/ "
					 "(build-win64.ps1 / build-android.ps1 / build-macos.sh)?"),
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
	//   1. dxcompiler.dll                       (DXC, Dawn dep — see below)
	//   2. dxil.dll                             (DXIL signing helper, Dawn dep)
	//   3. libGemmaModelConstraintProvider.dll  (standalone, no deps)
	//   4. libLiteRt.dll                        (LiteRT core)
	//   5. LiteRtLm.dll                         (imports from libLiteRt.dll)
	//   6. libLiteRtWebGpuAccelerator.dll       (imports from libLiteRt.dll)
	//   7. libLiteRtTopKWebGpuSampler.dll       (imports from libLiteRt.dll)
	//
	// With --define=litert_link_capi_so=true, LiteRtLm.dll dynamically
	// links against libLiteRt.dll (instead of statically including it),
	// so libLiteRt.dll MUST be loaded before LiteRtLm.dll or Windows
	// will fail with "Missing import: libLiteRt.dll" (GetLastError=126).
	//
	// dxcompiler/dxil go first because the WebGPU accelerator DLLs
	// loaded later in this sequence call LoadLibraryA("dxcompiler.dll")
	// / ("dxil.dll") internally during D3D12 device init (Dawn compiles
	// WGSL → HLSL → DXIL at runtime). Once a DLL is in the process's
	// loaded-modules table, filename-only LoadLibraryA returns that
	// handle directly without doing a search, so pre-loading our staged
	// copies by full path here guarantees the WebGPU prebuilt finds
	// them in packaged builds. The editor incidentally satisfies this
	// via UE's CEF3 / ShaderConductor preload; packages don't.
	//
	// Failure to load DXC is non-fatal — CPU backend doesn't need it,
	// and a user with a system-installed dxcompiler.dll on PATH may
	// also be fine. We log and continue.
	DxCompilerHandle = LoadStagedDll(TEXT("dxcompiler.dll"));
	DxilHandle       = LoadStagedDll(TEXT("dxil.dll"));

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
#elif PLATFORM_MAC
	// Mac load order — same dependency reasoning as Windows minus DXC
	// (DirectX Shader Compiler is Windows-only):
	//
	//   1. libGemmaModelConstraintProvider.dylib  standalone, no deps
	//   2. libLiteRt.dylib                        LiteRT core
	//   3. libLiteRtLm.dylib                      imports from libLiteRt
	//   4. libLiteRtMetalAccelerator.dylib        Metal GPU backend (preferred)
	//   5. libLiteRtTopKMetalSampler.dylib        Metal-side top-K sampling
	//   6. libLiteRtWebGpuAccelerator.dylib       optional WebGPU path (Dawn -> Metal)
	//   7. libLiteRtTopKWebGpuSampler.dylib       optional WebGPU top-K
	//
	// dyld would resolve LC_LOAD_DYLIB entries automatically at app launch,
	// so manual pre-loading is not strictly required — but doing it gives
	// us a hard Log/Error signal that staging is correct, in both editor
	// and packaged builds. Failure of an optional accelerator is non-fatal:
	// the LiteRT engine falls back to CPU when no GPU backend loads.
	GemmaConstraintProviderHandle = LoadStagedDll(TEXT("libGemmaModelConstraintProvider.dylib"));
	LiteRtHandle                  = LoadStagedDll(TEXT("libLiteRt.dylib"));
	LiteRtLmHandle                = LoadStagedDll(TEXT("libLiteRtLm.dylib"));

	if (LiteRtHandle)
	{
		MetalAcceleratorHandle  = LoadStagedDll(TEXT("libLiteRtMetalAccelerator.dylib"));
		TopKMetalSamplerHandle  = LoadStagedDll(TEXT("libLiteRtTopKMetalSampler.dylib"));
		WebGpuAcceleratorHandle = LoadStagedDll(TEXT("libLiteRtWebGpuAccelerator.dylib"));
		TopKWebGpuSamplerHandle = LoadStagedDll(TEXT("libLiteRtTopKWebGpuSampler.dylib"));
	}

	const bool bCanCallLiteRtLm = (LiteRtLmHandle != nullptr);
#elif PLATFORM_IOS
	// iOS: frameworks are embedded into MyApp.app/Frameworks/ at packaging
	// time and resolved by dyld at launch via @rpath in each framework's
	// LC_ID_DYLIB / LC_LOAD_DYLIB load commands. We can't (and shouldn't)
	// dlopen frameworks at runtime — App Store validation rejects apps
	// that load arbitrary code paths. The dependency graph:
	//
	//   LiteRtLm.framework -> LiteRt.framework
	//                      -> GemmaModelConstraintProvider.framework
	//   LiteRtMetalAccelerator.framework -> LiteRt.framework
	//   LiteRtTopKMetalSampler.framework -> LiteRt.framework
	//
	// is resolved by dyld at app launch via the @rpath/<Name>.framework/
	// <Name> install_names that build-ios.sh sets via install_name_tool.
	// By the time StartupModule runs, every symbol in litert_lm_*() is
	// already mapped into the process — no manual handle bookkeeping.
	const bool bCanCallLiteRtLm = true;
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
	// Linux: no LiteRT-LM library is shipped. The smoke test would fail
	// at link time (no symbol to resolve), so skip it.
	const bool bCanCallLiteRtLm = false;
#endif

	// --------------------------------------------------------------
	// Trivial startup smoke test: call one cheap C API function so we
	// know the LiteRT-LM library is loaded and callable.
	//   Windows: proves the delay-load trampolines + import lib wiring.
	//   Mac:     proves the @rpath dyld lookup found our staged dylibs.
	//   iOS:     proves the embedded framework loaded with the app.
	//   Android: proves the linker resolved against our .so.
	// --------------------------------------------------------------
#if PLATFORM_WINDOWS || PLATFORM_ANDROID || PLATFORM_MAC || PLATFORM_IOS
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
	// from libLiteRt + use DXC), then LiteRtLm, then libLiteRt, then
	// constraint provider, then DXC last.
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
	if (DxilHandle)
	{
		FPlatformProcess::FreeDllHandle(DxilHandle);
		DxilHandle = nullptr;
	}
	if (DxCompilerHandle)
	{
		FPlatformProcess::FreeDllHandle(DxCompilerHandle);
		DxCompilerHandle = nullptr;
	}
#elif PLATFORM_MAC
	// Mac: same reverse-dependency order as Windows minus DXC. dyld would
	// also clean these up at process exit, but explicit FreeDllHandle
	// keeps the editor PIE workflow tidy when the module is reloaded.
	if (TopKWebGpuSamplerHandle)       { FPlatformProcess::FreeDllHandle(TopKWebGpuSamplerHandle);       TopKWebGpuSamplerHandle       = nullptr; }
	if (WebGpuAcceleratorHandle)       { FPlatformProcess::FreeDllHandle(WebGpuAcceleratorHandle);       WebGpuAcceleratorHandle       = nullptr; }
	if (TopKMetalSamplerHandle)        { FPlatformProcess::FreeDllHandle(TopKMetalSamplerHandle);        TopKMetalSamplerHandle        = nullptr; }
	if (MetalAcceleratorHandle)        { FPlatformProcess::FreeDllHandle(MetalAcceleratorHandle);        MetalAcceleratorHandle        = nullptr; }
	if (LiteRtLmHandle)                { FPlatformProcess::FreeDllHandle(LiteRtLmHandle);                LiteRtLmHandle                = nullptr; }
	if (LiteRtHandle)                  { FPlatformProcess::FreeDllHandle(LiteRtHandle);                  LiteRtHandle                  = nullptr; }
	if (GemmaConstraintProviderHandle) { FPlatformProcess::FreeDllHandle(GemmaConstraintProviderHandle); GemmaConstraintProviderHandle = nullptr; }
#endif  // PLATFORM_WINDOWS / PLATFORM_MAC

	// On Android / iOS / Linux: nothing to unload — shared libraries are
	// managed by the OS dynamic linker and freed at process exit along
	// with the rest of the game process. iOS specifically does not
	// expose dlclose for embedded frameworks anyway.
}

#undef LOCTEXT_NAMESPACE

IMPLEMENT_MODULE(FInoLiteRTModule, InoLiteRT)
