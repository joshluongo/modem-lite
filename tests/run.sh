#!/bin/sh
# Run the modem-lite tests in an OpenWrt rootfs container:
#   docker run --rm --platform linux/amd64 -v "$PWD:/src:ro" \
#     openwrt/rootfs:x86-64-v25.12.6 sh /src/tests/run.sh
set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
PKG=$SRC/luci-app-modem-lite/root

export FAKE=/tmp/fake MODEMLITE_SYSROOT=/tmp/sysroot \
	MODEMLITE_RUNDIR=/tmp/ml-run MODEMLITE_FWD_STATE=/tmp/ml-forwarded
mkdir -p "$FAKE" /tmp/bin
cp "$SRC/tests/fake/sms_tool" "$SRC/tests/fake/uclient-fetch" /tmp/bin/
chmod +x /tmp/bin/*
export PATH=/tmp/bin:$PATH

# Fake sysfs: EC200A on 1-1 with RNDIS usb0 and option ttys on interfaces 2-4.
S=$MODEMLITE_SYSROOT/sys
U=$S/devices/platform/usb/1-1
mkdir -p "$S/class/tty" "$U/1-1:1.0/net/usb0"
for i in 0 1 2; do
	mkdir -p "$U/1-1:1.$((i + 2))/ttyUSB$i/tty/ttyUSB$i"
	mkdir -p "$S/class/tty/ttyUSB$i"
	ln -s "../../../devices/platform/usb/1-1/1-1:1.$((i + 2))/ttyUSB$i" "$S/class/tty/ttyUSB$i/device"
done
for i in 1 2 3; do
	mkdir -p "$S/class/leds/green:signal$i"
	echo 0 > "$S/class/leds/green:signal$i/brightness"
done

mkdir -p /usr/share/ucode
cp "$PKG/usr/share/ucode/modemlite.uc" /usr/share/ucode/

ucode -L /usr/share/ucode "$SRC/tests/test.uc"

# rpcd plugin contract: "list" signature and a "call" with JSON on stdin.
cp "$PKG/etc/config/modem-lite" /etc/config/modem-lite
touch /etc/config/network
uci -q set network.wan=interface
uci -q set network.wan.proto=dhcp
uci -q set network.wan.device=usb0
uci commit network
ucode "$PKG/usr/libexec/rpcd/modem-lite" list | jsonfilter -e '@.sms_send.number' | grep -qx str
echo '{"number":"+61412345678","text":"via rpc"}' |
	ucode "$PKG/usr/libexec/rpcd/modem-lite" call sms_send | jsonfilter -e '@.ok' | grep -qx true
ucode "$PKG/usr/libexec/rpcd/modem-lite" call connect | jsonfilter -e '@.connected' | grep -qx true
ucode "$PKG/usr/libexec/rpcd/modem-lite" call status | jsonfilter -e '@.operator' | grep -qx 'Telstra Mobile'
echo "rpcd plugin checks passed"
