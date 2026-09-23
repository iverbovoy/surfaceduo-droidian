# The shell on two panels

Phosh runs on this device out of the box, and it centres things. Both panels
are a single output, so the middle of the screen is the middle of the hinge:
84 physical pixels that are addressable and physically hidden. The lock
screen's clock was cut in half by it, the home bar's drag handle was entirely
inside it, and a column of app icons fell into it.

One file fixes most of that without patching phosh: `gtk.css`. The second
thing you would reach for - gmobile's cutout description - was a trap for a
long time, and is now how the top bar and the notification shade are split in
two. Both stories are below, because the trap is still there on a stock
phosh.

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

**And on a stock phosh it breaks the notification shade completely.** With
that file in place, pulling the shade down gives a black screen: no clock, no
quick settings, no notifications, and the status bar gone with them - the
panel unfolds and nothing at all is drawn in it. Remove the file, restart
phosh, and the shade comes back exactly as it should. It was reproduced both
ways, twice.

The cause is one line. phosh treats a cutout that overlaps the clock as a
notch and shifts the bar's contents by `notch.height + notch.y` - and that
same shift is applied as a top margin to the settings menu. A notch is tens
of pixels tall. A hinge is the whole display, so the shade is pushed 1800
pixels down, off the bottom of a screen 1800 pixels tall.

`phosh-patches/0004` says so: a cutout as tall as the panel is not a notch
but a **seam**, a hinge between two halves of one display. Phosh skips the
notch arithmetic for it, and the shell gives such a display a top bar - and
so a notification shade - per half, each anchored to its own three edges and
reaching only as far as the seam. Either half can be pulled down on its own,
neither is cut in two by the bezel, and each centres its own clock, so the
CSS that used to nudge the clock out of the bezel is gone.

At first both bars drew all of it - the same clock, the same signal, the
same battery, a hinge apart - which side by side reads as one bar drawn
twice rather than as two halves. It showed on the lock screen first, where
the bar is only indicators.

So `gtk.css` deals the contents out instead. phosh's bar is a box with three
children: the network group at the start, the clock as the centre child, the
indicators at the end. Each half keeps the children that belong at its own
outer edge and lets go of the rest - signal and clock on the near half,
battery and the rest of the indicators on the far half, nothing in the
middle where the bezel is. Read across the open device it is still one bar,
and nothing in it is said twice.

Let go of, not removed: an invisible child keeps its place in the box, which
is what holds the clock centred on its own half rather than letting it slide
over once the indicators beside it stop drawing. The strips themselves stay
whole - each is what the finger pulls its own shade by.

Two things the far half did not inherit on its own, both found by pulling
its shade down and watching it stop:

- **Its height.** The shell sets the top panel's surface to the display's
  usable height whenever the monitor is configured, and did it for the first
  panel only. A shade is as tall as the surface it unfolds inside, so the far
  one opened a finger's width and stopped there, arrow and all.
- **Its background.** Each panel makes a second layer surface behind itself,
  anchored to all four edges, which is what dims the screen under an open
  shade. Two of them, each the full width, meant either shade dimmed both
  halves. The background now carries its panel's margins - set when the panel
  is mapped, not where the background is made: margins are ordinary
  properties and GObject applies those after `constructed()` has run, so
  asking for them there returns zero, which is exactly the bug in a quieter
  form.
- **One pixel of exclusive zone.** The near panel reserves the bar's height
  and the far one, whose bar is the same bar, must reserve almost nothing,
  since the zones of surfaces anchored to the same edge are added up. Almost,
  not exactly: phoc keeps a dragged surface's zone at its reservation less
  the margin it is folded by, so a panel that reserved nothing reached zero
  the moment its shade was fully unfolded - and phoc draws every surface
  whose zone is zero or less underneath every surface whose zone is positive.
  The far shade opened *behind its own dimming surface*: it was there,
  drawing its buttons, and the half was black. Both screenshots were black to
  the byte, because a black dimmer over a black wallpaper is the same
  picture.

  One pixel keeps that panel on the near one's side of the line. It costs a
  logical pixel of the display's top and leaves the two halves of the bar two
  physical pixels out of line, both measured. Splitting the reservation in
  half instead is arithmetically neater and looks wrong: two positive zones
  on one edge stack, so the second half's bar sat sixteen pixels lower.

Taking the bar off the lock screen entirely was tried first, on the grounds
that that screen has a clock of its own. It only moved the question: the
halves are uneven everywhere, not only there. Split honestly and there is
nothing left to hide, so the lock screen gets the same bar as everything
else.

### The dock keeps out of the way

The dock is on the overlay layer and the shade on the one below it, so the
dock's strip along the bottom edge is in front of an open shade. Swiping up
to close the shade raised the app grid instead.

