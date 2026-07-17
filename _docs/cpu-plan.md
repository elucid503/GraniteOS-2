## Proposed plan

1. Establish a measurable software baseline

- Instrument Quartz time, pixels processed, backdrop captures, blur passes, and cache hits.
- Capture reference screenshots for each density, headers, overlapping glass, chromatic edges, damage regions, and resize behavior.
- Keep these as visual-parity tests for every GPU milestone.

2. Add optional virtio-gpu 3D support

Extend the driver with:

- `VIRTIO_GPU_F_VIRGL` negotiation.
- Capset discovery.
- Context create/destroy.
- 3D resource creation and attachment.
- Resource transfers.
- `SUBMIT_3D`.
- Fences and completion handling.

These are the standard commands provided by the VirtIO GPU 3D protocol. [VirtIO 1.3 specifies the feature and command set](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html).

Add a separate QEMU build option using approximately:

```text
-display sdl,gl=on
-device virtio-gpu-gl-device
```

If virgl is unavailable or initialization fails, GraniteOS continues with the current 2D device and software Quartz.

3. Build the smallest possible GPU proof

Before touching Quartz:

- Create one rendering context.
- Create a GPU render target.
- Submit a clear and a textured fullscreen quad.
- Present it through the existing scanout.
- Exercise resize, context teardown, and fallback.

Keep command submission synchronous initially. The driver currently allows one control request in flight, which is sufficient for correctness during bring-up.

4. Port Quartz as fragment passes

The existing algorithm maps cleanly to four GPU passes:

1. Copy/capture the damaged backdrop halo.
2. Downsample and horizontally blur into a half-resolution texture.
3. Vertically blur into a second half-resolution texture.
4. Resolve refraction, rim clarity, material tint, and chromatic dispersion with a fragment shader.

The final shader would consume:

- Original backdrop texture.
- Blurred frost texture.
- Window RGBA material texture.
- Two-channel signed displacement texture.
- Coverage/density constants.
- Scissor rectangle for damage.

Chromatic aberration remains three samples: center, red shifted inward, and blue shifted outward. This should closely reproduce [the current Quartz resolver](C:\\Users\\paul\\Desktop\\Projects\\Systems\\GraniteOS-2\\user\\servers\\display\\quartz.zig:530).

Initially, read the result back for comparison only. This validates shader parity but should not be the shipping architecture because readback would erase much of the performance gain.

5. Move final composition to a GPU-owned scanout

For real acceleration:

- Keep application UI rasterization on the CPU.
- Upload only damaged portions of window surfaces.
- Store each window as a GPU texture.
- Have the GPU compose the ordered window list into the final scanout.
- Invoke the Quartz passes when a Quartz layer is encountered.
- Draw borders, title overlays, and ordinary alpha windows as simple textured quads.

This avoids GPU-to-CPU readback and lets Quartz sample the already-composed layers beneath it.

The display driver should own resource IDs and virgl contexts. The compositor should receive opaque texture handles through a narrow internal API; clients should not submit raw GPU command streams.

6. Simplify after parity

Once the GPU path is stable:

- Remove the CPU full-screen Quartz output cache from the GPU backend.
- Retain only GPU-resident backdrop/frost textures.
- Batch all passes for a damage region into one submission.
- Add fences so the CPU can prepare the next region while the GPU renders.
- Preserve the software implementation for unsupported hosts, tests, and recovery.

The first meaningful milestone should be: **one Quartz panel rendered by virgl with screenshot parity, while the rest of the desktop remains CPU-composited**. The first performance milestone should be: **GPU-owned scanout with no readback**.

One practical risk is host availability. QEMU describes virgl acceleration primarily around Linux host support, so the build must probe capabilities at runtime and never make accelerated Quartz mandatory. The current software path is valuable precisely because it gives GraniteOS a dependable fallback across QEMU installations.
