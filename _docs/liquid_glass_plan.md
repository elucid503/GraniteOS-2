# Procedural "Liquid Glass" for the GraniteOS 2 Compositor — Implementation Plan

> Status: **design only**. This document is a plan; it changes no runtime code.
> It builds on the architecture survey of the software compositor and proposes a
> procedural glass system that can be attached to *any* window or sub-element,
> not just the launcher and clock popouts.

---

## 1. Goal

Give arbitrary UI elements an Apple-style "liquid glass" material: the pixels
*behind* the element remain visible but are **blurred**, **tinted**, and
**refracted** (lensed) around the element's shape, with a specular rim and a
subtle inner shadow. The effect must be:

- **Procedural** — driven by a small material descriptor plus the element's
  geometry, so any element (windows, panels, menus, popouts, and even
  sub-rectangles inside a client surface) can opt in without bespoke code.
- **Correct** — the backdrop must always reflect the *current* composited state
  of everything beneath the element in Z-order, including while windows below
  are moving/animating.
- **Efficient** — it must fit the existing CPU/software-blit budget on the
  ARM64 QEMU target. No GPU/virgl path exists, so every pixel is touched by the
  CPU; algorithms must be O(pixels) with tiny constants and must never re-touch
  pixels that did not change.

---

## 2. Current architecture (what we build on)

Grounded in the present code so the plan stays concrete:

- **Software compositor.** `user/servers/display/main.zig` maps a virtio-gpu
  dumb framebuffer (`map_scanout`) and composites into a cached back buffer
  (`build_back_buffer`). `composite()` walks damage rectangles, finds the
  lowest fully-covering opaque window per damaged region, paints windows
  bottom-to-top with `draw_window()`, then blits only the damaged band from the
  back buffer to the uncached scanout (`fb.blit`) and flushes it.
- **Surfaces.** `user/lib/draw/draw.zig` `Surface` is a flat `[*]u32` with a
  `stride` and a `clip` rect. Compositing uses `blit` / `blit_masked`
  (`user/servers/display/render.zig`) — straight memcpy-speed copies plus 8-bit
  coverage masks for rounded corners.
- **Rounded-corner LUTs.** `user/lib/draw/round.zig` precomputes per-radius
  coverage masks (`masks_for`) — the exact precomputed-lookup pattern we will
  reuse for the displacement/normal field.
- **Damage.** `user/servers/display/damage.zig` merges dirty rects (cap 12) and
  only that band is recomposited and rescanned each frame.
- **Window model.** `user/servers/display/manager.zig` `Window` exposes
  `frame()`, `content()`, `is_panel()`, `decorated()`, `is_desktop()`, and
  stacking order via `stacked(index)`. Window flags live in
  `user/lib/ipc/proto.zig` (`flag_undecorated=1`, `flag_fullscreen=2`,
  `flag_panel=4`, `flag_minimized=8`, `flag_desktop=16`, `flag_maximized=32`;
  next free bit = **64**).
- **Panels are opaque today.** The launcher (`user/servers/launcher/main.zig`)
  and the calendar/weather popouts (`user/programs/gui/taskbar.zig`) are just
  undecorated/panel windows blitted opaquely. There is no blur/refraction code
  anywhere in the tree.

### Key consequence for the design

The compositor already composites **strictly bottom-to-top into a single shared
back buffer**. That is the ideal substrate for glass: at the moment we are about
to paint a glass element, the back buffer already contains everything beneath it
for the damaged region. Glass becomes "read the back buffer under my rect →
transform → write back." The whole feature is an interception at
`draw_window()` time plus a damage-model extension.

---

## 3. Design principles

1. **Backdrop = the back buffer, read in place.** Never re-render the scene into
   a scratch layer per glass element. When `draw_window()` reaches a glass
   element, everything below it for the current damage region is already in
   `back`. We snapshot only the footprint we need.
2. **Separate the *material* (procedural, data) from the *geometry* (per-element
   shape).** A `GlassMaterial` descriptor (blur radius, tint, refraction
   strength, rim, shadow) plus a `GlassShape` (rounded-rect today; extensible to
   an arbitrary coverage+height field) fully specify the look. No element needs
   custom drawing code.
