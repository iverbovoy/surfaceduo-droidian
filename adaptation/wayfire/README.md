# wayfire-duo: dual-screen Wayland session for the Surface Duo 1

An optional alternative to Phosh that treats the Duo as what it is: two
1350x1800 panels with an 84 px hinge between them, not one 2784x1800
slab. Phosh centers everything into the hinge (the lockscreen clock is
literally split by the seam); this session keeps every window on a
single panel.

## Components

| file | installed to | role |
|---|---|---|
| `wayfire-duo.service` | `/usr/lib/systemd/system/` | session unit (Phosh launch recipe: hwcomposer backend, PAM, tty7) |
| `wayfire-duo.ini` | `~droidian/.config/` (via postinst) | wayfire config: output 2784x1800@scale2, autostart |
| `sfduo-tiler` | `/usr/local/sbin/` | hinge-aware auto-tiler (wayfire IPC, python3 stdlib) |
| `sfduo-screens` | `/usr/local/sbin/` | panel power on/off/toggle via sysfs `bl_power` (do NOT use `wlr-randr --off` - disabling the sole output crashes wayfire) |
| `sfduo-powerkey` + `.service` | `/usr/local/sbin/`, systemd | power button = screen toggle; runs only with the wayfire session (Phosh owns the key itself) |
| `sfduo-osk` | `/usr/local/bin/` | launch wvkbd on a single panel (off the hinge); falls back to full-width on an un-patched binary |
| `sfduo-kbd-toggle` | `/usr/local/bin/` | show/hide the wvkbd on-screen keyboard |
| `sfduo-launcher-toggle` | `/usr/local/bin/` | open/close the fuzzel launcher |
| `waybar-config.jsonc` + `waybar-style.css` | `~droidian/.config/waybar/` | top bar on the LEFT panel: apps, kbd, clock, wifi, battery |
| `fuzzel.ini` | `~droidian/.config/fuzzel/` | launcher anchored to the left panel |
| `wvkbd-0.20-...-configure.patch` | (build-time) | REQUIRED wvkbd fix, see below |

## The tiler

Zones in logical coordinates (scale 2): left panel `[0,675]`, hinge
`[675,717]` (84 physical px of nothing), right panel `[717,1392]`.
Every new window goes to the emptier panel; any window that later
covers the hinge (self-maximizing apps, fullscreen requests) is
re-snapped to its nearest panel within half a second. Watch it work:
`tail -f ~droidian/.cache/sfduo-tiler.log`.

## wvkbd must be patched

Debian's wvkbd 0.15 segfaults under wayfire ("Resize 0x0") and upstream
0.20 silently never draws: wayfire sends an initial `0x0` layer-surface
configure before the real one, upstream treats it as a size mismatch and
recreates the surface forever (the real configure always arrives at a
destroyed proxy). The first patch acks the `0x0` configure and waits.

A second patch (`wvkbd-0.20-single-panel.patch`) adds a `-w WIDTH`
option: instead of anchoring left+right+bottom (full 1392 px, straddling
the hinge), it requests a fixed width anchored to one side, so the OSK
sits on a single panel. `sfduo-osk` passes `-w 675 -non-exclusive` (add
`--panel-right` to move it to the right panel). Both options are
additive - a binary built without them is untouched, and `sfduo-osk`
probes for `-w` support before using it, so an un-rebuilt OSK keeps the
old full-width behaviour.

`-non-exclusive` is mandatory with `-w`: the surface is then anchored to
2 edges, and wayfire supports layer-shell exclusive zones only for 1- or
3-edge anchors - with an exclusive zone set it refuses to arrange the
surface AT ALL, so the keyboard runs but never shows (found the hard
way; the only symptom is `Unsupported: layer-shell exclusive zone for
surfaces anchored to 0, 2 or 4 edges` in `/tmp/wf.log`).

Build natively on the device (~2 min):

```
apt install gcc make pkg-config libwayland-dev libxkbcommon-dev libpango1.0-dev libwayland-bin
git clone https://github.com/jjsullivan5196/wvkbd && cd wvkbd
patch -p0 < wvkbd-0.20-wayfire-0x0-configure.patch
patch -p0 < wvkbd-0.20-single-panel.patch      # single-panel -w option
make LAYOUT=mobintl        # man page fails without scdoc - harmless
install -m755 wvkbd-mobintl /path/to/repo/out/wvkbd-mobintl-0.20-patched-arm64
```

`build.sh` ships `out/wvkbd-mobintl-0.20-patched-arm64` to
`/usr/local/bin/wvkbd-mobintl` (overriding the 0.15 deb via PATH) when
the file exists, same pattern as `out/wlan.ko`. Until you rebuild with
the single-panel patch the keyboard still works, just full-width.

## Using the session

Phosh stays the default. Switch over ssh - **and restart the vendor
composer HAL between sessions**:

```
systemctl stop phosh                     # or wayfire-duo
pkill -f 'composer@2[.]4-service'        # android init respawns it in ~5 s
sleep 10
systemctl start wayfire-duo              # or phosh
```

Why: the composer HAL keeps per-client display state that goes stale
when a compositor exits uncleanly (wayfire segfaults on teardown). The
next session then starts "active" but every frame fails with
`prepare: validate failed for display 0: 2` (BAD_DISPLAY) in
`/tmp/wf.log` - system alive, ssh fine, screens black, power button
dead. A composer restart right before the session start fixes it
deterministically; the old "wait ~2 minutes" advice only sometimes let
the state recover on its own. (Note the `[.]` in the pkill pattern -
without it pkill matches your own ssh shell and kills the session.)

Instant silent unit exits right after a previous session stopped are the
same disease. Session debug log: `/tmp/wf.log`.

## Known gaps

- wayfire implements no text-input/input-method protocols: squeekboard
  and maliit cannot work, wvkbd (virtual-keyboard protocol) is the only
  OSK route.
- The keyboard sits on the left panel (`sfduo-osk -w 675`), off the
  hinge. A true split layout (left-half keys on the left panel, right-half
  on the right, thumbs on both) is still TODO - it needs wvkbd layout
  surgery, not just a width, so single-panel is the shipped answer.
- Because of the forced `-non-exclusive` (see above), windows do not
  auto-shrink above the OSK - it overlays their bottom 260 px.
- The power button toggles the screens via `sfduo-powerkey` (short
  press; long-press PMIC hard-reset untouched). It does NOT lock or
  suspend - fold-to-sleep remains the suspend path. If the panels look
  dead anyway, check ssh before assuming a freeze - and see the
  composer-restart note.
- Volume keys are dead at the kernel level on this port (vol-down's PMIC
  RESIN irq fires but qpnp-pon emits no input event; vol-up's PMIC GPIO
  irq never fires) - hence on-screen buttons instead of key bindings.
- No swap-window-between-panels gesture yet; close and reopen instead.
