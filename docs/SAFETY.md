# Safety protocol - read before touching your Duo

The Surface Duo 1 has **no public EDL (emergency download) loader**.
If the bootloader chain stops accepting images, no software can revive
the device - chip-off UFS reprogramming is the only remaining path. One
of our units is a permanent brick for exactly this reason. Every rule
below was paid for.

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

## The three failure mechanisms we know

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

### 2. Per-slot RAM-boot wedge

After a crashed RAM-boot, the *current slot* may start rejecting ALL
RAM-boots - including a previously-working TWRP - with "Device Error".
`fastboot erase misc` does not clear it; cold power-cycles do not clear
it; getvars stay pristine. `fastboot set_active <other>` → the other
slot boots fine.

This is why rule 3 exists: consecutive crash-retries can wedge both
slots, and a device with both slots wedged is indistinguishable from
our permanently dead unit.

Also note: TWRP sessions / reboots tend to flip the active slot -
**verify `fastboot getvar current-slot` before every RAM-boot.**

### 3. The unrecoverable state (what an actual brick looks like)

On our dead unit, LUN 4 partition *content* never loads (GPT is
readable, content access fails) on both slots, with both stock and TWRP
images, before and after misc/metadata hygiene. If you reach a state
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

## Bootloader facts that save time

- "Device critical unlocked: false" while `flashing unlock` says
  "already unlocked" is NORMAL on bootloader 2022.815.527 - critical
  unlock is neither needed nor used by this port.
- WOA flashes boot from **fastbootd** (userspace, inside recovery), not
  the bootloader fastboot. Partition `userdata` = `/dev/block/sda6`.
- Stock boot images RAM-boot fine - that is your recovery-escape proof
  before any experiments.