3. **Precompute everything shape-dependent into LUTs**, keyed by
   `(width, height, corner_radius, bevel_width)`, cached and shared, exactly as
   `round.masks_for` caches corner masks. Per-frame work is then just table
   lookups + adds.
4. **Everything is O(footprint) with tiny constants.** Box blur via running sums
   (O(1)/pixel/pass), separable H then V, optionally at half resolution.
5. **Backdrop-dependent invalidation is a first-class concept.** A glass element
   must repaint when *its own* content changes **or** when anything beneath it in
   its footprint changes. This is the one genuinely new idea for the damage
   system and the main correctness risk.

---

## 4. The procedural material model

### 4.1 `GlassMaterial` (data, in `user/lib/draw/glass.zig`)

```
GlassMaterial = {
    blur_radius:      u8,      // backdrop softening, in (downsampled) px
    blur_passes:      u8,      // 1..3 box-blur passes (3 ≈ Gaussian)
    downsample:       u8,      // 1,2,4: blur at 1/n res, upsample on write
    tint:             Color,   // material color
    tint_alpha:       u8,      // 0..255 tint-over-backdrop weight
    refraction:       u8,      // 0 = flat frosted glass; >0 = lensing strength
    edge_width:       u8,      // px band over which refraction ramps to 0 in the interior
    rim_light:        u8,      // specular highlight intensity on the top/left bevel
    rim_shadow:       u8,      // inner shadow intensity on the bottom/right bevel
    noise:            u8,      // optional per-pixel dither to hide banding
}
```

Named presets ship in the theme (`user/servers/display/main.zig` theme block and
`user/lib/gfx/prefs.zig`): e.g. `regular`, `clear`, `dock`, `menu`. Presets keep
call sites declarative and let the whole desktop restyle from one place.

### 4.2 `GlassShape` (geometry)

- **Phase 1:** rounded rectangle — reuse `corner_radius` semantics already in
  `render.zig` / `round.zig`. This covers windows, panels, menus, and popouts,
  i.e. everything that exists today.
- **Phase 2 (procedural "any element"):** a generic shape is
  `(coverage: []u8, height: []u8)` over the element's bounding box — an 8-bit
  alpha coverage map plus an 8-bit height field. The rounded rect is just one
  generator of this pair. This is what makes glass apply to *any* element:
  pills, circles, notches, per-glyph chips, or client-supplied masks all reduce
  to the same coverage+height buffers.

### 4.3 From height field to refraction (the "liquid" look)

The signature lensing = sampling the backdrop with a per-pixel offset. Derive a
surface normal from the height field and offset the sample along it:

```
n = normalize( ∂h/∂x, ∂h/∂y, k )          // k tunes "thickness"
offset(x,y) = refraction * (n.x, n.y)      // horizontal displacement, in px
sample = bilinear(backdrop, x + offset.x, y + offset.y)
```

For a rounded rect, `h` is flat in the interior and ramps down over `edge_width`
at the border/corners, so the backdrop **magnifies and bends near the edges**
and is merely blurred in the middle — precisely the liquid-glass edge lens.
Because `h` depends only on the shape, the entire `(offset.x, offset.y)` field is
**precomputed once per `(w,h,radius,edge_width)`** and cached; per pixel we do one
LUT read + one bilinear fetch.

### 4.4 Compositing order per glass element (all reads from `back`)

For each glass element, over its clipped footprint:

1. **Capture** the backdrop footprint from `back` (bounded by the damage clip).
2. **Blur** the captured copy (downsample → separable box blur ×passes →
   implicit upsample on read).
3. **Refract + write**: for each covered pixel, bilinear-sample the *blurred*
   backdrop at `(x+off.x, y+off.y)`, blend `tint` over it by `tint_alpha`, add
   `rim_light`/`rim_shadow` from the bevel LUT, apply `coverage` as alpha against
   the existing `back` pixel (anti-aliased edges), optional `noise` dither.
4. **Client content on top**: the element's own opaque pixels (text, icons) are
   then blitted normally over the glass via the existing `blit_content` path.

No extra full-frame buffers: one small scratch buffer sized to the largest glass
footprint (grown on demand), reused across elements and frames.

---

## 5. Compositor integration

### 5.1 Draw path

Extend `draw_window()` in `user/servers/display/main.zig`:

```
fn draw_window(window, clip):
    if window.glass != null:
        glass.render_backdrop(&back, window.frame(), clip, window.glass.*)  // steps 1–3 above
    ... existing title bar / blit_content / border ...   // step 4 + chrome
```

The glass draws **before** `blit_content` so client pixels land on top. Chrome
(title bar, border) for a glass window is drawn with translucency so it reads as
part of the glass, not an opaque cap.

### 5.2 Z-order guarantees (already mostly satisfied)

`composite()` paints strictly bottom-to-top from the first fully-covering opaque
window upward. Requirement: **glass never contributes to the "fully covering
opaque" search** — a glass element is not opaque, so the covering-window scan
(`covers` + `surfaces.covers`) must skip elements whose material is
translucent/glass, forcing the wallpaper/lower windows to actually be painted
into `back` first. This is a small guard in the existing loop, not a rework.

### 5.3 Stacked glass

Painting bottom-to-top makes stacked glass automatically correct: a higher glass
element captures a `back` that already contains the lower glass element's output.
The only rule is that each glass element's **damage footprint reblurs whenever a
lower one under it changed** — handled by §6.

---

## 6. Damage model extension (the hard part)

Today damage answers only: "did *this rect's own* pixels change?" Glass needs:
"did anything change *underneath* a glass element's footprint?" Plan:

1. **Register glass footprints.** The manager keeps the set of visible glass
   elements and their frames (already has stacking + `frame()`).
2. **Damage amplification.** In `add_damage()` / when merging into
   `damage.List`, after collecting a raw dirty rect `r`, for every glass element
   `g` whose frame intersects `r` **and sits above the change in Z-order**, add
   `g.frame() ∩ screen` (expanded by `blur_radius + refraction` to account for
   the blur/lens reaching outside the change) to the damage set. Iterate to a
   fixpoint so stacked glass propagates (glass over glass).
3. **Bounded cost.** Because glass footprints are the small chrome elements
   (dock, launcher, menus, popouts), amplification adds a handful of rects. The
   `damage.List` cap (12) already coalesces; we raise the cap or add a dedicated
   glass-dirty list if measurements show merging thrash.
4. **Blur-halo bleed.** Blur samples pixels *outside* the element by up to
   `blur_radius`. So (a) the **capture** rect is the footprint dilated by the
   halo, and (b) damage that lands only in the halo (not the element proper)
   must still trigger a reblur. Both handled by dilating footprints by
   `blur_radius + max_refraction_offset` wherever they enter damage math.
5. **Idle cost = zero.** If nothing under a glass element changes, no
   amplification fires and the element is not repainted — critical for the
   always-open dock.

This is the piece that does not exist today and where correctness bugs (stale /
smeared backdrops when a window moves under the dock) will hide. It gets the most
test coverage (§10).

---

## 7. Public API / protocol surface

1. **New window flag** `flag_glass: u64 = 64` in `user/lib/ipc/proto.zig`. A
   window created with it is composited as glass using a material id.
2. **Material selection.** Add a small `set_glass` display request (material id +
   optional shape params: corner radius, edge width) alongside existing window
   ops, so clients pick a preset without shipping pixel math. Default material
   derives from the window kind (panel→`dock`, undecorated popout→`menu`).
3. **Client-side helper** in `user/lib/gfx` (e.g. `window.enable_glass(preset)`),
   so the launcher and `taskbar.zig` opt in with one call and their existing
   opaque fills are dropped.
4. **Sub-element glass (procedural, Phase 2).** Expose
   `glass.render_backdrop(surface, rect, clip, material, shape)` as a **library**
   primitive in `user/lib/draw/glass.zig`. Any server or app that owns a
   `Surface` (including the compositor for its own chrome, or an app for a
   region inside its window) can apply glass to an arbitrary sub-rect with a
   supplied coverage/height field — no compositor involvement required for
   purely intra-surface glass. This is the "extend to any element" mechanism.

---

## 8. Efficiency plan

Target: the added per-frame cost is a small multiple of a plain blit of the glass
footprint, and **zero** when the backdrop is idle.

- **Box blur, not Gaussian.** Running-sum box blur is O(1) per pixel per pass;
  3 passes approximate a Gaussian. Separable: horizontal pass then vertical pass.
