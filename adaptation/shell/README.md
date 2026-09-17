# The shell on two panels

Phosh runs on this device out of the box, and it centres things. Both panels
are a single output, so the middle of the screen is the middle of the hinge:
84 physical pixels that are addressable and physically hidden. The lock
screen's clock was cut in half by it, the home bar's drag handle was entirely
inside it, and a column of app icons fell into it.

One file fixes that without patching phosh: `gtk.css`. The second thing you
would reach for - gmobile's cutout description - is a trap, and the reason is
worth the section below.

## gmobile's cutout: what it does, and what it costs

gmobile carries a description of the display panel for each device and phosh
asks it where the cutouts are, looking the file up by the device tree's
`compatible` string:

```
$ cat /firmware/devicetree/base/compatible
qcom,sm8150-mtp
```

Droidian's phosh session already sets

```
G_RESOURCE_OVERLAYS=/org/gnome/gmobile/devices/display-panels=/var/lib/droidian/phosh-notch
```

and nothing ever put a file there. Dropping a `qcom,sm8150-mtp.json` in that
directory, with the hinge as a cutout

```json
{ "name": "Surface Duo 1", "x-res": 2784, "y-res": 1800, "border-radius": 0,
  "width": 145, "height": 93,
  "cutouts": [ { "name": "hinge", "path": "M 1350 0 h 84 v 1800 h -84 Z" } ] }
```

does work: the log says `Mapped file … as a resource overlay` and the top
bar's clock moves out of the bezel. That is also the only thing phosh does
with cutouts.

**And it breaks the notification shade completely.** With that file in place,
pulling the shade down gives a black screen: no clock, no quick settings, no
notifications, and the status bar gone with them - the panel unfolds and
nothing at all is drawn in it. Remove the file, restart phosh, and the shade
comes back exactly as it should. It was reproduced both ways, twice.

So the file is not installed on this device, and the clock is moved with two
lines of CSS instead, which costs nothing and moves the shade's clock too.
A phone whose notifications are unreachable is a worse phone than one with a
clock in an odd place.

## The rest, in CSS

`gtk.css` belongs in the session user's `~/.config/gtk-3.0/gtk.css`. GTK3
reads user CSS from the user config directory only; there is no system-wide
`gtk.css` it will load, so the file is installed per user.

Each widget the shell centres is given `margin-left: 478px` - the near panel
plus the hinge - so that what was centred on the whole screen is centred on
the right panel, under the thumb of a right hand. The app grid is the
exception: it keeps both panels, and only its column count changes.

Three things had to be learned the hard way, and they are why the selectors
look the way they do:

- **`PhoshLayerSurface` is a `GtkWindow`, and a GTK3 window does not apply its
  own CSS padding to its child.** `phosh-lockscreen { padding-right: … }`
  parses, matches, paints its background across the whole screen, and moves
  nothing.
- **GtkBuilder ids are not visible to CSS here.** `#box_info`, `#box_unlock`,
  `#box_datetime` - the ids in phosh's `.ui` files - match nothing at all.
  What matches is an element name from phosh's own stylesheet
  (`phosh-lockscreen`, `phosh-app-grid-button`), a style class from the `.ui`
  (`.phosh-lockscreen-arrow`, `.phosh-search-bar`), or a name set explicitly
  with `<property name="name">` (`#phosh-lockscreen-clock`, `#home-bar`).
- **A style class reaches everything that wears it, including what is not
  on screen.** `label.dim-label` was meant for the "Slide up to unlock" hint;
  it also matched the artist line in the lock screen's media player, hidden
  in a revealer - and a revealer that shows nothing still asks for its
  child's width. A 478px margin on that label made the player ask for 598,
  the area holding the notifications could shrink no further, and everything
  in the box drifted. Two afternoons of "the layout will not hold still"
  came down to that one selector. Select by position in the tree when the
  widget has no name of its own.
