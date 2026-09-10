# Third-Party Notices

InoLiteRT is distributed under the [Apache License 2.0](LICENSE), Copyright 2026 Inoland.

**That grant covers Inoland's own code only — `Source/InoLiteRT/`, `LiteRT/scripts/`,
`LiteRT/overlay/`, and `Convert/*/scripts/`.** This repository also redistributes 43 prebuilt
third-party binaries under `Source/ThirdParty/`, and those carry their own licenses. Two of them
are **not** open source. The table below is authoritative where it disagrees with any other
document here.

---

## Summary

| Path | Component | License | Notes |
|---|---|---|---|
| `Source/InoLiteRT/`, `LiteRT/scripts/`, `LiteRT/overlay/`, `Convert/*/scripts/` | InoLiteRT | Apache-2.0 | Inoland's own code |
| `Source/ThirdParty/Public/litert/` | LiteRT + LiteRT-LM C API headers | Apache-2.0 | Google AI Edge |
| `Source/ThirdParty/{Win64,Android,Mac,IOS}/` — `*LiteRt*` | LiteRT + LiteRT-LM runtimes | Apache-2.0 | Google AI Edge |
| `…/*GemmaModelConstraintProvider*` | Gemma constraint provider | Apache-2.0 code; **model terms apply to weights** | See §2 |
| `Source/ThirdParty/Win64/dxcompiler.dll` | Microsoft DirectX Shader Compiler | **University of Illinois/NCSA** | LLVM fork — **not MIT**, see §3 |
| `Source/ThirdParty/Win64/dxil.dll` | Microsoft DXIL signing library | **Microsoft proprietary** | Not open source — see §3 |
| `Convert/NeuTTS/voices/jo.pt` | Derived from a Neuphonic reference voice | **NeuTTS Open License v1.0** | Revenue-capped — see §4 |
| `Convert/NeuTTS/vendor/neutts` *(submodule)* | neuphonic/neutts | NeuTTS Open License v1.0 | Reference, not redistributed |
| `Convert/NeuCodec/vendor/neucodec` *(submodule)* | neuphonic/neucodec | See upstream | Reference, not redistributed |
| `LiteRT/vendor/*` *(submodules)* | LiteRT, LiteRT-LM, litert-torch | Apache-2.0 | Build input, not redistributed |

Submodules are **references**, not redistribution — cloning this repo does not copy their
contents unless you ask for them with `--recurse-submodules`.

---

## 1. LiteRT and LiteRT-LM — Google LLC

