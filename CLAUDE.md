# CLAUDE.md — InoLiteRT plugin

This file provides guidance to Claude Code (claude.ai/code) when working
inside `Plugins/InoLiteRT/`. The hosting demo project is documented in
`E:/Projects/InoProject/CLAUDE.md`.

## Purpose

`InoLiteRT` is an Unreal Engine 5.7 runtime plugin whose job is to
**build Google's two on-device ML runtimes from source and expose them
as a UE module** that other plugins (currently `InoAgents`) declare as a
dependency:

- **LiteRT-LM** — Google's on-device LLM runtime (Gemma 4 inference,
  tool calling, streaming). Upstream:
  https://github.com/google-ai-edge/LiteRT-LM
- **LiteRT** — Google's underlying TFLite-based inference runtime.
  Upstream: https://github.com/google-ai-edge/LiteRT

LiteRT-LM is built from source via Bazel. LiteRT itself ships pre-built
by Google inside LiteRT-LM's `prebuilt/<platform>/` folder — we don't
compile LiteRT ourselves. The matching Windows import library
`libLiteRt.lib` is synthesized at build time from the DLL's export table
via MSVC's `lib.exe /def:` (faster than building LiteRT from source,
exposes all ~424 public symbols).

**LiteRT C API headers** (`litert/c/*.h`, `litert/c/internal/*.h`,
`litert/c/options/*.h`, `litert/build_common/config/*.h`) come from
Bazel's external-fetch of the LiteRT repo, pulled automatically when
Bazel builds `//ino:LiteRtLm`. The fetched copy lands at
`vendor/LiteRT-LM/bazel-litert-lm/external/litert/`, pinned by
`vendor/LiteRT-LM/WORKSPACE`'s `LITERT_REF`. That's what the build
scripts actually read from when staging headers, so the staged headers
always match the DLL Bazel built against.

In parallel, we also keep `vendor/LiteRT/` as a git submodule — a
manually-managed working tree of the LiteRT repo, pinned to the **same
SHA** as `LITERT_REF`. The submodule is for source visibility (IDE
browsing, debugging, inspecting the C API in context); the build
pipeline does NOT read from it. Bazel still uses its own external
fetch. Keeping the submodule and `LITERT_REF` in sync is a manual
discipline — see "Updating LiteRT-LM" below.

Artifacts are staged into `Source/ThirdParty/{Win64,Android/<arch>,Public}/`.
The single UE module (`InoLiteRT`) embeds all third-party wiring directly
— no separate "ThirdParty external module" subdirectory. Consumer plugins
(InoAgents, future ones) link against it via ordinary Build.cs
`PublicDependencyModuleNames` entries.

The plugin is target-platform-aware: **Windows (Win64)** and **Android
(arm64-v8a + x86_64)** ship today. iOS, Linux, and macOS are scaffolded
in `Source/InoLiteRT/Private/InoLiteRT.cpp` (gated `#if PLATFORM_WINDOWS
|| PLATFORM_ANDROID`) but no library has been built for them yet.

## Layout

