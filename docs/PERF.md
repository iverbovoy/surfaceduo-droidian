# Where the time goes: the shell's animations on this device

Measured on 2026-09-18 on the perf kernel, screen on, `schedutil`. What
the port's shell (the dock, its grid, the launch curtain) costs per frame,
where the cost turned out to be, and what would and would not help. The
question that started it was "would Rust make this faster"; the answer is
at the end.

## What was measured

- A frame of the dock's grid sliding up, first version (one GTK3 window
  across both panels, the grid scrolled into view): **57-130 ms**, 8-17 fps.
- The same with the grid as its own layer surface moved by its margin
  through gtk-layer-shell: no better - every `set_margin` made GTK repaint
  the window.
- The same with the margin sent straight to the compositor (a
  `zwlr_layer_surface_v1.set_margin` + `wl_surface.commit`, no buffer
  attached): **16-17 ms**, 60 fps.
- The dock's strip crossing to the other panel as a cross-fade (opacity per
  frame, whole-window repaint): 42-100 ms per frame. As a dip below the
  screen edge and back, with the buttons swapped while nothing is visible
  (two margin slides, one repaint): 18-29 ms. As two windows, one per half
  of the dock, sliding in a straight line to where they are next wanted
  (margin slides only, nothing repainted): **16 ms**, every frame, measured
  on every kind of crossing.

## Where the time was

`perf` on the dock while it animated: 56 % in pixman (cairo's software
rasteriser painting the window at scale 3), 23 % in the kernel copying the
buffer, 3 % in Python. `perf` on phoc during the same animation: 57 % in
`libGLESv2_adreno.so` - the GL driver copying the client's shared-memory
buffer into a texture, on the CPU, for every buffer a client commits.

So one frame of an animated GTK3 window costs, on this device:

1. the client repainting the window (cairo/pixman, CPU, ~proportional to
   pixels: a 1113x688 logical window at scale 3 is 3 Mpx and 27 MB);
2. the compositor copying that buffer into a texture through hybris
   (~30-40 ms per surface committed, almost regardless of its size - a
   3.4 MB strip cost about what a 27 MB stage did);
3. and the frame clock: GDK only advances a window's frame clock when the
   compositor sends it a frame callback, and a surface that has slid below
   the screen edge is not drawn and gets none - an animation driven by that
   window's tick callback stalls.

### The texture upload, measured twice

A small GLES program on the device (`glTexSubImage2D` into a 3339x2160
BGRA texture - a phosh buffer at scale 3 - best of four, `glFinish`
included) first said that partial uploads were pathological on this
driver: a band of 1080 rows took 101 ms against 9.5 ms for the whole
texture, and a wlroots patch to upload whole textures was on the way. Then
the governor turned out to be `powersave` while it was measured. The same
binary with `schedutil`:

| upload | `powersave` | `schedutil` |
|---|---|---|
| whole texture, 27 MB | 9.5 ms | 5.6 ms |
| band of 1080 rows | 101 ms | 6.0 ms |
| the same with `ROW_LENGTH` + `SKIP_ROWS`, as wlroots does it | - | 2.9 ms |
| band of 100 rows | 3.8 ms | 0.2 ms |
| rectangle 540x688 | 13.4 ms | 0.3 ms |
| rectangle 84x1113 (a dock column) | - | 0.1 ms |
| whole texture right after the GPU drew from it | 24.4 ms | 4.6 ms |
| whole texture at output scale 2 (2226x1440) | - | 3.0 ms |

The partial path is CPU work in the driver, and at 576 MHz it is seventeen
times slower; at full clocks damage-sized uploads cost well under a
millisecond and wlroots' per-rectangle update is the right one. Nothing to
patch. The "30-40 ms per surface committed" in point 2 above comes from the
same afternoon and is due a re-measure with the governor checked first.

### The lock screen, measured

The unlock swipe is the first animation a user sees. Measured 2026-09-18 on
the perf kernel, screen on, `schedutil` verified: the lock screen locked with
`loginctl lock-session`, a 2 s swipe up from the synthetic finger
(`tools/sfduo-touch`), phosh's frames counted from its `sendmsg` calls
(`strace -tt -e trace=sendmsg`, one per frame flushed to the compositor),
`perf record` on phosh and phoc during the same swipe.

