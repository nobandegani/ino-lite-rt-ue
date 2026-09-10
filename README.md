# InoLiteRT

**Google's on-device ML runtimes, packaged for Unreal Engine 5.** This plugin builds and ships
[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) and
[LiteRT](https://github.com/google-ai-edge/LiteRT) as linkable UE modules, so consumer plugins
can `#include "litert/lm/engine.h"` and call the C API directly — on Windows, Android, macOS and
iOS.

It is infrastructure, not a feature. InoLiteRT has no Blueprint surface and no gameplay API of
its own: it owns the hard parts — Bazel cross-compilation, per-platform binary staging, DLL load
ordering, App Store-compliant framework packaging — so that plugins like
[InoAgents](https://github.com/nobandegani/ino-agents-ue) can treat the LiteRT C API as simply
available.

> **Licensing in one line:** this plugin is Apache-2.0 and so are the LiteRT runtimes, but it also
> ships **`dxil.dll` (Microsoft proprietary)** on Win64 and a **revenue-capped Neuphonic voice
> file** under `Convert/`. See [Licensing](#licensing) before shipping.

---

## Contents

- [What consumers get](#what-consumers-get)
- [Requirements](#requirements)
- [Install](#install)
- [Building the runtimes](#building-the-runtimes)
- [Platform support](#platform-support)
- [How startup works](#how-startup-works)
- [Model conversion](#model-conversion)
- [Version pinning](#version-pinning)
- [Troubleshooting](#troubleshooting)
- [Licensing](#licensing)

---

## What consumers get

Add `InoLiteRT` to your module's dependencies and the LiteRT C APIs are on your include path:

```cpp
#include "litert/lm/engine.h"          // LiteRT-LM: LLM inference, tool calling, streaming
#include "litert/c/litert_compiled_model.h"  // LiteRT: arbitrary TFLite models
```

Headers are added via `PublicSystemIncludePaths`, so upstream's canonical include style works and
third-party warnings don't poison your build. Import libraries, delay-load registration, runtime
staging and Android UPL packaging are all handled by `InoLiteRT.Build.cs` — a consumer declares
the dependency and nothing else.

There is deliberately **no wrapper API**. Consumers call upstream's C API directly, so there is
no abstraction to fall behind a LiteRT-LM version bump.

---

## Requirements

**To consume it** (the common case): Unreal Engine 5 (developed against 5.7) and a platform with
committed binaries. Prebuilt runtimes for Win64, Android, macOS and iOS are in the repo, so a
clean recursive clone compiles without building anything.

**To rebuild the runtimes**: see [Building the runtimes](#building-the-runtimes). You only need
this to move the LiteRT-LM pin or add a platform.

---

## Install

This repo uses **five git submodules**, so clone recursively:

```bash
cd YourProject/Plugins
git clone --recurse-submodules https://github.com/nobandegani/ino-lite-rt-ue.git InoLiteRT
```

Already cloned flat?

```bash
git submodule update --init --recursive
```

Then add `InoLiteRT` to your `.uproject` `Plugins` array, regenerate project files, and build.

> **The submodules are build inputs, not runtime dependencies.** The plugin compiles and runs
> from the committed binaries alone. You need the submodules only to rebuild the runtimes, to run
> the model converters, or to inspect the corresponding source for the binaries you are shipping.
> `--recurse-submodules` on a fresh clone is still the path of least surprise.

---

## Building the runtimes

Scripts live in `LiteRT/scripts/` and stage their output into `Source/ThirdParty/`.

| Script | Host | Target |
|---|---|---|
| `setup.ps1` / `setup.sh` | Windows / Unix | One-time toolchain prep (bazelisk, etc.) |
| `build-win64.ps1` | Windows | Windows x64 DLLs + import libs |
| `build-android.ps1` | Windows | `arm64-v8a` and `x86_64` `.so` files |
| `build-macos.sh` | macOS | macOS arm64 `.dylib` files |
| `build-ios.sh --arch arm64` | macOS | iOS device `.framework` |
| `build-ios.sh --arch sim_arm64` | macOS | iOS simulator `.framework` |
| `clean.ps1` / `clean.sh` | — | Drop Bazel output trees |

Only **LiteRT-LM** is built from source, via Bazel. **LiteRT itself is not built here** — its
`libLiteRt` shared library is the upstream prebuilt shipped inside LiteRT-LM's
`prebuilt/<platform>/`, and its headers come from Bazel's external fetch. Both are pinned by
`LITERT_REF` in LiteRT-LM's `WORKSPACE`, so moving the LiteRT-LM pin moves LiteRT with it.

The exported C symbol surface is defined by the Bazel overlay at `LiteRT/overlay/ino/` —
`BUILD.bazel` plus `LiteRtLm_exports.cc`. That overlay is the only Inoland-authored input to the
native build.

`build-win64.ps1` also downloads Microsoft's DXC release (see
[Licensing](#licensing)) and caches the zip under `LiteRT/.cache/`.

---

## Platform support

| Platform | Artifact | Linkage | GPU backend |
|---|---|---|---|
| **Windows x64** | `.dll` + import `.lib` | Delay-loaded | WebGPU → D3D12 (needs DXC) |
| **Android** `arm64-v8a`, `x86_64` | `.so` | Dynamic linker + UPL `<soLoadLibrary>` | OpenCL, WebGPU |
| **macOS** arm64 | `.dylib` | `@rpath`, preloaded by full path | Metal (preferred), WebGPU |
| **iOS** `arm64`, `sim_arm64` | `.framework` (+ `.zip`) | Embedded + code-signed by UE | Metal |

iOS ships `.framework` bundles rather than bare dylibs because App Store policy requires every
dynamic library to be an embedded, signed framework inside `MyApp.app/Frameworks/`. The build
script wraps each upstream `.dylib` and rewrites install names to
`@rpath/<Name>.framework/<Name>`; UE's `IOSToolChain` handles embedding and signing.

**Not supported:** Linux is scaffolded but has no build script — the module excludes the LiteRT-LM
header there so it still links. macOS x86_64 is unsupported because upstream LiteRT-LM ships no
`macos_x86_64` prebuilts.

---

## How startup works

The module loads at `PreLoadingScreen` so the runtimes are mapped before any consumer plugin's
`StartupModule` runs. On Windows it preloads seven DLLs **in a specific order**:

```
1. dxcompiler.dll                       DXC — Dawn dependency
2. dxil.dll                             DXIL signing — Dawn dependency
3. libGemmaModelConstraintProvider.dll  required sibling of LiteRtLm.dll
4. libLiteRt.dll                        LiteRT core
5. LiteRtLm.dll                         the Bazel-built LLM runtime
6. libLiteRtWebGpuAccelerator.dll       WebGPU → D3D12
7. libLiteRtTopKWebGpuSampler.dll       GPU-side top-K sampling
```

Order is load-bearing. Built with `--define=litert_link_capi_so=true`, `LiteRtLm.dll` imports
from `libLiteRt.dll`; loading it first fails with `GetLastError=126` ("missing import"). DXC goes
first because the WebGPU DLLs call `LoadLibraryA("dxcompiler.dll")` internally during D3D12 init —
preloading by **absolute path** puts the staged copies in the process module table so those
base-name lookups resolve to them.

Startup also verifies, via `GetModuleFileNameW`, that each DLL was actually mapped from the path
it asked for and not served from the loader's base-name cache for a same-named DLL another module
loaded earlier. That check exists because such a collision is exactly what caused an
editor-versus-packaged divergence on `dxcompiler.dll`.

macOS uses the same ordering minus DXC. On iOS and Android, dyld and the Android dynamic linker
resolve everything at launch, so startup only runs a smoke test
(`litert_lm_set_min_log_level`).

**Models are never loaded here.** Pulling a multi-GB Gemma bundle at `StartupModule` would freeze
the editor; model loading is the consumer subsystem's job.

---

## Model conversion

`Convert/` holds dev-time Python tooling, not runtime code:

| Directory | Produces |
|---|---|
| `Convert/NeuTTS/` | NeuTTS Nano backbone → `.litertlm` bundle; voice encoder → `.pt` |
| `Convert/NeuCodec/` | NeuCodec decoder → `.tflite` |

Each has its own `requirements.txt` and `sanity_check.py`. These are only needed if you are
producing NeuTTS model bundles — nothing in the plugin's runtime path touches them.

> These scripts pull in Neuphonic submodules whose license caps commercial use by revenue, and
> `Convert/NeuTTS/voices/jo.pt` is a redistributed derivative of a Neuphonic voice sample. See
> [Licensing](#licensing).

---

## Version pinning

`LiteRT/LITERT_LM_TAG` is the **authoritative** LiteRT-LM pin. Current pins:

| Submodule | Commit | Describes as |
|---|---|---|
| `LiteRT/vendor/LiteRT-LM` | `a0afb5a5` | `v0.9.0-434-ga0afb5a5` |
| `LiteRT/vendor/LiteRT` | `a412f505` | `v2.1.5-183-ga412f5050` |
| `LiteRT/vendor/litert-torch` | `49d68fca` | `v0.9.1` |

`LiteRT/vendor/LiteRT` is a **source-visibility mirror only** — kept on the `LITERT_REF` SHA from
LiteRT-LM's `WORKSPACE` so the matching source is available for inspection, but not consumed by
the build. `litert-torch` is a dev-time PyTorch → `.tflite` converter.

The LiteRT-LM submodule is marked `ignore = dirty` in `.gitmodules` because its Bazel build mutates
tracked files and drops untracked artifacts into the working tree on every build; without that it
would show perpetually dirty in the superproject. `LITERT_LM_TAG` is what actually governs.

See [`CLAUDE.md`](CLAUDE.md) for the layout diagram, pinning strategy, and the manual update
procedure.

---

## Troubleshooting

Everything logs under **`LogInoLiteRT`**.

| Symptom | Cause |
|---|---|
| `GetLastError=126` on `LiteRtLm.dll` | Load order violated — `libLiteRt.dll` must load first. |
| `FindPlugin("InoLiteRT") returned null` | Plugin descriptor missing from the cooked build. |
| DLL mapped from an unexpected path (logged) | Loader base-name cache collision — another module already loaded a same-named DLL. |
| Works in editor, breaks packaged (GPU) | The classic DXC case: the editor rides along on UE's ShaderConductor copy. Confirm `dxcompiler.dll` and `dxil.dll` are staged. |
| GPU output never terminates in Shipping | A DXC version mismatch. The pinned v1.9.2602 is what upstream tested against — do not substitute UE's fork. |
| Linux build errors on `engine.h` | Expected — Linux has no build script; the header is excluded there. |

---

## Licensing

This plugin is **Apache-2.0** ([`LICENSE`](LICENSE)), matching LiteRT and LiteRT-LM. All source
files carry matching headers.

**That grant does not cover everything in the repository.** Full per-path detail is in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md); the two items that can actually bite you:

> **⚠️ `Source/ThirdParty/Win64/dxil.dll` is Microsoft proprietary.** It is the DXIL signing
> library, shipped only as a signed binary in Microsoft's DXC releases under Microsoft's own
> redistribution terms — not an OSI license, and not Apache-2.0. (`dxcompiler.dll` beside it is
> open source, under the University of Illinois/NCSA license — **not** MIT, as an earlier revision
> of `InoLiteRT.tps` claimed.) Both are needed only for the **GPU** backend; on CPU they are
> inert and can be dropped from staging entirely. Confirm the terms on the release you ship.

> **⚠️ `Convert/NeuTTS/voices/jo.pt` is revenue-capped.** It is a derivative of a Neuphonic
> reference voice under the **NeuTTS Open License v1.0**, which conditions all commercial use on
> your legal entity earning **under $5M USD/year**. This affects the NeuTTS conversion path only —
> LiteRT-LM inference, the plugin's actual purpose, is unaffected. Delete `Convert/NeuTTS/` and
> `Convert/NeuCodec/` and the restriction goes with them.

**Gemma model weights are not in this repository.** They download at runtime and remain subject to
Google's [Gemma Terms of Use](https://ai.google.dev/gemma/terms), which carry restrictions
Apache-2.0 does not.

Corresponding source for every committed binary is the pinned submodule set above, and
`LiteRT/scripts/` are the exact scripts that produced them, Bazel flags included.
