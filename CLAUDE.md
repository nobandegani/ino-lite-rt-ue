# CLAUDE.md — ino_lite_rt_ue plugin

This file provides guidance to Claude Code (claude.ai/code) when working
inside `Plugins/ino_lite_rt_ue/`. The hosting demo project is documented
in `E:/Projects/InoProject/CLAUDE.md`.

## Purpose

`ino_lite_rt_ue` is an Unreal Engine 5 runtime plugin whose job is to
**build Google's two on-device ML runtimes from source and expose them
as UE modules** so other plugins (and game code) can consume both:

- **LiteRT-LM** — Google's on-device LLM runtime (Gemma 4 inference,
  tool calling, streaming). Upstream:
  https://github.com/google-ai-edge/LiteRT-LM
- **LiteRT** — Google's TFLite-based inference runtime for arbitrary
  TFLite models (the underlying runtime LiteRT-LM itself depends on,
  but also useful standalone for non-LLM TFLite workloads). Upstream:
  https://github.com/google-ai-edge/LiteRT

Both are built from source via Bazel into shared libraries that ship
inside the plugin's `Binaries/ThirdParty/`, with import libs + headers
staged under `Source/ThirdParty/`. UE consumers link against them via
ordinary Build.cs `PublicDependencyModuleNames` entries.

The plugin is target-platform-aware: **Windows (Win64)** and **Android
(arm64-v8a)** today, matching the hosting project's targets. iOS, Linux,
and macOS are scaffolded but not yet built.

## High-level layout

```
Plugins/ino_lite_rt_ue/
├── ino_lite_rt_ue.uplugin            ← UE plugin manifest
│
├── LiteRT/                           ← Bazel build workspace umbrella for both runtimes
│   ├── LITERT_TAG                    ← pinned LiteRT commit SHA (matches LiteRT-LM's LITERT_REF)
│   ├── LITERT_LM_TAG                 ← pinned LiteRT-LM commit SHA
│   ├── vendor/
│   │   ├── LiteRT/                   ← git submodule → google-ai-edge/LiteRT
│   │   │                                (used for staging LiteRT C API headers;
│   │   │                                 the libLiteRt.dll itself is shipped pre-built
│   │   │                                 by Google inside LiteRT-LM's prebuilt/<platform>/)
│   │   └── LiteRT-LM/                ← git submodule → google-ai-edge/LiteRT-LM
│   ├── overlay/ino/                  ← files staged into the LiteRT-LM submodule before build
│   │   ├── BUILD.bazel               ← defines //ino:LiteRtLm cc_binary target
│   │   └── LiteRtLm_exports.cc       ← DllMain + force-reference of every C API fn
│   └── scripts/                      ← setup.ps1, build-win64.ps1,
│                                       build-android-arm64.ps1, update-litert.ps1,
│                                       clean.ps1 (currently all LiteRT-LM-focused)
│
├── Source/
│   ├── ino_lite_rt_ue/               ← runtime UE module — loads DLLs, exposes API
│   │   ├── ino_lite_rt_ue.Build.cs
│   │   ├── Public/                   ← UE-facing types (Blueprint subsystems,
│   │   │                               settings, helpers)
│   │   └── Private/                  ← module impl + DLL loading + smoke tests
│   │
│   └── ThirdParty/                   ← UE External modules wrapping the built libs
│       ├── LiteRTLM/                 ← LiteRT-LM external module (the .dll/.so +
│       │                               import lib + C API headers staged here by
│       │                               LiteRT/scripts/build-*.ps1)
│       │   ├── LiteRTLM.Build.cs
│       │   ├── LiteRTLM.tps
│       │   ├── LiteRTLM_UPL_Android.xml
│       │   ├── Public/litert/lm/     ← engine.h (staged from build)
│       │   ├── Win64/LiteRtLm.lib    ← import lib (staged from build)
│       │   └── Android/arm64-v8a/    ← .so files (staged from build)
│       │
│       └── LiteRT/                   ← LiteRT external module (planned, same shape)
│
└── Binaries/ThirdParty/              ← runtime DLLs / .so files (gitignored)
    ├── LiteRTLM/Win64/, /Android/...
    └── LiteRT/Win64/, /Android/...
```

## Build flow

The Bazel build is **outside** UE's build pipeline. Devs run a script
once per platform per upstream version bump:

