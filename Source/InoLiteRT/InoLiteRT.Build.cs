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
		//     Source/ThirdParty/Public/litert/c/options/   LiteRT per-vendor options headers
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
		//     InoLiteRT.tps                  third-party software notification
		//     InoLiteRT_UPL_Android.xml      Android packaging directives

		string ThirdPartyDir = Path.Combine(PluginDirectory, "Source", "ThirdParty");
		string PublicDir     = Path.Combine(ThirdPartyDir, "Public");
		string Win64Dir      = Path.Combine(ThirdPartyDir, "Win64");
		string AndroidBaseDir = Path.Combine(ThirdPartyDir, "Android");

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
			// Android artifacts produced by
			// Plugins/ino_lite_rt_ue/LiteRT/scripts/build-android.ps1
			// staged under Source/ThirdParty/Android/<arch>/. We support
			// both arm64-v8a (real devices, default) and x86_64 (emulators).
			//
			// Unlike Windows, Android does NOT use import libraries — the
			// .so is linked directly via PublicAdditionalLibraries. There is
			// no libLiteRt.so on Android (upstream's --dynamic_mode=off
			// statically links LiteRT into the monolithic libLiteRtLm.so).
			//
			// We iterate over both arches and File.Exists-guard each .so.
			// UBT runs Build.cs once per target architecture, so only the
			// matching arch's .so will actually be linked into the per-arch
			// build output. RuntimeDependencies entries for both arches are
			// fine — UE's APK packaging step routes each .so to lib/<arch>/
			// based on its source path, and the UPL XML's <copyFile>
			// directives use $S(Architecture) to pick the right one per
			// packaging pass.

			string[] AndroidArches = new string[] { "arm64-v8a", "x86_64" };

			string[] AndroidSoFiles = new string[]
			{
				"libLiteRtLm.so",                      // Bazel-built (monolithic)
				"libGemmaModelConstraintProvider.so",  // upstream prebuilt
				"libLiteRtGpuAccelerator.so",          // upstream prebuilt
				"libLiteRtOpenClAccelerator.so",       // upstream prebuilt
				"libLiteRtTopKOpenClSampler.so",       // upstream prebuilt
				"libLiteRtTopKWebGpuSampler.so",       // upstream prebuilt
				"libLiteRtWebGpuAccelerator.so",       // upstream prebuilt
			};

			foreach (string Arch in AndroidArches)
			{
				string ArchDir = Path.Combine(AndroidBaseDir, Arch);

				// Link against libLiteRtLm.so (only the matching arch
				// actually links; UBT picks based on Target.Architecture).
				string LiteRtLmSo = Path.Combine(ArchDir, "libLiteRtLm.so");
				if (File.Exists(LiteRtLmSo))
				{
					PublicAdditionalLibraries.Add(LiteRtLmSo);
				}

				// Stage every shipped .so for this arch.
				foreach (string So in AndroidSoFiles)
				{
					string SoPath = Path.Combine(ArchDir, So);
					if (File.Exists(SoPath))
					{
						RuntimeDependencies.Add(SoPath);
					}
				}
			}

			// AndroidManifest.xml additions + build.gradle tweaks for APK packaging.
			AdditionalPropertiesForReceipt.Add(
				"AndroidPlugin",
				Path.Combine(ModuleDirectory, "InoLiteRT_UPL_Android.xml"));
		}
		// iOS / Linux / macOS: not yet implemented. Linking succeeds because
		// no static references; runtime calls fail gracefully.
	}
}