- **A CSS margin only lands on a widget GTK3 allocates through a CSS gadget.**
  Labels, images and boxes have one. `GtkEventBox` does not, which is why the
  home bar's handle ignores a margin and the box that centres it does not.

The `.ui` files are the reference for all of this and they are inside the
binary:

```
gresource list    /usr/libexec/phosh
gresource extract /usr/libexec/phosh /mobi/phosh/ui/lockscreen.ui
```

### The app grid

A `GtkFlowBox` fits as many equal columns as the child's minimum width allows,
and an odd number of columns always puts one column astride the hinge. At the
icons' natural width that is seven columns, with the fourth in the bezel.

Six columns instead. The minimum width that produces six is the child's whole
width, padding included - 145 px against 922 px of usable row and 6 px of
column spacing - so the button gets `min-width: 109px` and 18 px of padding on
each side. The gap between the third and the fourth column then falls on 464,
the middle of the seam, and the padding insets each icon far enough that the
two columns beside the gap stop drawing well before the bezel begins.

## Installing

Since 0.13 the adaptation package installs all of it: the dock and the
brightness keeper with their autostart entries, and the CSS as
`/usr/share/sfduo/gtk.css`, linked into the user's `~/.config/gtk-3.0/` unless
a file of their own is already there (GTK reads a user stylesheet from nowhere
else). By hand, the CSS alone is:

```
install -Dm644 -o droidian -g droidian gtk.css /home/droidian/.config/gtk-3.0/gtk.css
systemctl restart phosh
```

A fresh Droidian 101 image has none of what the dock needs - `wlrctl`,
`wtype`, the gtk-layer-shell typelib, `dconf` - and the package can only
recommend them, because it is installed offline with `dpkg` before the device
has seen a network. Until they are there the dock says so in the journal and
exits. Once online:

```
sudo sfduo-shell-setup
```

The gmobile cutout described above is not installed: it costs the whole
notification shade, as that section explains.

All of this is experimental and changes from one release to the next. To go
back to stock phosh behaviour, remove `/etc/xdg/autostart/sfduo-dock.desktop`
and the `gtk.css` link, and restart the shell.

A black background, which suits a screen with a black bar down the middle:

```
gsettings set org.gnome.desktop.background picture-options 'none'
gsettings set org.gnome.desktop.background primary-color '#000000'
```

## Checking it without a finger

`grim` needs the output awake or it fails with "failed to copy output":

```
wlr-randr --output HWCOMPOSER-1 --on
grim /tmp/shot.png
```

`wtype` drives the shell from the shell: any key press moves the lock screen
to the passcode page, and `wtype -M alt -k F1 -m alt` toggles the app grid
(`org.gnome.desktop.wm.keybindings panel-main-menu`). With no application
running phosh keeps the grid open, so the home bar is only visible once
something has been launched.

## The dock

`sfduo-dock` is one bar across the bottom of both panels, cut by the bezel
rather than doubled: the buttons are dealt out across the two halves, each app
appearing once, and each half is pushed against the seam and rounded only on
its outer side, so that across the hinge it reads as a single thing. Which
half an app sits in is which panel it opens on - the Duo's own behaviour.

Nothing in it talks to the compositor directly. Placement is phoc's: it tiles
the focused window to half the output on `<Super>Left` / `<Super>Right`, which
are mutter's keybindings and live in `org.gnome.mutter.keybindings`, not in
`phoc.ini`. So a launch is three steps:

```
start the app  ->  wait for its toplevel to be mapped and focused  ->  send the chord
```

The waiting is `wlrctl toplevel find app_id:… state:active` asked every tenth
of a second. wlrctl's own `wait` and `waitfor` actions do not mean "wait for
this window to open" and return 1 immediately; `find` is a plain question and
answers correctly. Focus matters because the chord goes to whatever is
focused, and it is a *toggle*: sent to a window already on that side it pushes
it back to full width, so the dock remembers where it put each app.

