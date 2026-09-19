# System pieces the device needs

Small files that belong to the port rather than to any application on it.
Each was found necessary on hardware; none is optional.

Since 0.13 the adaptation package installs all of them except the sudoers
rule (units go to `/usr/lib/systemd/system/` there); the paths below are for
installing by hand.

```
sfduo-slot-guard.service   /etc/systemd/system/          mark the boot good, pin slot A
sfduo-modem.service        /etc/systemd/system/          the modem online and on LTE, every boot
sfduo-modem                /usr/local/sbin/              ...the script it runs
50-sfduo-lid.conf          /etc/systemd/logind.conf.d/   closing the device locks it
sfduo-screens              /usr/local/sbin/              panel power without the compositor
50-sfduo-screens           /etc/sudoers.d/               the session may run the above
dconf/50-sfduo-phoc        /etc/dconf/db/local.d/        windows tile, they do not fill the display
dconf/locks/50-sfduo-phoc  /etc/dconf/db/local.d/locks/  ...and phosh cannot change that back
dconf/profile-user         /etc/dconf/profile/user       makes the system database count
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

## The modem comes up offline, and on 3G

Measured on two consecutive boots with the SIM in (2026-09-17): ofono leaves
`/ril_0` at `Online=false`, ModemManager probes it in that state, marks it
`failed` and never looks again - the shell shows no SIM at all. And when it is
put online by hand, `TechnologyPreference` is `umts` although
`AvailableTechnologies` lists `lte`: 3G gave signal 37 and 170-650 ms pings
where LTE gives 77-87 and 70-90 ms. Every install of this port therefore
looks like "the modem does not work", then like "LTE does not work".

`sfduo-modem` waits for ofono's modem, sets `Online`, prefers `lte` if the
modem offers it, and restarts ModemManager if it had already given up.
ofono does store the preference (`/var/lib/ofono/<imsi>/radiosetting`), and
once it has been set it came back as `lte` on the next boot - but only after
something put the modem online, so the unit does both.

```
install -m755 sfduo-modem /usr/local/sbin/
install -m644 sfduo-modem.service /etc/systemd/system/
systemctl enable sfduo-modem.service
```

Mobile data is one line, and needs nothing else - its route metric lands at
700 against wifi's 600, so wifi stays preferred:

```
nmcli c add type gsm ifname '*' con-name <name> apn <apn>
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

Who arms the reader matters. Droidian's `fpd-unlockd` asks droidian-fpd to
listen only when logind's `IdleHint` goes from idle to active, and the
idle-delay of 0 below (0.14.1) means the session is never idle: the reader
listened once, when `fpd-unlockd` started, the daemon gave that attempt up
after its 30 seconds, and every later lock had nobody listening - the finger
did nothing and the enrolment looked broken. `sfduo-fingerprint` (in
`../shell`) arms it on what the screen shows instead: locked and lit. It
listens again after each timeout or unknown finger, lets go when the screen
goes dark or the phone is unlocked another way, and buzzes - 150 ms on an
unlock, 100 ms for a finger it does not know; `fpd-unlockd`'s buzz was 12 ms
and went unnoticed. droidian-fpd serves one client at a time, so the package
masks `fpd-unlockd` with a link to `/dev/null` in `/etc/systemd/user`.

A finger is enrolled from the settings (`droidian-fpd-gui` and
`droidian-fpd-client` from the archive cannot be installed: both need
`libbatman-wrappers`, which rolling no longer carries).

## An open device stays on