**License:** Apache-2.0. **Upstream:**
[LiteRT](https://github.com/google-ai-edge/LiteRT) ·
[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)

These are the reason the plugin exists. The committed binaries were built from these exact pins:

| Submodule | Commit | Describes as |
|---|---|---|
| `LiteRT/vendor/LiteRT-LM` | `a0afb5a56acd106b23a2b2385b8469834dc268c0` | `v0.9.0-434-ga0afb5a5` |
| `LiteRT/vendor/LiteRT` | `a412f505023085780a098e777b8eb816c07347f2` | `v2.1.5-183-ga412f5050` |
| `LiteRT/vendor/litert-torch` | `49d68fcaa2b61af40dafcfb63ff010bb2247c20b` | `v0.9.1` |

`LiteRT/LITERT_LM_TAG` is the authoritative LiteRT-LM pin. Only LiteRT-LM is built from source
here; `libLiteRt` itself is the upstream prebuilt shipped inside LiteRT-LM's
`prebuilt/<platform>/`, pinned transitively by `LITERT_REF` in LiteRT-LM's `WORKSPACE`.

Redistributed binaries, by platform:

- **Win64** — `LiteRtLm.dll`/`.lib`, `libLiteRt.dll`/`.lib`/`.exp`,
  `libLiteRtWebGpuAccelerator.dll`, `libLiteRtTopKWebGpuSampler.dll`
- **Android** (`arm64-v8a`, `x86_64`) — `libLiteRtLm.so`, `libLiteRtGpuAccelerator.so`,
  `libLiteRtOpenClAccelerator.so`, `libLiteRtWebGpuAccelerator.so`,
  `libLiteRtTopKOpenClSampler.so`, `libLiteRtTopKWebGpuSampler.so`
- **Mac** (arm64) — `libLiteRtLm.dylib`, `libLiteRt.dylib`, `libLiteRtMetalAccelerator.dylib`,
  `libLiteRtWebGpuAccelerator.dylib`, `libLiteRtTopKMetalSampler.dylib`,
  `libLiteRtTopKWebGpuSampler.dylib`
- **iOS** (`arm64`, `sim_arm64`) — `LiteRtLm.framework` (+ `.framework.zip`)

Apache-2.0 §4 obliges you to retain the license, state changes, keep attribution notices, and
pass along any upstream `NOTICE` file. Upstream ships no `NOTICE` file at these pins, so this
document serves that role. The build scripts under `LiteRT/scripts/` are the complete record of
how the binaries were produced, including every Bazel flag.

**Modifications by Inoland.** The vendored sources are unmodified upstream checkouts. The only
addition is the Bazel overlay at `LiteRT/overlay/ino/` (`BUILD.bazel` +
`LiteRtLm_exports.cc`), which defines the exported C symbol surface; it is Inoland-authored and
Apache-2.0.

---

## 2. Gemma model constraint provider

`libGemmaModelConstraintProvider.{dll,so,dylib}` and
`GemmaModelConstraintProvider.framework` ship on every platform. The library code is part of the
Apache-2.0 LiteRT-LM distribution.

**Gemma model weights are not in this repository.** They are downloaded at runtime by the
consuming plugin and remain subject to Google's
[Gemma Terms of Use](https://ai.google.dev/gemma/terms), which carry use restrictions that
Apache-2.0 does not. If you ship Gemma weights, read those terms.

---

## 3. Microsoft DirectX Shader Compiler (Win64 only)

Two DLLs are staged on Win64, taken from Microsoft's official
[DirectXShaderCompiler](https://github.com/microsoft/DirectXShaderCompiler) release
**v1.9.2602** (`dxc_2026_02_20.zip`, SHA-256
`a1e89031421cf3c1fca6627766ab3020ca4f962ac7e2caa7fab2b33a8436151e`) — the exact version upstream
LiteRT-LM pins in its `WORKSPACE`.

They are needed only when LiteRT-LM runs with `backend=gpu`: Dawn calls
`LoadLibraryA("dxcompiler.dll")` / `("dxil.dll")` during D3D12 device init to translate
WGSL → HLSL → DXIL. On CPU they are inert. The editor happens to work without them because UE
preloads its own ShaderConductor copy; packaged builds do not get that ride-along.

> **These two files do not share a license, and neither is Apache-2.0.**

**`dxcompiler.dll`** is built from the DirectXShaderCompiler open-source tree — an LLVM 3.7 fork
under the **University of Illinois/NCSA Open Source License** (see `LICENSE.TXT` upstream). An
earlier revision of `InoLiteRT.tps` described both DLLs as MIT; that was wrong.

**`dxil.dll`** is **not** built from the open-source tree. It is Microsoft's DXIL signing
library, shipped only as a signed binary in Microsoft's releases, under Microsoft's own
redistribution terms rather than an OSI license. Treat it as proprietary third-party
redistribution.

> **⚠️ Verify before you ship.** If you redistribute a packaged build containing `dxil.dll`,
> confirm the redistribution terms attached to the DXC release you are shipping. If that is not
> acceptable for your distribution, the options are: run LiteRT-LM on CPU (these DLLs are then
> unused and can be dropped from staging), or resolve DXC from the end user's existing
> environment instead of bundling it.

Note this is **not** UE's bundled ShaderConductor copy. That was the earlier approach and was
abandoned deliberately: UE 5.7's fork produced correct GPU output in editor PIE but runaway
non-terminating output in packaged Shipping builds. See `LiteRT/scripts/build-win64.ps1` for the
full reasoning.

---

## 4. NeuTTS / NeuCodec — Neuphonic Limited

**Upstream:** [neutts](https://github.com/neuphonic/neutts) ·
[neucodec](https://github.com/neuphonic/neucodec)
**License:** NeuTTS Open License v1.0 — see `COPYING`/`LICENSE` in the `Convert/NeuTTS/vendor/neutts`
submodule.

Both are **submodules**, used by the conversion scripts under `Convert/` to produce `.litertlm`
and `.tflite` bundles. Cloning this repository does not copy them.

**One derived file is redistributed, though:** `Convert/NeuTTS/voices/jo.pt` is encoded from
Neuphonic's `jo` reference voice sample (`samples/jo.wav` + `samples/jo.txt` in the neutts
submodule) by `Convert/NeuTTS/scripts/encode_voice.py`. It is a derivative work of that sample.

> **⚠️ The NeuTTS Open License is not open source.** It permits redistribution, but conditions
> **all commercial use** on your legal entity earning **under $5,000,000 USD in annual revenue**,
> aggregated across entities under common control. Above that threshold you need a paid license
> from Neuphonic. The license also terminates automatically on any breach.
>
> This affects only the NeuTTS conversion path. **LiteRT-LM inference — the plugin's main
> purpose — is entirely unaffected.** If you do not use NeuTTS, delete `Convert/NeuTTS/`,
> `Convert/NeuCodec/`, and their submodule entries in `.gitmodules`, and nothing of value is
> lost.

Pins: `neutts` at `857bec0255f13ec726db5af76e5b97426183a724`, `neucodec` at
`ffcfd4eccadfa6b793318b20c322afc7278daccb`.

---

## Reporting a problem with these notices

If a component is misattributed or a notice is missing, please open an issue at
https://github.com/nobandegani/ino-lite-rt-ue/issues and it will be corrected.
