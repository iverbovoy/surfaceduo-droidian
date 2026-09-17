# System pieces the device needs

Small files that belong to the port rather than to any application on it.
Each was found necessary on hardware; none is optional.

```
sfduo-slot-guard.service   /etc/systemd/system/          mark the boot good, pin slot A
50-sfduo-lid.conf          /etc/systemd/logind.conf.d/   closing the device locks it
sfduo-screens              /usr/local/sbin/              panel power without the compositor
50-sfduo-screens           /etc/sudoers.d/               the session may run the above
```

## The slot guard

The Duo has A/B slots and a bootloader that counts failed boots. Nothing in
Droidian marks a boot successful on this device, so after enough boots the
bootloader concludes the slot is broken and switches to the other one -
which has nothing bootable in it, and the device lands in fastboot. That is
the "slot-b drift" the SAFETY protocol talks about.

The unit runs after the Android container is up (the bootctrl HAL lives
there) and calls `android_bootctl mark-boot-successful` and
`set-active-boot-slot 0`. It needs `/var/lib/droidian/lxc_attach_workaround`
to exist on this device, or `lxc-attach` silently eats the last argument and
the call does nothing - the failure that caused the drift in the first place.

```
install -m644 sfduo-slot-guard.service /etc/systemd/system/
systemctl enable sfduo-slot-guard.service
```

## Closing the device locks it

The hinge has a hall sensor and it shows up as a lid switch
(`Surface Duo Lid Switch`, `SW_LID`), so logind sees every fold. What it does
about it is `HandleLidSwitch*`. The port's status table records fold-to-sleep
working through this switch; on the device as it is today suspend is turned
off in the session (`sm.puri.phosh enable-suspend` is `false`), so the policy
here is lock - on battery, on power and docked alike. To have the fold
suspend again, turn that setting on and set the three keys to `suspend`.

Two things worth knowing about the mechanics:

- Drop-ins in `logind.conf.d` apply in name order and the last one wins. A
  file that sorts later and says `ignore` silently takes the lock away, on
  battery only, and the device then folds and unfolds straight back to the
  desktop. That is what it looked like when another project's drop-in was
  still installed.
- `systemctl kill -s HUP systemd-logind` reloads the config without a
  restart. It may drop an ssh session in passing; the shell survives.

Once locked, the fingerprint sensor on the power key unlocks it the moment a
finger rests there - which, on a device you hold by that edge, is the moment
you open it. It can look as if the lock screen never came.

## Panel power

`sfduo-screens off|on|toggle` drives `bl_power` on the two panel backlights,
the same path the system uses. It exists because `wlr-randr --off` on the
sole `HWCOMPOSER-1` output crashed the compositor of the day. Brightness
survives a cycle; rendering continues underneath.
