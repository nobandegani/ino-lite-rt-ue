# LiteRT build workspace

This directory is the build workspace for the `ino_lite_rt_ue` plugin's
two on-device ML runtimes:

- **LiteRT-LM** — Google's on-device LLM runtime (Gemma 4, tool calling,
  streaming). Built from source via Bazel, produces `LiteRtLm.dll` /
  `libLiteRtLm.so`.
- **LiteRT** — Google's underlying TFLite-based inference runtime. The
  compiled `libLiteRt.dll` is shipped pre-built by Google inside the
  LiteRT-LM submodule (so we don't compile it ourselves), but its source
  is also vendored here as a submodule for header staging.

The Bazel build is deliberately **outside** of UE's build pipeline. It
runs once per dev machine per upstream version bump; UE just links
against the artifacts it stages into `Source/ThirdParty/LiteRTLM/` and
`Binaries/ThirdParty/LiteRTLM/`.

## Layout

```
LiteRT/
├── LITERT_TAG              Plain-text pinned LiteRT commit SHA
├── LITERT_LM_TAG           Plain-text pinned LiteRT-LM commit SHA
├── README.md               This file
│
├── overlay/                Files staged into the LiteRT-LM submodule before each build
│   └── ino/
│       ├── BUILD.bazel     Defines //ino:LiteRtLm target (cc_binary, linkshared=1)
│       └── LiteRtLm_exports.cc   DllMain stub + force-reference of every
│                                 litert_lm_* C API function (so MSVC's
│                                 linker pulls their .obj files out of
│                                 //c:engine's static archive).
│
├── scripts/                LiteRT-LM build automation
│   ├── setup.ps1                 One-time preflight + overlay application
│   ├── build-win64.ps1           Build + stage Win64 LiteRT-LM artifacts
│   ├── build-android-arm64.ps1   Cross-compile + stage Android LiteRT-LM artifacts
│   ├── update-litert.ps1         Bump LiteRT-LM submodule + rebuild
│   └── clean.ps1                 Wipe Bazel cache for this workspace
│
└── vendor/
    ├── LiteRT/             Git submodule → google-ai-edge/LiteRT
    │                       Pinned to the same commit as
    │                       LiteRT-LM's WORKSPACE LITERT_REF.
    │                       Used for staging LiteRT C API headers.
    └── LiteRT-LM/          Git submodule → google-ai-edge/LiteRT-LM
                            Pinned to LITERT_LM_TAG. Bazel builds this.
```

**Note:** there are currently no standalone LiteRT build scripts. The
`libLiteRt.dll` we ship is the pre-built one shipped inside LiteRT-LM's
submodule (`vendor/LiteRT-LM/prebuilt/<platform>/`). The LiteRT source
submodule exists primarily so we can stage the LiteRT public C API
headers (`litert/c/litert_*.h`) into `Source/ThirdParty/LiteRT/Public/`
for UE consumers.

## Pinning: commit SHA, not release tag

Both `LITERT_TAG` and `LITERT_LM_TAG` hold **40-character commit SHAs**,
not release tags. LiteRT-LM is pre-1.0; many fixes land between tags.
Pinning to SHAs lets us pick those up without waiting, while staying
immutable and bisectable.

`LITERT_TAG` must always match the `LITERT_REF` value in
`vendor/LiteRT-LM/WORKSPACE`. When you bump LiteRT-LM, also bump LiteRT
to whatever LITERT_REF the new LiteRT-LM commit pins. They move
together.

## One-time setup (new dev machine)

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
7. (Android only) Install Android NDK r28b or newer via Android Studio's
   SDK Manager. UE 5.7's NDK (r27.2) is too old for LiteRT-LM's Bazel
   config; the two NDKs coexist under `%LOCALAPPDATA%\Android\Sdk\ndk\`.
8. Run `.\scripts\setup.ps1` to apply the overlay and verify the LiteRT-LM submodule.

## Building LiteRT-LM (Windows)

```powershell
cd Plugins/ino_lite_rt_ue/LiteRT
.\scripts\build-win64.ps1
```

First cold build is ~30–60 minutes. Subsequent incremental builds are seconds.

Outputs are staged directly into the plugin:

- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Win64/LiteRtLm.dll`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Win64/libLiteRt.dll`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Win64/libGemmaModelConstraintProvider.dll`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Win64/libLiteRtWebGpuAccelerator.dll`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Win64/libLiteRtTopKWebGpuSampler.dll`
- `Plugins/ino_lite_rt_ue/Source/ThirdParty/LiteRTLM/Win64/LiteRtLm.lib`
- `Plugins/ino_lite_rt_ue/Source/ThirdParty/LiteRTLM/Public/litert/lm/engine.h`

## Building LiteRT-LM (Android arm64-v8a)

```powershell
cd Plugins/ino_lite_rt_ue/LiteRT
.\scripts\build-android-arm64.ps1
```

Cross-compiled from the Windows host. Auto-detects the newest NDK r28+
under `%LOCALAPPDATA%\Android\Sdk\ndk\` and points Bazel at it for the
build only — your environment is not modified.

Outputs:

- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Android/arm64-v8a/libLiteRtLm.so`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Android/arm64-v8a/libGemmaModelConstraintProvider.so`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Android/arm64-v8a/libLiteRtGpuAccelerator.so`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Android/arm64-v8a/libLiteRtOpenClAccelerator.so`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Android/arm64-v8a/libLiteRtTopKOpenClSampler.so`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Android/arm64-v8a/libLiteRtTopKWebGpuSampler.so`
- `Plugins/ino_lite_rt_ue/Binaries/ThirdParty/LiteRTLM/Android/arm64-v8a/libLiteRtWebGpuAccelerator.so`
- `Plugins/ino_lite_rt_ue/Source/ThirdParty/LiteRTLM/Public/litert/lm/engine.h`
  (same header, shared across platforms)

The Win64 build uses `--define=litert_link_capi_so=true` to split
LiteRT core into a separate `libLiteRt.dll`. The Android build does
NOT pass that flag because upstream's `build:android` config sets
`--dynamic_mode=off` which force-statics everything into one
monolithic `libLiteRtLm.so`. There is no `libLiteRt.so` on Android.

## Updating LiteRT-LM (and LiteRT along with it)

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

**Manual step required after:** the script does not yet bump the LiteRT
submodule. Open `vendor/LiteRT-LM/WORKSPACE`, find the new
`LITERT_REF`, then:

```powershell
git -C vendor/LiteRT checkout <new LITERT_REF>
Set-Content LITERT_TAG "<new LITERT_REF>`n" -NoNewline:$false
```

Otherwise LiteRT's vendored source headers will drift from the LiteRT
binary actually shipped by LiteRT-LM, and consumer code may compile
against newer/older API surfaces than the DLL implements.

**Caveat:** `update-litert.ps1` only rebuilds Win64. Android is a
separate invocation — run `build-android-arm64.ps1` to refresh those
binaries. Forgetting this means Win64 binaries from the new SHA +
Android binaries from the old SHA, which usually crashes on launch
with opaque dynamic-linker errors.

Commit the submodule pointers + both `LITERT_TAG` files only after
both platform builds succeed and UE actually loads the resulting
DLLs/.so.

## Current target

The build produces `//ino:LiteRtLm` — a `cc_binary(linkshared=1)`
depending on `//c:engine` (the full CPU + GPU target, not the smaller
`//c:engine_cpu`). On Windows the GPU path is WebGPU → D3D12 via
upstream's prebuilt `libLiteRtWebGpuAccelerator.dll`; on Android it's
WebGPU **and** OpenCL prebuilts so the engine can pick whichever the
device supports.

Backend selection at runtime is via the `backend_str` parameter to
`litert_lm_engine_settings_create`: `"cpu"` or `"gpu"`. There is no
DirectML, Vulkan, or Windows-NPU path — those are not shipped by
upstream for Windows. NPU on Android (Qualcomm QNN / MediaTek) exists
in the upstream source but is not currently wired through this build.

## Do not edit files inside `vendor/`

Both submodules are upstream code. Our own customizations live in
`overlay/` and are copied into `vendor/LiteRT-LM/` at setup time.
`setup.ps1` updates the submodule's `.git/info/exclude` so the overlay
files don't show as dirty in the submodule's working tree.

When upgrading LiteRT-LM, two things may need attention in the
overlay:

- **`overlay/ino/BUILD.bazel`** — verify `//c:engine` is still the
  right target. Upstream renames packages occasionally.
- **`overlay/ino/LiteRtLm_exports.cc`** — the force-reference array
  must list every `LITERT_LM_C_API_EXPORT`-marked function in the new
  `c/engine.h`. Re-extract via the awk one-liner in the file's own
  comment block. A missing entry results in that symbol silently
  dropping from the DLL — the build succeeds, callers fail at runtime.
