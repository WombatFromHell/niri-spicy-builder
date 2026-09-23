# RESEARCH: GL sync-object errors in the niri-spicy build

Status: **fixed and validated** (2026-09-22). Root cause: a single
`GlesTexture` offscreen animation buffer was created and bound on the
**target** device's renderer but drawn on the **render** device's frame, so
its GL fences crossed the per-device share groups. The crossing texture was
niri's `TtyOffscreen::Gles` buffer (§5.4). Fix: `MultiRenderer` routes
offscreen `create_buffer`/`bind` to the render device (§9,
`0002-fix-multirenderer-offscreen-routing.patch`), validated live: zero GL
errors, zero guard skips, tile animations render correctly, smoke test passes
with `SESSION_STRICT=1`. Sections 1–5 are history; §6–§10 reflect the full
investigation.

Pinned refs:

- niri: `15c93f6` (`15c93f62b4a2963b0b3fe8f1732c3ea73f9396f5`, losnoco/niri, "tests: run the shaders on a real renderer")
- smithay: `ce13557` (`ce13557df3f29525f195816c112bbfebd4e5a822`, losnoco/smithay, "vulkan: rescale HDR PQ content to the output reference white")
- Mesa: `26.2.2` tag (`mesa-26.2.2` on GitLab), source tarball cached at `/tmp/mesa-mesa-26.2.2`

## 1. The symptom

Error strings (all from smithay's GLES renderer KHR_debug callback,
`smithay::backend::renderer::gles`, mod.rs:428-448):

```
ERROR smithay::backend::renderer::gles: [GL] GL_INVALID_VALUE in glClientWaitSync (not a valid sync object)
ERROR smithay::backend::renderer::gles: [GL] GL_INVALID_VALUE in glWaitSync (not a valid sync object)
ERROR smithay::backend::renderer::gles: [GL] GL_INVALID_VALUE in glDeleteSync (not a valid sync object)
```

Original report: fired at ~7 ms intervals during Dolphin spawn on a
hybrid-graphics (BIOS HybridGraphics enabled) machine, in release RPMs built
by `build-rpm-spicy.sh`.

## 2. Environment and GPU topology

Machine: `methyl-bazzite`, Fedora 44 (Bazzite), kernel
`7.2.6-ogc3.1.fc44.x86_64`, Mesa 26.2.2 (OpenGL ES 3.2), GL renderer on both
paths observed: AMD Radeon RX 9070 XT (radeonsi, gfx1201).

Session: `uwsm_niri.desktop` → niri `26.04 (15c93f6)` (i.e. this build's own
RPM), pid 3179, started 08:31:03 local (MDT). Journal timestamps below are
local; tracing payload timestamps inside messages are UTC (+6h).

Dual AMD GPU, both `amdgpu`:

| node | PCI id | device id | identity | render node | boot_vga | connected outputs |
|---|---|---|---|---|---|---|
| card1 | `0000:03:00.0` | `0x7550` | Navi 48 [RX 9070/9070 XT] (dGPU, ASRock) | `renderD128` | 1 | `HDMI-A-1` (UGREEN dock) |
| card0 | `0000:13:00.0` | `0x164e` | Raphael iGPU (MSI) | `renderD129` | 0 | `DP-4` (Dell AW3426DW) |

niri session wiring (from its startup log):

- `using as the render node: /dev/dri/renderD128` → primary render node = **dGPU**
- adds `card1` first: "this is the primary node", then adds `card0`
- `explicit sync enabled for primary gpu` (EGL explicit sync — unrelated to the
  GL fence objects at issue, but same neighborhood)
- active output: `compositing on primary plane connector="DP-4"` — **the working
  monitor is on card0 (iGPU), while rendering happens on card1 (dGPU)**

