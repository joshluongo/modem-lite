// Tests for modemlite.uc. Run by tests/run.sh inside an OpenWrt rootfs
// container (needs ucode, uci, flock and the fakes in tests/fake on PATH).

'use strict';

let fs = require('fs');
let ml = require('modemlite');
let FAKE = getenv('FAKE');
let failures = 0, count = 0;

function eq(name, got, want) {
	count++;
	if (sprintf('%J', got) != sprintf('%J', want)) {
		failures++;
		warn(sprintf('FAIL %s\n  got:  %J\n  want: %J\n', name, got, want));
	}
}

function ok(name, cond) {
	eq(name, !!cond, true);
}

function sh(cmd) {
	let p = fs.popen(cmd, 'r');
	let out = p.read('all');
	p.close();
	return out;
}

function reset(link) {
	sh(`rm -rf ${FAKE}/inbox ${FAKE}/active ${FAKE}/sent ${FAKE}/posts ${FAKE}/at.log /tmp/ml-run /tmp/ml-forwarded; mkdir -p ${FAKE}/inbox; touch ${FAKE}/active`);
	fs.writefile(FAKE + '/link', link ?? '0 0');
	fs.writefile(FAKE + '/apn', 'telstra.internet');
	fs.writefile(FAKE + '/pdp', 'IPV4V6');
	fs.writefile(FAKE + '/cpin', '+CPIN: READY');
}

function at_log() {
	return filter(split(fs.readfile(FAKE + '/at.log') ?? '', '\n'), l => l != '');
}

function cfg(modem, slack, wan) {
	return {
		modem: { autoconnect: '1', signal_led: ['green:signal1', 'green:signal2', 'green:signal3'], ...(modem ?? {}) },
		slack: slack ?? {},
		wan: wan ?? { proto: 'dhcp', device: 'usb0' }
	};
}

function add_sms(i, body) {
	fs.writefile(`${FAKE}/inbox/${i}`, body);
}

/* ---- Parsers (replies captured from the EC200A) -------------------------- */

eq('cgdcont', ml.parse_cgdcont(['+CGDCONT: 2,"IPV4V6","telstra.internet","0.0.0.0",0,0', '+CGDCONT: 8,"IPV4V6","ims","0.0.0.0",0,0']),
	[{ cid: 2, pdp: 'IPV4V6', apn: 'telstra.internet' }, { cid: 8, pdp: 'IPV4V6', apn: 'ims' }]);
eq('data cid skips IMS/empty', ml.data_cid([{ cid: 1, apn: '' }, { cid: 8, apn: 'IMS' }, { cid: 2, apn: 'x' }]), 2);
eq('data cid none', ml.data_cid([{ cid: 8, apn: 'ims' }]), null);
eq('link up', ml.parse_link(['+QNETDEVCTL: 1,2,1,1']), { cid: 2, up: true });
eq('link down', ml.parse_link(['+QNETDEVCTL: 0,0,0,0']), { cid: 0, up: false });
eq('signal', ml.parse_signal(['+CESQ: 51,99,255,255,20,50', '+CSQ: 27,99']), { rsrp: -91, rsrq: -10.0, csq: 27, rssi: -59 });
eq('signal unknown', ml.parse_signal(['+CESQ: 99,99,255,255,255,255', '+CSQ: 99,99']), {});
eq('level rsrp', ml.signal_level({ rsrp: -91, csq: 5 }), 3);
eq('level rsrp weak', ml.signal_level({ rsrp: -110 }), 1);
eq('level csq fallback', ml.signal_level({ csq: 12 }), 2);
eq('level none', ml.signal_level({}), 0);
eq('cops', ml.parse_cops(['+COPS: 0,0,"Telstra Mobile",7']), { operator: 'Telstra Mobile', act: 'LTE' });
eq('cops unregistered', ml.parse_cops(['+COPS: 0']), {});
eq('cereg', ml.parse_reg(['+CEREG: 0,5']), 'roaming');
eq('utc epoch', ml.utc_epoch('2026-11-06 01:02:03'), 1793926923);
eq('utc epoch leap', ml.utc_epoch('2024-02-29 00:00:00'), 1709164800);

