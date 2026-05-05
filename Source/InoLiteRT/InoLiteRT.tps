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

    On Windows we additionally ship dxcompiler.dll and dxil.dll
    (Microsoft's DirectX Shader Compiler — https://github.com/microsoft/DirectXShaderCompiler,
    MIT license; copy taken from UE's bundled Engine/Binaries/ThirdParty/ShaderConductor/Win64/).
    Required at runtime by the Dawn-based WebGPU GPU accelerator to
    compile WGSL shaders to DXIL for D3D12. Inert when LiteRT runs on
    CPU.

    Ships as DLLs (Windows x64) and .so files (Android arm64-v8a and
    x86_64) alongside the plugin, exposed to UE consumers via the
    InoLiteRT module.
  </Function>
  <Eula>https://www.apache.org/licenses/LICENSE-2.0</Eula>
  <RedistributeTo>
    <EndUserGroup>Licensees</EndUserGroup>
    <EndUserGroup>P4</EndUserGroup>
    <EndUserGroup>Git</EndUserGroup>
  </RedistributeTo>
</TpsData>