This means the session permanently exercises smithay's multi-device
`GpuManager` cross-GPU path: `gpu_manager.renderer(&primary_render_node /* renderD128/dGPU */, &render_node /* renderD129/iGPU */, format)`
(niri `tty.rs:1625`, wrapper `tty_renderer.rs:672-683`). Rendering occurs on the
dGPU EGL context; the frame is copied to the iGPU target for scanout.

Kernel: no GPU reset, hang, ring timeout, or XDCR/fault events this boot (only
boot-command-line noise from the grep). `UnableToDropMaster ... DRM leasing`
warning at startup is unrelated noise.

## 3. Journal evidence (this boot, as of 10:15 local)

963 matching error lines total, in ~20 discrete one-second bursts. Every burst
is a `ClientWaitSync`/`WaitSync` pair per frame for the burst's duration,
terminated by a single `glDeleteSync` error.

Anatomy of the 09:51:54 burst: pairs from `.379` to `.522` (~7 ms apart ≈ frame
period, i.e. **one offending texture drawn every frame**), final
`glDeleteSync` error at `.528` — i.e. the texture lives ~150 ms then is
dropped. All lines come from the **session compositor**
(`uwsm_niri.desktop[3179]`), never from the nested test compositor.

| local time | errors | trigger |
|---|---|---|
| 08:31:14–23 | 213 | login: Steam / xwayland-satellite window churn (visible in log at 08:31:10) |
| 08:32:58, 08:33:46–52, 08:35:13 | 278 | more login-time app windows |
| 09:22:40–44 | 152 | kitty spawn (`app-niri-kitty-29253.scope` at 09:22:43) |
| 09:26:06 | 65 | Dolphin spawn (`app-niri-dolphin-39078.scope`) — the original report |
| 09:43:47 | 51 | smoke-test attempt #1 (its `systemd-cat --user` tagging was broken at that point, so no `niri-smoke` tag exists for it) |
| 09:47:15 | 47 | smoke run #2 (`niri-smoke[47136]` starts same second) |
| 09:51:54 | 61 | smoke run #3 (`niri-smoke[48663]` starts same second) |
| 09:57:19 | 69 | unattributed — no app scope logged; consistent with a window from an already-running app |

Conclusions drawn:

1. **Bursts coincide with window-creation events** in whichever compositor gets
   the new window (login apps, kitty, Dolphin, and — notably — the *nested
   niri's own window appearing inside the session* during all smoke runs).
2. The bug is **not** specific to Dolphin; Dolphin was just one instance.
3. Errors continue independently of our testing (09:57:19 burst after the last
   smoke run).
4. Bursts are discrete: one bad texture's lifetime, not a permanently invalid
   global state.
5. Not every window triggers a burst (triggers between bursts are unknown) —
   the *filter* is itself a clue (see §6, open questions).

## 4. Reproduction status

- **Session compositor (TTY backend, multi-device): reproduces, on demand-ish.**
  Opening any new window (kitty, Dolphin, the nested compositor's window)
  reliably produced a burst during this investigation (4/4 observed cases).
- **Nested compositor (winit backend): does NOT reproduce.** Three smoke runs,
  each with 3 open/kill cycles of kitty inside the nested compositor:
  `journalctl -t niri-smoke` contains **0** GL errors. The nested run logs a
  single `Initializing OpenGL ES Renderer ... ptr=...` — one EGL context, one
  GPU (dGPU via the Wayland winit EGL platform), no `GpuManager` multi-device
  involvement. Texture churn alone on this driver is therefore *not* sufficient;
  the session's multi-device TTY path (or another session-specific factor) is
  required.
- **Standalone EGL experiment: reproduces the exact 3-message pattern on
  demand** (see §10). No session restart needed.

Structural reason a second instrumented instance can't be run side-by-side: the
session holds DRM master on both cards; a second TTY niri cannot acquire the
devices. Reproducing *with instrumentation* therefore requires replacing the
session binary (install the RPM) and restarting the session.

## 5. Code path analysis (pinned refs)

### 5.1 Where the three GL calls happen

`smithay/src/backend/renderer/gles/texture.rs` (original, pre-instrumentation
layout, lines ~71-121):

```rust
struct TextureSync { read_sync: Mutex<Option<GLsync>>, write_sync: Mutex<Option<GLsync>> }

unsafe fn wait_for_syncpoint(sync: &mut Option<GLsync>, gl: &Gles2) {
    if let Some(sync_obj) = *sync {
        match gl.ClientWaitSync(sync_obj, 0, 0) {
            ALREADY_SIGNALED | CONDITION_SATISFIED => { let _ = sync.take(); gl.DeleteSync(sync_obj); }
            _ => { gl.WaitSync(sync_obj, 0, TIMEOUT_IGNORED); }   // WAIT_FAILED lands here
        };
    }
}
```

Call sites:

- **Create**: `update_write` (texture.rs:119/119 → `glFenceSync` after CPU upload,
  mod.rs:949, 1043, 1120, and after rendering-into-a-texture in `finish_internal`,
  mod.rs:2448) and `update_read` (texture.rs:100 → after drawing, mod.rs:2998).
  Gated on `Capability::Fencing`, which is enabled whenever GLES ≥ 3.0
  (mod.rs:500-503) — active on this machine (ES 3.2).
- **Wait**: `wait_for_upload` at draw time (mod.rs:2881), `wait_for_all` at
  `bind_texture` and import paths (mod.rs:728, 901, 1094).
- **Delete**: the success arm of `wait_for_syncpoint`, the replace-old-sync arms
  of `update_read`/`update_write`, and texture `Drop` → `CleanupResource::Sync`
  → cleanup does `gl.DeleteSync` (mod.rs:322-327).

**`glFenceSync`'s return value is never checked** (original texture.rs:100 and
:119 store it straight into `Some(...)`).

### 5.2 The observed error sequence maps exactly onto this code

1. `ClientWaitSync(invalid)` → KHR_debug error #1, returns `WAIT_FAILED`.
2. `WAIT_FAILED` is not `ALREADY_SIGNALED|CONDITION_SATISFIED` → falls into `_`
   arm → `WaitSync(invalid)` → error #2. The sync is **not** `take()`n.
3. Next frame, same texture, same two errors → the observed per-frame pairs.
4. Texture dropped → `CleanupResource::Sync` → `DeleteSync(invalid)` → error #3,
   once, ending the burst.

So exactly **one** sync handle is invalid for the whole lifetime of one texture.

### 5.3 Why multi-device matters

`GbmGlesBackend::enumerate` (multigpu/gbm.rs:181-189) creates **one
`EGLContext::new_with_priority` per device display, not shared** (confirmed:
configless context, `EGL_CONTEXT_OPENGL_DEBUG` never set — niri/smithay never
pass `debug: true`; `egl/context.rs:255` gates the debug bit on
`GlAttributes.debug`, and `new_with_priority` → `new_internal` with
`config=None` never reaches that branch). GL sync objects are only valid within
their context's share group. A `GLsync` created under the dGPU context and
waited/deleted while the iGPU context is current (or vice versa) yields
precisely `GL_INVALID_VALUE … not a valid sync object` at
all three call sites. The nested winit compositor never has two such contexts —
consistent with §4.

The handle is *not* NULL (see §6, H1 dead). Which texture crosses is now
determined — see §5.4.

### 5.4 The crossing texture: niri's offscreen animation buffer

The instrumented session (RUST_LOG=...gles::texture=debug) shows exactly 3
crossing `GlesTexture` objects, each crossing in **both** directions, each
re-uploaded (write fence) and re-drawn (read fence) **every frame** during
compositor animations (drag/open/close/resize — per user report). That is the
signature of an **offscreen render target** re-rendered every animation frame.

Mechanism (niri + smithay multi-GPU path):

- niri's offscreen animation buffers are `TtyOffscreen::Gles(GlesTexture)`
  (niri `tty_renderer.rs:743`), created via `TtyRenderer::create_buffer`
  (`tty_renderer.rs:802-810`) → `MultiRenderer::create_buffer`.
- smithay's `MultiRenderer::create_buffer` **and** `MultiRenderer::bind`
  (multigpu/mod.rs) route to the **target** device's renderer (iGPU) when a
  target exists; the single-device branch (R == T) routes to the render device.
  So the buffer's `GlesTexture` is owned by the **iGPU** renderer/EGL context.
- niri draws the buffer as a source texture via
  `UniversalTextureRenderElement::draw` (niri `render_helpers/texture.rs:364`),
  whose `TtyOffscreen::Gles` arm calls `frame.as_gles_frame()` =
  `MultiFrame::as_mut()` = the **render** device's (dGPU) frame (multigpu/mod.rs
  `MultiFrame.frame` is the R frame; `as_mut` returns `self.frame`).
