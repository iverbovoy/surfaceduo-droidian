# Safety protocol - read before touching your Duo

The Surface Duo 1 has **no public EDL (emergency download) loader**.
If the bootloader chain stops accepting images, no software can revive
the device - chip-off UFS reprogramming is the only remaining path.
This failure mode is real, not theoretical. Every rule below exists
because of it.

## The golden rules

1. **RAM-boot only** (`fastboot boot`) until an image has proven itself
   across many boring cycles. Flashing (`fastboot flash boot_x`) comes
   last, to the *inactive* slot first.
2. **One change per boot cycle.** New kernel? Stock DTB. New DTB? Old
   kernel. When something dies you must know exactly what killed it.
3. **One RAM-boot attempt per crashed image.** Never re-try a crashed
   kernel "to see if it repeats" - see the per-slot wedge below.
4. Battery ≥ 50 % before a session, ≥ 20 % for any boot attempt.
5. Keep TWRP at hand (RAM-boot it, never flash it). It is the universal
   safe diagnostic: full shell, adb, all partitions.
6. Use `tools/flash-safely.sh` for every device interaction. It encodes
   all of this: offline image validation before anything touches the
   device, per-serial attempt counters, health baselines, battery gates,
   brick-signature detection.

## The three known failure mechanisms

### 1. BCB poison (reversible - but only if you know it exists)

If stock Android ever **normal-boots while a foreign rootfs sits on
userdata**, its init fails (`init_user0_failed`) and writes
`boot-recovery --prompt_and_wipe_data` into the misc partition's
Bootloader Control Block. While that BCB pends, ABL rejects *all* boot
images on *both* slots ("Failed to load/authenticate boot image: Device
Error" on `fastboot boot`, "Failed to load image from partition" on
`continue`). Slot counters stay pristine. A cold power-cycle does NOT
clear it. It looks exactly like a brick.

**Cure**: RAM-boot TWRP, zero the first 2 KB of misc (LUN 0 - safe):
`dd if=/dev/zero of=/dev/block/platform/soc/1d84000.ufshc/by-name/misc bs=2048 count=1`

**Prevention - the parking brake**: before any risky step, flash a
one-shot `bootonce-bootloader` BCB into misc (2 KB image, the string at
offset 0, zeros elsewhere - `tools/make-misc-brake.sh` creates it). If
the device resets unattended, ABL consumes the flag and parks in
fastboot instead of letting stock boot into the poison scenario. Note the Duo auto-boots when a charger is
attached (`off-mode-charge=0`) - the brake is not optional.

**What the brake does not do** (measured 2026-09-16): it does not stop a
*deliberate* reboot. `bootonce-bootloader` was written to `misc` from the
running Droidian, verified byte for byte, and `systemctl reboot` walked
straight past it into Droidian, leaving the command in `misc` unconsumed.
Its job is the unattended reset; do not rely on it to reach fastboot on
demand. For that, ask the kernel the way Android does - the reboot
syscall with `"bootloader"` as its argument:

```
python3 -c 'import ctypes; l=ctypes.CDLL("libc.so.6"); l.sync();
l.syscall(142, 0xfee1dead, 672274793, 0xA1B2C3D4, b"bootloader")'
```

(`__NR_reboot` is 142 on aarch64; `0xA1B2C3D4` is `LINUX_REBOOT_CMD_RESTART2`.)
The device lands in fastboot within about thirty seconds.

### 2. Per-slot RAM-boot wedge

After a crashed RAM-boot, the *current slot* may start rejecting ALL
RAM-boots - including a previously-working TWRP - with "Device Error".
`fastboot erase misc` does not clear it; cold power-cycles do not clear
it; getvars stay pristine. `fastboot set_active <other>` → the other
slot boots fine.

This is why rule 3 exists: consecutive crash-retries can wedge both
slots, and a device with both slots wedged is indistinguishable from
a permanently dead one.

Also note: TWRP sessions / reboots tend to flip the active slot -
**verify `fastboot getvar current-slot` before every RAM-boot.**

### 3. The unrecoverable state (what an actual brick looks like)

On the dead unit behind this document, LUN 4 partition *content* never
loads (GPT is readable, content access fails) on both slots, with both
stock and TWRP images, before and after misc/metadata hygiene. If you
reach a state
where the wedge does not clear by switching slots and clean misc does
not help - STOP. Do not cycle lock/unlock. Do not flash anything.
Collect getvar output and ask the community first.

## Practical cadence that works (per boot cycle)

```
fastboot getvar current-slot          # verify - it flips on its own!
fastboot set_active a                 # your known-good RAM-boot slot
fastboot erase misc
fastboot flash misc misc-brake.img    # re-arm the parking brake
./tools/flash-safely.sh ram-boot <image>
# ... session ...
# the moment the device lands back in fastboot: re-arm the brake FIRST
```

## If flashing is attempted anyway: three confusing behaviours

Rule 1 stands: RAM-boot is the only mode this port recommends, and
nothing below is an invitation to flash. But flashing does get
attempted eventually, and these three behaviours cost real time to
work out. Meeting them for the first time mid-session, on a device
with no EDL escape, is the wrong moment to start guessing.

**`fastboot flash boot_a` can answer "Device Error" and write
nothing.** This is not a bad image and not a lock problem: the
bootloader on this device can refuse to write that UFS LUN at all.
The same image written with `dd` from a booted system goes in without
complaint. Reading the fastboot failure as "the image must be broken"
and rebuilding images from scratch is chasing a ghost.

**A flashed boot has to satisfy AVB; a RAM-booted one does not.**
`fastboot boot` bypasses verification entirely, so an image that
RAM-boots perfectly well can refuse to boot once flashed, with vbmeta
left untouched. That gap makes a clean RAM-boot a weaker proof than it
feels like.

**The active slot can drift back on its own.** Two non-obvious causes.
First, `lxc-attach` on this device swallows the last argument, so every
`bootctl` call made through it silently receives an empty command and
does nothing at all; `touch /var/lib/droidian/lxc_attach_workaround`
restores it. Second, the bootloader takes its slot from the vendor
bootctrl HAL's own storage rather than from `fastboot set_active`, so a
slot chosen in fastboot can be quietly overruled on the next boot.
Verify `fastboot getvar current-slot` instead of assuming.

## Bootloader facts that save time

- "Device critical unlocked: false" while `flashing unlock` says
  "already unlocked" is NORMAL on bootloader 2022.815.527 - critical
  unlock is neither needed nor used by this port.
- WOA flashes boot from **fastbootd** (userspace, inside recovery), not
  the bootloader fastboot. Partition `userdata` = `/dev/block/sda6`.
- Stock boot images RAM-boot fine - that is your recovery-escape proof
  before any experiments.