eq('merge multipart', ml.merge_parts([
	{ index: 3, sender: '61400', timestamp: '2026-11-06 01:00:00', reference: 9, part: 2, total: 2, content: 'world' },
	{ index: 1, sender: '61400', timestamp: '2026-11-06 01:00:00', reference: 9, part: 1, total: 2, content: 'hello ' },
	{ index: 2, sender: 'Telstra', timestamp: '2026-11-06 02:00:00', content: 'single' },
	{ index: 4, error: 'error decoding pdu', sender: '', timestamp: '', content: '' }
]), [
	{ indexes: [2], sender: 'Telstra', timestamp: '2026-11-06 02:00:00', text: 'single', parts: 1, total: 1, complete: true },
	{ indexes: [1, 3], sender: '61400', timestamp: '2026-11-06 01:00:00', text: 'hello world', parts: 2, total: 2, complete: true }
]);

eq('slack format escapes', ml.slack_format({ sender: '<b>', timestamp: 'T', text: 'a & <b>', complete: true }),
	sprintf('*SMS from &lt;b&gt;* on %s, T UTC\na &amp; &lt;b&gt;', trim(fs.readfile('/proc/sys/kernel/hostname'))));

/* ---- Data call: default stock state (context 2 stored, inactive) --------- */

reset();
let st = ml.cycle(cfg());
let log = at_log();

ok('connect: CGACT before QNETDEVCTL', index(log, '/dev/ttyUSB1 AT+CGACT=1,2') >= 0 &&
	index(log, '/dev/ttyUSB1 AT+CGACT=1,2') < index(log, '/dev/ttyUSB1 AT+QNETDEVCTL=1,2,1'));
eq('connect: status', [st.present, st.port, st.netdev, st.cid, st.apn, st.connected, st.autoconnect],
	[true, '/dev/ttyUSB1', 'usb0', 2, 'telstra.internet', true, true]);
eq('status: identity', [st.manufacturer, st.model, st.imei, st.iccid], ['Quectel', 'EC200A', '861234567890123', '89610123456789012345']);
eq('status: radio', [st.rsrp, st.rsrq, st.operator, st.act, st.registration, st.sim, st.level],
	[-91, -10.0, 'Telstra Mobile', 'LTE', 'home', 'READY', 3]);
eq('leds', map([1, 2, 3], i => trim(fs.readfile(`${getenv('MODEMLITE_SYSROOT')}/sys/class/leds/green:signal${i}/brightness`))), ['1', '1', '1']);
ok('APN never written when unset', !length(filter(log, l => match(l, /QICSGP|CGDCONT=/))));
eq('status file round-trip', ml.read_status(cfg()).imei, '861234567890123');

// Second cycle: link up, nothing re-dialled and identity cached.
sh(`rm ${FAKE}/at.log`);
ml.cycle(cfg());
log = at_log();
ok('steady state: no dial', !length(filter(log, l => match(l, /CGACT=|QNETDEVCTL=/))));
ok('steady state: identity cached', !length(filter(log, l => match(l, /CGSN/))));

// Not managed: wan on another proto, or autoconnect off.
for (let c in [cfg(null, null, { proto: 'ncm', device: '/dev/ttyUSB2' }), cfg({ autoconnect: '0' })]) {
	reset();
	st = ml.cycle(c);
	ok('unmanaged: no dial', !length(filter(at_log(), l => match(l, /CGACT=|QNETDEVCTL=/))) && !st.connected && !st.autoconnect);
}

// Manual reconnect works regardless.
reset('2 1');
sh(`echo 2 > ${FAKE}/active`);
st = ml.cycle(cfg({ autoconnect: '0' }), { force_connect: true });
ok('force connect re-dials', st.connected && length(filter(at_log(), l => match(l, /QNETDEVCTL=1,2,1/))) == 1);

/* ---- APN, auth, PIN ------------------------------------------------------ */

