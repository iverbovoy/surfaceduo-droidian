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
destroyed proxy). The one-line patch acks the `0x0` configure and waits.

Build natively on the device (~2 min):

```
apt install gcc make pkg-config libwayland-dev libxkbcommon-dev libpango1.0-dev libwayland-bin
git clone https://github.com/jjsullivan5196/wvkbd && cd wvkbd
patch -p0 < wvkbd-0.20-wayfire-0x0-configure.patch
make LAYOUT=mobintl        # man page fails without scdoc - harmless
install -m755 wvkbd-mobintl /path/to/repo/out/wvkbd-mobintl-0.20-patched-arm64
```

`build.sh` ships `out/wvkbd-mobintl-0.20-patched-arm64` to
`/usr/local/bin/wvkbd-mobintl` (overriding the 0.15 deb via PATH) when
the file exists, same pattern as `out/wlan.ko`.

## Using the session

Phosh stays the default. Switch over ssh:

```
systemctl stop phosh && systemctl start --job-mode=flush wayfire-duo   # in
systemctl stop wayfire-duo && systemctl start phosh                    # out
```

If wayfire crashed (it segfaults on teardown sometimes), wait ~2 minutes
before starting it again - earlier attempts exit instantly and silently.
Session debug log: `/tmp/wf.log`.

## Known gaps

- wayfire implements no text-input/input-method protocols: squeekboard
  and maliit cannot work, wvkbd (virtual-keyboard protocol) is the only
  OSK route.
- The keyboard spans the hinge; keys near the seam are partially
  swallowed (a split layout is TODO).
- Volume keys are dead at the kernel level on this port (vol-down's PMIC
  RESIN irq fires but qpnp-pon emits no input event; vol-up's PMIC GPIO
  irq never fires) - hence on-screen buttons instead of key bindings.
- No swap-window-between-panels gesture yet; close and reopen instead.
