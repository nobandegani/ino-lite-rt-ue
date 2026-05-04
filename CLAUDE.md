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
`litert/build_common/config/*.h`) come from Bazel's external-fetch of
the LiteRT repo, pulled automatically when Bazel builds
`//ino:LiteRtLm`. The fetched copy lands at
`vendor/LiteRT-LM/bazel-litert-lm/external/litert/`, pinned by
`vendor/LiteRT-LM/WORKSPACE`'s `LITERT_REF`. We do not maintain a
separate `vendor/LiteRT` submodule — `WORKSPACE` is the single source
of truth for both the runtime DLL and the headers, so the two can
never drift out of sync.

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
│       └── LiteRT-LM/                   ← git submodule (Bazel builds this; LiteRT
│                                          itself is fetched into Bazel's external/
│                                          tree via WORKSPACE's LITERT_REF, no
│                                          separate submodule needed)
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
        ├── Win64/                       ← 5 DLLs + 2 import libs
        │   ├── libLiteRt.{dll,lib}
        │   ├── LiteRtLm.{dll,lib}
        │   ├── libGemmaModelConstraintProvider.dll
        │   ├── libLiteRtWebGpuAccelerator.dll
        │   └── libLiteRtTopKWebGpuSampler.dll
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
| **Windows x64**       | ✅ shipping   | ✅ shipping            | CPU + GPU via D3D12/WebGPU. 5 DLLs total. |
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
the headers we stage. Single SHA, single source of truth; no manual
sync step.

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

```powershell
# Pin to a release tag:
.\scripts\update-litert.ps1 v0.11.0

# Pin to an explicit commit SHA:
.\scripts\update-litert.ps1 4dbbf9375f52ad9738b80c9c1a12d671a0f5ffb6

# Pin to whatever's currently on main:
.\scripts\update-litert.ps1 main
```

The script:
1. `git fetch --tags origin` inside the LiteRT-LM submodule
2. `git checkout <Ref>` — works for tags, SHAs, branches
3. Resolves to a 40-char SHA via `git rev-parse HEAD`
4. Writes the resolved SHA into `LITERT_LM_TAG`
5. Re-runs `build-win64.ps1`

**Manual steps required after:**

1. **Rebuild Android too.** `update-litert.ps1` only re-runs the Win64
   build. For Android, run the Android script(s) separately:
   ```powershell
   .\scripts\build-android.ps1                    # arm64-v8a
   .\scripts\build-android.ps1 -Arch x86_64       # if you ship x86_64
   ```
   Forgetting this means Win64 binaries from the new SHA + Android
   binaries from the old SHA, which usually crashes on launch with
   opaque dynamic-linker errors.

Commit the submodule pointer + `LITERT_LM_TAG` only after all
relevant platform builds succeed and UE actually loads the resulting
DLLs/.so.

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
- Pinned LiteRT-LM commit: see `LiteRT/LITERT_LM_TAG`
- Pinned LiteRT commit: see `LiteRT/vendor/LiteRT-LM/WORKSPACE`'s
  `LITERT_REF` (Bazel reads it; we don't keep a separate file or
  submodule for the LiteRT pin)
