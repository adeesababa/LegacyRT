#!/usr/bin/env bash
# Compiles the trace passes in this folder to SPIR-V for the helper (GL_EXT_ray_query needs SPIR-V 1.4+: Vulkan 1.2).
# Needs glslangValidator and spirv-val (Vulkan SDK). Usage: shaders/compile.sh   (writes <name>.spv next to each source)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
n=0
for f in *.comp; do
  b="${f%.*}"
  glslangValidator -V --target-env vulkan1.2 -o "$b.spv" "$f"
  spirv-val --target-env vulkan1.2 "$b.spv"
  n=$((n+1))
done
# Passes built from another pass's source with a define (each source's header names its variants)
while read -r out src defs; do
  # shellcheck disable=SC2086
  glslangValidator -V --target-env vulkan1.2 $defs -o "$out.spv" "$src.comp"
  spirv-val --target-env vulkan1.2 "$out.spv"
  n=$((n+1))
done <<'RT_VARIANTS'
RtGITrace RtAOTrace -DRT_GI_PASS
RtRadianceCache RtAOTrace -DRT_CACHE_PASS
RtLampTraceSplit RtLampTrace -DSPLIT
RtLampTraceExterior RtLampTrace -DEXTERIOR
RtPathTraceGrid RtPathTrace -DPT_LIGHT_GRID
RtPathTraceGI RtPathTrace -DPT_RESTIR_GI
RT_VARIANTS
echo "compiled $n passes"
