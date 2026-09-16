# The shell on two panels

Phosh runs on this device out of the box, and it centres things. Both panels
are a single output, so the middle of the screen is the middle of the hinge:
84 physical pixels that are addressable and physically hidden. The lock
screen's clock was cut in half by it, the home bar's drag handle was entirely
inside it, and a column of app icons fell into it.

Two files fix that without patching phosh.

```
qcom,sm8150-mtp.json   the hinge, described to gmobile as a cutout
gtk.css                the rest of the shell, moved off the seam
```

## What phosh already knows how to do

gmobile carries a description of the display panel for each device and phosh
asks it where the cutouts are. It looks the file up by the device tree's
`compatible` string:

```
$ cat /firmware/devicetree/base/compatible
qcom,sm8150-mtp
```

Droidian's phosh session already sets

```
G_RESOURCE_OVERLAYS=/org/gnome/gmobile/devices/display-panels=/var/lib/droidian/phosh-notch
```

and nothing ever put a file there. Dropping `qcom,sm8150-mtp.json` into that
directory is enough - the log then says

```
Mapped file '/var/lib/droidian/phosh-notch/qcom,sm8150-mtp.json' as a resource overlay
```

and the top bar's clock, which was centred in the bezel, moves to the left of
the bar. `x-res`/`y-res` are the panel in physical pixels and the cutout path
is in the same units: `M 1350 0 h 84 v 1800 h -84 Z` is the hinge.

That is the whole of phosh's cutout support. `gsettings get sm.puri.phosh
shell-layout` is `device`, which enables it, and the only thing it places is
that clock - every other centred widget in the shell still centres on 464.

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

```
install -Dm644 qcom,sm8150-mtp.json /var/lib/droidian/phosh-notch/qcom,sm8150-mtp.json
install -Dm644 -o droidian -g droidian gtk.css /home/droidian/.config/gtk-3.0/gtk.css
systemctl restart phosh
```

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

`sfduo-dock` is a bar across the bottom of both panels: the same apps on each
side, a gap over the hinge, and the side you touch decides which panel the app
opens on - the Duo's own behaviour.

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

Two rough edges, both known:

- phoc's halves are exactly half the output, so a tiled window reaches 14
  logical pixels into the hinge on its inner edge. Fixing it properly means
  patching `view_arrange_tiled` in phoc to read the same gmobile cutout the
  CSS above is built around.
- `gsettings set sm.puri.phoc auto-maximize false` is what lets a window stay
  tiled rather than being forced back to full width.

## What this does not fix

Phosh has no home screen. When the last window closes it shows the app grid,
and there is no state in which you see a wallpaper and a dock and nothing
else - the dock above floats over the grid rather than replacing it. Giving
the shell a real home screen, or a window per panel as a first-class idea, is
a patch to phosh, not a stylesheet.