Since 0.14.1 the screen does not blank and lock on its own
(`dconf/52-sfduo-idle`: `org.gnome.desktop.session idle-delay` is 0, a
default a user's own value overrides). An open Duo on a desk is being looked
at, and closing it is how it is put away; the backlight still dims after a
short idle (`idle-dim`, to 30 %), and the power button locks as before.

There is a second reason, found while measuring the kernel: Droidian's
`mobile-power-saver` ties its hard saving to the blanked screen - the CPU
governor goes to `powersave` (every core at its lowest clock: 576 MHz on the
little ones, 826 MHz on the big one, of 2.8 GHz) and processes are frozen.
Anything measured over ssh with the screen off measures that, not the
system: a root login that starts a user manager took 20 s that way and
1.5 s with the screen on, `systemctl daemon-reload` 7 s against 1.7 s. With
idle blanking off an open device runs at full speed; Droidian already has
idle suspend on battery off (`sleep-inactive-battery-type` is `nothing`).

And a third: at boot the screen is off until phosh has drawn, so the saver
starts in its off state, and the first "on" never reaches it - the device
runs at its lowest clocks until the screen has been turned off and on once
by hand. Measured 2026-09-18 on the debug kernel: `daemon-reload` 30 s that
way, 2.2 s after a screen cycle; a root login 26 s against 2 s. The
"debug kernel" numbers that had been going around were mostly this. Since
0.15.1 `sfduo-cpufreq.service` waits for the shell and sets `schedutil`
once; the saver keeps toggling on screen events after that.

## Panel power

`sfduo-screens off|on|toggle` drives `bl_power` on the two panel backlights,
the same path the system uses. It exists because `wlr-randr --off` on the
sole `HWCOMPOSER-1` output crashed the compositor of the day. Brightness
survives a cycle; rendering continues underneath.

## Windows tile; phosh would rather they did not

phoc tiles a window to half the output on `<Super>Left` / `<Super>Right`,
which is how the dock puts an application on one panel. That only works
while `sm.puri.phoc auto-maximize` is off, and phosh turns it on again on
every start unless it decides the device is docked - an external monitor or
keyboard. Setting it with `gsettings` therefore holds until the next
restart of the shell, which is how every application came to open across
both panels again one afternoon with nothing in the dock changed.

The system dconf database is the way to say it for good: a default in
`/etc/dconf/db/local.d/` and a lock on the key in `locks/`, compiled with
`dconf update` (`dconf-cli` is not installed by default). A locked key is
not writable by anyone in the session, phosh included - `gsettings set`
answers "The key is not writable" - and phoc picks the value up live.

```
install -Dm644 dconf/50-sfduo-phoc       /etc/dconf/db/local.d/50-sfduo-phoc
install -Dm644 dconf/locks/50-sfduo-phoc /etc/dconf/db/local.d/locks/50-sfduo-phoc
install -Dm644 dconf/profile-user        /etc/dconf/profile/user
dconf update
```

The lock belongs to the patched phosh, and `sfduo-phosh-install` (the
shell's README) owns it from 0.14: on the packaged phosh no window can be
tiled anyway, and a locked-off auto-maximize only leaves every window at its
own size under the top bar, so the script drops the lock whenever the
packaged binary is what runs and puts it back with the patched one.

## Applications

The image's app grid is Droidian's; the port hides what it does not want
(`apps/hidden.list` - an override per desktop id in
`/usr/local/share/applications`, which `XDG_DATA_DIRS` lists before
`/usr/share`; the packages stay, because purging any of them takes the
`droidian-phosh-full` metapackage with it and the next `apt autoremove`
would take half the system), sets the dock's six apps as a dconf default
(`dconf/53-sfduo-apps`; a user's own favourites win, and `dock.json` wins
over both), and adds what a fresh image lacks once it is online:
`sudo sfduo-apps` installs Telegram, cool-retro-term (the terminal in the
dock - its CRT shaders render through hybris), what Claude Code needs and
Claude Code itself from npm, fastfetch and htop. `sfduo-apps --purge` does
remove the hidden packages, after marking the metapackage's other
dependencies as wanted. No Spotify: there is no client for arm64 Linux and
the web player needs Widevine, which Firefox lacks here.

## Settings

The device came with three settings programs: GNOME Settings (gnome-control-
center 48), Mobile Settings (phosh-mobile-settings) and Droidian's
mobile-settings service, which has no window. Neither of the two with a
window carried any of the port's own settings, and GNOME Settings offered
pages for hardware this phone does not have.

`sfduo-settings` ("Settings" in the grid) is the one list now, grouped for
this device: Connections, Screen, Sound and Notifications, Surface Duo,
Security, Apps and Accounts, System, For Developers. Each row opens its page
in whichever program has it (`gnome-control-center wifi`,
`phosh-mobile-settings osk`, `gnome-control-center system datetime`) or a
page of its own. Everything stays on the panel Settings was opened on: before
a row opens its page, Settings asks the dock to put that program's window on
its own panel (`org.sfduo.Dock.Follow(app_id, leader)`), so the page comes
up over the list and the other panel is left as it was; a window of that
program already open on the other panel is moved across. The Surface Duo
page says what is installed; its switches are #20.

A page from another program is a window a second away on a cold start,
and the first version showed exactly that: a tap, a second of nothing, a
floating window jumping into place under a black curtain. Now Settings
answers the tap in its own motion - it slides in a page titled as the one
coming, with a spinner if the wait passes half a second - and the other
program's window lands on it. The dock's curtain for a window that follows
another is the colour of a libadwaita window, without an icon, so it reads
as that page. Back closes the window; Settings is the active window again
and slides its stand-in away, back to the list. If the window never comes,
the stand-in goes by itself after 8 s.

Left out, on purpose, and why:

| Page | Why |
|---|---|
| Displays | phosh applies a scale set there live, over phoc.ini's 2, and the dock and the shell's CSS are made for phoc.ini's |
| Printers, Remote desktop, Thunderbolt, Device security | nothing to do on this phone |
| NFC | `nfcd` does not start and there is no NFC device |
| Waydroid | not installed (#21) |
| Encryption | not tried with this boot chain; a device that cannot unlock its root cannot boot |
| Mobile Settings: alerts, convergence | alerts are broken here (its schema is missing), convergence is an external display, never tested |

GNOME Settings and Mobile Settings stay installed and leave the grid by
`NoDisplay` overrides in `/usr/local/share/applications`, not `Hidden` ones -
a hidden entry is gone for launching by id too, and phosh and the dock
launch Settings by id. Settings' SSH page cannot be reached from its command
line in 48 (`system secure-shell` lands on System), so that row opens System.

Both old programs are split views that show the list and the page side by
side above a width (550sp and 500sp); a window on one panel is 675 logical
px, so both did. `sfduo-one-column`, installed as
`/usr/local/bin/gnome-control-center` and `/usr/local/bin/phosh-mobile-settings`
and named by D-Bus service files in `/usr/local/share/dbus-1/services` (both
are D-Bus activated), takes the window's `.ui` from the installed binary at
launch, raises the line to 900sp and serves it through `G_RESOURCE_OVERLAYS`:
list, then page, on one panel; two columns spanned across both. It
re-extracts when the binary changes and runs the program untouched if the
line is not in the file any more. A session bus that started before the
service directory existed needs `org.freedesktop.DBus.ReloadConfig` or a new
login.

Their own lists are not the way in any more, Settings is. Going back to
the list closes the window outright, and Settings is underneath where it
was: the rewritten `.ui` connects the list page's `shown` signal to
`gtk_window_close`, which GtkBuilder finds by name in the loaded libraries
when the window's class has no callback of that name. The list's column
also holds a single "‹ Settings" button (`window.close`), for the moment
the page is on screen and in case the signal never comes. The list is still in the `.ui`, hidden
(the programs' code holds on to it), with the search and menu buttons above
it. The same launch-time rewrite does it, with Python's XML parser rather
than sed; a file of an unexpected shape gets the width change only.

While Settings runs, the dock shows no button of its own for a window that
follows it: GNOME Settings over Settings was a second gear beside the
first.

## The hinge angle

`sudo sfduo-sensorfw-install`, once after the package: the hinge-angle
sensor is a rebuilt sensorfw (`sensorfw-hinge-patch/` - the patch touches
the hybris adaptor library, so it is not a plugin that can be dropped in),
carried as debs under `/usr/lib/sfduo/sensorfw/`; dpkg holds its lock while
the package's postinst runs, so it cannot install them itself. The script
installs the qt6 debs and the qt5 transitional stubs from the same build
(the qt6 half alone deconfigures the stock stubs and wedges apt), maps the
adaptor in `sensord-hybris.conf` - the one file sensorfwd reads - restarts
it and checks that `hingesensor` loads. Found missing on a fresh 101 image
on 2026-09-18 (#54): the July install had it by hand.
