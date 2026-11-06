// Shared logic for luci-app-modem-lite: modem status and data call, APN,
// SIM PIN, signal LEDs, SMS and Slack forwarding.
//
// Written for the Quectel EC200A (ASR, RNDIS) in the MERCUSYS MB118-4G v1 but
// only relies on standard 3GPP commands plus Quectel's AT+QNETDEVCTL. All AT
// and SMS traffic goes through sms_tool (package sms-tool), serialised per
// port with flock. By default the modem's USB interface 3 is the control port
// and interface 4 the SMS port, so the two never contend.

'use strict';

let fs = require('fs');
let uci = require('uci');

// Test seam: prefixes /sys lookups so tests can supply a fake sysfs tree.
const SYSROOT = getenv('MODEMLITE_SYSROOT') ?? '';
const RUNDIR = getenv('MODEMLITE_RUNDIR') ?? '/var/run/modem-lite';
const STATUS_FILE = RUNDIR + '/status.json';
const FWD_STATE = getenv('MODEMLITE_FWD_STATE') ?? '/etc/modem-lite/forwarded';
const LOCKDIR = '/var/lock';
const INCOMPLETE_GRACE = 900;	// forward a multipart SMS with missing parts after 15 min

let last_log = null;
let prev_level = null;
let verbose_log = false;

function log(msg) {
	if (!verbose_log || msg == last_log)
		return;

	last_log = msg;
	system(['logger', '-t', 'modem-lite', msg]);
}