The shell says which half is open, on the session bus: `org.sfduo.Shade`,
one read-only property `Open` - `none`, `left`, `right` or `both` - with
PropertiesChanged behind it. On a stock phosh nobody owns the name, the read
fails and the dock behaves as it always did.

The dock then takes no touches at all on that half: an empty input region on
its strip and on the window that holds the buttons, so the finger reaches the
shade underneath rather than being swallowed by a dock that does nothing with
it. Closing the shade is a swipe up on the shade itself, which is what the
hand was aiming at.

And it goes out of sight while any shade is down - both halves dip below the
edge, the way they do when both panels are taken, and rise again when the
shade folds. A bar that cannot be touched is a bar standing under the shade
for nothing; the shade is what the hand is holding at that moment.

That region only reaches the compositor with a commit, and the dock's strip
draws nothing, so nothing was committed: the strip kept its old region, and
the bottom 84 px of an open shade (the dock's height) stayed the dock's and
did nothing. It was first put down to phosh; stopping the dock gave the
strip back to the shade at once. The dock now queues a frame whenever it
changes a region.

### Each shade has its own job

Two shades showing the same things are one shade drawn twice.
`phosh-patches/0006` deals the settings menu out between them, the way
Android's split shade does on a large screen: the near half keeps the
settings - brightness, volume, the quick settings, the torch, lock and
power - and the far half keeps what is going on - the media player and the
notifications. Each still opens on its own swipe.

The widgets are hidden, not made transparent: GTK3's CSS can take a widget's
opacity away and nothing else, and an invisible widget keeps its space and
its touches. Lock and power on the far half are the exception: they keep
their places with nothing drawn and nothing taken, because the clock between
them is centred by them.

On the lock screen both halves stay whole. phosh shows neither the player
nor the notifications in a shade there, so a far half that hid the rest
would open onto nothing.

One ordering trap, for the next patch in this file: the .ui binds the
bottom half's visibility to `on-lockscreen`, and `g_object_set` holds a
notify back until it returns. Dealing the halves out from the property's
setter ran before that binding, and the binding put the notifications back
on the near half after every unlock. It runs from a `notify::on-lockscreen`
handler connected after the template, which runs after the binding.

The lock screen is also where a second shade's brightness scale showed:
at zero, whatever the backlight. phosh's brightness helper kept one scale
in its globals, and the second shade's took them over.
`phosh-patches/0007` keeps a list: one connection to the power daemon,
every scale showing its value and following a change made from any of them
(checked from either side on the device).

A new notification's banner was the last thing that crossed the hinge:
phosh anchors it to the top edge alone, so it is centred on the output, and
the centre of this output is the seam. `phosh-patches/0008` anchors it to
the top and the right on a display with a seam and centres it in the far
half, where the shade that holds the notifications is. The slide in and out
keeps that margin; phosh's own animation used to set the other three to zero.

The far shade also lists the open windows (`phosh-patches/0009`, a
`PhoshRunningApps` above the notifications): icon, name, which panel the
window is on, and a button that closes it; a tap on a row brings the window
forward and folds the shade. Together with an application's own way out, it
is how a window is closed on this device: the dock's swipe only puts a
window away. A swipe used to close it past 220 px of travel, one gesture
standing for two things that cannot be undone alike - a window swiped a
finger too far was gone - and that reading is retired.

Which panel a window is on is the dock's to say: the compositor tiles a
window when asked and keeps no record of the half, and wlr-foreign-toplevel
carries no geometry. The dock publishes what it placed on the session bus -
`org.sfduo.Dock`, one read-only property `Placed`, app id to `left` or
`right`, with PropertiesChanged behind it - and the rows follow it. Without
the dock the rows just leave the panel out.

A settings page belongs to the Settings window that opened it (#90).
The dock publishes its existing `Follow` relationships as the read-only
`Follows` property (`a{ss}`, page app id to leader app id), with
`PropertiesChanged` whenever a relationship changes. `phosh-patches/0014`
uses it to filter the page's row while the leader has an open window, just
as the dock already leaves out its extra button. The row stays available:
closing the leader makes a surviving page appear again, and a settings
program opened without its leader is listed normally. Opening or closing
windows, a late app id and a dock restart all refresh the filter. With an
older dock, or no dock, every window is listed as before.

### No home bar where the dock is

phosh keeps fifteen logical pixels along the bottom for its home bar, as an
exclusive zone, and phoc takes them off the usable area - so every window on
this display was that much shorter than its panel. On the screen it read as
two halves that do not line up: a window stopping short of the bottom while
the dock on the other half ran to the edge (measured on a lossless
screenshot: 28 physical pixels).

That bottom edge is the dock's here. The swipe up on it raises the
applications, and over a window it puts the window away; the home bar is a
second thing in the same place that says nothing. `phosh-patches/0013`: on a
display with a seam - which the shell already works out for the top bar and
the shades - the home bar reserves nothing and shows nothing. Every other
display keeps it, so a stock phosh restored by `--restore` is unchanged.

### The unlock hands the desktop back

The lock screen used to be destroyed on the unlock and the desktop was there
in the next frame. `phosh-patches/0010` fades it out instead, 300 ms easing
out: the compositor applies a layer surface's alpha while it composes, so
nothing is repainted and the desktop shows through as it goes. The unlock
itself - the locked state, logind - happens at once as before; only the
picture lingers, and it takes no touches and no keys while it does. The dock's
halves come in from the sides at the same moment (#72). Measured with
`sfduo-perfcheck` against the build without it: launches 0.9 s and 1.0 s,
every animation 16.1-17.4 ms a frame - no cost.

### One window, the whole panel

The near half's bar reserves its height at the top of the output, and one
output is both panels: every window lost those 32 px, on either side. With
one panel taken and the other free, the free half's bar can say it all.
`phosh-patches/0011` does that: the taken half's bar folds up out of sight
but for a 4 px handle its shade is still pulled by, the free half's bar
shows signal, clock and indicators (`phosh-bar-all` / `phosh-bar-none` in
gtk.css, the contents fading across), and the reservation drops to a pixel:
the window runs to the top of its panel. With both panels taken, or none,
and on the lock screen, the bars are as before.

Which panels are taken is the dock's to say: `org.sfduo.Dock` has a `Busy`
property - none, left, right or both, windows only, the app grid not
counting - and phosh follows its PropertiesChanged. Without a dock nothing
changes.

It took a fix in phoc (`phoc-patches/0004`): a draggable surface's zone was
worked out from its exclusive height only while it was being dragged, so a
new height on a bar at rest was stored and ignored, and the window stayed
32 px down. Now the commit that sets it applies it and the output
rearranges, which re-tiles the tiled windows too.

### No status bar (0.17)

The one-window case turned out to be the whole answer. Since 0.17 both
halves of the bar are folded to their handles whenever the dock is running
and the phone is not locked, whatever is open (#95, #96): a strip of fixed
icons lit in the same pixels all day is the classic OLED burn-in, and its
height came out of every window. The lock screen keeps its bar - the screen
is lit to be glanced at. What the bar said went where it belongs:

- **The time**, the date and the weather stand on the free panel as a clock
  of the dock's (`DesktopClock`, #98) - on the right panel when both are
  free, gone when neither is. It is a top-layer surface, because phosh's
  home, which is what the desktop's black actually is, is one too and hid a
  clock on the bottom layer; it follows the dock's own panel, which already
  counts launches in flight, the keyboard and a pulled shade. Grey and thin,
  and each minute it steps up to 12 px from its place. The weather is GNOME
  Weather's first city, through its library, with met.no switched on (the
  library's default sources gave nothing for Kyiv). A design of its own: #101.
- **Signal, Wi-Fi and battery** are in the right-hand shade's head, under
  its clock and date (`phosh-patches/0015`) - indicators of their own, the
  bar keeping its for the lock screen.
- **A microphone or a camera in use** is a dot in the right panel's top
  corner (`PrivacyDot`, #99): orange while PulseAudio has a source output,
  green while the camera app's window is open (Android's camera service
  tells no one), blue while something asks for the location (GeoClue's
  `InUse`). The blue one only became possible once GNOME Clocks stopped
  following the location all day - its background process, running for the
  alarms, held GeoClue in use at every moment for its world clocks' "current
  location"; the port's dconf default turns that off (`54-sfduo-location`,
  #102). A low battery was already gsd-power's notification, at UPower's
  20 % and 5 %.

### The system screen (#109)

Left of the left panel there is one more page, as on the Surface Duo 2: a
swipe right anywhere on the left panel's desktop brings it, a swipe left on
it takes it away. It is light (#F2F2F2), to break the black - nobody stays
there long - and coming in its background goes from the desktop's black to
light with the finger, the content appearing over the last third. It shows
the time as the shade's head does; the desktop's large clock slides off the
right edge as it comes, and the dock's left half moves to the right panel as
it does for the grid. Only from the desktop: not over a window, not locked.
What it holds is still to come.

It is a program of its own, `sfduo-system-screen`, because the colour change
is a new frame every step: GTK4 draws through the GPU here, GTK3 (the dock)
does not. Measured: 16.6-16.8 ms a frame (median), with ~80 ms before the
first frames after idle - the dock wakes it at the touch (`Begin`), before
the finger has moved. That held only with nothing else moving: with the
dock's half and the clock moving along, a quarter of the slides ran at 33 ms
a frame. phoc sent frame done after hwcomposer's swap, which blocks ~5 ms,
leaving a client ~10 ms of its 16.6; the system screen, drawing a whole panel
in 5-10 ms, missed now and then, and with another surface keeping phoc on its
own clock it stayed a frame behind. `phoc-patches/0013` sends frame done
before the repaint (#123): every slide at 16.6 since, the dock following
frame by frame. On the session bus as `org.sfduo.SystemScreen`: `Open`,
`Close`, `Begin`, `SetProgress(d)` and a `Progress` it says as it moves,
which the dock follows. The swipe is caught by a transparent surface of the
dock's over a free panel (`SwipeCatcher`), clear of the shades' strip along
the top and the dock's along the bottom.

### Swipes from anywhere on an empty panel

With no window on a panel there is no reason for its gestures to start at an
edge (#135). The dock's catcher lies over every free panel's desktop, and the
first 12 px of travel decide what a finger is doing:

- **right:** the system screen, under the finger, from either panel. It
  comes only while the left panel it takes is free, so it never covers a
  window.
- **up:** the app grid on that panel, under the finger. It is the same
  drag the strip along the bottom starts.
- **down:** that panel's shade, under the finger (#136). phoc drags the
  shade, not the dock: `phoc-patches/0014` passes a drag that starts on a
  surface of the `sfduo-catcher` namespace on to the folded shade above it.
  Only the way that unfolds it counts; up or sideways the touch stays with
  the catcher. Once it is a drag, the touch is cancelled on the catcher,
  where it went.
- **left**, while the system screen is out: it goes back under the finger,
  from the right panel, as the swipe right there brought it.

A panel with a window keeps the gestures it had. A catcher hidden while phoc
took its touch for the shade could miss the cancel: its gesture kept the
touch as its own, and the next one went nowhere. GTK names a touch by its
slot, the same for every first finger. The gesture is reset whenever a
catcher is shown or hidden.

### Back, from the edge

A window's back arrow is at its top, far from a thumb. As on Android, a
swipe in from the side edge is "back" (#80): the dock keeps a 14 px strip
along the outer edge of a panel with a window on it (the left panel's left
edge, the right panel's right edge - where the thumbs are when the Duo is
held like a book), from below the bar to above its own band. A round "<"
comes out of the edge with the finger and turns blue past 64 px; let go
there and the dock gives the window on that panel the focus and sends it
Alt+Left, which is back to libadwaita's navigation (Settings, Mobile
Settings, the port's Settings, the GNOME apps) and to Firefox. Terminals
are left out by app id - Alt+Left is a word back there. The strips take
touches only where the bottom band does: a busy panel, no shade, no grid,
not locked.

### Minimize, which phoc did not have

phoc 0.47 dropped every minimize request: xdg_toplevel's `set_minimized`,
and wlr-foreign-toplevel's, which is what `wlrctl toplevel minimize` and so
the dock's swipe along a busy panel's band send - that swipe had never
minimized anything. `phoc-patches/0005` gives a view a minimized
state: not drawn, no input, the focus handed on, the window fading away as
a closed one does; activating it brings it back. The dock reads it as a
free panel (`Busy`), so the bar moves across (#79).

Back at the first page of the port's Settings minimizes it, as back from an
app's first screen does on a phone: its navigation view takes Alt+Left
while it can pop, and what it lets through at the list minimizes the
window. Other apps say nothing about being at their first page, so a swipe
there still does nothing.

### Closing and minimizing look different, and the dock follows at once

A closed window fades and shrinks a little in place (200 ms); a minimized
one shrinks to a third and drops to the bottom edge of its panel, where the
dock is, fading late so the eye follows it there (280 ms) - phoc-patches/0006,
one "ghost" with two kinds. A window put away over another one - the port's
Settings over its own list - fades where it stands instead: what the eye
follows there is the window underneath, and a copy of this one flying down
over it is one motion too many (phoc-patches/0010).

A ghost is the window, not the client's whole surface (phoc-patches/0011).
A client that draws its own decorations draws its shadow outside the
window's geometry, and phoc offsets a view by that geometry when it renders
it: a ghost made of the surface carried those margins along, a pale edge
above and below a window crossing to the other panel. What is repainted is
still the surface's rectangle - shadow and all, and for anything that
travels the whole path between its ends, or a slice of the window stays
behind in the seam.

### A window that fills a panel has no edge to draw

libadwaita outlines a window with a pale hairline and lights the top of its
header the same way. On a phone with a desktop around the window that is its
edge; here a window is given a whole panel, so the "edge" lands along the top
of the screen - a grey line, measured at rgb(70,70,70) over a window of
rgb(34,34,38) and noticed in use before it was measured.

The package says so once, in `/etc/xdg/gtk-4.0/gtk.css`: a window that has
taken a panel (`.maximized`, `.tiled`, `.fullscreen`) draws no outline and no
highlight over its header. GTK4 reads that file for every application and
every user, which is checked on the device - so it needs no overlay in any
program's own resources. A window that has not taken a panel, a dialog over
one, keeps its edge.

### A new window is not drawn until it is where it belongs

A window maps at whatever size its client asked for and is placed a beat
later, so it used to be drawn twice over - its own size and place first,
the panel's second - with the client laying its contents out again in
between and the dock's slide carrying the first frame into the second.
Filmed at 60 fps, opening a Settings page: the window appears at about two
thirds of the panel, grows over ten frames and reflows twice.

`phoc-patches/0010` holds a new window at zero alpha from its map and lets
it go, with the fade it used to get at the map, at the first frame it draws
after it has been put on a panel, is drawn at that panel's size (scale and
all - a window wider than a panel is scaled into it, and the panel is
shorter while the shell's bar is still on it), and its client has stopped
drawing for 110 ms. Anything still unsettled after 700 ms is shown as it
is, which is also what a window nobody places gets. A window still held is
tiled without the sliding ghost: what would travel is the frame it drew
before anything placed it.

The dock used to learn of windows by asking every half second, so it
crossed onto a freed panel up to half a second after the window had gone.
phosh now says it at once on `org.sfduo.Shade`: `WindowsChanged("opened" |
"changed" | "closed")` (phosh-patches/0012; a minimize arrives as a
"changed"). The dock looks again half-way through the window's motion -
100 ms after a close, 140 ms after a change - and measured, it starts to
move about 200 ms after the command. The half-second beat stays, for a
shell that says nothing.

### An open app, called to the other panel

With an app on one panel the dock stands on the other. A tap there on that
app's button used to give its window the focus where it was - nothing to
see. The hand is on the free panel, so the app comes to it: the dock moves
the window across, with any window following it (a page the port's Settings
opened over itself), and takes the panel the app left.

It first did that as a user would - focus, wait for it, the tiling chord -
half a second a window, and a pair came across as two jumps with the page
disappearing under the list between them. `phoc-patches/0007` gives the dock
a direct way: `org.sfduo.Phoc.Tile(app_id, side)` on the session bus tiles
an app's windows without focusing or raising anything, and each slides
across (its last buffer moving, the window shown on arrival, 260 ms). The
dock sets off at the same moment instead of after its next look at the
windows. Measured: 24-37 ms from the tap to both moving; the dock's
crossing 16.2 ms a frame. New windows it adopts are tiled the same way. On
a stock phoc the old way still works.

### A panel is what maximized means, and what a window is fitted into

On an output with a seam, maximizing put a window across the hinge.
`phoc-patches/0008` makes maximized the panel the window is on - as the
Duo's own Android does - and fits a window that cannot be that narrow into
its panel: GNOME's first-run wizard asks for about 1024 px where a panel is
675, and stood across the hinge whatever tiled it. Such a window is scaled
down (the compositor's own scale-to-fit, applied to the panel instead of the
output) and centred on the panel rather than resized - asked for the panel's
size it answers with its own, and phoc then placed it by the difference,
hundreds of pixels down.

The wizard itself does not run on this port any more: the package marks it
done, as finishing it would (`gnome-initial-setup-done`). Fitted, it was
small in a field of black; its pages - language, keyboard, time zone,
privacy - are all in Settings.

### A shade folds from anywhere

phosh lets an open shade be folded only by its handle: `update_drag_handle`
puts it in phoc's `HANDLE` drag mode, and the handle is worked out from the
bottom of the quick settings, which left a finger only the lower part of
the shade (measured: from y=650 of 900 down). `phosh-patches/0005` makes
the whole surface the handle, as phosh already does on the lock screen,
except while the notification list can still scroll further: then a swipe
up scrolls it, and once it is at its end the next one folds the shade.

Nothing is lost to it. phoc holds a drag as pending until it has gone 16 px
along its axis and gives it back to the surface if it goes 24 px across
first, and while the shade is unfolded it takes only a drag towards folding:
the brightness slider still moves, a swipe down still scrolls the list, a tap
is still a tap (all checked on the device).

What remains is phoc's own threshold: a fold needs 30 % of the travel, about
260 px, and phoc does not look at the speed. A swipe that starts high on the
shade has no room for that and springs back.

So the file **is** installed, by `sfduo-phosh-install`, in step with the
patched binary and never without it: `--restore` takes it away again. On a
stock phosh the shade would be unreachable, which is a worse phone than one
with a clock in an odd place.

## The output scale

Droidian's generic `phoc.ini` scales every phone's output by 3, which makes
the Duo's two panels 928x600 logical - a phone's worth of space in which GNOME
Calculator loses its bottom row. Android runs these panels at 400 dpi, a
scale of 2.5, and from 0.14.1 to 0.15.3 so did the port. But GTK3 has no
fractional scale: at 2.5 it draws at 3 into a 27 MB buffer per frame and
phoc scales it down, and the lock screen's unlock swipe ran at 40 fps that
way; at 2 the same swipe runs at 55-60 (`docs/PERF.md`, "The lock screen,
measured"). So since 0.15.4 the port's scale is 2: `phoc.ini` (this
directory, Droidian's file with that one line changed - phosh-session takes
`/etc/phosh/phoc.ini` whole when it exists) makes the output 1392x900
logical, with the hinge at [675, 717]. It is a conffile: change the scale
there (2.5 is still there to try), run `sudo sfduo-shell-css`, restart the
shell.

Everything below is in logical pixels and therefore depends on the scale.
The dock asks the compositor for the output's size; the CSS cannot, so it is
a template.

## The rest, in CSS

`gtk.css` belongs in the session user's `~/.config/gtk-3.0/gtk.css`. GTK3
reads user CSS from the user config directory only; there is no system-wide
`gtk.css` it will load, so the file is installed per user. It is generated:
`gtk.css.in` holds the rules with tokens where the geometry goes, and
`sfduo-shell-css` fills them in for the scale in `phoc.ini` (the package does
it at build time and again in postinst). The numbers in this section are
the scale-3 ones the rules were worked out with; at 2 read 717 for 478,
675 for 450 and 1392 for 928 (at 2.5: 573, 540, 1113).

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
./sfduo-shell-css --scale 2 --template gtk.css.in -o /tmp/gtk.css
install -Dm644 -o droidian -g droidian /tmp/gtk.css /home/droidian/.config/gtk-3.0/gtk.css
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

The gmobile cutout described above is installed with the patched phosh and
only with it, by `sfduo-phosh-install`: on a stock phosh it costs the whole
notification shade, as that section explains.

All of this is experimental and changes from one release to the next. To go
back to Droidian's own shell - the packaged phosh, phoc and keyboard, no dock,
no shell CSS - switch "Two-panel shell" off on Settings' Surface Duo page, or:

```
sudo sfduo-shell --stock     # --duo brings it back
sudo sfduo-shell --restart
```

It is one switch because the parts do not work apart: under the port's phosh
the dock is the desktop (stopped, it left only the wallpaper - no launcher, no
way back to a window put away), and under the packaged phosh no window takes
the focus, so the dock can place none. `sfduo-shell --stock` runs the three
`--restore`s below; the dock and `sfduo-shell-css` stand down while
`/etc/sfduo/phosh-stock` is there. The output scale is the same command,
`sudo sfduo-shell --scale 2|2.5|3`, and the same Settings page.

A black background, which suits a screen with a black bar down the middle -
the package sets it as the default (`/etc/dconf/db/local.d/51-sfduo-background`);
by hand it is:

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
(or the first button): a grid of every application on the panel that was
swiped - alphabetical, four to a row at the dock's icon size, scrolling -
while the other panel keeps what it was showing and stays touchable. The
open grid counts as a window on its panel, so the dock crosses to the other
one exactly as it does for an application. Launching goes onto the panel
the grid is on. Moving down across the grid, a tap on empty space, or
launching something closes it. `pkill -USR1 -f sfduo-dock` toggles it from
outside, for a keybinding (on the panel it was last opened on; the right one
at first). Until 0.15.2 the grid was dealt across both panels, half the
alphabet each, at phosh's 64 px icons.

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

Two things worth knowing:

- phoc's halves are exactly half the output, and the middle of the output is
  the middle of the hinge, so a tiled window reached half the hinge into the
  bezel on its inner edge - 14 logical pixels at scale 3, 21 at 2 - and
  lost that much of its content. Since 0.14.2 the package carries a patched
  phoc (`phoc-patches/0001`, installed by `sfduo-phoc-install` beside exactly
  the phoc version it was built for, with the same version lock, `--restore`
  and marker as the phosh one): a `tiling-seam` in the output's section of
  `phoc.ini`, the hinge as a fraction of the output's width, makes the halves
  stop short of it. Left half: from the usable area's left edge to the seam;
  right half: from the seam to the usable area's right edge. Without the key
  phoc tiles as before, and a phoc without the patch warns about the key and
  ignores it. Built like phosh, in a Droidian arm64 container under qemu:
  `build/Dockerfile.phoc` on top of `build/Dockerfile.phosh`, the tree at
  droidian/phoc 98211ea with the patch applied, `meson setup _build
  --prefix=/usr --libdir=lib/aarch64-linux-gnu -Dembed-wlroots=disabled`
  (the system wlroots is Droidian's fork with the hwcomposer backend) and
  `ninja -C _build src/phoc`; the binary goes to `out/phoc/` for the package.
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

0.13.0 had the dock cover for a stock phosh by setting the hint itself when
it started beside a shell less than 45 seconds old. That was wrong, and the
first outside install showed it within the hour: twenty seconds into a boot
the dock has usually not started yet, an owner who unlocks in that time is
already past the lock screen, and the dock then marked an unlocked phone as
locked - for good, since nothing was left to clear it - and hid. One lock and
unlock brought it back. 0.13.1 removed the heuristic: with an unpatched phosh
the dock can sit over the first lock screen after a boot, which is the smaller
harm; with the port's phosh neither happens.

`phosh-patches/0001` fixes it at the source and makes phosh say its state at both of those moments -
both, because which comes first depends on how long the shell took to start
(1 s on a warm restart, 10 s on a bad one, and the order flips). On a slow
start that is still most of a minute after the lock screen is drawn, so the
dock also treats "nobody owns `org.gnome.ScreenSaver` yet" as locked.

The package carries the patched binary (0001-0012) and
`sudo sfduo-phosh-install` puts it in place at install time - but only beside
exactly the phosh version it was built for; on any other it says so and
leaves the packaged shell alone. `sudo sfduo-phosh-install --restore` puts the
packaged binary back and leaves a marker (`/etc/sfduo/phosh-stock`) so that
the next install or upgrade of this package, whose postinst runs the same
script, does not quietly put the patched one back again - it did until 0.13.1,
and a restore made just before an upgrade looked as if it had never happened.
`--patched` removes the marker and installs the patched binary again. A phosh
upgrade replaces the binary on its own either way. Restoring phosh alone
changes the binary and the tiling lock; the marker also stops the dock and
empties the shell's CSS the next time each starts. `sfduo-shell --stock`
(Installing, above) is the whole of it at once, phoc and the keyboard too.

The patches are against droidian/phosh at cf38ab5, the tree the installed
package was built from, configured as the package is (`--prefix=/usr
--libdir=lib/aarch64-linux-gnu`; a `/usr/local` build looks for its plugins in
the wrong place). The binary replaces `/usr/libexec/phosh`; the packaged one
is kept beside it as `phosh.stock`. `0002` makes the status bar say LTE
rather than 4G. `0004` reads a cutout that runs the display's whole height as
a seam and gives such a display a top bar, and a notification shade, per
half; it is inert without that cutout in gmobile's device description, which
is why the two are installed and withdrawn together.

While the phone is locked the dock is not hidden - a hidden layer surface is
a destroyed one, and takes a few frames to come back - it steps down from the
overlay layer to the top one. The lock screen is on the overlay layer and
covers everything beneath it, which is all "hidden" ever had to mean. It also
lets the launch curtain be raised *under* the lock screen, over a window
nobody has placed yet (the first-run wizard, on a new install): the unlock
signal arrives after the lock screen has already gone, so a curtain raised in
answer to it is always a moment late, and one that is already there is not.

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

### Windows the dock did not launch

The shell's own grid, a notification, the first-run wizard, a terminal: a
window nobody asked the dock for opens across both panels like any other. On
its next beat the dock adopts it - focuses it and tiles it onto the free
panel, the right one when both are free - once per window; if the chord
cannot reach it, it stays as it opened rather than being chased. On an
install from scratch the first thing on the screen is GNOME's Initial Setup,
and this is what puts it on one panel.

### The launch curtain

A new window maps at its own size, across both panels, and on a compositor
that cannot be told where a window should open it can only be tiled once it
has the focus - most of a second in the wrong place. The dock is above
everything, so it covers the stage for that second: black, with the app's
icon on the panel it is headed for, lifted 250 ms after the tiling chord so
the window has laid itself out at its new size. It lifts on every path,
including a launch that never produces a window.

The curtain is a launch's, not a placement's, now that the port's phoc
holds a new window until it is where it belongs (phoc-patches/0010): a
window the dock merely adopts - one it did not launch, a page opened by
the port's Settings - is no longer covered at all. The dock asks the
session bus whether `org.sfduo.Phoc` is there to know; on a stock phoc the
curtain goes up as before.

`pkill -USR2 -f sfduo-dock` launches whatever `$XDG_RUNTIME_DIR/sfduo-launch`
names (`org.gnome.Settings.desktop right`) exactly as a tap would - curtain,
placement and all - for checking this without a finger.

### When a launched app opens across both panels

Placement depends on the new window taking the focus, and for a day of this
port's life nothing could: every launch logged `Layer surface has focus, not
focusing view yet` in phoc, `wlrctl toplevel find … state:active` never
matched, and the tiling chord went nowhere. Reboots "fixed" it for a launch or
two, which made it look like stale session state. It was not.

phosh's home overview takes keyboard interactivity while it is unfolded, and
gives it up when the first window appears - `set_keyboard_interactivity(0)` -
**and then never commits its surface**. That state is double-buffered; without
a commit the compositor never sees it, and keeps the keyboard on a home that
is folded and out of sight. The top panel commits at the same point in its
own code; home left it to the next redraw, and under this shell a folded home
has nothing to redraw. A `WAYLAND_DEBUG=1` dump of phosh shows it plainly: the
request, then zero commits of that `wl_surface` for as long as you care to
wait. Reproduces on a clean Droidian 101 image with a stock phosh:

```
systemctl restart phosh            # unlock, then, in the session's environment:
gnome-control-center &
wlrctl toplevel find app_id:org.gnome.Settings state:active; echo $?   # 1, forever
```

`phosh-patches/0003` is the one missing line. With it the same sequence
answers 0.

On a shell that cannot do this the dock steps back, since 0.14: with the
packaged phosh in place of the patched one, everything the dock did around a
launch was harm - a black curtain for as long as it waited (twenty seconds,
per launch and per window it tried to adopt), the window then left at its own
size under the top bar because `auto-maximize` is off for the tiling's sake,
and a curtain held under the lock screen that stayed for twenty seconds after
the unlock. Now the dock compares the shell's binary with the patched one the
package carries at start, and otherwise learns from the first window: one
that takes the focus within four seconds settles it, one that does not
(outside the lock screen, which holds the keyboard by right) makes the dock
step back - no curtain, no chord. It says so once in the journal, with what to
run (`sudo sfduo-phosh-install`). Every later window is still asked, without a
curtain: a shell that starts placing windows is believed again.

The window's size is not the dock's to fix: phoc refuses maximize, minimize
and fullscreen requests for a window that does not have the focus (the
fullscreen one fails an assertion on it, the others are dropped without a
word), so on such a shell nothing outside phosh can put a window right. That
is why the dconf lock keeping `auto-maximize` off belongs to the patched
phosh: `sfduo-phosh-install` puts the lock in place with the patched binary
and drops it whenever the packaged phosh is what runs - after `--restore`, and
when the version lock leaves the packaged one alone - so that phosh
maximizes windows itself, as it does on any other phone. The first outside
install ran into all of this at once, on a phosh the version lock had left
unpatched.

### Seeing what a gesture did

`SFDUO_DOCK_DEBUG=1` in the dock's environment makes it say, on stderr, where
each drag began, how it ended, and when one was cancelled. Start it the way
the session does, not from a bare ssh shell: launched with an empty
environment it works, but what it launches inherits that environment, and
GNOME Settings, for one, refuses to start without `XDG_CURRENT_DESKTOP`
("only supported under GNOME and Unity") - which looks exactly like a dock
that ignores a tap.

## The on-screen keyboard takes one panel

phosh-osk-stub anchors its surface to the left and right edges, so on this
display the keyboard ran across the bezel: half the keys on each panel and a
dead column through the middle. Since 0.15 the package carries a patched one
(`osk-patches/0001`, `sfduo-osk-install`, the same version lock, marker and
`--restore` as phosh and phoc): when phoc.ini names a `tiling-seam` and the
output is in landscape, the keyboard is anchored bottom-right with the width
of one panel, computed from the monitor's geometry and the seam - the same
arithmetic as the CSS and the dock. In portrait the panels are stacked and it
spans the output as before. The right panel always, for now; following the
window being typed into would need phosh to tell the keyboard where that
window is. Since the output scale is 2 (0.15.4) the key rows are 60 px
instead of the stub's 50 on such a display (`osk-patches/0002`): the scale is
chosen for the whole display, and 50 px rows came out a fifth lower than at
2.5. Built with `build/Dockerfile.osk` from droidian/phosh-osk-stub at
43ef51f, `meson setup _build --prefix=/usr --libdir=lib/aarch64-linux-gnu`,
`ninja -C _build`; the binary goes to `out/osk/`.

## The hinge, and the fold effect

`sfduo-posture` holds the one session with sensorfw and publishes what it
reads as `org.sfduo.Posture` on the session bus: the angle sixty times a
second, the raw reading, the posture, whether the hinge is turning and how
fast. Readings arrive ten times a second, in whole degrees, fifteen apart
during a brisk fold; the daemon glides between them at a constant speed
rather than springing, which is the difference between a smooth picture and
a shivering one. Everything that wants the hinge reads this instead of
talking to sensorfw itself.

`sfduo-fold` is what the hinge drives. Opening the device turns the lit
pieces of the last frame away from the eye and brings them back to flat as
the hand finishes the movement - the pieces travel out of step with each
other and arrive together, and the sheet is blurred and dimmed towards its
outer edge. It ends at `FOLD_BOOK` degrees, 150 by default: at 90 the sheet
is sharp while the hand is still opening and the last third of the movement
has nothing to look at. Every number is an environment variable, listed at
the top of the script.

Both autostart with the session. The effect reads the hinge only through
`org.sfduo.Posture`, so without the posture daemon it starts, says so and
does nothing.

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
