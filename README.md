# InoLiteRT

Unreal Engine 5.7 runtime plugin that builds Google's
[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) and
[LiteRT](https://github.com/google-ai-edge/LiteRT) on-device ML
runtimes from source via Bazel and exposes them as a UE module for
consumer plugins (e.g. `InoAgents`) to link against.

Target platforms: **Windows x64** and **Android** (`arm64-v8a`,
`x86_64`). iOS / Linux / macOS are scaffolded but not built.

The plugin owns three submodules under `LiteRT/vendor/`:

- `LiteRT-LM/` — Bazel builds this; pinned by `LiteRT/LITERT_LM_TAG`.
- `LiteRT/` — source-visibility mirror of LiteRT, kept in sync with
  the `LITERT_REF` SHA inside `LiteRT-LM/WORKSPACE`.
- `litert-torch/` — PyTorch → `.tflite` converter, dev-time tool only.

See [`CLAUDE.md`](./CLAUDE.md) for the build instructions, layout
diagram, pinning strategy, and the manual update procedure.
