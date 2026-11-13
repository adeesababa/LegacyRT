#!/usr/bin/env bash
# Compiles the trace passes in this folder to SPIR-V for the helper (GL_EXT_ray_query needs SPIR-V 1.4+: Vulkan 1.2).
# Needs glslangValidator and spirv-val (Vulkan SDK). Usage: shaders/compile.sh   (writes <name>.spv next to each source)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
n=0
for f in *.comp; do
  b="${f%.*}"
  glslangValidator -V --target-env vulkan1.2 -I. -o "$b.spv" "$f"
  spirv-val --target-env vulkan1.2 "$b.spv"
  n=$((n+1))
done
# Passes built from another pass's source with a define (each source's header names its variants)
while read -r out src defs; do
  # shellcheck disable=SC2086
  glslangValidator -V --target-env vulkan1.2 -I. $defs -o "$out.spv" "$src.comp"
  spirv-val --target-env vulkan1.2 "$out.spv"
  n=$((n+1))
done <<'RT_VARIANTS'
RtGITrace RtAOTrace -DRT_GI_PASS
RtRadianceCache RtAOTrace -DRT_CACHE_PASS
RtLampTraceSplit RtLampTrace -DSPLIT
RtLampTraceExterior RtLampTrace -DEXTERIOR
RtLampTraceSigma RtLampTrace -DSIGMA
RtPathTraceGrid RtPathTrace -DPT_LIGHT_GRID
RtPathTraceGI RtPathTrace -DPT_RESTIR_GI
RtShadowDenoisePackSun RtShadowDenoisePack -DSUN
RtShadowDenoisePackLamps RtShadowDenoisePack -DLAMPS
RtShadowDenoiseTemporalSun RtShadowDenoiseTemporal -DSUN
RtShadowDenoiseTemporalLamps RtShadowDenoiseTemporal -DLAMPS
RtShadowDenoiseFfxPrepareSun RtShadowDenoiseFfxPrepare -DSUN
RtShadowDenoiseFfxPrepareLamps RtShadowDenoiseFfxPrepare -DLAMPS
RtShadowDenoisePostBlur RtShadowDenoiseBlur -DPOST
RT_VARIANTS
# The FidelityFX shadow denoiser port (RtShadowDenoiseFfx.hlsl, an optional test core) is HLSL: it needs dxc (Vulkan SDK).
if command -v dxc >/dev/null 2>&1; then
  dxc -spirv -fspv-target-env=vulkan1.2 -T cs_6_2 -E main -D STAGE_TILE -Fo RtShadowDenoiseFfxTile.spv RtShadowDenoiseFfx.hlsl
  for p in 0 1 2; do
    dxc -spirv -fspv-target-env=vulkan1.2 -T cs_6_2 -E main -D STAGE_FILTER -D PASS=$p -Fo RtShadowDenoiseFfxFilter$p.spv RtShadowDenoiseFfx.hlsl
  done
  n=$((n+4))
else
  echo "dxc not found: the four RtShadowDenoiseFfx* passes were not built (only the DenoiserCore 1 test path needs them)"
fi
echo "compiled $n passes"