Install: the script to `/usr/local/bin/sfduo-dock`, the `.desktop` to
`/etc/xdg/autostart/`. Its apps come from `~/.config/sfduo/dock.json`
(`{"apps": ["org.gnome.Calculator.desktop", …]}`) and fall back to the shell's
own favourites. It sits on the overlay layer, because phosh's app grid is a
layer surface too and otherwise covers it.

### It is also the desktop

With nothing running phosh has only one state, and that state is the app grid;
there is no wallpaper-and-dock to switch to. So the dock covers it. With no
window open it anchors to all four edges, paints itself black and puts the two
slabs along the bottom - a desktop with nothing on it but the dock. The moment
an application has a window it shrinks back to an 84px strip and reserves it,
so the window stops above the icons rather than under them.

Covering means covering: the exclusive zone is -1 in that state, which ignores
what other surfaces reserved and is the only way to hide the strip phosh keeps
for its home bar - the grid shows through it otherwise. The top panel is spared
by hand, with a 32px top margin, because a status bar is worth keeping.

Everything that is not on the dock is behind a swipe up across the strip
(or the first button): a grid of every application, dealt across the two
panels alphabetically - the first half on the left, the second on the right,
three columns each, each half scrolling on its own - and launching onto the
panel that was tapped, exactly like the dock. The strip fades as the grid
rises over it. Moving down across the grid, a tap on empty space, or
launching something closes it. `pkill -USR1 -f sfduo-dock` toggles it from
outside, for a keybinding.

The grid follows the finger, and the window does no work at the moment of
opening. Three things make that so, each found by doing it the other way
first:

- **The window is always the height of the stage** - the space between
  phosh's bars - transparent where it is nothing, with an input region of
  just the strip while closed, so touches above it fall through to the
  application underneath. Growing the window at the moment of opening was a
  round trip to the compositor, a relayout and the first paint of forty
  icons, all on the first frame of the gesture.
- **The grid is scrolled into view, not moved.** A viewport the height of
  the stage holds a transparent spacer with the grid beneath it, and the
  scroll position is the grid's position. Scrolling a viewport shifts its
  window without laying anything out again. No other GTK3 container will
  park a widget below the edge: a GtkFixed grows to hold it, a GtkLayout
  hands it its natural size and ignores the move, a GtkOverlay clamps the
  margin so it fits. And a bare viewport asks for its child's height, so
  the viewport here is subclassed to ask for the stage's.
- **The finger sets the position directly while it is down**; letting go
  hands over to a frame-clock animation that eases out over what is left of
  220ms. A flick decides by direction, a slow release by which side of
  halfway the grid was left on. One gesture makes one decision, against the
  state it began in: opening used to grow the window upward, and the finger
  that had not moved was suddenly hundreds of pixels lower in the window's
  coordinates, which read as a swipe down.

That matters more than it sounds: with phosh's own grid pushed off the
screen, this is the only way to everything else.

Icons are normalised on purpose. A themed icon comes in whatever sizes the
theme happens to carry - 16, 48, 256, scalable - so asking for a named size
gets one app a 64px bitmap and the next a 32px one; and a button sized to its
child leaves the row ragged even once the glyphs match. Hence a fixed pixel
size on every image and a fixed box around every button.

Two rough edges, both known:

- phoc's halves are exactly half the output, so a tiled window reaches 14
  logical pixels into the hinge on its inner edge. Fixing it properly means
  patching `view_arrange_tiled` in phoc to read the same gmobile cutout the
  CSS above is built around.
- `gsettings set sm.puri.phoc auto-maximize false` is what lets a window stay
  tiled rather than being forced back to full width.

### It hides while the phone is locked

The dock is on the overlay layer, which is above the lock screen as well as
above everything else, so it has to be told. The source is logind's
`LockedHint` on the seat's own session:

- phosh's `org.gnome.ScreenSaver` answers **false** while its lock screen is
  on the display - "active" there means blanked. Closing the device shows the
  lock screen without the screen saver ever going active.
