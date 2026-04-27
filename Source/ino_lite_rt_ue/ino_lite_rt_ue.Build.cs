// Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.

using UnrealBuildTool;

public class ino_lite_rt_ue : ModuleRules
{
	public ino_lite_rt_ue(ReadOnlyTargetRules Target) : base(Target)
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

				// External module defined by LiteRT.Build.cs (sibling file in
				// this same directory). Exposes LiteRT's litert/c/*.h and
				// LiteRT-LM's litert/lm/engine.h, links against libLiteRt.lib
				// and LiteRtLm.lib, and stages every runtime DLL/.so for
				// packaging. Public so other plugins / game modules that
				// depend on us can also #include the LiteRT and LiteRT-LM
				// headers without explicitly listing LiteRT in their own
				// Build.cs.
				"LiteRT",
			}
			);


		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"CoreUObject",
				"Engine",
				"Slate",
				"SlateCore",
				// ... add private dependencies that you statically link with here ...
			}
			);


		DynamicallyLoadedModuleNames.AddRange(
			new string[]
			{
				// ... add any modules that your module loads dynamically here ...
			}
			);
	}
}
