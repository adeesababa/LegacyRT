# LegacyRT

**Hardware ray tracing for old 32-bit Direct3D 9 games**, added beside the game's own renderer instead of replacing it.

> Early and experimental. It runs today inside one game ([Vegas Shaders](https://github.com/adeesababa/VegasShaders) for
> Fallout: New Vegas), where it drives ray-traced sun and lamp shadows, ambient occlusion, global illumination, reflections and
> an optional path tracer. This repository is the game-independent part, split out so it can be reused. Expect rough edges.

## The problem it solves

Windows' 32-bit Vulkan drivers expose no ray tracing: a 32-bit process does not see `VK_KHR_acceleration_structure` or
`VK_KHR_ray_query`, even on an RTX card (checked on AMD and NVIDIA drivers in 2026). Most Direct3D 9 games are 32-bit.

LegacyRT gets around that with three parts:

```
 32-bit game process                                        64-bit helper process (same GPU)
 ┌───────────────────────────────────────────┐              ┌──────────────────────────────────────────┐
 │ the game, drawing as usual (Direct3D 9)   │              │ helper/NvrRtHelper.exe                   │
 │   │                                       │              │   its own Vulkan device with ray queries │
 │ patched DXVK d3d9.dll (dxvk/patches)      │  shared GPU  │   imports the shared images + semaphores │
 │   - Direct3D 9 -> Vulkan (DXVK)           │  images +    │   builds BLAS/TLAS from staged geometry  │
 │   - stages geometry into a shared arena   │  timeline    │   runs the trace passes (shaders/)       │
 │   - exports images + timeline semaphores  │  semaphores  │   writes results into shared images      │
 │   │                                       │ <──────────> │                                          │
 │ a game plugin ("feeder", per game)        │  shared      │                                          │
 │   - camera, objects, lights, materials,   │  memory      │                                          │
 │     G-buffer; registers passes; composes  │  (protocol)  │                                          │
 │     the traced results into its frame     │              │                                          │
 └───────────────────────────────────────────┘              └──────────────────────────────────────────┘
```

- **No CPU waits per frame.** The game posts a frame record into a ring in shared memory and signals a timeline semaphore; the
  helper's GPU work waits for it on the GPU and signals back. The game only waits (briefly, with a timeout) before reusing a
  ring slot the helper has not read yet.
- **Hybrid by design.** The game keeps rasterising its frame; ray tracing adds what the raster lacks. A full path tracer is
  there too, for comparison or for players with fast RTX cards.

## How it differs from RTX Remix

[RTX Remix](https://github.com/NVIDIAGameWorks/rtx-remix) and LegacyRT both bring ray tracing to old Direct3D 9 games, from
opposite directions:

| | RTX Remix | LegacyRT |
|---|---|---|
| **Approach** | Replaces the game's renderer: captures the draw calls and path-traces the whole frame itself | **Hybrid**: the game keeps rendering its own frame; ray tracing adds shadows, AO, GI and reflections (a full path tracer is optional) |
| **What it knows about the game** | Nothing game-specific: it reads the draw stream | **Engine-aware**: a per-game feeder hands over the game's real lights, materials, actors and buffers |
| **Best fit** | Fixed-function games (roughly pre-2004), with little per-game code | Games with their **own shaders**, where reading the draw stream alone is not enough, and mods that want to keep the game's look |
| **Look** | Remastered: new materials and assets through its own toolkit | The game's own look, with physically correct light added |
| **Per-game work** | Low for the games it suits | A feeder plugin per game (camera, geometry, lights, materials) |
| **32-bit games** | Bridges the game to its own 64-bit renderer | The game and its raster stay in the 32-bit process; only the ray tracing runs in a 64-bit helper on the same GPU |

Neither replaces the other: Remix is the quicker path for the games it fits; LegacyRT is for games and mods that want ray
tracing to work *with* the original renderer rather than in place of it.

## What is in here

| Folder | What |
|---|---|
| `helper/` | `NvrRtHelper.exe` (64-bit, C++, Vulkan): the scene, acceleration structures, pass dispatch, frame capture and offline `--replay`. `NvrRtProtocol.h` is the shared-memory contract both sides include. |
| `shaders/` | The trace passes (GLSL with `GL_EXT_ray_query`): sun shadows, lamp shadows (incl. many-lights / ReSTIR variants), flashlight shadows, AO + GI + a radiance cache, reflections, a reference path tracer with light grid, ReSTIR GI and denoiser inputs. `compile.sh` builds them. |
| `dxvk/` | The DXVK changes as a `git am` patch series on DXVK v3.0.1, and `build.sh` (Linux / WSL, MinGW). The series also holds the extension's non-RT parts (compute and full-screen passes, HDR output, tessellation, DLSS image sharing) that the game side uses. The RT-specific patches are 0026 (shared images and timeline semaphores), 0028, 0029, 0033, 0034. |

**Not in here:** the feeder for Fallout: New Vegas. It lives inside Vegas Shaders (GPL v3, see that repository's
`src/core/Rt*.cpp` and the RT effects) because it is built on that mod's framework. It is the reference for writing a feeder
for another game.

Some comments point at design notes (`docs/next/FORK-RT-CORE.md`, `RT-PATH-TRACING.md`, ...) from the development
repository. They are not published yet; `ARCHITECTURE.md` here covers the essentials.

## Using it in another game

A game needs a feeder plugin that hands the helper:
1. **Geometry**: which draws are world objects, their vertex/index data (the patched DXVK stages it on the GPU) and world transforms.
2. **The camera**: view and projection matrices.
3. **Lights**: positions, colours and ranges (the hardest part to find in most games).
4. **Materials and screen buffers**: albedo, normals, roughness/metal, depth (from the game's own shaders, or rebuilt).

…and composes the traced images back into its frame. See `ARCHITECTURE.md` for the protocol and the rules for writing a pass.
Requirements at run time: a GPU with Vulkan ray queries (RTX 20xx+, RX 6000+, recent Intel Arc) and its 64-bit driver.

## Build

- **Helper:** `helper/NvrRtHelper.vcxproj` (Visual Studio 2022, x64). Needs the Vulkan SDK (`%VULKAN_SDK%`).
- **Shaders:** `shaders/compile.sh` (Vulkan SDK's `glslangValidator` and `spirv-val`).
- **DXVK:** `dxvk/build.sh` on Linux or WSL (see its header for packages). Produces the 32-bit `d3d9.dll`.

## Licence

MIT (see `LICENSE`). The DXVK patches modify DXVK, which is under the zlib licence; DXVK's notices stay with its files.