- Net: the `GlesTexture` is **created + bound on the iGPU** (write fence created
  under the iGPU ctx in `finish_internal`) but **drawn on the dGPU** (read fence
  created under the dGPU ctx in `update_read`), and:
  - `wait_for_upload` (dGPU ctx, before draw) waits the iGPU write fence → cross.
  - next frame's `bind`/`wait_for_all` (iGPU ctx) waits the dGPU read fence → cross.
  - `glDeleteSync` on drop is cross too.

This explains every observed property: animation-only (offscreen buffers are
only used then), per-frame (re-rendered each animation frame), both directions,
multi-device-only (single GPU ⇒ R == T ⇒ no cross), and bursty (one per active
animation buffer). The `TtyOffscreen::Multi` arm (per-context textures via
dmabuf) is safe — only the `Gles` arm bypasses per-context routing.

## 6. Hypotheses — updated

| # | hypothesis | status | evidence |
|---|---|---|---|
| H1 | `glFenceSync` returned **NULL** (unchecked) and `Some(NULL)` is stored | **DEAD** | Standalone test A: handle 0 under a valid context raises `GL_INVALID_VALUE (not a valid sync object)` in `glClientWaitSync` and `glWaitSync` (with `GL_TIMEOUT_IGNORED`, matching smithay's calls) but **`glDeleteSync(0)` is silently ignored** per Mesa spec (`syncobj.c: delete_sync` returns early for `sync==0`). Niri's journal shows the error at **all three** sites ⇒ the offending handle is non-NULL. |
| H2 | **Cross-context sync**: handle created in one device's EGL context, used while another (non-shared) context is current | **CONFIRMED (live)** | Standalone test B reproduced the exact 3-message pattern. **Live instrumented session confirmed**: every crossing sync's creation-context ≠ wait-context, in both directions, on exactly 3 offscreen animation buffers (§5.4). |
| H3 | **Stale handle after context recreation** (EGL context destroyed/recreated, old sync dead) | **DEAD** | Live data shows each wait-context consistently paired with its own display pointer (no context recreation); the crossing is purely cross-share-group (H2). |
| H4 | GPU reset / context loss | **Dead (weak as before)** | No kernel reset/hang events; bursts track window creation. |

### Mesa 26.2.2 source analysis (syncobj.c, errors.c, debug_output.c, st_manager.c)

- Sync objects live in `ctx->Shared->SyncObjects`, a **per-share-group** hash
  set. `_mesa_get_and_ref_sync` validates: handle non-NULL, present in the
  current share group's set, type `GL_SYNC_FENCE`, not `DeletePending`.
  Failure ⇒ `GL_INVALID_VALUE "not a valid sync object"`.
- `_mesa_ClientWaitSync` / `_mesa_WaitSync` raise the error for any handle
  failing validation; `_mesa_WaitSync` additionally requires
  `timeout == GL_TIMEOUT_IGNORED` *before* sync validation (a finite timeout
  short-circuits the error — an early test artifact that briefly muddied the
  NULL-handle results).
- `_mesa_FenceSync` inserts into `ctx->Shared->SyncObjects` and returns the
  object pointer as the handle (raw pointer, no object-ID indirection).
- **KHR_debug reporting is per-context**: `_mesa_error` (errors.c) only emits
  the debug message for the *current* context that has a registered callback
  **and** `DebugOutput` enabled. `DebugOutput` is set to TRUE only via
  `glDebugControl(GL_DEBUG_OUTPUT, TRUE)` or when the context is created with
  the debug bit (`st_manager.c:1038-1041`: `ST_CONTEXT_FLAG_DEBUG` →
  `_mesa_set_debug_state_int(ctx, GL_DEBUG_OUTPUT, TRUE)`), i.e.
  `EGL_CONTEXT_OPENGL_DEBUG → __DRI_CTX_ATTRIB_FLAGS → ST_CONTEXT_FLAG_DEBUG`.
  Empirically confirmed: a non-debug context with a registered callback emits
  nothing (test 0, `cb_count=0`), even after `glDebugControl(GL_DEBUG_OUTPUT,
  TRUE)` (still 0 — unexplained wrt source; possibly a Mesa 26 quirk or
  dispatch issue in the headerless test).
- Implication for niri: each per-device `GlesRenderer` registers **its own**
  KHR_debug callback (gles/mod.rs:637, uninstalled at 1801), so an error raised
  under device B's context is reported by B's own callback — the instrumented
  build's context-pointer mismatch line discriminates H2 directly regardless.

### Open puzzle (does not block root-causing)

Niri's per-device contexts are genuinely non-debug (no `EGL_CONTEXT_OPENGL_DEBUG`,
smithay never calls `glDebugControl`, no `debug: true` anywhere in niri or
smithay), yet the live session emits KHR_debug messages — while the standalone
test only fires the callback on debug-bit contexts. Leading candidate:
Fedora's Mesa 26.2.2 RPM differs from the upstream `mesa-26.2.2` tag (e.g. a
Fedora patch enabling debug output). Worth a quick check of
`/usr/lib64/mesa/dri` / `rpm -q mesa-dri-drivers` patches later, but the
instrumented build doesn't depend on it.

