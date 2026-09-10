<?xml version="1.0" encoding="utf-8"?>
<TpsData xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Name>LiteRT and LiteRT-LM</Name>
  <Location>
    Plugins/InoLiteRT/Source/ThirdParty/Win64/                  (Windows x64 DLLs + import libs)
    Plugins/InoLiteRT/Source/ThirdParty/Android/arm64-v8a/      (Android arm64-v8a .so files)
    Plugins/InoLiteRT/Source/ThirdParty/Android/x86_64/         (Android x86_64 .so files, when built)
    Plugins/InoLiteRT/Source/ThirdParty/Public/                 (C API headers, shared across all platforms)
  </Location>
  <Function>
    On-device ML inference runtimes from Google AI Edge:

    - LiteRT (https://github.com/google-ai-edge/LiteRT): TFLite-based
      inference runtime for arbitrary TFLite models. Provides the
      LiteRt* C API and the legacy TfLite* interpreter API.

    - LiteRT-LM (https://github.com/google-ai-edge/LiteRT-LM): on-device
      LLM runtime layered on top of LiteRT. Used for Gemma 4 inference,
      tool-calling, and streaming generation via the litert_lm_* C API.

    On Windows we additionally ship dxcompiler.dll and dxil.dll from
    Microsoft's DirectX Shader Compiler
    (https://github.com/microsoft/DirectXShaderCompiler), taken from the
    official GitHub release v1.9.2602 (dxc_2026_02_20.zip) — the exact
    version upstream LiteRT-LM pins in its WORKSPACE. NOT UE's bundled
    ShaderConductor copy; see LiteRT/scripts/build-win64.ps1 for why that
    was abandoned. Required at runtime by the Dawn-based WebGPU GPU
    accelerator to compile WGSL shaders to DXIL for D3D12. Inert when
    LiteRT runs on CPU.

    These two DLLs do NOT share one license:

    - dxcompiler.dll is built from the DirectXShaderCompiler open-source
      tree, which is an LLVM 3.7 fork under the University of
      Illinois/NCSA Open Source License (see LICENSE.TXT in that repo).
      It is not MIT, as an earlier revision of this file stated.

    - dxil.dll is a Microsoft-signed binary that is NOT built from the
      open-source tree. It is the DXIL signing library, shipped only in
      Microsoft's binary releases under Microsoft's own redistribution
      terms. Treat it as proprietary third-party redistribution and
      confirm the current terms attached to the release before shipping.

    Ships as DLLs (Windows x64) and .so files (Android arm64-v8a and
    x86_64) alongside the plugin, exposed to UE consumers via the
    InoLiteRT module.
  </Function>
  <!-- LiteRT and LiteRT-LM are Apache-2.0. The two DXC DLLs staged on
       Win64 are not covered by that grant — dxcompiler.dll is
       University of Illinois/NCSA and dxil.dll is Microsoft
       proprietary. See the Function notes above and the repository's
       THIRD_PARTY_NOTICES.md for the per-file breakdown. -->
  <Eula>https://www.apache.org/licenses/LICENSE-2.0</Eula>
  <RedistributeTo>
    <EndUserGroup>Licensees</EndUserGroup>
    <EndUserGroup>P4</EndUserGroup>
    <EndUserGroup>Git</EndUserGroup>
  </RedistributeTo>
</TpsData>
