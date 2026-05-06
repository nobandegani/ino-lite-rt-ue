# CLAUDE.md — InoLiteRT plugin

This file provides guidance to Claude Code (claude.ai/code) when working
inside `Plugins/InoLiteRT/`. The hosting demo project is documented in
`E:/Projects/InoProject/CLAUDE.md`.

## What this plugin is

An Unreal Engine 5.7 plugin that integrates **LiteRT** and **LiteRT-LM**
into Unreal — building the libraries from source and exposing them as a
UE module that other plugins can depend on.

## Layout

```
Plugins/InoLiteRT/
├── InoLiteRT.uplugin          ← UE plugin manifest
├── LiteRT/                    ← Source + scripts for building LiteRT-LM
│                                and producing the libs Unreal links against
├── Convert/                   ← Tooling for converting other models to LiteRT
└── Source/                    ← The UE module (Build.cs, headers, runtime glue)
```

- **`LiteRT/`** — owns the build pipeline. Bazel workspace, build scripts
  (`build-win64.ps1`, `build-android.ps1`, `setup.ps1`, `clean.ps1`),
  vendored upstream submodules. Outputs land in `Source/ThirdParty/`.
- **`Convert/`** — dev-time tooling for taking external models (PyTorch,
  HF, etc.) and producing `.tflite` artifacts that LiteRT/LiteRT-LM can
  load. Per-model subfolders.
- **`Source/`** — the UE-side module. `Build.cs` wires up the staged
  third-party libs, `StartupModule` loads the runtime DLLs/.so in
  dependency order at `LoadingPhase=PreLoadingScreen`.

## Target platforms

Win64 and Android (arm64-v8a + x86_64). iOS, Linux, macOS are scaffolded
but not built.

## How other plugins consume this

Add `"InoLiteRT"` to `PublicDependencyModuleNames` in their `Build.cs`,
and `{ "Name": "InoLiteRT", "Enabled": true }` to their `.uplugin`. No
Bazel knowledge required on the consumer side — by the time consumer
`StartupModule` runs, the runtimes are already mapped.
