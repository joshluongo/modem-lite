# modem-lite

An OpenWrt package feed with one package, `luci-app-modem-lite`. It is a small
LuCI app and helper daemon for an AT-command USB LTE modem. It was written for
the Quectel EC200A in the MERCUSYS MB118-4G v1 and kept small for its 8 MiB
flash.

- **Network → Mobile Modem**: live signal (bars, RSRP/RSRQ/RSSI), operator,
  registration, SIM state, data-connection state, modem identity. It has
  *Reconnect* and *Restart modem* buttons, plus settings for automatic
  connection, APN, IP type, PAP/CHAP, SIM PIN, data context, AT/SMS ports, the
  check interval and the signal LEDs.
- **SMS → Messages**: the inbox stored on the modem (multipart messages are
  joined). Each message can be forwarded to Slack or deleted. There is also a
  form for sending an SMS.
- **SMS → Slack Forwarding**: posts new incoming SMS to a Slack
  [incoming webhook](https://api.slack.com/messaging/webhooks), optionally
  deleting them from the modem afterwards, with a test button.

The daemon (`/etc/init.d/modem-lite`) also keeps the modem's data call up and
drives the signal LEDs. It replaces the former in-tree `mercusys-modem`
helper. If you still run an image that contains that helper, disable it
(`/etc/init.d/mercusys-modem disable; /etc/init.d/mercusys-modem stop`), so
the two do not share the AT port.

## Footprint

All code is ucode, shell and JavaScript (architecture `all`). The only new
dependency is `sms-tool` (a ~20 KB C binary), used for all modem I/O. Everything
else (`luci-base`, `ucode`, `rpcd`, `uclient-fetch`, `ca-bundle`) is already in a
standard LuCI image. `comgt` is not needed.

## Build

Add this repository as a feed in your OpenWrt tree or SDK:

```sh
echo "src-git modemlite https://github.com/joshluongo/modem-lite.git" >> feeds.conf
# or, for a local checkout:
# echo "src-link modemlite /path/to/modem-lite" >> feeds.conf
./scripts/feeds update modemlite
./scripts/feeds install luci-app-modem-lite
```

Then either build it into the image (`CONFIG_PACKAGE_luci-app-modem-lite=y`
in `make menuconfig`, under LuCI → Applications) or build just the package:

```sh
make package/luci-app-modem-lite/compile
# -> bin/packages/<arch>/modemlite/luci-app-modem-lite-1.0.0-r1.apk
```

Packages installed with `apk` live in the overlay (about 1 MiB free on the
MB118-4G) and are not kept across `sysupgrade`. Building the package into the
image avoids both problems.

## Install a built package

```sh
scp -O luci-app-modem-lite-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'apk update && apk add sms-tool &&
  apk add --allow-untrusted /tmp/luci-app-modem-lite-*.apk'
```

`--allow-untrusted` is needed because your own build is not signed with the
release key.

## Configuration

`/etc/config/modem-lite` (also editable from LuCI):

| Option | Default | Meaning |
| --- | --- | --- |
| `modem.autoconnect` | `1` | Keep the data call up while `wan` is `proto dhcp` on the modem's network interface |
| `modem.apn` | (unset) | APN to write to the data context. Leave unset to keep the APN stored in the modem |
| `modem.pdptype` | `IPV4V6` | `IP`, `IPV6` or `IPV4V6` |
| `modem.auth`, `username`, `password` | `none` | `none`, `pap` or `chap` |
| `modem.pin` | (unset) | SIM PIN, entered at most once per boot |
| `modem.cid` | auto | Data context: first context with a non-IMS APN (2 on the MB118 stock profile) |
| `modem.at_port`, `modem.sms_port` | auto | tty on USB interface 3 / 4 |
| `modem.interval` | `15` | Seconds between checks |
| `modem.signal_led` | `green:signal1..3` | LEDs used as signal bars |
| `slack.enabled`, `slack.webhook`, `slack.delete` | off | SMS forwarding to Slack |
| `slack.label` | hostname | Device label shown under each forwarded message |

Forwarded messages use the same card layout as
[lazysms](https://github.com/joshluongo/lazysms): 📱 bold sender, the body as
plain text exactly as received, and a context line with the received time
(router's local time zone) and the device label, posted as `modem-lite`.

Limits that come from `sms-tool`:

- Sent messages are a single GSM 7-bit SMS: plain ASCII, up to 160
  characters. The characters `^{}\[~]|` count twice.
- Numbers must be in international format.
- `sms-tool` prints the SMS centre's local time without its zone. The
  package reads the zone from each raw PDU and converts it to UTC; LuCI shows
  the result in the browser's time zone.

When Slack forwarding is first enabled, the messages already on the modem
are recorded as seen and are not posted. Forwarding state is kept in
`/etc/modem-lite/forwarded`, which is written only when a message is
forwarded or disappears.

## Tests

The tests run in the official OpenWrt rootfs container. A fake `sms_tool`
reproduces the EC200A replies recorded on the device, and a fake sysfs tree
stands in for the hardware:

```sh
docker run --rm --platform linux/amd64 -v "$PWD:/src:ro" \
  openwrt/rootfs:x86-64-v25.12.6 sh /src/tests/run.sh
```