```
Plugins/InoLiteRT/
├── InoLiteRT.uplugin                    ← UE plugin manifest (LoadingPhase=PreLoadingScreen)
│
├── LiteRT/                              ← Bazel build workspace
│   ├── LITERT_LM_TAG                    ← pinned LiteRT-LM commit SHA
│   ├── overlay/ino/                     ← files staged into the LiteRT-LM submodule before build
│   │   ├── BUILD.bazel                  ← //ino:LiteRtLm cc_binary target
│   │   └── LiteRtLm_exports.cc          ← DllMain stub + force-reference of every C API fn
│   ├── scripts/                         ← Build automation
│   │   ├── setup.ps1                    ← one-time preflight + overlay application
│   │   ├── build-win64.ps1              ← build + stage Win64 artifacts
│   │   ├── build-android.ps1            ← build + stage Android (-Arch arm64-v8a|x86_64)
│   │   └── clean.ps1                    ← wipe Bazel caches
│   └── vendor/
│       ├── LiteRT-LM/                   ← git submodule (Bazel builds this; pinned by LITERT_LM_TAG)
│       ├── LiteRT/                      ← git submodule (source visibility only; not what
│       │                                  Bazel reads — Bazel re-fetches its own copy into
│       │                                  LiteRT-LM/bazel-litert-lm/external/litert/ via
│       │                                  LiteRT-LM/WORKSPACE's LITERT_REF. Keep this
│       │                                  submodule's pointer in sync with LITERT_REF.)
│       └── litert-torch/                ← git submodule (PyTorch→.tflite converter, dev-time
│                                          tool only; not consumed at runtime. Pinned by
│                                          release-date proximity to our LiteRT SHA — see
│                                          "Pinning" below for the soft-compat rationale.)
│
└── Source/
    ├── InoLiteRT/                       ← The single UE module
    │   ├── InoLiteRT.Build.cs           ← embeds third-party wiring (libs, DLLs, UPL, includes)
    │   ├── InoLiteRT.tps                ← third-party software notification
    │   ├── InoLiteRT_UPL_Android.xml    ← APK packaging directives
    │   ├── Public/InoLiteRT.h           ← FInoLiteRTModule (DLL handle members)
    │   └── Private/InoLiteRT.cpp        ← StartupModule loads DLLs in dep order + smoke test
    │
    └── ThirdParty/                      ← staged build outputs (consumed by UE)
        ├── Public/litert/c/             ← 27 LiteRT C API headers (consumer-visible)
        ├── Public/litert/c/internal/    ← 15 LiteRT internal headers
        ├── Public/litert/c/options/     ← 11 LiteRT per-vendor option headers
        ├── Public/litert/lm/engine.h    ← LiteRT-LM C API header
        ├── Win64/                       ← 7 DLLs + 2 import libs
        │   ├── libLiteRt.{dll,lib}
        │   ├── LiteRtLm.{dll,lib}
        │   ├── libGemmaModelConstraintProvider.dll
        │   ├── libLiteRtWebGpuAccelerator.dll
        │   ├── libLiteRtTopKWebGpuSampler.dll
        │   ├── dxcompiler.dll           (DXC, copied from UE ShaderConductor)
        │   └── dxil.dll                 (DXIL signing, copied from UE ShaderConductor)
        └── Android/<arch>/              ← 7 .so files per arch (no separate libLiteRt.so)
            ├── libLiteRtLm.so           (Bazel-built ~52 MB monolithic)
            ├── libGemmaModelConstraintProvider.so
            ├── libLiteRtGpuAccelerator.so
            ├── libLiteRtOpenClAccelerator.so
            ├── libLiteRtTopKOpenClSampler.so
            ├── libLiteRtTopKWebGpuSampler.so
            └── libLiteRtWebGpuAccelerator.so
```

## How other plugins consume this

In a consumer plugin's `Build.cs`:

```csharp
PublicDependencyModuleNames.AddRange(new string[] {
    "InoLiteRT",   // exposes <litert/c/litert_*.h> + <litert/lm/engine.h>,
                   // links the import libs, declares delay-load DLLs, stages
                   // RuntimeDependencies for cook/package.
});
```

In its `.uplugin`:

```json
"Plugins": [
    { "Name": "InoLiteRT", "Enabled": true }
]
```

That's it — no Bazel knowledge, no DLL loading code in the consumer.
`FInoLiteRTModule::StartupModule` runs at `LoadingPhase=PreLoadingScreen`
which executes strictly before any consumer's `Default`-phase
`StartupModule`, so by the time consumer code runs, the DLLs/.so are
already mapped and callable. A `litert_lm_set_min_log_level(0)` smoke
test at startup confirms the link.

The first and currently only consumer is `Plugins/InoAgents/`.

## Target platforms