## 7. Work completed so far

### 7.1 Patch mechanism for `patches/niri-spicy/`

- `build-lib.sh`: `apply_patches <tree>` applies sorted `*.patch` from
  `patches/niri-spicy/{niri,smithay}/` via `git apply` right after `sync_repo`
  (which hard-resets the tree each build ⇒ a patch that stops applying fails
  the build, deliberately).
- `build-rpm-spicy.sh`: calls `apply_patches niri` and `apply_patches smithay`.
- `patches/niri-spicy/README.md` + `niri/` + `smithay/` created.
- Unit-tested in scratch repos (apply, no-op on missing dir, fail on re-apply
  to dirty tree, re-apply after reset); all scripts pass `bash -n`.

Wiring check: the losnoco/niri fork's committed `Cargo.toml` carries
`[patch."https://github.com/Smithay/smithay.git"] smithay = { path = "../smithay" }`
(removed in the post-build working tree only because `entrypoint.sh`'s
`sed` trims the manifest for RPM metadata; `sync_repo` + `git checkout Cargo.toml`
restore it before every `cargo build`). `Cargo.lock` lists `smithay` with no
`source` line, confirming the local path patch is what gets compiled — **edits
under `.builder-cache/src/smithay` do reach the binary.**

### 7.2 Smoke test: `smoke-test-spicy.sh`

Nested winit niri + real client inside it (auto-detect
alacritty/foot/kitty/ghostty/konsole; found kitty), 3 open/kill cycles,
readiness gate via PID marker, `NIRI_SOCKET` unset to avoid session IPC
collision, journal via `systemd-cat -t niri-smoke` (no `--user` — unsupported),
raw-log fallback. Currently **passing**: "OK: no compositor GL errors",
exit 0.

Known limitations (by design of the winit path, §4):