1. `LiteRT/scripts/setup.ps1` — preflight (Bazelisk, MSVC, Git path,
   Developer Mode, Bazel output base), initialize the LiteRT-LM submodule,
   copy `overlay/` files into the submodule, register them in the
   submodule's `.git/info/exclude` so the submodule's working tree stays
   clean.
2. `LiteRT/scripts/build-win64.ps1` — `bazelisk build //ino:LiteRtLm`,
   then copy the resulting `LiteRtLm.dll` + `libLiteRt.dll` + GPU
   accelerator DLLs + import lib + headers into `Binaries/ThirdParty/LiteRTLM/Win64/`
   and `Source/ThirdParty/LiteRTLM/{Win64,Public}/`.
3. `LiteRT/scripts/build-android-arm64.ps1` — same but with
   `--config=android_arm64`, NDK r28+, separate Bazel output base.
4. (planned) standalone LiteRT staging — currently the LiteRT runtime
   ships via LiteRT-LM's prebuilt `libLiteRt.dll`. A separate script to
   stage LiteRT's public C API headers (`litert/c/litert_*.h`) from
   `vendor/LiteRT/` into `Source/ThirdParty/LiteRT/Public/` is on the
   to-do list.

UE's normal build (`Setup.bat` → editor build) **does not** invoke
Bazel. It just links against the already-staged outputs. If those
outputs aren't on disk yet, UE's link step fails with "library not
found" — the fix is "run the Bazel script".

## How other plugins consume this

In another plugin's `Build.cs`:

```csharp
PublicDependencyModuleNames.AddRange(new string[] {
    "LiteRTLM",   // exposes <litert/lm/engine.h> + delay-loaded LiteRtLm.dll
    "LiteRT",     // exposes the standalone LiteRT C API
});
```

That's it — no Bazel knowledge required, no DLL loading. The runtime
DLL preload + `set_min_log_level` smoke test happen in
`ino_lite_rt_ue`'s `StartupModule`, which is set to load at
`PreLoadingScreen` so the DLLs are mapped before any consumer's
`StartupModule` runs.

## Target platforms

| Platform        | LiteRT-LM | LiteRT   | Notes |
|---|---|---|---|
| **Windows x64** | ✅ built  | (planned) | CPU + GPU via D3D12/WebGPU. `LiteRtLm.dll` + `libLiteRt.dll` + 3 prebuilt accelerator DLLs. |
| **Android arm64-v8a** | ✅ built | (planned) | CPU + GPU via OpenCL/WebGPU. Monolithic `libLiteRtLm.so` + 6 prebuilt accelerator `.so`. |
| iOS / Linux / macOS | ⏳ stubs | ⏳ stubs | Scaffold compiles; runtime calls fail gracefully. |

## Status

This plugin is a fresh extraction from the older `InoAgents` plugin —
the LiteRT-LM build workspace, ThirdParty external module, runtime DLL
loading, and Blueprint-facing subsystem/conversation/tool API are
being moved in piece by piece. Until the move is complete, expect:

- Some path / name references in scripts and Build.cs files may still
  use `InoAgents` / `InoAgentsLibrary` instead of `ino_lite_rt_ue` /
  `LiteRTLM`. Grep before trusting any specific reference.
- LiteRT-LM is built and shipping. Standalone LiteRT staging (just the
  C API headers — the DLL is already shipped via LiteRT-LM's prebuilt)
  is a TODO; `Source/ThirdParty/LiteRT/` exists but is empty.
- The runtime UE module under `Source/ino_lite_rt_ue/` is currently
  still the Epic-generated scaffold (`Fino_lite_rt_ueModule`, no real
  startup logic yet). The DLL load order, log category, settings, and
  Blueprint subsystem from the InoAgents version need to be ported.

## Authoritative references

- Upstream LiteRT-LM: https://github.com/google-ai-edge/LiteRT-LM
- Upstream LiteRT: https://github.com/google-ai-edge/LiteRT
- LiteRT-LM C API header: `LiteRT/vendor/LiteRT-LM/c/engine.h`
- LiteRT C API headers: `LiteRT/vendor/LiteRT/litert/c/litert_*.h`
- Pinned LiteRT-LM commit: see `LiteRT/LITERT_LM_TAG`
- Pinned LiteRT commit: see `LiteRT/LITERT_TAG` (must match `vendor/LiteRT-LM/WORKSPACE`'s `LITERT_REF`)
- Build details (Bazel toolchain, MAX_PATH workarounds, NDK story):
  see comments inline in `LiteRT/scripts/*.ps1` and the upstream
  CI `.github/workflows/ci-build-*.yml`.
