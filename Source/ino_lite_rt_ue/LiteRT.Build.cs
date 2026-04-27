// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

using System.IO;
using UnrealBuildTool;

/// <summary>
/// External UE module that exposes both LiteRT and LiteRT-LM to consumers.
///
/// Artifacts referenced here are produced by
///     Plugins/ino_lite_rt_ue/LiteRT/scripts/build-win64.ps1
/// and staged into the consolidated ThirdParty tree:
///     Source/ThirdParty/Public/litert/c/         LiteRT C API headers
///     Source/ThirdParty/Public/litert/c/internal/  LiteRT internal headers
///     Source/ThirdParty/Public/litert/lm/        LiteRT-LM C API header (engine.h)
///     Source/ThirdParty/Win64/libLiteRt.lib      LiteRT import lib (synthesized via lib.exe)
///     Source/ThirdParty/Win64/LiteRtLm.lib       LiteRT-LM import lib (Bazel output)
///     Source/ThirdParty/Win64/libLiteRt.dll      LiteRT runtime (Google's prebuilt)
///     Source/ThirdParty/Win64/LiteRtLm.dll       LiteRT-LM runtime (our Bazel build)
///     Source/ThirdParty/Win64/libGemmaModelConstraintProvider.dll  required sibling
///     Source/ThirdParty/Win64/libLiteRtWebGpuAccelerator.dll       GPU accelerator
///     Source/ThirdParty/Win64/libLiteRtTopKWebGpuSampler.dll       GPU sampler
///
/// If any of these are missing, run
///     Plugins/ino_lite_rt_ue/LiteRT/scripts/build-win64.ps1
/// See Plugins/ino_lite_rt_ue/CLAUDE.md for the full build story.
/// </summary>
public class LiteRT : ModuleRules
{
	public LiteRT(ReadOnlyTargetRules Target) : base(Target)
	{
		Type = ModuleType.External;

		// Paths to the consolidated ThirdParty staging tree.
		string ThirdPartyDir = Path.Combine(PluginDirectory, "Source", "ThirdParty");
		string PublicDir     = Path.Combine(ThirdPartyDir, "Public");
		string Win64Dir      = Path.Combine(ThirdPartyDir, "Win64");
		string AndroidDir    = Path.Combine(ThirdPartyDir, "Android", "arm64-v8a");

		// Public headers — consumers do
		//     #include "litert/c/litert_compiled_model.h"
		//     #include "litert/lm/engine.h"
		PublicSystemIncludePaths.Add(PublicDir);

		if (Target.Platform == UnrealTargetPlatform.Win64)
		{
			// --- Import libraries (link time) ---
			PublicAdditionalLibraries.Add(Path.Combine(Win64Dir, "libLiteRt.lib"));
			PublicAdditionalLibraries.Add(Path.Combine(Win64Dir, "LiteRtLm.lib"));

			// --- Runtime DLLs (delay-loaded at startup) ---
			//
			// libLiteRt.dll                           LiteRT core runtime (Google's prebuilt)
			// LiteRtLm.dll                            our Bazel-built monolithic LLM runtime
			// libGemmaModelConstraintProvider.dll     required sibling of LiteRtLm.dll
			// libLiteRtWebGpuAccelerator.dll          GPU accelerator (loaded on demand
			//                                          when backend="gpu" is requested)
			// libLiteRtTopKWebGpuSampler.dll          GPU-side top-K sampling
			PublicDelayLoadDLLs.Add("libLiteRt.dll");
			PublicDelayLoadDLLs.Add("LiteRtLm.dll");
			PublicDelayLoadDLLs.Add("libGemmaModelConstraintProvider.dll");
			PublicDelayLoadDLLs.Add("libLiteRtWebGpuAccelerator.dll");
			PublicDelayLoadDLLs.Add("libLiteRtTopKWebGpuSampler.dll");

			// --- Runtime staging (copied next to the executable at cook/package time) ---
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libLiteRt.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "LiteRtLm.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libGemmaModelConstraintProvider.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libLiteRtWebGpuAccelerator.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libLiteRtTopKWebGpuSampler.dll"));
		}
		else if (Target.Platform == UnrealTargetPlatform.Android)
		{
			// Android arm64-v8a artifacts produced by
			//     Plugins/ino_lite_rt_ue/LiteRT/scripts/build-android-arm64.ps1
			// staged into Source/ThirdParty/Android/arm64-v8a/.
			//
			// Unlike Windows, Android does NOT use import libraries — .so files
			// are linked directly with PublicAdditionalLibraries at UE build time,
			// and the linker resolves symbols against the .so's export table.
			//
			// NOTE: no libLiteRt.so on Android. Upstream's build:android forces
			// --dynamic_mode=off which link-statics everything into libLiteRtLm.so.
			// The prebuilt GPU accelerator .so files have DT_NEEDED(libLiteRt.so)
			// records that won't resolve at runtime — backend=gpu is currently
			// non-functional on Android until upstream ships proper Android GPU
			// artifacts. backend=cpu works fine.
			//
			// NOTE: build-android-arm64.ps1 has not yet been updated to stage
			// into the consolidated Source/ThirdParty/Android tree (it still
			// writes to Binaries/ThirdParty/LiteRTLM/...). This branch is
			// scaffolding for when that's fixed.

			string LiteRtLmSo = Path.Combine(AndroidDir, "libLiteRtLm.so");
			if (File.Exists(LiteRtLmSo))
			{
				PublicAdditionalLibraries.Add(LiteRtLmSo);
			}

			string[] AndroidRuntimeSoFiles = new string[]
			{
				"libLiteRtLm.so",                      // Bazel-built (monolithic ~49 MB)
				"libGemmaModelConstraintProvider.so",  // prebuilt, constraint provider
				"libLiteRtGpuAccelerator.so",          // prebuilt, general GPU accelerator
				"libLiteRtOpenClAccelerator.so",       // prebuilt, OpenCL-specific
				"libLiteRtTopKOpenClSampler.so",       // prebuilt, OpenCL top-K sampler
				"libLiteRtTopKWebGpuSampler.so",       // prebuilt, WebGPU top-K sampler
				"libLiteRtWebGpuAccelerator.so",       // prebuilt, WebGPU accelerator
			};
			foreach (string So in AndroidRuntimeSoFiles)
			{
				string SoPath = Path.Combine(AndroidDir, So);
				if (File.Exists(SoPath))
				{
					RuntimeDependencies.Add(SoPath);
				}
			}

			// Apply the AndroidManifest.xml additions + build.gradle tweaks
			// that tell UE's APK packager to bundle our native libraries.
			AdditionalPropertiesForReceipt.Add(
				"AndroidPlugin",
				Path.Combine(ModuleDirectory, "LiteRT_UPL_Android.xml"));
		}
		else
		{
			// iOS / Linux / macOS: not yet implemented. Linking succeeds because
			// no static references; runtime calls fail gracefully.
		}
	}
}