1. Single EGL context ⇒ structurally cannot hit the multi-device error.
2. Its journal check filters `-t niri-smoke` ⇒ it does **not** look at session
   compositor errors — even though running it demonstrably *provokes* session
   bursts (the nested window appearing in the session). Watching the whole
   journal during the run window would detect the original bug firing in the
   session; needs care to report nested-vs-session separately (nested must be
   clean; session hits = the known bug, i.e. reproduction).

### 7.3 Standalone EGL experiment: `scratch/egl-sync-test/`

- `egl-sync-test.c`: headerless C (no EGL/GLES headers exist on host or in the
  builder image): dlopens `libEGL.so.1`, resolves `eglGetProcAddress` via
  dlsym, and resolves **all** other EGL entry points (including
  `eglGetPlatformDisplayEXT`, `eglQueryDevicesEXT`) through it — Mesa serves
  extension entry points only via `eglGetProcAddress`, not as dynamic symbols.
- Runs in a throwaway podman container from the `niri-spicy-builder:f44` image:
  `--device /dev/dri/renderD128 --device /dev/dri/renderD129` (SELinux `:z`
  relabel of `/dev/dri` is not permitted), `--entrypoint /bin/bash` (image
  ENTRYPOINT hijacks the command), plus `dnf install -y mesa-libEGL` inside
  (image ships no libEGL.so.1).
- Mesa 26 device displays expose **zero** EGL configs (display advertises
  `EGL_MESA_configless_context`) ⇒ contexts are created configless:
  `eglCreateContext(dpy, EGL_NO_CONFIG, share, attrs)` with ES 3.0 attrs and
  (for the tests that need it) `EGL_CONTEXT_OPENGL_DEBUG=1`.
- Tests:
  - **0**: non-debug context + registered callback + `glBindBuffer` sanity
    check → `cb_count=0` (KHR_debug does NOT fire without the debug bit;
    `glDebugControl(GL_DEBUG_OUTPUT,TRUE)` also did not unblock it).
  - **A**: handle 0 under valid ctx A → errors in `glClientWaitSync` and
    `glWaitSync` (with `GL_TIMEOUT_IGNORED`), silent in `glDeleteSync`.
  - **B** (true cross-device after fixing an early bug where `open_device`
    ignored its index and both displays were device 0): fence created on ctx A
    (device 0), used while ctx B (device 1) is current, callback registered on
    **both** contexts → **exact niri 3-message pattern**; `glIsSync` under
    ctx B = 0.
  - Control: fence created+used on ctx B → `GL_ALREADY_SIGNALED`, no errors.
- Gotchas found along the way: `glClientWaitSync`/`glWaitSync` function-pointer
  timeout param must be `GLuint64` (a 32-bit `EGLint` produced garbage
  0x911d reads); `eglChooseConfig` constants (EGL_RENDERABLE_TYPE=0x3040,
  EGL_NONE terminator=0x3038) verified against Mesa headers; `glGetError` via
  `eglGetProcAddress` returns incoherent values in this setup — the KHR_debug
  callback is the only reliable error channel in the experiment.
- `probe.c` / `probe2.c`: minimal plumbing checks (EGL side healthy —
  `eglMakeCurrent` works, current context/display correct, `eglGetError`
  clean; GL error plumbing via `eglGetProcAddress` broken — invalid calls set
  no GL error and fire no callback, identical on host and container).

## 8. Instrumented build — current state

- **Patch**: `patches/niri-spicy/smithay/0001-instrument-texture-sync.patch`
  captured via `git -C .builder-cache/src/smithay diff`, verified to apply
  cleanly (`git apply --check` against the clean `ce13557` tree).
- What it logs (tagged `[sync-instr]`):
  - On creation: `read`/`write` label, per-texture identity (`tex=0x...`),
    `glFenceSync` handle, **or an explicit `returned NULL` error**, EGL context
    + display pointers.
  - On wait (`wait_for_syncpoint`): if the stored creation-context pointer
    differs from the current one → **error naming both pointers (H2
    discriminator)**, plus handle value.
  - On drop and cleanup `DeleteSync`: handle + owning context.