| Platform              | LiteRT-LM    | LiteRT                | Notes |
|---|---|---|---|
| **Windows x64**       | ✅ shipping   | ✅ shipping            | CPU + GPU via D3D12/WebGPU. 7 DLLs total (5 LiteRT-LM + dxcompiler.dll + dxil.dll for the Dawn shader compile path). |
| **Android arm64-v8a** | ✅ shipping   | ✅ statically linked   | CPU + GPU via WebGPU/OpenCL. 7 .so files. Monolithic libLiteRtLm.so. |
| **Android x86_64**    | ✅ shipping   | ✅ statically linked   | Same shape as arm64-v8a. For emulators / x86 Chromebooks. |
| iOS / Linux / macOS   | ⏳ stubs only | ⏳ stubs only          | No library built. Consumer InoAgents has stub C API impls in `InoLiteRtLmStubs_NonWindows.cpp`. |

Backend selection at runtime is via the `backend_str` parameter to
`litert_lm_engine_settings_create`: `"cpu"`, `"gpu"`, or `"npu"`. The
upstream enum (`runtime/executor/executor_settings_base.h`) also accepts
`"cpu_artisan"`, `"gpu_artisan"`, and `"google_tensor_artisan"` (legacy
hand-written paths) — InoLiteRT does not expose those via its UE-side
enum. NPU support exists in the upstream source for Android Qualcomm
Hexagon but is untested on this pin. There is no DirectML, Vulkan, or
Windows-NPU path.

The Windows GPU path (Dawn → D3D12) compiles WGSL → HLSL → DXIL at
runtime, so it requires `dxcompiler.dll` + `dxil.dll` in the process.
We stage UE's bundled copy from `Engine/Binaries/ThirdParty/ShaderConductor/Win64/`
into `Source/ThirdParty/Win64/` (build-win64.ps1's last staging step)
and pre-load by full path in `FInoLiteRTModule::StartupModule` so the
WebGPU prebuilt's filename-only `LoadLibraryA` resolves correctly in
packaged builds. Editor PIE incidentally satisfies this via UE's
CEF3/ShaderConductor preload; without our staging, packaged GPU
`engine_create` returned NULL with no useful error log.

GPU on Android is **untested** on the current pin; CPU works. Earlier
docs claimed GPU was broken because the prebuilt accelerator `.so` files
had a phantom `DT_NEEDED(libLiteRt.so)` — that's no longer true (verified:
their `DT_NEEDED` lists only contain system libs + EGL/GLESv3). Whether
GPU works end-to-end on a real device hasn't been verified.

## Pinning: commit SHA, not release tag

`LITERT_LM_TAG` holds a **40-character commit SHA**, not a release tag.
LiteRT-LM is pre-1.0; many fixes land between tags. Pinning to a SHA
lets us pick those up without waiting, while staying immutable and
bisectable.

