# bench: the port against stock Android, measured the same way

Stock Android goes on the Surface Duo once more, to be measured, and is then
never installed on it again: the numbers kept here are the baseline the port
is compared against from then on. The same measurements are taken on a
Surface Duo 2 with its stock Android, to see how the port on the first Duo
stands against the newer phone. The work is #177.

Everything is driven from the computer by `sfduo-bench`: over ssh when the
phone runs the port, over adb when it runs Android. Each run appends its raw
measurements, one JSON object a line, to `results/<date>-<target>.jsonl`;
`sfduo-bench report results/*.jsonl` prints them side by side.

## Conditions

A number taken under other conditions is not the same number. Before every
series:

- **The phone at rest.** Five minutes untouched after a boot or an install,
  nothing else started, the phone at room temperature (neither charging hot
  nor fresh from a pocket).
- **Charge between 100 and 60 %.** The fuel gauge's power limits
  (thermal-engine's `fg-pack` zones, #174) do not act in that range.
- **Display on and unlocked.** The port's shell throttles with the display off
  (`docs/PERF.md`), and on a locked phone every swipe lands on the lock
  screen, which redraws all of itself each frame. `sfduo-bench` refuses to run
  either way.
- **Brightness fixed** at the same backlight level on both systems (read from
  sysfs on the Duo 1, where both systems drive the same panels).
- **Wi-Fi on and connected, SIM in, Bluetooth off**, on both.
- **The same apps on the same data**: the phone freshly set up, no accounts
  signed in, so that no app has anything to load but itself.

Every measurement is repeated 10 times. The report gives the median with
the range; the first repetition after a start of the shell or a boot is
kept, and shows as the upper end of the range, because a user meets it too.

## Scenarios

### launch - from the request to the app's first frame

Each app is started from nothing: its window closed and its process gone,
page cache left as it is (neither system's "cold start" drops the page
cache). On the port the request is the dock's launch (the same path as a tap
on its icon), and the first frame is the compositor mapping the app's window
(`phoc_view_map`) and the output frame that follows it. On Android it is
`am start -W` - the activity manager's `TotalTime`, from the intent to the
app's first frame drawn.

The two measure slightly different ends: Android's TotalTime stops when the
app has drawn its first frame; the port's stops when the compositor has put
it on the panel. The port's number is therefore the stricter one, by up to a
frame.

Apps that run all the time by design - Clock (alarms), Phone (incoming
calls) and Messages (incoming texts) on the port - are not killed; their
launch is a window from a running process, and is marked `resident`.

The apps, by kind:

| kind | port | Android (Duo 1 / Duo 2) |
|---|---|---|
| settings | GNOME Settings | Settings |
| calculator | GNOME Calculator | to be listed from the device |
| clock | GNOME Clocks | Clock |
| contacts | GNOME Contacts | Contacts |
| phone | GNOME Calls | Phone |
| messages | Chatty | Messages |
| calendar | GNOME Calendar | Outlook / Calendar |
| weather | GNOME Weather | MSN Weather or none |
| browser | Firefox | Edge |
| camera | Droidian Camera | Camera |

The Android column is filled in from the devices themselves; a kind with no
counterpart is left out of the comparison rather than matched with something
unlike it.

### What every launch must do

A launch is good when it does all of these, every time; the launch scenario
is to check each one and say which launch broke which, with the frame:

1. **It answers at once.** Within 100 ms of the tap something on the panel
   changes - on the port, the dock's curtain with the app's name.
2. **It always finishes.** Ten launches out of ten end with the app's window;
   the curtain is never left standing.
3. **No empty or black frame.** From the tap to the app's window, every frame
   on the panel shows either the curtain or the app.
4. **No flicker.** Once shown, the window is not hidden and shown again, and
   the panel's brightness does not dip and come back.
5. **In place from its first frame.** The window's first frame has the size
   and position it keeps, covering its panel: no jump, no strip through
   which another app shows.
6. **In time.** The first frame no later than the app's baseline (its median
   in the report), and the curtain gone within two frames of it.

Checked with a 60 fps screen recording of each launch (1, 3, 4, 5) and
probes in the compositor on the window's map and unmap and its geometry
(1, 2, 4, 5, 6).

### grid - the app list opened and closed

A swipe up opens the list of all apps and a swipe down closes it: the port's
app grid, and on Android the launcher's app drawer. What is measured is the
compositor's frame times through each motion - from the finger coming down
until the first pause of 150 ms after it lifts - read as:

- `dropped`: frames missed, a frame 1.5 refreshes late or more counting as one
  per refresh missed,
- `p50`, `p95`, `max`: the time between frames, in ms (16.7 is every refresh),
- `fps` over the motion.

On the port the frames are the compositor's output frames
(`wlr_output_send_frame` in wlroots, probed with perf); on Android,
SurfaceFlinger's present times for the launcher's layer
(`dumpsys SurfaceFlinger --latency`).

The finger is synthetic on both: `sfduo-touch script` on the port (one uinput
touchscreen for the whole series), `input swipe` on Android, each at the same
distance and speed. The port's finger lifts while it is still moving: a
finger resting before it lifts showed, in the frame times, as frames the
shell had dropped (#148).

### Still to be written

- **drain**: the charge counter of the Duo 1's fuel gauge - the same gauge on
  both systems - with the display on at the fixed brightness and with the
  phone closed; `dumpsys batterystats` alongside on Android.
- **boot**: from the power key to a usable screen.
- **wake**: from the power key and from opening the lid to the first frame.
- **scroll**: a long list in Settings, flung.
- **switch**: an app in the background brought back.

## What not to trust

Found while writing this, and guarded against in the tool:

- A perf probe on a function that is also called through the library's PLT
  gets two probe points; the PLT one sees only some calls. Frames recorded
  there looked dropped in pairs. Only the function itself is recorded.
- A phone that locked itself during a series measured the lock screen.