- **Compile fixes applied** (first build failed with 5 errors):
  - `ffi::egl` does not exist — EGL bindings are `crate::backend::egl::ffi`,
    imported as `ffi_egl` in gles/mod.rs:58 ⇒ `use super::ffi_egl;` in
    texture.rs.
  - `{tex:p}` on a `usize` ⇒ `{tex:#x}`.
  - `self as *const _ as usize` computed while the sync `Mutex` was already
    mutably borrowed ⇒ compute the pointer **before** the lock.
  - **`trace!` is stripped in release builds** — niri's Cargo.toml enables
    tracing `release_max_level_debug` ⇒ creation-success and drop lines bumped
    `trace!` → `debug!` (verified: the first built RPM contained only the
    `error!` strings).
- **RPM built** (12:55 MDT, log `build-instrumented2.log`):
  `dist/niri-26.04.git+15c93f6-1.fc44.x86_64.rpm` — verified to contain **all**
  instrumentation strings (NULL error, mismatch line, drop/queuing lines,
  creation line).
- **RUST_LOG drop-in**:
  `/home/josh/.config/systemd/user/niri.service.d/10-sync-instr.conf` with
  `Environment="RUST_LOG=smithay::backend::renderer::gles::texture=debug"`
  (niri honors RUST_LOG via tracing EnvFilter, main.rs:52).
- **Session confirmed (live)**: user installed the instrumented RPM and
  restarted the session (twice — the second time with the corrected RUST_LOG
  drop-in at `wayland-wm@niri.desktop.service.d/10-sync-instr.conf`, since the
  session runs under `wayland-wm@niri.desktop.service`/uwsm, not `niri.service`).
  The debug-level creation lines (tex= pointer, read/write label) now appear.
  Analysis of session pid 262654: 99 mismatch lines, all on exactly 3 crossing
  textures, each crossing in both directions, per-frame during animations →
  root cause confirmed (§5.4).
- **Gotcha**: the session's systemd unit is `wayland-wm@niri.desktop.service`
  (uwsm), not `niri.service`; journal greps must use
  `journalctl --user -u "wayland-wm@niri.desktop"`, and the RUST_LOG drop-in
  must live under `wayland-wm@niri.desktop.service.d/`.

## 9. Fix design (root cause confirmed — §5.4)

The offscreen buffer must live entirely on one device. Since niri draws it on
the render device's frame, it should be created and bound on the **render**
device.

**Primary fix (smithay `MultiRenderer`) — IMPLEMENTED + VALIDATED**
(`0002-fix-multirenderer-offscreen-routing.patch`): `create_buffer` and
`bind` route to `self.render` (the render device) instead of `self.target`,
adding the constraint that the render device's renderer supports
`Offscreen<Target>` / `Bind<Target>`. This makes the multi-device case
consistent with the single-device case (which already routes to the render
device) and puts the buffer's `GlesTexture` on the device that draws it. All
of its GL fences are then created and consumed under the same per-device
context.

- Validation (2026-09-22, fixed session): **zero** session GL errors, **zero**
  `sync-instr` mismatch lines, **zero** band-aid guard skips (the crossing is
  eliminated, not just guarded), tile open/close animations render correctly,
  `smoke-test-spicy.sh` passes with `SESSION_STRICT=1`.

**Fallback / band-aid (smithay `GlesTexture`)**: track each sync's owning
context; on wait/delete, if the current context differs, re-make-current if it
is the owning renderer's own context, else skip the GL call and leak the fence
(bounded by texture lifetime; no sync is lost since the wait already fails
today). Also add a defensive NULL check on `glFenceSync`. This suppresses the
GL errors without changing which GPU renders the animation, so it is a
stopgap, not the correct fix.

