// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

using System.IO;
using UnrealBuildTool;

public class InoLiteRT : ModuleRules
{
	public InoLiteRT(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicIncludePaths.AddRange(
			new string[] {
				// ... add public include paths required here ...
			}
			);


		PrivateIncludePaths.AddRange(
			new string[] {
				// ... add other private include paths required here ...
			}
			);


		PublicDependencyModuleNames.AddRange(
			new string[]
			{
				"Core",
			}
			);


		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"CoreUObject",
				"Engine",
				"Slate",
				"SlateCore",

				// IPluginManager — used in StartupModule to resolve our
				// plugin's install path so we can load DLLs by full absolute path.
				"Projects",
			}
			);


		DynamicallyLoadedModuleNames.AddRange(
			new string[]
			{
				// ... add any modules that your module loads dynamically here ...
			}
			);

		// =====================================================================
		// LiteRT + LiteRT-LM third-party integration
		// =====================================================================
		// This is the only UE module in the plugin, so it owns the third-party
		// wiring directly (no separate external module). Build artifacts are
		// produced by Plugins/ino_lite_rt_ue/LiteRT/scripts/build-win64.ps1
		// and staged into the consolidated tree:
		//
		//     Source/ThirdParty/Public/litert/c/         LiteRT C API headers
		//     Source/ThirdParty/Public/litert/c/internal/  LiteRT internal headers
		//     Source/ThirdParty/Public/litert/lm/        LiteRT-LM C API header
		//     Source/ThirdParty/Win64/libLiteRt.lib      LiteRT import lib
		//     Source/ThirdParty/Win64/LiteRtLm.lib       LiteRT-LM import lib
		//     Source/ThirdParty/Win64/libLiteRt.dll      LiteRT runtime
		//     Source/ThirdParty/Win64/LiteRtLm.dll       LiteRT-LM runtime
		//     Source/ThirdParty/Win64/libGemmaModelConstraintProvider.dll
		//     Source/ThirdParty/Win64/libLiteRtWebGpuAccelerator.dll
		//     Source/ThirdParty/Win64/libLiteRtTopKWebGpuSampler.dll
		//
		// Companion files in this same directory:
		//     LiteRT.tps                  third-party software notification
		//     LiteRT_UPL_Android.xml      Android packaging directives

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
			// Import libraries (link time)
			PublicAdditionalLibraries.Add(Path.Combine(Win64Dir, "libLiteRt.lib"));
			PublicAdditionalLibraries.Add(Path.Combine(Win64Dir, "LiteRtLm.lib"));

			// Runtime DLLs (delay-loaded at startup)
			PublicDelayLoadDLLs.Add("libLiteRt.dll");
			PublicDelayLoadDLLs.Add("LiteRtLm.dll");
			PublicDelayLoadDLLs.Add("libGemmaModelConstraintProvider.dll");
			PublicDelayLoadDLLs.Add("libLiteRtWebGpuAccelerator.dll");
			PublicDelayLoadDLLs.Add("libLiteRtTopKWebGpuSampler.dll");

			// Runtime staging (copied next to the executable at cook/package time)
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libLiteRt.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "LiteRtLm.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libGemmaModelConstraintProvider.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libLiteRtWebGpuAccelerator.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "libLiteRtTopKWebGpuSampler.dll"));
		}
		else if (Target.Platform == UnrealTargetPlatform.Android)
		{
			// Android arm64-v8a artifacts (when present) — produced by
			// Plugins/ino_lite_rt_ue/LiteRT/scripts/build-android-arm64.ps1.
			//
			// NOTE: build-android-arm64.ps1 has not yet been updated to stage
			// into the consolidated Source/ThirdParty/Android tree (it still
			// writes to Binaries/ThirdParty/LiteRTLM/...). This branch is
			// scaffolding for when that's fixed.
			//
			// Unlike Windows, Android does NOT use import libraries — the
			// .so is linked directly via PublicAdditionalLibraries. There is
			// no libLiteRt.so on Android (upstream's --dynamic_mode=off
			// statically links LiteRT into the monolithic libLiteRtLm.so).

			string LiteRtLmSo = Path.Combine(AndroidDir, "libLiteRtLm.so");
			if (File.Exists(LiteRtLmSo))
			{
				PublicAdditionalLibraries.Add(LiteRtLmSo);
			}

			string[] AndroidRuntimeSoFiles = new string[]
			{
				"libLiteRtLm.so",
				"libGemmaModelConstraintProvider.so",
				"libLiteRtGpuAccelerator.so",
				"libLiteRtOpenClAccelerator.so",
				"libLiteRtTopKOpenClSampler.so",
				"libLiteRtTopKWebGpuSampler.so",
				"libLiteRtWebGpuAccelerator.so",
			};
			foreach (string So in AndroidRuntimeSoFiles)
			{
				string SoPath = Path.Combine(AndroidDir, So);
				if (File.Exists(SoPath))
				{
					RuntimeDependencies.Add(SoPath);
				}
			}

			// AndroidManifest.xml additions + build.gradle tweaks for APK packaging.
			AdditionalPropertiesForReceipt.Add(
				"AndroidPlugin",
				Path.Combine(ModuleDirectory, "LiteRT_UPL_Android.xml"));
		}
		// iOS / Linux / macOS: not yet implemented. Linking succeeds because
		// no static references; runtime calls fail gracefully.
	}
}