The matching LiteRT version is pinned by `vendor/LiteRT-LM/WORKSPACE`'s
`LITERT_REF` — Bazel reads that value, downloads the LiteRT tarball,
and unpacks it into `bazel-litert-lm/external/litert/`. The same fetch
is the source for both the prebuilt DLLs (which ride along inside
LiteRT-LM's `prebuilt/` folder, also pinned to the WORKSPACE SHA) and
the headers we stage.

`vendor/LiteRT/` mirrors this SHA as a separate submodule pointer.
That submodule is NOT what Bazel builds against — Bazel always uses
its own external fetch. The submodule is purely a manually-curated
view for browsing; **its pointer must be re-pinned to the new
`LITERT_REF` whenever LiteRT-LM is updated**, or it will silently
diverge from what's actually shipped.

`vendor/litert-torch/` is a separate concern: it's the upstream
PyTorch→`.tflite` converter (https://github.com/google-ai-edge/litert-torch).
It's a Python-side dev tool, not consumed at runtime by UE — its
output is `.tflite` files we'd ship as game data. Compatibility with
our LiteRT pin is **soft, not SHA-locked**: upstream doesn't pin a
LiteRT commit anywhere (its `setup.py` just lists
`ai-edge-litert-nightly` with no version constraint), so the only
practical anchor is **release-date proximity**. We pin to the
litert-torch release whose tag date is closest to our LiteRT pin's
commit date. The current pin is **`v0.9.0`** (2026-04-23), 4 days
before our LiteRT SHA `47615eb6e` (2026-04-27). When LiteRT-LM is
bumped, re-evaluate whether a newer litert-torch release lines up
better — but a mismatch only manifests if a converter feature
introduced after our LiteRT pin's date is used, so this is "review
when convenient", not a hard sync.

## Build flow

The Bazel build is **outside** of UE's build pipeline. UE's normal build
just links against the artifacts staged into `Source/ThirdParty/`. If
those outputs aren't on disk yet, UE's link step fails with "library not
found" — the fix is "run the Bazel script".

### One-time setup (new dev machine)

1. Enable Developer Mode: Settings → System → For developers → Developer Mode → On
2. Install Visual Studio 2022 with the C++ workload
3. Install bazelisk: `winget install Bazel.Bazelisk`
4. Install Git for Windows (must be at `C:\Program Files\Git`)
5. Install Python 3 (any 3.10+)
6. Set `BAZEL_VC` user environment variable to `<VS install>\VC`, e.g.:
   ```
   C:\Program Files\Microsoft Visual Studio\2022\Community\VC
   ```
   (single backslashes — raw registry string, no escaping)
7. (Android only) Install Android **NDK r28.x** (e.g. r28.2) via Android
   Studio's SDK Manager → SDK Tools → NDK (Side by side) →
   "Show Package Details" → pick a 28.x version → Apply.
   We deliberately pin to r28.x — that's what upstream develops against.
   UE 5.7's NDK (r27.2) is too old for LiteRT-LM and coexists at
   `%LOCALAPPDATA%\Android\Sdk\ndk\` as a separate subdirectory.
8. Run `.\scripts\setup.ps1` to apply the overlay, verify the LiteRT-LM
   submodule, and create the three short Bazel output bases.

### Bazel output bases (Windows MAX_PATH workaround)

Windows MAX_PATH (260 chars) means we can't use long output base paths
— Bazel's intermediate filenames (especially Rust proc-macro `.rcgu.o`
files at ~220 chars) blow past the limit. Setup creates three short
ones, one per build configuration:

| Base               | Build                |
|---|---|
| `C:/b/ino-w-x64`   | Windows x86_64       |
| `C:/b/ino-a-a64`   | Android arm64-v8a    |
| `C:/b/ino-a-x64`   | Android x86_64       |

Naming: `ino-<platform>-<arch>` where platform is `w` (windows) or `a`
(android), and arch is `a64` (arm64-v8a) or `x64` (x86_64).

### Building (Windows)

```powershell
cd Plugins/InoLiteRT/LiteRT
.\scripts\build-win64.ps1
```

First cold build is ~30–60 minutes. Subsequent incremental builds are
seconds.

What it does:
1. Runs `setup.ps1` (preflight + overlay).
2. `bazelisk build //ino:LiteRtLm` against the LiteRT-LM submodule with
   `--define=litert_link_capi_so=true` so LiteRT core ends up in a
   separate `libLiteRt.dll` (matching the prebuilt's name). Bazel also
   fetches the LiteRT source tarball at this point (the SHA pinned by
   `WORKSPACE`'s `LITERT_REF`) and unpacks it under
   `vendor/LiteRT-LM/bazel-litert-lm/external/litert/`.
3. Copies the prebuilt `libLiteRt.dll` (from
   `vendor/LiteRT-LM/prebuilt/windows_x86_64/`) and synthesizes
   `libLiteRt.lib` from the DLL's export table directly via dumpbin +
   `lib.exe /def:`. We deliberately do NOT use upstream's
   `litert/c/windows_exported_symbols.def` for this — that file is a
   curated subset (~230 symbols) maintained for Google's internal
   binaries' link needs, not the full DLL surface (~424 symbols).
4. Stages the LiteRT C API headers from the Bazel-fetched tree
   (`vendor/LiteRT-LM/bazel-litert-lm/external/litert/litert/c/`) into
   `Source/ThirdParty/Public/litert/`, alongside `libLiteRt.dll`/`.lib`
   in `Source/ThirdParty/Win64/`. Same SHA the DLL was built against,
   guaranteed.

### Building (Android)

```powershell
cd Plugins/InoLiteRT/LiteRT
.\scripts\build-android.ps1                    # default: arm64-v8a (real devices)
.\scripts\build-android.ps1 -Arch x86_64       # emulators / x86 Chromebooks
```

Cross-compiled from the Windows host. Auto-detects the highest installed
NDK r28.x under `%LOCALAPPDATA%\Android\Sdk\ndk\` and points Bazel at it
for the build only — your environment is not modified.

What it does:
1. NDK r28.x preflight.
2. `setup.ps1`.
3. `bazelisk build //ino:LiteRtLm --config=android_<arch>`. Deliberately
   does NOT pass `--define=litert_link_capi_so=true` — upstream's
   `--dynamic_mode=off` on Android force-links LiteRT core directly
   into the monolithic `libLiteRtLm.so` (~52 MB), so no separate
   `libLiteRt.so` is produced.
4. Stages our `.so` plus the 6 prebuilt accelerator/constraint `.so`
   files into `Source/ThirdParty/Android/<arch>/`.

The Win64 build splits LiteRT core into a separate DLL via
`--define=litert_link_capi_so=true`. The Android build does NOT pass
that flag because upstream's `build:android` config sets
`--dynamic_mode=off` which force-statics everything into one monolithic
`libLiteRtLm.so`. There is no `libLiteRt.so` on Android.

### Updating LiteRT-LM (and LiteRT along with it)

The update flow is **manual** — there is no `update-litert.ps1` wrapper.
LiteRT pins along with LiteRT-LM (LiteRT-LM's `WORKSPACE` has a
`LITERT_REF` value that names the LiteRT commit Bazel will fetch and
build against), so bumping LiteRT-LM bumps the LiteRT version in the
same step. There are **two** SHAs you must touch each time:

- The `LiteRT-LM` submodule pointer (and `LITERT_LM_TAG` mirroring it).
- The `LiteRT` submodule pointer, re-pinned to whatever `LITERT_REF`
  now reads as inside the newly-checked-out LiteRT-LM tree. Bazel will
  fetch its own copy at `LITERT_REF` regardless, but the submodule is
  what your IDE / source browser sees, so it must agree.

```powershell
# 1. Move the LiteRT-LM submodule HEAD to the new ref. Works for tags,
#    SHAs, branches.
cd Plugins\InoLiteRT\LiteRT\vendor\LiteRT-LM
git fetch --tags origin
git checkout v0.11.0-rc.1                  # or a SHA, or 'main'
$sha = git rev-parse HEAD                  # 40-char commit SHA

# 2. Write the resolved SHA into LITERT_LM_TAG (in the LiteRT/ workspace).
cd ..\..
Set-Content LITERT_LM_TAG $sha

# 3. Sync the LiteRT submodule to the new LITERT_REF. LiteRT-LM's
#    WORKSPACE pins the LiteRT commit Bazel will fetch — we mirror
#    that same SHA in our LiteRT submodule pointer for source
#    visibility. They MUST agree, or your IDE will browse a different
#    LiteRT than what Bazel actually builds against.
$litertRef = (Select-String -Path vendor\LiteRT-LM\WORKSPACE `
    -Pattern '^LITERT_REF\s*=\s*"([0-9a-f]+)"').Matches.Groups[1].Value
git -C vendor\LiteRT fetch origin
git -C vendor\LiteRT checkout $litertRef

# 4. Re-check the overlay's force-keep array. Re-extract the upstream
#    LITERT_LM_C_API_EXPORT list with the awk one-liner in
#    overlay/ino/LiteRtLm_exports.cc's MAINTENANCE comment, diff against
#    the existing array, and add any new entries. A missing entry
#    silently drops that symbol from the DLL — the build succeeds, but
#    callers fail at runtime.

# 5. Rebuild every platform we ship. Don't skip any — Win64 binaries
#    from the new SHA + Android binaries from the old SHA usually
#    crashes on launch with opaque dynamic-linker errors.
.\scripts\build-win64.ps1
.\scripts\build-android.ps1                # arm64-v8a (default)
.\scripts\build-android.ps1 -Arch x86_64   # if you ship x86_64

# 6. Test in UE: launch the editor / package an Android build and
#    confirm FInoLiteRTModule's startup smoke test
#    (litert_lm_set_min_log_level) passes.

# 7. Only after all that — commit the submodule pointers
#    (vendor/LiteRT-LM, vendor/LiteRT, plus vendor/litert-torch if you
#    bumped it in step 7a below) + LITERT_LM_TAG + any overlay changes
#    in the InoLiteRT plugin repo, in one cohesive commit so the SHAs
#    always advance together.
```

**7a. (Optional, soft-compat) Re-evaluate litert-torch.** litert-torch
isn't SHA-locked to LiteRT, but if our LiteRT pin moved by more than
a few weeks, check whether a newer litert-torch release is now a
closer date match (its compatibility surface is the `.tflite` format,
which is generally forward-compatible within LiteRT 2.x). To bump:

```powershell
git -C vendor\litert-torch fetch --tags origin
git -C vendor\litert-torch checkout v0.X.Y     # whichever tag is closest in date
```

Skip this step if our LiteRT pin barely moved or no newer
litert-torch tag has shipped since the current one.

### Cleaning

```powershell
.\scripts\clean.ps1
```

Runs `bazelisk clean --expunge` for each output base that exists
(Win64, Android arm64-v8a, Android x86_64). Skips bases that don't
exist on disk. Disk caches (the content-addressed kind, separate
from output bases) are intentionally NOT wiped — they survive across
expunges and speed up cold rebuilds.

## Bazel target

The build produces `//ino:LiteRtLm` — a `cc_binary(linkshared=1)`
depending on `//c:engine` (the full CPU + GPU target, not the smaller
`//c:engine_cpu`). On Windows the GPU path is WebGPU → D3D12 via
upstream's prebuilt `libLiteRtWebGpuAccelerator.dll`; on Android it's
WebGPU **and** OpenCL prebuilts so the engine can pick whichever the
device supports.

## Do not edit files inside `vendor/`

Both submodules are upstream code. Our own customizations live in
`overlay/` and are copied into `vendor/LiteRT-LM/` at setup time.
`setup.ps1` updates the submodule's `.git/info/exclude` so the overlay
files don't show as dirty in the submodule's working tree.

When upgrading LiteRT-LM, two things may need attention in the overlay:

- **`overlay/ino/BUILD.bazel`** — verify `//c:engine` is still the right
  target. Upstream renames packages occasionally.
- **`overlay/ino/LiteRtLm_exports.cc`** — the force-reference array
  must list every `LITERT_LM_C_API_EXPORT`-marked function in the new
  `c/engine.h`. Re-extract via the awk one-liner in the file's own
  comment block. A missing entry results in that symbol silently
  dropping from the DLL — the build succeeds, callers fail at runtime.

## Authoritative references

- Upstream LiteRT-LM: https://github.com/google-ai-edge/LiteRT-LM
- Upstream LiteRT: https://github.com/google-ai-edge/LiteRT
- LiteRT-LM C API header (canonical, in submodule):
  `LiteRT/vendor/LiteRT-LM/c/engine.h`
- LiteRT-LM C API header (staged copy consumers `#include`):
  `Source/ThirdParty/Public/litert/lm/engine.h`
- LiteRT C API headers: `Source/ThirdParty/Public/litert/c/litert_*.h`
- Pinned LiteRT-LM commit: see `LiteRT/LITERT_LM_TAG` (mirrors the
  `LiteRT/vendor/LiteRT-LM` submodule pointer).
- Pinned LiteRT commit: see `LiteRT/vendor/LiteRT-LM/WORKSPACE`'s
  `LITERT_REF`. The same SHA is mirrored as the `LiteRT/vendor/LiteRT`
  submodule pointer (kept in sync manually — Bazel only reads
  `LITERT_REF`, the submodule is for source visibility).
- Pinned litert-torch tag: see `LiteRT/vendor/litert-torch` submodule
  pointer. Soft-pinned by release-date proximity to the LiteRT SHA,
  not a strict ABI match — see "Pinning" above for the rationale.
- Upstream litert-torch: https://github.com/google-ai-edge/litert-torch
