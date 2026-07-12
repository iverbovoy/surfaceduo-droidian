#!/bin/sh
# sfduo: RNDIS gadget + static IP + root telnet (proven on this kernel 2026-07-11)
mount -t configfs none /sys/kernel/config 2>/dev/null
G=/sys/kernel/config/usb_gadget/sfduo
if [ ! -d "$G" ]; then
    UDC=""
    i=0
    while [ $i -lt 60 ]; do
        UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
        [ -n "$UDC" ] && break
        i=$((i + 1)); sleep 1
    done
    [ -z "$UDC" ] && exit 1
    mkdir -p $G/strings/0x409 $G/configs/c.1/strings/0x409 $G/functions/rndis.usb0
    echo 0x1d6b > $G/idVendor
    echo 0x0104 > $G/idProduct
    echo sfduo > $G/strings/0x409/manufacturer
    echo "sfduo Droidian" > $G/strings/0x409/product
    echo duo1-0001 > $G/strings/0x409/serialnumber
    echo rndis > $G/configs/c.1/strings/0x409/configuration
    # 500 (max for USB2 non-PD): the charger ICL follows what we declare -
    # 250 here capped charging at 250 mA (found 2026-07-11)
    echo 500 > $G/configs/c.1/MaxPower
    ln -sf $G/functions/rndis.usb0 $G/configs/c.1/rndis.usb0
    echo "$UDC" > $G/UDC
    sleep 2
fi
IFACE=""
for CAND in usb0 rndis0; do
    [ -e "/sys/class/net/$CAND" ] && IFACE=$CAND && break
done
ip addr add 172.16.42.1/24 dev "${IFACE:-usb0}" 2>/dev/null
ip link set "${IFACE:-usb0}" up
# root shell over telnet (no sshd in this nightly; busybox is static arm64)
/usr/local/bin/busybox telnetd -l /bin/bash -b 172.16.42.1 -p 23
exit 0