- **Downsample.** Blur at 1/2 or 1/4 resolution (`downsample`), upsample bilinearly
  on read. Quarters/sixteenths the blur cost; glass blur hides the resolution
  loss.
- **Precomputed LUTs**, cached like `round.masks_for`, keyed by
  `(w,h,radius,edge_width)`:
  - displacement field `(off.x, off.y)` per pixel (i8 pairs),
  - bevel rim light/shadow intensities,
  - edge coverage (anti-alias alpha).
  Cache a few entries (dock, launcher, menu, popout sizes); evict LRU. Building a
  LUT is a one-time cost paid on first use / resize, never per frame.
- **Dirty-only reblur.** Reblur/repaint a glass element only for the intersection
  of its footprint with the amplified damage — usually a sub-rect, not the whole
  element.
- **Single reused scratch buffer** sized to the largest glass footprint (+halo),
  grown on demand; no per-element allocation.
- **SIMD-friendly inner loops.** Reuse the `PixelVector` pattern already in
  `draw.zig` (`fill_rect_alpha`) for the tint/rim blend and the box-blur adds.
- **Fixed-point math.** Normals/offsets as integers/fixed-point; no floats in the
  hot loop. Bilinear via 8-bit fractional weights.
- **Fence discipline.** Keep the existing `draw.fence()` before reading client
  surfaces; glass reads only `back` (compositor-owned), so no extra cross-process
  fences are needed.

### Rough budget sanity

A dock/launcher footprint is on the order of a few hundred × a few hundred px.
At 1/2-res, 3-pass separable box blur that is ~hundreds of thousands of adds —
well under the cost of the full-frame blits `composite()` already performs each
present. Real-time is not at risk; the risk is *correctness*, not throughput.

---

## 9. Edge cases (enumerated)

Backdrop / correctness:
- **Window moving under glass** → §6 amplification must reblur the dock/popout
  every frame of the drag; otherwise a smeared trail. Primary regression test.
- **Glass over glass** (popout above the dock) → fixpoint amplification so the
  upper one reblurs when the lower repaints.
- **Glass over the wallpaper only** → wallpaper fill must happen into `back`
  before capture (guaranteed once glass is excluded from the covering-opaque
  scan, §5.2).
- **Glass at/over the screen edge** → capture/refraction sampling clamps to
  screen bounds; edge pixels replicate rather than read garbage.
- **Blur halo extending past a screen edge** → clamp; do not sample off-surface.
- **Element larger than the scratch buffer** → grow scratch or tile the footprint
  into scratch-sized bands.
- **Mode change / resolution change** → `on_mode_change` remaps scanout and
  rebuilds `back`; must also invalidate all glass LUT caches and scratch sizing.
- **Minimized / hidden glass** → skip entirely; drop from the glass footprint set
  so it stops amplifying damage.
- **Zero-size / degenerate rect, radius > half-extent** → clamp radius; skip if
  footprint empty (mirror existing guards in `render.blit_content`).
- **Stale client surface after resize** → glass backdrop still renders (it reads
  `back`, not the client surface); client content simply lands late, exactly as
  the existing `surface_of(slot) orelse return` path already tolerates.

Visual quality:
- **Banding** in the blur/tint gradient → optional ordered-dither `noise`.
- **Corner seams** between refraction and the existing corner coverage masks →
  the glass coverage LUT must be the single source of edge alpha; do not
  double-apply `round` masks and glass coverage.
- **Over-refraction near tight corners** producing sampling artifacts → clamp
  offset magnitude; ramp `refraction` to 0 within `edge_width` of true corners.
- **Text legibility** over a busy backdrop → `tint_alpha` floor + optional rim
  shadow behind content; presets tuned so client text stays readable.

Performance / robustness:
- **Fullscreen glass** (`flag_fullscreen`) → effectively whole-screen blur;
  guard with a max footprint and/or force higher `downsample`; realistically
  disallow glass on fullscreen windows via material validation.
- **Rapid open/close of popouts** → LUT cache keyed by size avoids rebuild churn;
  reuse across open/close.
- **Damage list saturation** during a drag with several glass elements → raise
  `damage.capacity` or maintain a separate glass-dirty accumulator so ordinary
  damage coalescing is unaffected.