- logind's `Lock`/`Unlock` signals only fire for the path `loginctl
  lock-sessions` takes, not for closing the device.
- `LockedHint` is set for both.

**Except for the one lock that matters most: the one the shell starts in.**
phosh comes up locked, on every boot and every restart, and phosh 0.49 as
Droidian packages it (cf38ab5) does not tell logind - later versions were not
checked. It listens to its own lock state only once it owns
`org.gnome.ScreenSaver`, and can only set the hint once it has a proxy for its
session; the startup lock happens before either, and nothing replays it. So
`LockedHint` is `no` behind the lock screen until the first unlock, and the
dock sat on the lock screen after every reboot. It hid for a whole day of
development, because every lock *after* startup works.

`phosh-patches/0001` makes phosh say its state at both of those moments -
both, because which comes first depends on how long the shell took to start
(1 s on a warm restart, 10 s on a bad one, and the order flips). On a slow
start that is still most of a minute after the lock screen is drawn, so the
dock also treats "nobody owns `org.gnome.ScreenSaver` yet" as locked.

The patches are against droidian/phosh at cf38ab5, the tree the installed
package was built from, configured as the package is (`--prefix=/usr
--libdir=lib/aarch64-linux-gnu`; a `/usr/local` build looks for its plugins in
the wrong place). The binary replaces `/usr/libexec/phosh`; the packaged one
is kept beside it as `phosh.stock`. `0002` makes the status bar say LTE
rather than 4G. `0003` is unfinished work on a top bar per panel, inert
without a full-height cutout in gmobile's device description.

The session has to be found, not assumed. `/org/freedesktop/login1/session/
self` is whichever session the process was started from, which for anything
launched over ssh is not the one with the screen - and `loginctl
list-sessions | head -1` is a manager session whose hint is always `no`, which
is a convincing way to conclude the hint does not work. The session wanted is
the `wayland` one attached to a seat:

```
loginctl list-sessions --no-legend | while read s _; do
  [ "$(loginctl show-session $s -p Type --value)" = wayland ] && echo $s
done
```

Two traps in subscribing to D-Bus signals, both of which look like "the signal
never arrives", and both of which cost a debugging round here:

- **A sender filter drops them.** With a well-known name as the sender, GDBus
  resolves the owner itself and discards signals until it has. Filter on
  interface and path instead.
- **A bus connection held in a local variable takes its subscriptions with it
  when it is collected.** Keep it on the instance.

## Brightness

The screen came back at 100% every time the device was opened, and there were
two separate reasons.

The first is the ambient light sensor: `gsettings get
org.gnome.settings-daemon.plugins.power ambient-enabled` was `true`, there is
a real sensor behind `net.hadess.SensorProxy`, and with an empty
`ambient-brightness-points` curve the level it computed after every unlock was
the maximum. Setting `ambient-enabled false` is the whole fix.

The second outlives that one. Closing the device powers the two DSI panels
down, and bringing them back up leaves each panel's backlight at the driver's
default, which is full: `panel0-backlight` and `panel1-backlight` both at 255
while gnome-settings-daemon still said 60%. Nothing re-applies it, because as
far as the shell is concerned nothing changed. `sfduo-brightness` watches the
two panels and, when one is at full while the shell believes otherwise, writes
the shell's own number back to it - handing gsd its current value is enough to
make it write the hardware again. A level of 100% is left alone, which is what
makes it safe.

Which device to watch matters. There are three:

```
backlight         pm8150l WLED, max 4095 - not wired to anything here, pinned at full
panel0-backlight  the left panel,  max 255
panel1-backlight  the right panel, max 255
```

The Duo's panels are OLED and are driven by DCS commands through the mdss
nodes, so `panel0`/`panel1` are the real ones. Reading `backlight` tells you
nothing: it says 4095 no matter what the screen is doing.

## What this does not fix

Phosh has no home screen. When the last window closes it shows the app grid,
and there is no state in which you see a wallpaper and a dock and nothing
else - the dock above floats over the grid rather than replacing it. Giving
the shell a real home screen, or a window per panel as a first-class idea, is
a patch to phosh, not a stylesheet.