reset('2 1');
sh(`echo 2 > ${FAKE}/active`);
st = ml.cycle(cfg({ apn: 'new.apn', pdptype: 'IP', auth: 'pap', username: 'u', password: 'p' }));
log = at_log();
ok('apn: QICSGP written', index(log, '/dev/ttyUSB1 AT+QICSGP=2,1,"new.apn","u","p",1') >= 0);
ok('apn: old bearer dropped then reconnected', index(log, '/dev/ttyUSB1 AT+CGACT=0,2') >= 0 && st.connected);
eq('apn: status shows new APN', [st.apn, st.pdp], ['new.apn', 'IP']);
sh(`rm ${FAKE}/at.log`);
ml.cycle(cfg({ apn: 'new.apn', pdptype: 'IP', auth: 'pap', username: 'u', password: 'p' }));
ok('apn: applied once', !length(filter(at_log(), l => match(l, /QICSGP/))));

reset();
// Fallback to 3GPP commands when QICSGP is not supported.
let r = sh(`FAKE_NO_QICSGP=1 ucode -L /usr/share/ucode -e 'let ml = require("modemlite"); ml.cycle({ modem: { apn: "fb.apn", pdptype: "IPV4V6", auth: "chap", username: "a", password: "b" }, slack: {}, wan: {} }); print("done")'`);
log = at_log();
ok('apn fallback: CGDCONT + CGAUTH', r == 'done' && index(log, '/dev/ttyUSB1 AT+CGDCONT=2,"IPV4V6","fb.apn"') >= 0 &&
	index(log, '/dev/ttyUSB1 AT+CGAUTH=2,2,"a","b"') >= 0);

reset();
ml.cycle(cfg({ apn: 'bad"apn' }));
ok('apn: quotes rejected', !length(filter(at_log(), l => match(l, /QICSGP|CGDCONT=/))));