**Not viable**: shared EGL contexts across devices — EGL share groups are
per-display (`eglCreateContext`'s `share_context` must be on the same
`EGLDisplay`), so a single share group spanning both GPUs is impossible.

Optional follow-ups: harden `smoke-test-spicy.sh` (done — it now checks the
session compositor separately, `SESSION_STRICT=1` makes session hits fail),
and chase the non-debug-context KHR_debug puzzle (§6) — e.g. diff Fedora's
Mesa RPM against upstream.

## 10. File reference

| path | relevance |
|---|---|
| `build-lib.sh` | `apply_patches`, `sync_repo` (hard reset each build) |
| `build-rpm-spicy.sh` | pinned refs, calls `apply_patches` |
| `smoke-test-spicy.sh` | nested-compositor smoke test |
| `patches/niri-spicy/` | patch drop dir (`niri/`, `smithay/`, README) |
| `patches/niri-spicy/smithay/0001-instrument-texture-sync.patch` | the instrumentation (verified, built into the 12:55 RPM) |
| `scratch/egl-sync-test/egl-sync-test.c` | standalone H1/H2 experiment (tests 0/A/B/control) |
| `scratch/egl-sync-test/probe.c`, `probe2.c` | GL/EGL plumbing sanity probes |
| `build-instrumented.log`, `build-instrumented2.log` | instrumented build logs (1st failed w/ 5 errors, 2nd OK) |
| `dist/niri-26.04.git+15c93f6-1.fc44.x86_64.rpm` | instrumented RPM, ready to install |
| `/home/josh/.config/systemd/user/niri.service.d/10-sync-instr.conf` | RUST_LOG drop-in for the session |
| `.builder-cache/src/smithay/src/backend/renderer/gles/texture.rs` | `TextureSync`, `wait_for_syncpoint`, unchecked `FenceSync`; instrumentation applied via patch |
| `.builder-cache/src/smithay/src/backend/renderer/gles/mod.rs` | KHR_debug callback (~428-448, registered 637 / unregistered 1801), `Capability::Fencing` (~500), call sites (728/901/949/1043/1094/1120/2448/2881/2998), cleanup `DeleteSync` (322) |
| `.builder-cache/src/smithay/src/backend/renderer/multigpu/gbm.rs:181-189` | per-device, non-shared `EGLContext` creation |
| `.builder-cache/src/smithay/src/backend/egl/context.rs:128,255` | `new_with_priority` (configless, no debug bit); debug bit only with `GlAttributes.debug` |
| `.builder-cache/src/niri/src/backend/tty.rs:1625` | `renderer(primary=dGPU, target=output device)` cross-GPU frame path |
| `.builder-cache/src/niri/src/backend/tty_renderer.rs:672-683` | `TtyGpuManager::renderer` wrapper |
| `.builder-cache/src/niri/src/backend/tty_renderer.rs:743,802-810` | `TtyOffscreen::Gles` + `TtyRenderer::create_buffer` (routes to `MultiRenderer::create_buffer`) |
| `.builder-cache/src/niri/src/render_helpers/texture.rs:286,364` | `UniversalTextureRenderElement` — the `TtyOffscreen::Gles` arm draws a single `GlesTexture` on `frame.as_gles_frame()` (render frame), bypassing per-context routing (the crossing) |
| `.builder-cache/src/smithay/src/backend/renderer/multigpu/mod.rs` | `MultiRenderer::create_buffer`/`bind` route to the **target** device; `MultiFrame.frame` is the **render** device's frame and `as_mut()` returns it |
| `.builder-cache/src/niri/Cargo.toml` | committed `[patch]` wiring local smithay; tracing `release_max_level_debug` (why `trace!` is stripped) |
| `entrypoint.sh` | container build: restore manifest, `cargo build --release`, RPM packaging |
| `/tmp/mesa-mesa-26.2.2` | Mesa 26.2.2 source tarball (syncobj.c, errors.c, debug_output.c, st_manager.c) |
