# Hinge-angle sensor for sensorfw (Surface Duo posture)

The Duo's hinge angle (0-360°, `android.sensor.hinge_angle`, type 36,
served by the MS `sns_fold` sensor on the SLPI) is not a sensor type
sensorfw knows about. This patch adds a `hybrishingeadaptor` +
`hingesensor` pair so the live angle is available over DBus.

Verified on device 2026-07-11: fold the device and degrees stream in
real time (146→167→152→120→156° in one test).

## What's here

- `hinge-core.patch` - changes to existing sensorfw files:
  `core/hybrisadaptor.{h,cpp}` (SENSOR_TYPE_HINGE_ANGLE), registration
  in `adaptors/adaptors.pro` + `sensors/sensors.pro`, and the new
  plugin `.so`s added to `debian/libsensorfw-qt6-plugins.install`.
- `new-files/` - the new adaptor + sensor sources (drop onto the tree
  as-is) and a template `debian/changelog` (the Droidian CI generates
  one at build time; building outside CI you must provide it yourself).

## Build

```
git clone https://github.com/sailfishos/sensorfw.git   # droidian uses the qt6 branch of its fork
# use the same source the droidian package was built from:
#   apt source sensorfw-qt6      (on the device or any droidian chroot)
cd sensorfw
git apply /path/to/hinge-core.patch
cp -r /path/to/new-files/* .
dpkg-buildpackage -us -uc -b       # arm64; a qemu-aarch64 chroot of the
                                   # droidian rootfs works (~1.5 h), needs
                                   # debhelper + qt6 build-deps installed
```

## Install traps (all hit in practice)

- Install the resulting qt6 debs with `apt install ./libsensorfw-qt6*.deb
  ./sensorfw-qt6*.deb` - plus the **qt5 transitional stubs from the same
  build**. Installing only the qt6 halves deconfigures the stock qt5
  stubs and wedges apt.
- The plugin only loads if it is mapped in the config file sensorfwd
  actually reads: it runs with `-c=/etc/sensorfw/sensord-hybris.conf`
  and ignores conf.d-style numbered files. Append:

  ```
  [plugins]
  hingeadaptor = hybrishingeadaptor
  ```

  (`adaptation/package/build.sh`'s postinst does this automatically.)

## Reading the angle

```
dbus-send --system --print-reply --dest=com.nokia.SensorService \
  /SensorManager local.SensorManager.requestSensor string:hingesensor
dbus-send --system --print-reply --dest=com.nokia.SensorService \
  /SensorManager/hingesensor local.HingeSensor.start int32:<sessionid>
dbus-send --system --print-reply --dest=com.nokia.SensorService \
  /SensorManager/hingesensor org.freedesktop.DBus.Properties.Get \
  string:local.HingeSensor string:hinge      # uint32 degrees
```