- **Multi-monitor / future x86_64** → glass is arch-agnostic (pure `Surface`
  math); no arch coupling introduced.

---

## 10. Testing strategy

- **Host unit tests** (`zig build test`) for the pure library
  (`user/lib/draw/glass.zig`) on `Surface.from_pixels` buffers:
  - box-blur correctness (uniform field stays uniform; impulse spreads
    symmetrically; running-sum equals naive box on small inputs),
  - displacement LUT symmetry for a rounded rect,
  - edge coverage matches `round` masks on the flat interior,
  - clamping at surface edges (no out-of-bounds sample),
  - `downsample` upsample path stays within tolerance of full-res.
- **Damage-amplification unit tests** on a synthetic `manager` + `damage.List`
  (the manager already has host tests): a change under a registered glass frame
  must add the (dilated) glass rect; stacked glass must reach a fixpoint; idle
  scene must add nothing.
- **Golden-image / scripted GUI** via `scripts/m9.sh`: dock over wallpaper, dock
  over a moving window, popout over dock; assert the composited band matches
  expectations (or at least is re-emitted) on each drag frame.
- **Perf smoke:** measure `composite()` time with the dock glass on, dragging a
  window beneath it, to confirm it stays within the present budget.

---

## 11. Phasing

1. **Primitive library** — `user/lib/draw/glass.zig`: capture + box blur +
   displacement sampler + tint/rim, all on `Surface`, with host tests. No
   compositor wiring yet. (Self-contained, low risk.)
2. **Rounded-rect glass on panels** — `flag_glass`, `set_glass`, LUT cache, hook
   into `draw_window()`, exclude glass from the opaque-cover scan. Convert the
   launcher + calendar/weather popouts. Static backdrop only (reblur every frame
   while a glass element is visible — simplest, slightly wasteful).
3. **Backdrop-dependent damage** — implement §6 amplification + fixpoint;
   drop the "reblur every frame" shortcut so idle cost goes to zero. This is the
   correctness-critical phase.
4. **Procedural any-element** — generic coverage+height shapes, the public
   `glass.render_backdrop` library entry, and sub-surface glass usage; theme
   presets in `prefs.zig`.
5. **Polish** — noise/dither, rim tuning, perf pass (downsample/SIMD), optional
   animated "liquid" flex on the height field for open/close transitions.

---

## 12. Risks & fallbacks

- **Biggest risk: damage amplification correctness** (stale/smeared backdrops).
  Mitigation: land Phase 2 with unconditional per-frame reblur first (always
  correct, just costs cycles), then optimize to dirty-driven reblur in Phase 3
  behind the same tests.
- **Perf on the software path.** Mitigation: `downsample` and `blur_passes` are
  runtime-tunable per material; presets can dial quality down globally, and glass
  can be disabled via prefs to fall back to today's opaque panels.
- **Scope creep to full transparency stack.** Keep glass a *material* on top of
  the existing bottom-to-top opaque compositor; do **not** introduce a general
  per-window alpha/blend graph. Glass reads `back` in place; that constraint is
  what keeps the feature cheap and bounded.

---

## 13. Touch list (files)

- `user/lib/draw/glass.zig` — **new**: material, shape, LUT cache, capture, blur,
  refraction sampler, tint/rim, `render_backdrop`.
- `user/lib/draw/round.zig` — reuse/extend LUT-cache pattern for displacement.
- `user/lib/ipc/proto.zig` — `flag_glass`, `set_glass` op + params.
- `user/lib/gfx/*` — client helper (`enable_glass`) + theme presets in `prefs.zig`.
- `user/servers/display/manager.zig` — glass flag/material on `Window`, glass
  footprint registry, exclude glass from opaque-cover.
- `user/servers/display/main.zig` — `draw_window()` hook, `add_damage`
  amplification, LUT/scratch invalidation on mode change.
- `user/servers/display/damage.zig` — capacity / glass-dirty accumulator if
  needed.
- `user/servers/launcher/main.zig`, `user/programs/gui/taskbar.zig` — opt the
  launcher and calendar/weather popouts into glass; drop opaque fills.
- Tests: host tests in `glass.zig` + manager/damage; `scripts/m9.sh` GUI checks.
