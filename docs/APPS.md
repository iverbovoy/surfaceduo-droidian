# Writing an application for this screen

What the first app built for this port had to learn about the device, so the
next one does not. Everything here was measured on hardware in September
2026; the app itself (a cell simulation in a fullscreen WebKitGTK shell) is a
separate, private repository, but none of this is about that app.

## The screen is one output with a hole in the middle

Phosh presents both panels as a single output:

```
output    HWCOMPOSER-1, 2784x1800 @ 60 Hz, phoc scale 2.5  ->  1113x720 logical
panels    two 1350x1800 DSI, side by side across the long edge
hinge     84 physical pixels between them: addressable, and physically hidden
zones     left [0,540]   seam [540,573]   right [573,1113]   (logical, scale 2.5)
```

The scale is the port's choice (`/etc/phosh/phoc.ini`, since 0.14.1; before
that Droidian's generic 3, which made the output 928x600 with the seam at
[450, 478]). A user can change it, so an app should derive the zones from
the output it is given, not from these numbers: the seam is the middle
84/2784 of the span, whatever the span is in logical pixels.

The compositor will not route around the seam. An app that keeps its content
out of it gets two clean pages; one that centres itself puts its middle under
the bezel. Nothing more is needed than that arithmetic - two pages, a dead
column between them - and it turned out that a desktop layout becomes a
two-page one by moving three elements, without touching anything that draws.

**Fullscreen or nothing.** The phosh panel (32 logical px) and home bar take
their strip off the top and bottom of the 720. A `.desktop` launch that
calls `fullscreen()` gets it all.

**Rotation.** Rotate the device and the logical output becomes 720x1113; the
panels are now one above the other and the seam is a horizontal band. Compute
the seam as a *fraction of the span* (84/2784), not as 84 divided by GTK's
scale factor - rotated, GTK reported a scale of 5 where the output is scaled
by 3, which narrowed the seam to 17 px and pushed the split 6 px off. And
recompute on every surface layout and monitor change; computing once at load
was wrong the moment the device turned. GdkSurface's `layout` signal fires
every frame, so compare the size it carries before doing any work.

**Posture** comes from sensorfw after the hinge patch in this repo: the
angle is live over DBus and a push socket (`/run/sensord.sock`). Band it with
hysteresis and send it to the page no faster than about twice a second;
reacting per degree makes both panels blink.

## Launching: the environment is not optional

Start the app with the session's environment. Launched with a bare `env`, a
GTK/WebKit app loses `LD_PRELOAD=libtls-padding.so` (and `EGL_PLATFORM=wayland`,
`GDK_GL=gles`, `GSK_RENDERER=gl`); hybris then cannot find Android's
`libEGL.so`, GL falls to software, memory climbs from 2.7 GB to 4.1 GB and the
web process dies with a grey screen and no error. A `.desktop` launch inherits
it; a systemd unit or a script with a clean environment does not. From a
shell, `mapfile -d "" -t E < /proc/$(pgrep -x phosh)/environ` and
`env -i "${E[@]}" ...` reproduces a session launch exactly.

## GL: glvnd only knows mesa

`/usr/share/glvnd/egl_vendor.d/` registers only mesa, and mesa has no driver
for this kernel, so any client that asks glvnd for EGL is rasterised in
software - `llvmpipe` threads - even with `libEGL_adreno.so` already mapped
into the process. WebKitGTK's WebGL is such a client. Point glvnd at hybris:

```
{ "file_format_version" : "1.0.0", "ICD" : { "library_path" : "libEGL_libhybris.so.0" } }
__EGL_VENDOR_LIBRARY_FILENAMES=/path/to/that.json <app>
```

Eight llvmpipe threads become none and rendering stays correct. WebKit's
dmabuf renderer stays disabled as the session has it: with mesa it measured
3x worse, with hybris it is indistinguishable from shared memory.

**Not yet done, on purpose:** shipping that JSON system-wide in
`/usr/share/glvnd/egl_vendor.d/` from the adaptation package, so every GL
client gets the GPU without asking. It is the right end state, but a global
ICD is picked up by every glvnd client - phosh, droidian-camera, everything -
and each of them has to be checked afterwards. Until then an app passes
`__EGL_VENDOR_LIBRARY_FILENAMES` itself.

## Touch, as WebKit delivers it

- Touch arrives as **touch events**, not pointer events: 797 `touchmove` to
  10 `pointermove` in one session. A view written for pointer events hears
  almost nothing.
- `navigator.maxTouchPoints` is **0** while two simultaneous touches arrive
  perfectly well. Do not feature-detect on it.
- A pinch does two things unless stopped: WebKit zooms the whole page (both
  panels, hinge and all - `visualViewport.scale` went to 1.08) *and*
  synthesises wheel events. `preventDefault` on the touch events in the
  capture phase stops both; translate the gesture yourself.
- 3 px is a tap threshold only a mouse can keep; a finger needs about 12.
- Anything under 40 logical px is under 6 mm on this panel.

## The cost of a frame

Every update a page makes costs this stack a fixed amount, and the amount is
not about pixels. Measured with a WebKitGTK app's two processes:

- a page that changes nothing: 0%
- an `requestAnimationFrame` loop that draws nothing: 3-8%
- a 60 px box spinning in CSS: **a whole core**
- window at a quarter of the area, canvas at a ninth of the pixels, 2D canvas
  instead of WebGL, four cells instead of sixteen: **no difference**

After each update the window process keeps rendering at 60 Hz for about half a
second, allocating a buffer per frame (page faults and `munmap` dominate its
profile), then idles. Updates closer together than that keep it at 70% of a
core without pause; sweeping the update period gave 117% total at 200 ms,
89% at 500 ms, 66% at 700 ms, 48% at 1000 ms. So: one clock for everything
that draws, resting slow and quickening under a finger, and nothing redrawn
that has not changed.

Two things that are free on a desktop GPU and are not here: a `box-shadow`
with a soft edge (Skia blurs it on the CPU on every repaint of what is under
it - half a core for a 30 px shadow over a live canvas) and a CSS gradient
background behind a changing surface (re-rasterised on every paint).

## Profiling: it works, and there are symbols

`linux-perf` (6.12) runs against this 4.14 kernel; set
`/proc/sys/kernel/perf_event_paranoid` to 1 and `kptr_restrict` to 0 for the
session and restore them after. Debug symbols: Droidian rebuilds Debian's
packages **reproducibly** - `libwebkitgtk-6.0.so.4.11.8` matched Debian's
2.48.3-1 arm64 build byte for byte - so Debian's `-dbgsym` fits the phone's
binary exactly. `debuginfod.debian.net` did not serve that build-id, but
`snapshot.debian.org`'s `/mr/binary/<pkg>/<version>/binfiles` API finds the
file (100 MB for WebKit, not the gigabyte one fears), and `perf report
--symfs` on the desk resolves everything. JavaScriptCore has its own sampling
profiler (`JSC_useSamplingProfiler=1 JSC_samplingProfilerPath=<dir>`); the
directory must be writable by the session user or WebKit aborts on an
assertion.

Three traps that each cost hours: the phone goes from 40 °C to 62 °C in
fifteen seconds and a hot core reports a higher %CPU for the same work, so no
comparison is valid without a cooldown between runs; a dev server that sends
no `Cache-Control` lets WebKit keep serving the old bundle after a rebuild,
so a fix can measure as a no-op that never ran; and `grim` needs the output
awake (`wlr-randr --output HWCOMPOSER-1 --on`) or fails with "failed to copy
output".