reset();
fs.writefile(FAKE + '/cpin', '+CPIN: SIM PIN');
st = ml.cycle(cfg({ pin: '9999' }));
ml.cycle(cfg({ pin: '9999' }));
eq('pin: wrong PIN tried once only', length(filter(at_log(), l => match(l, /CPIN="/))), 1);
st = ml.cycle(cfg({ pin: '1234' }));
eq('pin: new PIN unlocks', st.sim, 'READY');

/* ---- SMS ------------------------------------------------------------------ */

reset();
add_sms(0, '"sender":"61412345678","timestamp":"2026-11-06 01:00:00","content":"Hello \\u00e9"');
add_sms(1, '"sender":"Telstra","timestamp":"2026-11-06 02:00:00","reference":5,"part":1,"total":2,"content":"Part one, "');
add_sms(2, '"sender":"Telstra","timestamp":"2026-11-06 02:00:00","reference":5,"part":2,"total":2,"content":"part two"');
let l = ml.sms_list(cfg());
eq('sms list', map(l.messages, m => [m.indexes, m.sender, m.text]),
	[[[1, 2], 'Telstra', 'Part one, part two'], [[0], '61412345678', 'Hello é']]);

eq('send ok', ml.sms_send(cfg(), '+61 412 345 678', 'Hi [there]'), { ok: true });
eq('send recorded without +', trim(fs.readfile(FAKE + '/sent')), '61412345678\tHi [there]');
eq('send national rejected', ml.sms_send(cfg(), '0412345678', 'x').error, 'Use the international number format, e.g. +61412345678');
eq('send non-ascii rejected', ml.sms_send(cfg(), '61412345678', 'café').error, 'Only plain ASCII text can be sent');
eq('send too long', ml.sms_send(cfg(), '61412345678', sprintf('%0159d', 0) + '^').error, 'Message must be 1 to 160 characters');
eq('send 160 ok', ml.sms_send(cfg(), '61412345678', sprintf('%0160d', 0)), { ok: true });
eq('send bad number', ml.sms_send(cfg(), 'abc', 'x').error, 'Invalid phone number');
eq('send shell-safe', ml.sms_send(cfg(), '61412345678', "it's $(id) `x`"), { ok: true });
ok('send shell-safe recorded verbatim', index(fs.readfile(FAKE + '/sent'), "it's $(id) `x`") >= 0);

eq('delete', ml.sms_delete(cfg(), '1,2'), { ok: true });
eq('delete missing', ml.sms_delete(cfg(), '9').error, 'Could not delete message 9');
eq('list after delete', length(ml.sms_list(cfg()).messages), 1);

/* ---- Slack ---------------------------------------------------------------- */

let slack = { enabled: '1', webhook: 'https://hooks.slack.com/services/T/B/X' };

reset();
add_sms(0, '"sender":"61400000001","timestamp":"2026-11-06 01:00:00","content":"old"');
ml.forward_new(cfg(null, slack));
ok('forward: existing messages seeded, not posted', !fs.access(FAKE + '/posts') && length(trim(fs.readfile('/tmp/ml-forwarded'))) > 0);

add_sms(1, '"sender":"61400000002","timestamp":"2026-11-06 01:05:00","content":"new \\"quoted\\" <msg>"');
ml.forward_new(cfg(null, slack));
let posts = split(trim(fs.readfile(FAKE + '/posts')), '\n');
ok('forward: one post', length(filter(posts, x => x == '--')) == 1);
ok('forward: url and header', 'https://hooks.slack.com/services/T/B/X' in posts && 'Content-Type: application/json' in posts);
let body = json(posts[index(posts, '--post-data') + 1]);
ok('forward: payload', index(body.text, '*SMS from 61400000002*') == 0 && index(body.text, 'new "quoted" &lt;msg&gt;') > 0);

ml.forward_new(cfg(null, slack));
eq('forward: not repeated', length(filter(split(trim(fs.readfile(FAKE + '/posts')), '\n'), x => x == '--')), 1);

// Incomplete multipart: held back while recent, sent after the grace period.
add_sms(2, sprintf('"sender":"6140003","timestamp":"%s","reference":1,"part":1,"total":2,"content":"half"',
	trim(sh('date -u "+%Y-%m-%d %H:%M:%S"'))));
add_sms(3, '"sender":"6140004","timestamp":"2020-01-01 00:00:00","reference":2,"part":1,"total":2,"content":"stale half"');
ml.forward_new(cfg(null, slack));
posts = fs.readfile(FAKE + '/posts');
ok('forward: recent incomplete held', index(posts, '6140003') < 0);
ok('forward: stale incomplete sent', index(posts, 'incomplete: 1 of 2 parts') >= 0);

// Failure: not marked, retried next time.
reset();
add_sms(0, '"sender":"1","timestamp":"2026-11-06 01:00:00","content":"a"');
ml.forward_new(cfg(null, slack));
add_sms(1, '"sender":"2","timestamp":"2026-11-06 01:00:00","content":"b"');
sh(`rm -f ${FAKE}/posts`);
r = sh(`FAKE_FETCH_RC=4 ucode -L /usr/share/ucode -e 'let ml = require("modemlite"); ml.forward_new({ modem: {}, slack: ${sprintf('%J', slack)}, wan: {} })'`);
ml.forward_new(cfg(null, slack));
eq('forward: retried after failure', length(filter(split(trim(fs.readfile(FAKE + '/posts')), '\n'), x => x == '--')), 2);

// Delete after forwarding.
add_sms(2, '"sender":"3","timestamp":"2026-11-06 01:00:00","content":"c"');
ml.forward_new(cfg(null, { ...slack, delete: '1' }));
ok('forward: deleted after post', !fs.access(FAKE + '/inbox/2'));

// Disabling clears the state so re-enabling does not flood the channel.
ml.forward_new(cfg(null, { enabled: '0' }));
ok('forward: disable clears state', !fs.access('/tmp/ml-forwarded'));

eq('forward manual', ml.sms_forward(cfg(null, slack), '0'), { ok: true });
eq('forward manual missing', ml.sms_forward(cfg(null, slack), '42').error, 'Message not found');
eq('slack unconfigured', ml.slack_test(cfg()).error, 'Slack webhook URL is not configured');
eq('slack test', ml.slack_test(cfg(null, slack)), { ok: true });

/* ---- Modem absent --------------------------------------------------------- */

reset();
st = ml.cycle(cfg({ at_port: '/dev/does-not-exist' }));
eq('absent: status', st.present, false);
eq('absent: leds off', map([1, 2, 3], i => trim(fs.readfile(`${getenv('MODEMLITE_SYSROOT')}/sys/class/leds/green:signal${i}/brightness`))), ['0', '0', '0']);
eq('absent: sms', ml.sms_list(cfg({ sms_port: '/dev/does-not-exist' })).error, 'Modem SMS port not found');

printf('%d/%d checks passed\n', count - failures, count);
exit(failures ? 1 : 0);
