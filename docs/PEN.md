# The pen: what the digitizer sends, and what userspace gets

Short version: the Duo's digitizer reports a full pressure stylus. Almost
none of that reaches applications, and the reason is a udev rule this
port cannot currently do without.

Measured 2026-09-14 on a running device, kernel 4.14.190, adaptation
0.12.0. The pen used was a third-party MPP stylus (Metapen), not a
Microsoft pen, so an original may expose more.

## One device for two tools

The vendor `touchpen` HAL reads hidraw from the kernel spi-hid driver
and creates a single uinput node for both finger and pen:

```
/dev/input/event5   surface_touchscreen
```

It advertises pen bits, so udev classifies it `ID_INPUT_TABLET` and
libinput ignores it completely: no touch at all. The adaptation ships
`99-sfduo-touch.rules` to force it back to the touchscreen class, which
is what makes touch work and, in the same move, throws every pen
property away.

## What the node advertises

| | |
|---|---|
| `ABS_MT_PRESSURE` | 0 - 65535 |
| `ABS_MT_TOOL_TYPE` | 0 - 15 |
| `ABS_MT_TOUCH_MAJOR` / `MINOR` | 0 - 21067 |
| `ABS_MT_ORIENTATION` | -90 - 90 |
| `ABS_MT_POSITION_X` / `Y` | 0 - 17709 / 0 - 11411 |
| `ABS_MT_SLOT` | 0 - 11 (12 slots) |
| `BTN_STYLUS`, `BTN_TOOL_RUBBER` | present |

Absent: `ABS_PRESSURE`, `BTN_TOOL_PEN`, `BTN_TOUCH`, `ABS_DISTANCE`,
`ABS_TILT_X/Y`. The pen data uses the multitouch protocol throughout,
which is why nothing keyed on the classic tablet bits sees it.

## What it actually emits

Ten seconds of continuous contact, same node, same session:

| | finger | pen |
|---|---|---|
| position events | 385 | 1643 |
| pressure events | 18 | 1170 |
| pressure values | 0 or 65535 only | continuous, up to 60079 |
| `ABS_MT_TOUCH_MAJOR` | 375 events, 864 - 1671 | not sent |
| `ABS_MT_TRACKING_ID` | 0 - 23 | 65535 |

So pressure from a finger is a contact flag, and pressure from the pen
is real graded data at roughly three times the sampling rate.

Separately confirmed on the pen: `BTN_STYLUS` toggles with the barrel
button, `BTN_TOOL_RUBBER` toggles with the second control, and
`ABS_MT_TOOL_TYPE` is emitted with value 1 (`MT_TOOL_PEN`) when the
tool changes. The pen also tracks while hovering above the glass
without touching it.

## Reproducing this

`python3-evdev` is already on the device (the adaptation uses it).
Read the node without grabbing it, so the running session is
undisturbed:

```python
from evdev import InputDevice, ecodes
dev = InputDevice("/dev/input/event5")     # surface_touchscreen
print(dev.capabilities(verbose=True))      # what it advertises
for e in dev.read_loop():                  # what it sends
    if e.type != ecodes.EV_SYN:
        print(ecodes.EV[e.type], e.code, e.value)
```

## The fix, for whoever wants it

Split the stream into two uinput devices: a touchscreen carrying
fingers and a tablet carrying the pen, then hide the original node from
libinput. The discriminator is unambiguous, three independent signals
pointing the same way:

- pen: tracking id 65535, continuous `ABS_MT_PRESSURE`, no
  `ABS_MT_TOUCH_MAJOR`
- finger: small incrementing tracking id, pressure only at down and up,
  `ABS_MT_TOUCH_MAJOR` / `MINOR` / `ORIENTATION` present

The pen device should map `ABS_MT_PRESSURE` to `ABS_PRESSURE` and
announce `BTN_TOOL_PEN`, which is what libinput needs to expose it as a
tablet tool. `ABS_MT_TOUCH_MAJOR` on the finger side is also the raw
material for palm rejection, which does not exist on this port today.

Note that the splitter has to `EVIOCGRAB` the original node, so a crash
takes all input with it. Whoever builds this should treat the watchdog
as part of the job.