| output scale | phosh buffer | frames per 200 ms | frame gap median | p90 |
| --- | --- | --- | --- | --- |
| 2.5 (GTK3 renders at 3) | 3339x2160, 27 MB | 8 | 24.5 ms | 32 ms |
| 2 | 2226x1440, 12 MB | 11-12 | 17 ms | 22 ms |

Where the time goes at 2.5: **78 % of phosh's CPU in pixman** - `cairo_paint`
blitting the carousel's pages (libhandy snapshots each page to a surface and
paints it per frame; at 27 MB a page that is the frame), 11 % kernel (the
copy into the shm buffer); phoc meanwhile 17 % in the GL driver's upload
and 46 % in the vendor libraries behind it. Nothing of this is the dock's.
So the lock screen at 2.5 runs at 40 fps and at 2 at 55-60: a GTK3 surface
across both panels costs what its pixels cost, and 2.5 rounds up to 3.

Ways out, for the decision (#40, #48): ship scale 2 (everything GTK3 2.25x
cheaper, elements 20 % smaller than at 2.5); or keep 2.5 and make the lock
screen's surface one panel wide by a phosh patch (its content already sits
on one panel by CSS; the other panel would be a cheap black layer); or
accept 40 fps there.

Two more things that looked like slowness and were not the shell's:

- the CPU governor. `mobile-power-saver` starts in its screen-off state and
  puts every core on `powersave` (576-826 MHz) until the screen has been
  cycled; with idle blanking off that was the whole session. Launching
  Calculator took 8-14 s that way and 2 s otherwise. And not only at boot:
  the saver's `StopDozing` method restarts its dozing cycle without looking
  at the screen, and headphone-manager calls it on every headset-jack event
  - which on the Duo is every USB-C plug. From then on every core sits on
  `powersave` for 300 s out of every 330 s, screen on, until the next
  screen-off/on. `sfduo-cpufreq.service` watches the whole session and puts
  `schedutil` back whenever the screen is on and the governor says
  otherwise. Read `scaling_governor` before believing any measurement.
- Microsoft's debug kernel config, which had been blamed for most of the
  above and costs about 2.4x on process creation and 2x on boot, not the
  15x that was measured with the screen off.

## What follows for the shell

Animate by moving surfaces, not by repainting them. A surface whose pixels
do not change costs the compositor nothing to move; a surface repainted per
frame costs 30-40 ms whatever its size. Hence: one layer surface per thing
that moves (the grid of each panel, the curtain of each panel, the dock's
strip), margins sent straight to the compositor during a slide, GTK's own
API only for the resting states, and animations on a timer rather than the
window's frame clock. That is the shape the dock has since 0.15.2, and it
is what phosh itself does with its sliding surfaces.

Repaints that remain (the strip's buttons swapping, the grid's running
dots) are single frames and do not matter.

## Would Rust help

Not here. Python is 3 % of the dock's profile; the other 97 % is cairo,
pixman, the kernel and the GL driver, all C, all reached the same way from
any language. Rewriting the dock in Rust with the same toolkit (GTK3 via
gtk-rs) would render the same pixels through the same cairo into the same
shared-memory buffers and hand them to the same driver. The two things that
would change the picture are architectural, not linguistic:

- **Rendering on the GPU**, so the client's buffers are GPU buffers
  (dmabuf) and the compositor composites them without a copy. GTK4's GL
  renderer does this; the session already runs GTK4 applications with
  `GSK_RENDERER=gl` through hybris. Moving the dock to GTK4 (Python stays,
  `gtk4-layer-shell` is packaged) is the experiment worth running - with
  the caveat that a bare GTK4 test window with the GL renderer did not map
  in a first attempt outside the session's environment, so this is not yet
  shown to work for a layer-shell client.
- **Fewer, smaller surfaces that move rather than change**, which is done.

Where Rust would be the right tool is code that is CPU-bound in Python
itself: none of the port's is. The dock's per-frame Python is a few
arithmetic operations and one protocol request.
