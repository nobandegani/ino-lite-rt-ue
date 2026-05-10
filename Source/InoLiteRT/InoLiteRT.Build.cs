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
		// wiring directly (no separate external module). Per-platform build
		// scripts live under Plugins/InoLiteRT/LiteRT/scripts/:
		//   build-win64.ps1   Windows host -> Win64 artifacts
		//   build-android.ps1 Windows host -> Android arm64-v8a / x86_64
		//   build-macos.sh    macOS host   -> Mac arm64 (Apple Silicon)
		//   build-ios.sh      macOS host   -> iOS arm64 device / sim_arm64
		//
		// All scripts stage into a single consolidated tree:
		//
		//     Source/ThirdParty/Public/litert/c/           LiteRT C API headers
		//     Source/ThirdParty/Public/litert/c/internal/  LiteRT internal headers
		//     Source/ThirdParty/Public/litert/c/options/   LiteRT per-vendor options headers
		//     Source/ThirdParty/Public/litert/lm/          LiteRT-LM C API header
		//     Source/ThirdParty/Public/litert/build_common/ build_config.h
		//     Source/ThirdParty/Win64/                     Windows DLLs + import libs
		//     Source/ThirdParty/Android/<arch>/            Android .so files (per-ABI)
		//     Source/ThirdParty/Mac/                       macOS .dylib files (arm64)
		//     Source/ThirdParty/IOS/<arch>/                iOS .framework + .framework.zip
		//
		// Win64-specific notes:
		//     dxcompiler.dll + dxil.dll are required at runtime by the two
		//     WebGPU accelerator DLLs when LiteRT-LM is started with
		//     backend=gpu — Dawn calls LoadLibraryA("dxcompiler.dll") /
		//     ("dxil.dll") to translate WGSL -> HLSL -> DXIL during D3D12
		//     device init. Editor PIE happens to find them via UE's CEF3 /
		//     ShaderConductor preload; packaged builds need them explicitly
		//     staged.
		//
		// iOS-specific notes:
		//     App Store policy requires every dynamic library to be an
		//     embedded .framework bundle inside MyApp.app/Frameworks/,
		//     code-signed with the app's distribution identity. The build
		//     script wraps each upstream .dylib into a proper framework
		//     layout and rewrites install_names to @rpath/<Name>.framework/
		//     <Name>. UE's IOSToolChain handles embedding + signing.
		//
		// Companion files in this same directory:
		//     InoLiteRT.tps                  third-party software notification
		//     InoLiteRT_UPL_Android.xml      Android packaging directives

		string ThirdPartyDir = Path.Combine(PluginDirectory, "Source", "ThirdParty");
		string PublicDir     = Path.Combine(ThirdPartyDir, "Public");
		string Win64Dir      = Path.Combine(ThirdPartyDir, "Win64");
		string AndroidBaseDir = Path.Combine(ThirdPartyDir, "Android");
		string MacDir        = Path.Combine(ThirdPartyDir, "Mac");
		string IOSBaseDir    = Path.Combine(ThirdPartyDir, "IOS");

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

			// DXC — not link-imported (no PublicDelayLoadDLLs entry); pulled
			// in at runtime by Dawn via LoadLibraryA. Stage so packaged
			// builds have it on disk; pre-load by full path in StartupModule
			// so the filename lookup resolves to our copy.
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "dxcompiler.dll"));
			RuntimeDependencies.Add(Path.Combine(Win64Dir, "dxil.dll"));
		}
		else if (Target.Platform == UnrealTargetPlatform.Android)
		{
			// Android artifacts produced by
			// Plugins/InoLiteRT/LiteRT/scripts/build-android.ps1
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
		else if (Target.Platform == UnrealTargetPlatform.Mac)
		{
			// Mac artifacts produced by
			// Plugins/InoLiteRT/LiteRT/scripts/build-macos.sh
			// staged under Source/ThirdParty/Mac/. Apple Silicon (arm64)
			// only — upstream LiteRT-LM does not ship macos_x86_64 prebuilts.
			//
			// Unlike Windows there are no separate import libraries on Mac:
			// the .dylib is added directly to PublicAdditionalLibraries and
			// dyld resolves @rpath references at runtime. The build script
			// uses install_name_tool to set every dylib's LC_ID_DYLIB to
			// @rpath/<name>.dylib so UE's @loader_path rpath setup finds
			// them in the cooked bundle.
			//
			// Load order matters at runtime (libLiteRtLm imports from libLiteRt
			// when --define=litert_link_capi_so=true is used at build time),
			// but on Mac dyld discovers and resolves dependencies automatically
			// via LC_LOAD_DYLIB entries. We don't need to pre-load by hand
			// like we do on Windows — though InoLiteRT.cpp's StartupModule
			// does pre-load anyway as a hard signal that staging worked.
			string[] MacDylibs = new string[]
			{
				"libLiteRt.dylib",                       // LiteRT core (prebuilt)
				"libLiteRtLm.dylib",                     // our Bazel-built LLM runtime
				"libGemmaModelConstraintProvider.dylib", // constrained decoding (prebuilt)
				"libLiteRtMetalAccelerator.dylib",       // Metal GPU backend (prebuilt)
				"libLiteRtTopKMetalSampler.dylib",       // Metal top-K sampler (prebuilt)
				"libLiteRtWebGpuAccelerator.dylib",      // WebGPU GPU backend (prebuilt)
				"libLiteRtTopKWebGpuSampler.dylib",      // WebGPU top-K sampler (prebuilt)
			};

			foreach (string Dylib in MacDylibs)
			{
				string DylibPath = Path.Combine(MacDir, Dylib);
				if (File.Exists(DylibPath))
				{
					// Link-time: tells UBT to add this dylib to the LC_LOAD_DYLIB
					// list of the consuming binary, so dyld resolves it at launch.
					PublicAdditionalLibraries.Add(DylibPath);

					// Stage at packaging time. NonUFS so the file lands in the
					// .app bundle alongside the engine binaries rather than
					// being cooked into Pak files (.dylib must be loadable by
					// the OS, not extracted from a pak).
					RuntimeDependencies.Add(DylibPath);
				}
			}

			// Apple system frameworks. Metal is the native GPU API the prebuilt
			// libLiteRtMetalAccelerator.dylib calls into; Foundation provides
			// NSObject / NSString that the Metal accelerator uses internally.
			// Listing them here pulls them into the consuming binary's link
			// step so dyld can resolve them when the accelerator is dlopen'd.
			PublicFrameworks.AddRange(new string[] { "Metal", "Foundation" });
		}
		else if (Target.Platform == UnrealTargetPlatform.IOS)
		{
			// iOS artifacts produced by
			// Plugins/InoLiteRT/LiteRT/scripts/build-ios.sh --arch arm64|sim_arm64
			// staged as .framework bundles under Source/ThirdParty/IOS/<arch>/.
			//
			// App Store policy requires every dynamic library to be an embedded
			// .framework bundle inside MyApp.app/Frameworks/, code-signed with
			// the app's distribution identity. Raw .dylib loads are auto-rejected
			// at submission. The build script wraps each upstream dylib into a
			// proper framework (binary + Info.plist) and the install_name_tool
			// step rewrites every cross-library reference to
			// @rpath/<Name>.framework/<Name>.
			//
			// We must select the arm64 (device) vs sim_arm64 (simulator) variant
			// at Build.cs time — UE's IOSToolChain only embeds frameworks listed
			// in PublicAdditionalFrameworks for the target's active architecture,
			// and the framework binaries differ between the two slices.
			//
			// Detect simulator via foreach rather than UnrealArchitectures.Contains
			// for max version safety — Contains-on-collection landed in UBT in
			// UE 5.5; an explicit loop works back to UE 5.0.
			bool bIsIOSSimulator = false;
			foreach (UnrealArch Arch in Target.Architectures.Architectures)
			{
				if (Arch == UnrealArch.IOSSimulator)
				{
					bIsIOSSimulator = true;
					break;
				}
			}
			string IOSArchDir = bIsIOSSimulator
				? Path.Combine(IOSBaseDir, "sim_arm64")
				: Path.Combine(IOSBaseDir, "arm64");

			// Map of framework names to ship — must match build-ios.sh's
			// produced set. iOS gets a CPU-only build: monolithic LiteRtLm
			// (Bazel-built, statically embeds LiteRT core) + Gemma constraint
			// provider (prebuilt, no LiteRT dependency).
			//
			// libLiteRt + Metal accelerators are NOT shipped on iOS — see the
			// long comment in build-ios.sh for the duplicate-symbol rationale.
			// Metal acceleration is a follow-up that requires upstream LiteRT
			// BUILD changes.
			//
			// Order does NOT determine load sequence on iOS — dyld computes
			// the dependency graph from each framework's LC_LOAD_DYLIB entries
			// at app launch. The order here only affects link order, which is
			// irrelevant for these dylibs (none expose link-time imports we
			// statically reference).
			string[] IOSFrameworks = new string[]
			{
				"LiteRtLm",                     // monolithic Bazel build (statically embeds LiteRT)
				"GemmaModelConstraintProvider", // constrained decoding (prebuilt, LiteRT-independent)
			};

			foreach (string FwName in IOSFrameworks)
			{
				string FwZip = Path.Combine(IOSArchDir, FwName + ".framework.zip");
				if (File.Exists(FwZip))
				{
					// bCopyFramework=true tells UE's IOSToolChain to:
					//   1. Unzip the framework into Intermediate/IOS/.../Frameworks/
					//   2. Copy it into the .app bundle's Frameworks/ dir
					//   3. Re-sign it with the app's distribution identity at
					//      packaging time
					// CopyBundledAssets is null because our frameworks contain
					// no resource bundles (just the binary + Info.plist).
					PublicAdditionalFrameworks.Add(
						new Framework(FwName, FwZip, /*CopyBundledAssets=*/null, /*bCopyFramework=*/true));
				}
			}

			// Apple system frameworks. Same rationale as Mac: link-time
			// references for Metal/Foundation so dyld resolves them when
			// libLiteRtMetalAccelerator dlopens at runtime.
			PublicFrameworks.AddRange(new string[] { "Metal", "Foundation" });
		}
		// Linux: not yet implemented. Upstream ships prebuilt/linux_arm64/ and
		// prebuilt/linux_x86_64/ but we haven't wired a build script for it.
		// Linking succeeds because no static references; runtime calls fail
		// gracefully (the smoke test in InoLiteRT.cpp is gated on supported
		// platforms).
	}
}
