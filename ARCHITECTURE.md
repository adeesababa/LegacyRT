# How LegacyRT works

The contract between the game side and the helper is `helper/NvrRtProtocol.h` (MIT, included by both). This page is the
overview; the header is the authority (struct sizes, fields, flags).

## Start-up

1. The game side (the feeder plugin, through the patched DXVK) creates a named shared-memory block `NvrRtShared` and two
   events, `<base>-frame` (game -> helper) and `<base>-status` (helper -> game), then starts `NvrRtHelper.exe --shm <base>`.
2. It fills in, before `setupDone = 1`:
   - the Vulkan device identity (vendor, LUID, device and driver UUIDs), so the helper opens **the same GPU**;
   - up to 48 **shared images** (`NvrRtImageDesc`: NT handles duplicated into the helper, memory type, format, size). Image 0 is
     the **geometry arena**, where the patched DXVK stages vertex and index data on the GPU;
   - two **timeline semaphores**: `inputsReady` (game -> helper) and `outputReady` (helper -> game).
3. The game registers trace shaders (`.spv` paths, up to 32) at any time.
4. The helper imports everything, checks it has ray queries, and reports `NVR_RT_STATE_READY` (or `FAILED` with a message, and
   exits: the game then carries on without RT).

## Every frame

```
game (render thread)                                   helper
StageGeometry ... FlushStagedGeometry   (DXVK, GPU)
copy pass inputs into shared images     (DXVK, GPU)
frames[N % 4] = ops, instances, records, passes
latestFrame = N, SetEvent(frame)  ------------------>  wakes, copies frames[N % 4], consumedFrame = N
signal inputsReady = N            (DXVK flush)         GPU: wait inputsReady >= N
wait outputReady >= N             (GPU wait only)        arena -> own buffer; BUILD / RELEASE geometry (BLAS)
copy pass outputs out of shared images                   rebuild the scene (TLAS) from the instances
                                                         run the passes in order (barriers between them)
                                                         signal outputReady = N
```

Nobody waits on the CPU per frame. The game waits (briefly, with a timeout) only before overwriting a ring slot the helper has not
consumed yet, because geometry operations must not be lost.

A frame record holds:
- **Geometry ops** (`NvrRtGeometryOp`): `BUILD` geometry `id` from the arena (positions, then triangles, optionally texcoords),
  with flags for alpha-tested (non-opaque), dynamic (skinned, refit each frame), compaction and forced rebuild; `RELEASE` it.
- **Instances** (`NvrRtInstance`): a 3x4 transform (camera-relative world space), geometry id, custom index, cull mask, flags.
- **Records** (`NvrRtInstanceRecord`), one per instance: average albedo, flags (land, water, glow, metal, alpha-tested, textured,
  normal-mapped, material roughness/metal bits); the helper fills in where the geometry's data sits in binding 11.
- **Passes** (`NvrRtPass`, up to 8): shader index, dispatch size, up to 16 images with a write mask, 512 bytes of constants.

## Writing a trace pass

A pass is a compute shader with `GL_EXT_ray_query`, run by the helper. Its bindings (set 0):

| Binding | What |
|---|---|
| 0 | the scene (TLAS) |
| 1 | the pass's constants (uniform block, 512 bytes) |
| 2-9 | images 0-7 of the pass (storage images, layout GENERAL) |
| 10 | instance records (std430, by `rayQueryGetIntersectionInstanceIdEXT`) |
| 11 | geometry words: positions, triangles, texcoords (offsets from the record) |
| 12-19 | images 8-15 of the pass |

Cull-mask bits the game side uses: `0x10` alpha-tested geometry, `0x20` skinned actors, `0x40` the player's own parts, `0x80`
far LOD. A ray that must not see one of them drops that bit.

Rules learned the hard way:
- Keep a pass well under Windows' 2-second GPU timeout on the slowest GPU you support. One dispatch that runs longer loses the
  device, and the helper (and RT) is gone for the session. Split work across frames instead.
- Images are shared with a 32-bit process: formats and sizes are fixed at setup. Register every image a pass might ever use at
  setup, on or off.
- The arena may still hold an earlier flush's data if the game skipped a frame: the patched DXVK writes a sequence texel after
  each flush, and the helper checks it before building.

## Debugging

- `NvrRtHelper.exe --probe`: can this PC run it (64-bit driver with ray queries)?
- Frame capture: the game side can ask the helper to save one frame's inputs (`.nvrcap`), and
  `NvrRtHelper.exe --replay <file>` runs that frame again without the game, writing the pass outputs to images.
  `helper/rt_replay_compare.py` compares two replays.
- `helper/test/`: an end-to-end test without a game. A 32-bit program plays the game side through the patched `d3d9.dll`
  (geometry staging in several vertex and index formats, shared images and semaphores, the protocol), the helper builds and
  traces, and every ray is checked against the expected hit; then moved instances, released geometry and 300 frames of churn.
