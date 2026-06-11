# CLAUDE.md — InoLiteRT plugin

This file provides guidance to Claude Code (claude.ai/code) when working
inside `Plugins/InoLiteRT/`. The hosting demo project is documented in
`E:/Projects/InoProject/CLAUDE.md`.

## What this plugin is

An Unreal Engine 5.7 plugin that integrates **LiteRT** and **LiteRT-LM**
into Unreal and exposes them as a UE module other plugins depend on.

Only **LiteRT-LM** is built from source (Bazel target `//ino:LiteRtLm`,
defined by `overlay/ino/BUILD.bazel`). **LiteRT itself is NOT built
here** — its `libLiteRt.{dll,so,dylib}` is the upstream prebuilt shipped
inside LiteRT-LM's `prebuilt/<platform>/`, and its headers come from
Bazel's external fetch of the LiteRT repo. Both are pinned by
LiteRT-LM's `WORKSPACE` `LITERT_REF`, so moving the LiteRT-LM pin moves
LiteRT with it.

## Layout

```
Plugins/InoLiteRT/
├── InoLiteRT.uplugin          ← UE plugin manifest
├── LiteRT/                    ← Source + scripts for building LiteRT-LM
│                                and producing the libs Unreal links against
├── Convert/                   ← Tooling for converting other models to LiteRT
└── Source/                    ← The UE module (Build.cs, headers, runtime glue)
```

- **`LiteRT/`** — owns the build pipeline. Build scripts (`setup.ps1` +
  `build-win64.ps1` + `build-android.ps1` + `clean.ps1` for Windows
  hosts; `setup.sh` + `build-macos.sh` + `build-ios.sh` + `clean.sh`
  for macOS hosts), `overlay/` (the `//ino:LiteRtLm` Bazel target +
  `kLiteRtLmForceKeep[]`, the hand-maintained C-API export list copied
  into the submodule by setup), and vendored upstream submodules.
  Outputs land in `Source/ThirdParty/`. The LiteRT-LM pin is recorded
  in `LiteRT/LITERT_LM_TAG` — that file is authoritative; the
  `vendor/LiteRT-LM` submodule gitlink is marked `ignore = dirty`
  (build mutates it) and is NOT the source of truth. `vendor/LiteRT`
  is a mirror of `LITERT_REF` and is **not consumed by the build**.
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

## Build & capability model

The Bazel-built `LiteRtLm` binary is **CPU/XNNPACK only on every
platform** — no GPU/NPU accelerator is statically linked (upstream's
`litert_gpu_accelerator_deps()` is an OSS no-op;
`LiteRtStaticLinkedAcceleratorGpuDef` is permanently null). All GPU/NPU
capability is delivered by runtime `dlopen` of the prebuilt
accelerator/sampler libs the scripts stage next to it:

| Platform | GPU (prebuilt, dlopen'd) | NPU |
|---|---|---|
| Win64 | WebGPU/Dawn → D3D12 (needs staged `dxcompiler.dll`/`dxil.dll`)³ | ready, not functional¹ |
| Android arm64/x86_64 | OpenCL + WebGPU + samplers | ready, not functional¹ |
| macOS arm64 | Metal + WebGPU | n/a (no Apple NPU vendor) |
| iOS arm64/sim | CPU-only today² | upstream-disabled |

All four scripts stage BOTH upstream `build_config` variants under
`Public/litert/build_common/config/` plus an identical platform-dispatch
wrapper as `build_config.h` (template: `LiteRT/scripts/build_config_wrapper.h`).
The wrapper selects `build_config_gpu.h` (NPU-off) under
`TARGET_OS_IPHONE` and `build_config_gpu_npu.h` (upstream-default
`gpu,npu`) everywhere else — LiteRT-LM `runtime/executor/BUILD`
force-sets `LITERT_DISABLE_NPU` only under `@platforms//os:ios`, so the
iOS consumer header must differ, and the shared `Public/` tree means a
single staged variant would depend on which platform script ran last.

¹ Functional NPU additionally needs a `libLiteRtDispatch_<Vendor>`
  (Qualcomm / MediaTek / Intel OpenVINO / …) which is vendor-SDK-gated
  and ships in NO `prebuilt/` dir. The plugin is NPU-*ready*, not
  NPU-*functional*, until such a lib + an NPU-compiled model exist.
² iOS ships only the Gemma constraint provider. The prebuilt Metal
  accelerator exists upstream but isn't shipped — the monolithic-static
  iOS build would load a second LiteRT instance (unresolved upstream).
³ **Known upstream issue — Win64 GPU sampling falls back to CPU.** The
  pinned upstream `prebuilt/windows_x86_64/libLiteRtTopKWebGpuSampler.dll`
  exports only `Create`/`Destroy`/`SampleToIdAndScoreBuffer` and is
  missing `LiteRtTopKWebGpuSampler_UpdateConfig` (plus `CanHandleInput`/
  `HandlesInput`/`SetInputTensorsAndInferenceFunc`), which the pinned
  `runtime/components/sampler_factory.cc` Win64 path requires. So
  `GetSamplerCApi` fails the symbol resolve ("The specified procedure
  could not be found"), the WebGPU sampler is rejected, and LiteRT-LM
  falls back to **CPU sampling** (GPU still does prefill+decode — only
  token selection is on CPU, so the perf cost is small). Only the
  **Windows** upstream prebuilt is incomplete; the Android/Linux/macOS
  `prebuilt/` sampler libs export the full symbol set. This is an
  upstream LiteRT-LM Windows-packaging defect inherited through the pin,
  NOT an InoLiteRT staging bug (the build script copies the upstream
  prebuilt faithfully) and NOT fixable in the InoAgents consumer.
  Expected to be fixed upstream. Re-checked at v0.13.1 (2026-06-11):
  still missing — the DLL exports only `Create`/`Destroy`/
  `SampleToIdAndScoreBuffer` and `sampler_factory.cc` still requires
  `UpdateConfig`. On the next `LITERT_LM_TAG` bump, re-check whether
  `prebuilt/windows_x86_64/libLiteRtTopKWebGpuSampler.dll`
  exports `LiteRtTopKWebGpuSampler_UpdateConfig`; once it does, the Win64
  GPU sampler will work with no code change — delete this note then.

## Updating the runtime pin

1. Set `LiteRT/LITERT_LM_TAG` to the new LiteRT-LM SHA and check the
   `vendor/LiteRT-LM` submodule out to it; bump `vendor/LiteRT` to the
   new `WORKSPACE` `LITERT_REF` to keep the mirror honest.
2. Re-sync `overlay/ino/LiteRtLm_exports.cc` `kLiteRtLmForceKeep[]`
   against every `LITERT_LM_C_API_EXPORT` in `c/engine.h` — a missing
   entry is silently dropped from the DLL (no static check).
3. **Diff `c/engine.h` signatures old→new, not just export names** —
   existing functions can change parameters. The `InoAgents` plugin is
   the real LiteRT-LM consumer (InoLiteRT only loads the libs); changed
   signatures need call-site migration there.
4. Re-run the per-platform build script(s); verify the staged
   `LiteRtLm` exports the full `litert_lm_*` set; commit the rebuilt
   `Source/ThirdParty/<platform>/` + shared `Public/litert/**`.
5. Re-check the Win64 WebGPU-sampler issue (footnote ³): confirm whether
   the new pin's `prebuilt/windows_x86_64/libLiteRtTopKWebGpuSampler.dll`
   now exports `LiteRtTopKWebGpuSampler_UpdateConfig`. If it does, Win64
   GPU sampling is fixed with no code change — delete footnote ³.

## How other plugins consume this

Add `"InoLiteRT"` to `PublicDependencyModuleNames` in their `Build.cs`,
and `{ "Name": "InoLiteRT", "Enabled": true }` to their `.uplugin`. No
Bazel knowledge required on the consumer side — by the time consumer
`StartupModule` runs, the runtimes are already mapped.