// Single-quote for /bin/sh.
function q(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function run(cmd) {
	let p = fs.popen(cmd, 'r');

	if (!p)
		return { code: -1, out: '' };

	let out = p.read('all') ?? '';
	let code = p.close();

	return { code, out: replace(out, /\r/g, '') };
}

function lock_for(port) {
	fs.mkdir(LOCKDIR);

	return LOCKDIR + '/modem-lite.' + replace(port, /^.*\//, '') + '.lock';
}

function config() {
	let c = uci.cursor();
	let modem = c.get_all('modem-lite', 'modem') ?? {};
	let slack = c.get_all('modem-lite', 'slack') ?? {};
	let wan = c.get_all('network', 'wan') ?? {};

	return { modem, slack, wan };
}

function interval(cfg) {
	let n = +cfg.modem.interval;

	return (n >= 5 && n <= 3600) ? n : 15;
}

/* ---- Port discovery ------------------------------------------------------ */

// "/dev/ttyUSBn" of the tty on USB interface <ifnum> (e.g. ".../1-1:1.3/ttyUSB1").
function find_tty(ifnum) {
	let dir = SYSROOT + '/sys/class/tty';

	for (let name in sort(fs.lsdir(dir) ?? [])) {
		if (!match(name, /^ttyUSB[0-9]+$/))
			continue;

		let dev = fs.realpath(dir + '/' + name + '/device');

		if (dev && match(dev, regexp(':1\\.' + ifnum + '/' + name + '$')))
			return '/dev/' + name;
	}

	return null;
}

// Name of the network interface on the same USB device as the AT port (usb0).
function netdev_of(port) {
	let dev = fs.realpath(SYSROOT + '/sys/class/tty/' + replace(port, /^.*\//, '') + '/device');

	if (!dev)
		return null;

	let usbdev = fs.dirname(fs.dirname(dev));

	for (let intf in sort(fs.lsdir(usbdev) ?? [])) {
		if (!match(intf, /:1\.[0-9]+$/))
			continue;

		let nets = fs.lsdir(usbdev + '/' + intf + '/net');

		if (nets && length(nets))
			return nets[0];
	}

	return null;
}

function at_port(cfg) {
	let p = cfg.modem.at_port;

	if (p)
		return fs.access(p) ? p : null;

	return find_tty(3);
}

function sms_port(cfg) {
	let p = cfg.modem.sms_port;

	if (p)
		return fs.access(p) ? p : null;

	return find_tty(4);
}

/* ---- AT transport and parsers -------------------------------------------- */

// Reply lines of one AT command, without the echo, blank lines and final OK.
function at(port, cmd) {
	let r = run(sprintf('flock %s sms_tool -d %s at %s 2>/dev/null',
		q(lock_for(port)), q(port), q(cmd)));
	let lines = filter(map(split(r.out, '\n'), l => trim(l)), l => l != '' && l != cmd);

	return { ok: r.code == 0, lines };
}

function value_of(lines, prefix) {
	for (let l in lines)
		if (index(l, prefix) == 0)
			return trim(substr(l, length(prefix)));

	return null;
}

// First reply line with any "+XXX:" prefix removed (identity queries).
function first_value(r) {
	if (!r.ok)
		return null;

	for (let l in r.lines) {
		let v = trim(replace(l, /^\+[A-Z]+: */, ''));

		if (v != '')
			return v;
	}

	return null;
}

// [{ cid, pdp, apn }] from AT+CGDCONT?
function parse_cgdcont(lines) {
	let ctx = [];

	for (let l in lines) {
		let m = match(l, /^\+CGDCONT: *([0-9]+),"([^"]*)","([^"]*)"/);

		if (m)
			push(ctx, { cid: +m[1], pdp: m[2], apn: m[3] });
	}

	return ctx;
}

// First defined context whose APN is neither empty nor IMS (stock: 2).
function data_cid(ctx) {
	for (let c in ctx)
		if (c.apn != '' && lc(c.apn) != 'ims')
			return c.cid;

	return null;
}

// { cid, up } from "+QNETDEVCTL: <op>,<cid>,<urc>,<state>"; state 1 = connected.
function parse_link(lines) {
	for (let l in lines) {
		let m = match(l, /^\+QNETDEVCTL: *[0-9]+,([0-9]+),[0-9]+,([0-9]+)/);

		if (m)
			return { cid: +m[1], up: m[2] == '1' };
	}

	return null;
}

// RSRP/RSRQ from "+CESQ: <rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>" (255 = unknown)
// and RSSI from "+CSQ: <rssi>,<ber>" (99 = unknown).
function parse_signal(lines) {
	let s = {};
	let cesq = value_of(lines, '+CESQ:');
	let csq = value_of(lines, '+CSQ:');

	if (cesq) {
		let f = map(split(cesq, ','), x => +x);

		if (length(f) >= 6) {
			if (f[5] >= 0 && f[5] <= 97)
				s.rsrp = f[5] - 141;
			if (f[4] >= 0 && f[4] <= 34)
				s.rsrq = f[4] / 2.0 - 20;
		}
	}

	if (csq) {
		let n = +split(csq, ',')[0];

		if (n >= 0 && n <= 31) {
			s.csq = n;
			s.rssi = 2 * n - 113;
		}
	}

	return s;
}

// LED bars 0-3: RSRP >= -95/-105/-115 dBm, else CSQ >= 20/12/5.
// Thresholds are conventional; the stock table has not been extracted.
function signal_level(s) {
	if (s.rsrp != null)
		return (s.rsrp >= -95) ? 3 : (s.rsrp >= -105) ? 2 : (s.rsrp >= -115) ? 1 : 0;

	if (s.csq != null)
		return (s.csq >= 20) ? 3 : (s.csq >= 12) ? 2 : (s.csq >= 5) ? 1 : 0;

	return 0;
}

const ACT = {
	'0': 'GSM', '2': 'UMTS', '3': 'EDGE', '4': 'HSDPA', '5': 'HSUPA',
	'6': 'HSPA+', '7': 'LTE', '8': 'eMTC', '9': 'NB-IoT', '10': 'LTE',
	'11': 'NR', '12': 'NR', '13': 'LTE+NR'
};

const REG = {
	'0': 'not registered', '1': 'home', '2': 'searching', '3': 'denied',
	'4': 'unknown', '5': 'roaming'
};

function parse_cops(lines) {
	let v = value_of(lines, '+COPS:');
	let m = v ? match(v, /^[0-9]+,[0-9]+,"([^"]*)"(,([0-9]+))?/) : null;

	return m ? { operator: m[1], act: m[3] ? (ACT[m[3]] ?? m[3]) : null } : {};
}

function parse_reg(lines) {
	let v = value_of(lines, '+CEREG:') ?? value_of(lines, '+CREG:');
	let m = v ? match(v, /^[0-9]+,([0-9]+)/) : null;

	return m ? (REG[m[1]] ?? m[1]) : null;
}

/* ---- LEDs, WAN, status file ---------------------------------------------- */

function set_leds(cfg, level) {
	if (level == prev_level)
		return;

	prev_level = level;

	let leds = cfg.modem.signal_led ?? [];

	if (type(leds) != 'array')
		leds = split(leds, /[ \t]+/);

	for (let i = 0; i < length(leds); i++) {
		let f = SYSROOT + '/sys/class/leds/' + leds[i] + '/brightness';

		if (fs.access(f))
			fs.writefile(f, (level > i) ? '1' : '0');
	}
}

// Only dial while wan is the plain DHCP-on-modem setup; switching wan to
// another protocol (e.g. ncm) or disabling it hands control back.
function dial_managed(cfg, netdev) {
	let w = cfg.wan;

	return cfg.modem.autoconnect != '0' && netdev != null &&
		w.proto == 'dhcp' && w.disabled != '1' &&
		(w.device ?? w.ifname) == netdev;
}

// Restart DHCP discovery on wan now instead of after udhcpc's back-off.
function renew_wan() {
	let pid = trim(fs.readfile('/var/run/udhcpc-wan.pid') ?? '');

	if (match(pid, /^[0-9]+$/))
		system(['kill', '-USR1', pid]);
}

function write_status(st) {
	fs.mkdir(RUNDIR);

	let tmp = STATUS_FILE + '.tmp';

	if (fs.writefile(tmp, sprintf('%J', st)))
		fs.rename(tmp, STATUS_FILE);
}

function read_status(cfg) {
	let st = null;

	try {
		st = json(fs.readfile(STATUS_FILE) ?? 'null');
	}
	catch (e) {
		st = null;
	}

	if (!st)
		return { present: false, pending: true };

	st.stale = (time() - st.updated) > 3 * interval(cfg) + 30;

	return st;
}

/* ---- Modem control ------------------------------------------------------- */

// AT string arguments are double-quoted; reject what would break them.
function at_safe(s) {
	return s == null || !match(s, /["[:cntrl:]]/);
}

function connect(port, cid, link) {
	if (link?.up && link.cid != cid)
		at(port, sprintf('AT+QNETDEVCTL=0,%d,1', link.cid));

	// QNETDEVCTL fails with "+CME ERROR: 0" unless the context is active.
	at(port, sprintf('AT+CGACT=1,%d', cid));

	let ok = at(port, sprintf('AT+QNETDEVCTL=1,%d,1', cid)).ok;

	if (ok)
		renew_wan();

	return ok;
}

function disconnect(port, cid) {
	at(port, sprintf('AT+QNETDEVCTL=0,%d,1', cid));
	at(port, sprintf('AT+CGACT=0,%d', cid));
}

// Write the configured APN/PDP type/auth to context <cid> once per change.
// Returns true when the modem's settings were changed.
function apply_apn(cfg, port, cid, ctx, link) {
	let m = cfg.modem;

	if (!m.apn || !cid)
		return false;

	let pdp = m.pdptype ?? 'IPV4V6';
	let auth = { none: 0, pap: 1, chap: 2 }[m.auth ?? 'none'] ?? 0;
	let user = auth ? (m.username ?? '') : '';
	let pass = auth ? (m.password ?? '') : '';
	let sig = join('|', [cid, m.apn, pdp, auth, user, pass]);
	let sigfile = RUNDIR + '/applied';

	if (trim(fs.readfile(sigfile) ?? '') == sig)
		return false;

	if (!at_safe(m.apn) || !at_safe(user) || !at_safe(pass)) {
		log('APN, username or password contains invalid characters, not applied');
		return false;
	}

	let cur = filter(ctx, c => c.cid == cid)[0];
	let changed = false;
	let ok = true;

	if (auth || !cur || cur.apn != m.apn || cur.pdp != pdp) {
		ok = at(port, sprintf('AT+QICSGP=%d,%d,"%s","%s","%s",%d', cid,
			{ IP: 1, IPV6: 2, IPV4V6: 3 }[pdp] ?? 3, m.apn, user, pass, auth)).ok;

		if (!ok) {
			ok = at(port, sprintf('AT+CGDCONT=%d,"%s","%s"', cid, pdp, m.apn)).ok;

			if (ok && auth)
				ok = at(port, sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth, user, pass)).ok;
		}

		changed = ok;
	}

	if (ok) {
		fs.mkdir(RUNDIR);
		fs.writefile(sigfile, sig);
	}

	if (changed) {
		log(sprintf('APN "%s" (%s) written to context %d', m.apn, pdp, cid));

		// Drop the running bearer so the next connect uses the new APN.
		if (link?.up && link.cid == cid)
			disconnect(port, cid);
	}
	else if (!ok) {
		log(sprintf('failed to write APN to context %d', cid));
	}

	return changed;
}

// Enter the SIM PIN once per PIN value per boot, so a wrong PIN can never
// use up the SIM's remaining attempts.
function unlock_sim(cfg, port, sim) {
	let pin = cfg.modem.pin;
	let tried = RUNDIR + '/pin_tried';

	if (sim != 'SIM PIN' || !pin || !match(pin, /^[0-9]{4,8}$/))
		return false;

	if (trim(fs.readfile(tried) ?? '') == pin)
		return false;

	fs.mkdir(RUNDIR);
	fs.writefile(tried, pin);

	let ok = at(port, sprintf('AT+CPIN="%s"', pin)).ok;

	log(ok ? 'SIM unlocked' : 'SIM PIN rejected, not retrying until the PIN changes');

	return ok;
}

function identity(port) {
	let cached = null;

	try {
		cached = json(fs.readfile(RUNDIR + '/identity.json') ?? 'null');
	}
	catch (e) {
		cached = null;
	}

	if (cached?.port == port && cached?.imei)
		return cached;

	let id = {
		port,
		manufacturer: first_value(at(port, 'AT+CGMI')),
		model: first_value(at(port, 'AT+CGMM')),
		revision: first_value(at(port, 'AT+CGMR')),
		imei: first_value(at(port, 'AT+CGSN')),
		iccid: first_value(at(port, 'AT+QCCID')) ?? first_value(at(port, 'AT+CCID'))
	};

	fs.mkdir(RUNDIR);
	fs.writefile(RUNDIR + '/identity.json', sprintf('%J', id));

	return id;
}

// One poll: unlock SIM, apply APN, keep the data call up, update LEDs and
// the status file. opts.force_connect reconnects even if the link is up.
function cycle(cfg, opts) {
	let st = { updated: time(), present: false };
	let port = at_port(cfg);

	if (!port) {
		log('modem AT port not found');
		set_leds(cfg, 0);
		write_status(st);

		return st;
	}

	st.present = true;
	st.netdev = netdev_of(port);

	let id = identity(port);

	for (let k in id)
		st[k] = id[k];

	st.sim = value_of(at(port, 'AT+CPIN?').lines, '+CPIN:');

	if (unlock_sim(cfg, port, st.sim))
		st.sim = value_of(at(port, 'AT+CPIN?').lines, '+CPIN:');

	let ctx = parse_cgdcont(at(port, 'AT+CGDCONT?').lines);
	let cid = +cfg.modem.cid || data_cid(ctx) || (cfg.modem.apn ? 1 : null);
	let link = parse_link(at(port, 'AT+QNETDEVCTL?').lines);

	if (apply_apn(cfg, port, cid, ctx, link)) {
		ctx = parse_cgdcont(at(port, 'AT+CGDCONT?').lines);
		link = parse_link(at(port, 'AT+QNETDEVCTL?').lines);
	}

	if (!cid) {
		log('no stored internet context in AT+CGDCONT?, not connecting');
	}
	else if (opts?.force_connect || dial_managed(cfg, st.netdev)) {
		if (opts?.force_connect && link?.up)
			disconnect(port, link.cid);

		if (opts?.force_connect || !(link?.up && link.cid == cid)) {
			log(sprintf('data link down (%s), connecting context %d',
				link ? sprintf('context %d, state %d', link.cid, link.up) : 'no reply', cid));
			connect(port, cid, opts?.force_connect ? null : link);
			link = parse_link(at(port, 'AT+QNETDEVCTL?').lines);
		}
		else {
			log(sprintf('data link up on context %d', cid));
		}
	}

	let ctxinfo = filter(ctx, c => c.cid == cid)[0];

	st.cid = cid;
	st.apn = ctxinfo?.apn;
	st.pdp = ctxinfo?.pdp;
	st.connected = !!(link?.up && link.cid == cid);
	st.autoconnect = dial_managed(cfg, st.netdev);

	let sig = parse_signal([...at(port, 'AT+CESQ').lines, ...at(port, 'AT+CSQ').lines]);
	let cops = parse_cops(at(port, 'AT+COPS?').lines);

	for (let k in sig)
		st[k] = sig[k];

	st.operator = cops.operator;
	st.act = cops.act;
	st.registration = parse_reg(at(port, 'AT+CEREG?').lines);
	st.level = signal_level(sig);

	set_leds(cfg, st.level);
	write_status(st);

	return st;
}

function restart_modem(cfg) {
	let port = at_port(cfg);

	if (!port)
		return { error: 'Modem AT port not found' };

	// The modem resets and re-enumerates on USB; re-read its identity after.
	fs.unlink(RUNDIR + '/identity.json');

	return at(port, 'AT+CFUN=1,1').ok ? { ok: true } : { error: 'Modem did not accept AT+CFUN=1,1' };
}

/* ---- SMS ----------------------------------------------------------------- */

// Seconds since the epoch for "YYYY-MM-DD HH:MM:SS" in UTC.
function utc_epoch(ts) {
	let m = match(ts ?? '', /^([0-9]+)-([0-9]+)-([0-9]+) ([0-9]+):([0-9]+):([0-9]+)$/);

	if (!m)
		return null;

	let y = +m[1], mo = +m[2], d = +m[3];

	// Days from civil (Howard Hinnant).
	y -= (mo <= 2) ? 1 : 0;

	let era = int((y >= 0 ? y : y - 399) / 400);
	let yoe = y - era * 400;
	let doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1;
	let doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
	let days = era * 146097 + doe - 719468;

	return days * 86400 + (+m[4]) * 3600 + (+m[5]) * 60 + (+m[6]);
}

// Time zone in minutes east of UTC from the TP-SCTS of an SMS-DELIVER PDU
// (hex, with SMSC prefix), or null. The zone octet holds quarter hours as
// swapped BCD; bit 3 is the sign.
function pdu_tz(pdu) {
	let byte = (i) => {
		let s = substr(pdu, i * 2, 2);

		return (length(s) == 2) ? hex(s) : null;
	};
	let i = byte(0) + 1;			// skip SMSC address

	if (byte(i) == null || (byte(i) & 0x03) != 0)	// not SMS-DELIVER
		return null;

	let digits = byte(i + 1);

	i += 3 + int((digits + 1) / 2) + 2;	// first octet, OA length/type/digits, PID, DCS

	let tz = byte(i + 6);

	if (type(tz) != 'int' || length(pdu) < (i + 7) * 2)
		return null;

	let quarters = (tz & 0x07) * 10 + (tz >> 4);

	return ((tz & 0x08) ? -quarters : quarters) * 15;
}

// { index: tz minutes } from "sms_tool -r recv" ("MSG: <n>" then the PDU).
function pdu_zones(out) {
	let zones = {}, idx = null;

	for (let l in split(out ?? '', '\n')) {
		let m = match(trim(l), /^MSG: ([0-9]+)$/);

		if (m)
			idx = m[1];
		else if (idx != null && match(trim(l), /^[0-9A-Fa-f]+$/)) {
			zones[idx] = pdu_tz(trim(l));
			idx = null;
		}
	}

	return zones;
}

// "YYYY-MM-DD HH:MM:SS" in UTC for an epoch.
function fmt_utc(t) {
	let g = gmtime(t);

	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', g.year, g.mon, g.mday, g.hour, g.min, g.sec);
}

// SMSC local "YYYY-MM-DD HH:MM:SS" plus zone (minutes) -> same format in UTC.
function to_utc(ts, tz_minutes) {
	let t = utc_epoch(ts);

	if (t == null || tz_minutes == null)
		return ts;

	return fmt_utc(t - tz_minutes * 60);
}

// Join the parts of multipart messages: [{ indexes, sender, timestamp, text,
// parts, total, complete }], newest first.
function merge_parts(raw) {
	let out = [], groups = {};

	for (let m in raw ?? []) {
		if (m.error)
			continue;

		if (!(m.total > 1)) {
			push(out, {
				indexes: [m.index], sender: m.sender, timestamp: m.timestamp,
				text: m.content ?? '', parts: 1, total: 1, complete: true
			});
			continue;
		}

		let key = sprintf('%s|%d|%d', m.sender, m.reference, m.total);

		groups[key] ??= [];
		push(groups[key], m);
	}

	for (let key, list in groups) {
		list = sort(list, (a, b) => a.part - b.part);

		let seen = {}, text = '', indexes = [];

		for (let p in list) {
			push(indexes, p.index);

			if (seen[p.part])
				continue;

			seen[p.part] = true;
			text += p.content ?? '';
		}

		push(out, {
			indexes, sender: list[0].sender, timestamp: list[0].timestamp, text,
			parts: length(keys(seen)), total: list[0].total,
			complete: length(keys(seen)) >= list[0].total
		});
	}

	return sort(out, (a, b) => (a.timestamp < b.timestamp) - (a.timestamp > b.timestamp));
}

function sms_list(cfg) {
	let port = sms_port(cfg);

	if (!port)
		return { error: 'Modem SMS port not found' };

	let r = run(sprintf('flock %s sms_tool -d %s -j -f %s recv 2>/dev/null',
		q(lock_for(port)), q(port), q('%Y-%m-%d %H:%M:%S')));
	let d = null;

	try {
		d = json(r.out);
	}
	catch (e) {
		d = null;
	}

	if (r.code != 0 || type(d?.msg) != 'array')
		return { error: 'Could not read messages from the modem' };

	// sms_tool prints the SMSC's local time without its zone; take the zone
	// from each raw PDU and report UTC.
	let raw = run(sprintf('flock %s sms_tool -d %s -r recv 2>/dev/null',
		q(lock_for(port)), q(port)));
	let zones = pdu_zones(raw.out);

	for (let m in d.msg)
		m.timestamp = to_utc(m.timestamp, zones[m.index]);

	return { messages: merge_parts(d.msg) };
}

// sms_tool sends GSM 7-bit only; these characters take two septets.
function sms_septets(text) {
	return length(text) + length(match(text, /[][{}\\^~|]/g) ?? []);
}

function sms_send(cfg, number, text) {
	number = replace(trim(number ?? ''), /[ ()-]/g, '');
	text = replace(text ?? '', /\r/g, '');

	// sms_tool encodes numbers of 6+ digits as international, with no '+'.
	number = replace(number, /^\+/, '');

	if (!match(number, /^[0-9]{3,20}$/))
		return { error: 'Invalid phone number' };

	if (length(number) >= 6 && substr(number, 0, 1) == '0')
		return { error: 'Use the international number format, e.g. +61412345678' };

	if (match(text, /[^\n\x20-\x7e]/))
		return { error: 'Only plain ASCII text can be sent' };

	if (text == '' || sms_septets(text) > 160)
		return { error: 'Message must be 1 to 160 characters' };

	let port = sms_port(cfg);

	if (!port)
		return { error: 'Modem SMS port not found' };

	let r = run(sprintf('flock %s sms_tool -d %s send %s %s 2>&1',
		q(lock_for(port)), q(port), q(number), q(text)));

	if (match(r.out, /sms sent suc/))
		return { ok: true };

	return { error: trim(r.out) || 'Sending failed' };
}

function parse_indexes(s) {
	let idx = [];

	for (let x in split('' + (s ?? ''), ','))
		if (match(trim(x), /^[0-9]+$/))
			push(idx, +x);

	return idx;
}

function sms_delete(cfg, indexes) {
	let port = sms_port(cfg);
	let idx = (type(indexes) == 'array') ? indexes : parse_indexes(indexes);

	if (!port)
		return { error: 'Modem SMS port not found' };

	if (!length(idx))
		return { error: 'No message selected' };

	let failed = [];

	for (let i in idx) {
		let r = run(sprintf('flock %s sms_tool -d %s delete %d 2>&1',
			q(lock_for(port)), q(port), i));

		if (!match(r.out, /Deleted message/))
			push(failed, i);
	}

	return length(failed) ? { error: 'Could not delete message ' + join(', ', failed) } : { ok: true };
}

/* ---- Slack --------------------------------------------------------------- */

// Message layout follows lazysms (github.com/joshluongo/lazysms): a compact
// Block Kit card with the sender, the body as plain_text and a context line.
const SLACK_USERNAME = 'modem-lite';
const SLACK_ICON = ':iphone:';
const SMS_EMOJI = '📱';
const CLOCK_EMOJI = '🕒';
const ZWSP = '​';
const SENDER_MAX = 150;
const SECTION_MAX = 3000;

// Escape for Slack mrkdwn: & < > as entities, and a zero-width space after
// * _ ~ ` (Slack has no backslash escape) so untrusted text cannot format.
function slack_escape(s) {
	s = replace(replace(replace(s ?? '', '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

	return replace(s, /[*_~`]/g, (c) => c + ZWSP);
}

// Truncate to at most <max> UTF-8 characters, optionally ending in "...".
function truncate(s, max, ellipsis) {
	let chars = 0, i = 0, n = length(s);
	let limit = ellipsis ? max - 3 : max;
	let cut = null;

	for (; i < n; i++) {
		if ((ord(s, i) & 0xc0) == 0x80)
			continue;

		if (chars == limit && cut == null)
			cut = i;

		if (++chars > max)
			return substr(s, 0, cut ?? i) + (ellipsis ? '...' : '');
	}

	return s;
}

function hostname() {
	return trim(fs.readfile('/proc/sys/kernel/hostname') ?? 'OpenWrt');
}

// Router-local "YYYY-MM-DD HH:MM:SS (UTC+hh:mm)" for a UTC timestamp.
function local_time(ts) {
	let t = utc_epoch(ts);

	if (t == null)
		return ts ?? '';

	let l = localtime(t);
	let s = sprintf('%04d-%02d-%02d %02d:%02d:%02d', l.year, l.mon, l.mday, l.hour, l.min, l.sec);
	let off = int((utc_epoch(s) - t) / 60);
	let a = (off < 0) ? -off : off;

	return sprintf('%s (UTC%s%02d:%02d)', s, off < 0 ? '-' : '+', int(a / 60), a % 60);
}

function slack_label(cfg) {
	return cfg.slack.label || hostname();
}

function slack_post(cfg, payload) {
	let url = cfg.slack.webhook;

	if (!url || !match(url, /^https:\/\/[^ \t'"]+$/))
		return { error: 'Slack webhook URL is not configured' };

	payload.username = SLACK_USERNAME;
	payload.icon_emoji = SLACK_ICON;

	let r = run(sprintf('uclient-fetch -q -T 20 -O /dev/null --header %s --post-data %s %s 2>&1',
		q('Content-Type: application/json'), q(sprintf('%J', payload)), q(url)));

	return (r.code == 0) ? { ok: true } : { error: trim(r.out) || sprintf('Slack request failed (%d)', r.code) };
}

function slack_message(cfg, msg) {
	let label = slack_label(cfg);
	let body = msg.text ?? '';
	let when = local_time(msg.timestamp);
	let context = [
		{ type: 'mrkdwn', text: CLOCK_EMOJI + ' ' + when },
		{ type: 'mrkdwn', text: slack_escape(label) }
	];

	if (!msg.complete)
		push(context, { type: 'mrkdwn', text: sprintf('incomplete: %d of %d parts', msg.parts, msg.total) });

	return {
		text: truncate(sprintf('%s SMS from %s - %s: %s', SMS_EMOJI, slack_escape(msg.sender),
			slack_escape(label), slack_escape(body)), SECTION_MAX, true),
		blocks: [
			{ type: 'section', text: { type: 'mrkdwn',
				text: SMS_EMOJI + ' *' + truncate(slack_escape(msg.sender), SENDER_MAX, false) + '*' } },
			// plain_text is never parsed by Slack, so the body is sent unescaped.
			{ type: 'section', text: { type: 'plain_text', text: truncate(body, SECTION_MAX, true) || ' ' } },
			{ type: 'context', elements: context }
		]
	};
}

// Stable identity of a message for the forwarded-state file (FNV-1a).
function msg_key(m) {
	let s = join('|', [m.sender, m.timestamp, m.total, m.text]);
	let h = 2166136261;

	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 16777619) & 0xffffffff;

	return sprintf('%08x%04x', h, length(s) & 0xffff);
}

function sms_forward(cfg, indexes) {
	let idx = parse_indexes(indexes);
	let l = sms_list(cfg);

	if (l.error)
		return l;

	for (let m in l.messages)
		for (let i in m.indexes)
			if (i in idx)
				return slack_post(cfg, slack_message(cfg, m));

	return { error: 'Message not found' };
}

function slack_test(cfg) {
	let label = slack_escape(slack_label(cfg));

	return slack_post(cfg, {
		text: sprintf('%s modem-lite test message - %s', SMS_EMOJI, label),
		blocks: [
			{ type: 'section', text: { type: 'mrkdwn', text: SMS_EMOJI + ' *modem-lite test message*' } },
			{ type: 'section', text: { type: 'plain_text', text: 'SMS forwarding to this channel works.' } },
			{ type: 'context', elements: [
				{ type: 'mrkdwn', text: CLOCK_EMOJI + ' ' + local_time(fmt_utc(time())) },
				{ type: 'mrkdwn', text: label }
			] }
		]
	});
}

// Forward messages not forwarded before. When forwarding is (re-)enabled the
// messages already on the modem are recorded as seen, not forwarded.
function forward_new(cfg) {
	let s = cfg.slack;

	if (s.enabled != '1' || !s.webhook) {
		if (fs.access(FWD_STATE))
			fs.unlink(FWD_STATE);

		return;
	}

	let l = sms_list(cfg);

	if (l.error)
		return;

	let raw = fs.readfile(FWD_STATE);
	let first = (raw == null);
	let seen = {}, present = {}, changed = first;

	for (let k in split(raw ?? '', '\n'))
		if (k != '')
			seen[k] = true;

	for (let m in l.messages) {
		let key = msg_key(m);

		present[key] = true;

		if (first) {
			seen[key] = true;
			continue;
		}

		if (seen[key])
			continue;

		// Wait for the remaining parts of a multipart message for a while.
		if (!m.complete && time() - (utc_epoch(m.timestamp) ?? 0) < INCOMPLETE_GRACE)
			continue;

		let r = slack_post(cfg, slack_message(cfg, m));

		if (r.error) {
			log('Slack forwarding failed: ' + r.error);
			break;
		}

		log(sprintf('forwarded SMS from %s to Slack', m.sender));
		seen[key] = true;
		changed = true;

		if (s.delete == '1' && !sms_delete(cfg, m.indexes).error)
			delete present[key];
	}

	// Forget messages no longer on the modem, so the file stays small.
	for (let k in keys(seen)) {
		if (!present[k]) {
			delete seen[k];
			changed = true;
		}
	}

	if (changed) {
		fs.mkdir(fs.dirname(FWD_STATE));
		fs.writefile(FWD_STATE, join('\n', sort(keys(seen))) + '\n');
	}
}

function set_verbose(v) {
	verbose_log = v;
}

return {
	config, interval, cycle, read_status, restart_modem, set_verbose,
	sms_list, sms_send, sms_delete, sms_forward, slack_test, forward_new,
	// exported for tests
	parse_cgdcont, data_cid, parse_link, parse_signal, signal_level,
	parse_cops, parse_reg, merge_parts, utc_epoch, slack_message, slack_escape,
	truncate, local_time, msg_key, pdu_tz, to_utc
};
