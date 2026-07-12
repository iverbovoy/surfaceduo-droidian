# Temporary USB shell access - Droidian api30 nightly (no sshd)

Proven working 2026-07-11 on the Surface Duo 1 (serial <your-serial>).
The droidian phosh nightly ships no sshd, so these files inject our own
USB RNDIS gadget + a root telnet shell. Hand-injected from TWRP for now;
they will fold into the `adaptation-droidian-surfaceduo` package.

## Install (from TWRP, rootfs.img loop-mounted at /r)

```
cp sfduo-usb-gadget.sh /r/usr/local/sbin/ && chmod 755 /r/usr/local/sbin/sfduo-usb-gadget.sh
cp <static-arm64-busybox> /r/usr/local/bin/busybox && chmod 755 /r/usr/local/bin/busybox
#   (get one from Debian's busybox-static arm64 package: dpkg -x, take /bin/busybox)
cp sfduo-usb.service /r/etc/systemd/system/
ln -sf /etc/systemd/system/sfduo-usb.service \
       /r/etc/systemd/system/multi-user.target.wants/sfduo-usb.service
mkdir -p /r/etc/NetworkManager/conf.d && cp 99-sfduo-usb.conf /r/etc/NetworkManager/conf.d/
```

## Connect (host)

```
# a new RNDIS iface (enx…) appears ~40 s after RAM-boot
nmcli con mod "<conn>" ipv4.method manual ipv4.addresses 172.16.42.2/24 ipv4.never-default yes
nmcli con up "<conn>"
telnet 172.16.42.1
```

## Known limitations

- **busybox telnetd has no pty**: long piped output and `$(...)`
  readback get truncated. Run ONE short command per line, or dump to a
  file under /data and read it back from TWRP with adb. This is why the
  first fix (`ssh`) is a real openssh-server.
- Pick the gadget iface explicitly (`usb0`/`rndis0`), never the
  alphabetically-first netdev - the downstream kernel ships `bond0`,
  which stole 172.16.42.1 on the first attempt.
