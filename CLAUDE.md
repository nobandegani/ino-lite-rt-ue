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
  (`build-win64.ps1` + `build-android.ps1` + `setup.ps1` + `clean.ps1` for
  Windows hosts; `build-macos.sh` + `build-ios.sh` + `setup.sh` for macOS
  hosts), vendored upstream submodules. Outputs land in
  `Source/ThirdParty/`.
- **`Convert/`** — dev-time tooling for taking external models (PyTorch,
  HF, etc.) and producing `.tflite` artifacts that LiteRT/LiteRT-LM can
  load. Per-model subfolders.
- **`Source/`** — the UE-side module. `Build.cs` wires up the staged
  third-party libs, `StartupModule` loads the runtime DLLs/.so in
  dependency order at `LoadingPhase=PreLoadingScreen`.

## Target platforms

| Platform | Architectures | Build host | Script |
|---|---|---|---|
| Win64 | x86_64 | Windows | `build-win64.ps1` |
| Android | arm64-v8a, x86_64 | Windows | `build-android.ps1` |
| Mac | arm64 (Apple Silicon) | macOS arm64 | `build-macos.sh` |
| iOS | arm64 device, sim_arm64 | macOS arm64 | `build-ios.sh --arch …` |

Linux is scaffolded but not built. Mac x86_64 is unsupported (upstream
LiteRT-LM ships no `macos_x86_64` prebuilts; Apple Silicon is the M1+ era).
iOS frameworks are App Store-compliant — `.dylib` files are wrapped into
`.framework` bundles and embedded into `MyApp.app/Frameworks/` at packaging
time, signed with the app's distribution identity by UE's IOSToolChain.

## How other plugins consume this

Add `"InoLiteRT"` to `PublicDependencyModuleNames` in their `Build.cs`,
and `{ "Name": "InoLiteRT", "Enabled": true }` to their `.uplugin`. No
Bazel knowledge required on the consumer side — by the time consumer
`StartupModule` runs, the runtimes are already mapped.
