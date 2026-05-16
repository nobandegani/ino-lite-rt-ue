# InoLiteRT

Unreal Engine 5.7 runtime plugin that integrates Google's
[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) and
[LiteRT](https://github.com/google-ai-edge/LiteRT) on-device ML
runtimes and exposes them as a UE module for consumer plugins
(e.g. `InoAgents`) to link against.

Only **LiteRT-LM** is built from source via Bazel. **LiteRT itself is
not built here** — its `libLiteRt` shared library is the upstream
prebuilt shipped inside LiteRT-LM's `prebuilt/<platform>/`, and its
headers come from Bazel's external fetch. Both are pinned by the
`LITERT_REF` SHA in `LiteRT-LM/WORKSPACE`, so moving the LiteRT-LM
pin moves LiteRT with it.

Target platforms:

- **Windows x64** — `build-win64.ps1` (Windows host)
- **Android** `arm64-v8a` + `x86_64` — `build-android.ps1` (Windows host)
- **Mac arm64** (Apple Silicon) — `build-macos.sh` (macOS host)
- **iOS** `arm64` device + `sim_arm64` simulator — `build-ios.sh --arch …`
  (macOS host). Output is `.framework` bundles for App Store compliance.

Linux is scaffolded but not built. Mac x86_64 is unsupported (upstream
LiteRT-LM has no `macos_x86_64` prebuilts).

The plugin owns three submodules under `LiteRT/vendor/`:

- `LiteRT-LM/` — Bazel builds this. Pinned by `LiteRT/LITERT_LM_TAG`
  (authoritative); the submodule gitlink is `ignore = dirty` because
  the build mutates its working tree.
- `LiteRT/` — source-visibility mirror of LiteRT, kept on the
  `LITERT_REF` SHA from `LiteRT-LM/WORKSPACE`. **Not consumed by the
  build** — LiteRT ships as the prebuilt described above.
- `litert-torch/` — PyTorch → `.tflite` converter, dev-time tool only.

See [`CLAUDE.md`](./CLAUDE.md) for the build instructions, layout
diagram, pinning strategy, and the manual update procedure.
