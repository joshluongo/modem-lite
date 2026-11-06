'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require ui';
'require dom';

const callStatus = rpc.declare({ object: 'modem-lite', method: 'status' });
const callConnect = rpc.declare({ object: 'modem-lite', method: 'connect' });
const callRestart = rpc.declare({ object: 'modem-lite', method: 'restart' });

const QUALITY = [ _('No signal'), _('Poor'), _('Fair'), _('Good'), _('Excellent') ];
const BAR_COLORS = [ '#9e9e9e', '#d9534f', '#e8a33d', '#5cb85c', '#2e8b57' ];

// dBm needed for 1, 2, 3 and 4 bars.
const RSRP_BARS = [ -115, -105, -95, -85 ];
const RSSI_BARS = [ -103, -93, -83, -73 ];

// 0-4 bars from RSRP (LTE), falling back to RSSI from AT+CSQ.
function signalBars(st) {
	const [ value, steps ] = (st.rsrp != null) ? [ st.rsrp, RSRP_BARS ] : [ st.rssi, RSSI_BARS ];

	return (value == null) ? 0 : steps.filter(min => value >= min).length;
}

function signalMeter(st) {
	const n = signalBars(st);
	const bars = [ 1, 2, 3, 4 ].map(i => E('span', {
		style: 'display:inline-block;width:6px;border-radius:1px;height:%dpx;background:%s;opacity:%s'
			.format(4 + i * 4, i <= n ? BAR_COLORS[n] : 'currentColor', i <= n ? '1' : '0.2')
	}));

	return E('span', { style: 'display:inline-flex;align-items:center;gap:.6em' }, [
		E('span', {
			style: 'display:inline-flex;align-items:flex-end;gap:2px;height:20px',
			role: 'img',
			'aria-label': _('%d of 4 bars').format(n)
		}, bars),
		E('strong', {}, QUALITY[n])
	]);
}

function fmt(v, unit) {
	return (v == null || v === '') ? '-' : unit ? '%s %s'.format(v, unit) : String(v);
}

function row(label, value) {
	return E('tr', { class: 'tr' }, [
		E('td', { class: 'td left', style: 'width:33%' }, label),
		E('td', { class: 'td left' }, value)
	]);
}

function statusTable(st) {
	if (st.pending)
		return E('p', {}, E('em', {}, _('Waiting for the first update from the modem-lite service…')));

	if (!st.present)
		return E('p', {}, E('em', {}, _('Modem not detected. Check that it is powered and enumerated on USB.')));

	const network = [ st.operator, st.act ].filter(x => x).join(' · ') || '-';
	const data = st.connected
		? _('Connected (context %d, APN %s)').format(st.cid, st.apn || '-')
		: st.cid ? _('Disconnected (context %d)').format(st.cid) : _('Disconnected');
	const updated = new Date(st.updated * 1000).toLocaleTimeString();

	return E('table', { class: 'table' }, [
		row(_('Signal'), signalMeter(st)),
		row(_('RSRP / RSRQ'), '%s / %s'.format(fmt(st.rsrp, 'dBm'), fmt(st.rsrq, 'dB'))),
		row(_('RSSI'), st.csq != null ? '%s (CSQ %d)'.format(fmt(st.rssi, 'dBm'), st.csq) : '-'),
		row(_('Network'), network),
		row(_('Registration'), fmt(st.registration)),
		row(_('SIM'), fmt(st.sim)),
		row(_('Data connection'), E('span', { style: st.connected ? '' : 'color:#d9534f' }, data)),
		row(_('Automatic connection'), st.autoconnect
			? _('Active on %s').format(st.netdev)
			: _('Inactive (disabled, or wan is not DHCP on %s)').format(st.netdev || _('the modem interface'))),
		row(_('Modem'), [ st.manufacturer, st.model ].filter(x => x).join(' ') || '-'),
		row(_('Firmware'), fmt(st.revision)),
		row(_('IMEI'), fmt(st.imei)),
		row(_('ICCID'), fmt(st.iccid)),
		row(_('AT port'), fmt(st.port)),
		row(_('Updated'), st.stale
			? E('span', { style: 'color:#d9534f' }, _('%s (stale: is the modem-lite service running?)').format(updated))
			: updated)
	]);
}

function notifyResult(res, okMsg) {
	if (res && res.error)
		ui.addNotification(null, E('p', {}, res.error), 'danger');
	else if (okMsg)
		ui.addTimeLimitedNotification(null, E('p', {}, okMsg), 5000, 'info');
}

// Kept as a constant: LuCI's build-time jsmin misreads a regex after "return".
const AT_UNSAFE = /["\x00-\x1f\x7f]/;

function noQuotes(section_id, value) {
	return AT_UNSAFE.test(value) ? _('Quotes and control characters are not allowed') : true;
}

return view.extend({
	load() {
		return callStatus();
	},

	render(status) {
		const body = E('div', {}, statusTable(status));
		const refresh = () => callStatus().then(st => dom.content(body, statusTable(st)));

		const m = new form.Map('modem-lite');
		let s, o;

		s = m.section(form.NamedSection, 'modem', 'modem', _('Settings'));
		s.anonymous = true;
		s.tab('general', _('Connection'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'autoconnect', _('Connect automatically'),
			_('Keep the modem\'s data call up while <em>wan</em> is DHCP on the modem\'s network interface.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'apn', _('APN'),
			_('Leave empty to keep the APN already stored in the modem.'));
		o.validate = noQuotes;

		o = s.taboption('general', form.ListValue, 'pdptype', _('IP type'),
			_('Written together with the APN.'));
		o.value('IPV4V6', _('IPv4 and IPv6'));
		o.value('IP', _('IPv4 only'));
		o.value('IPV6', _('IPv6 only'));
		o.default = 'IPV4V6';

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication'));
		o.value('none', _('None'));
		o.value('pap', 'PAP');
		o.value('chap', 'CHAP');
		o.default = 'none';

		o = s.taboption('general', form.Value, 'username', _('Username'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.validate = noQuotes;

		o = s.taboption('general', form.Value, 'password', _('Password'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.password = true;
		o.validate = noQuotes;

		o = s.taboption('general', form.Value, 'pin', _('SIM PIN'),
			_('Entered once per boot when the SIM asks for it, so a wrong PIN cannot lock the SIM.'));
		o.password = true;
		o.validate = (id, v) => (!v || /^[0-9]{4,8}$/.test(v)) ? true : _('Expecting 4 to 8 digits');

		o = s.taboption('advanced', form.Value, 'cid', _('Data context (CID)'),
			_('PDP context used for the data call. Default: the first context with a non-IMS APN.'));
		o.datatype = 'range(1,15)';
		o.placeholder = _('auto');

		o = s.taboption('advanced', form.Value, 'at_port', _('AT port'),
			_('Default: the tty on the modem\'s USB interface 3.'));
		o.placeholder = _('auto');
		o.validate = (id, v) => (!v || /^\/dev\/[A-Za-z0-9_.-]+$/.test(v)) ? true : _('Expecting a /dev path');

		o = s.taboption('advanced', form.Value, 'sms_port', _('SMS port'),
			_('Default: the tty on the modem\'s USB interface 4.'));
		o.placeholder = _('auto');
		o.validate = (id, v) => (!v || /^\/dev\/[A-Za-z0-9_.-]+$/.test(v)) ? true : _('Expecting a /dev path');

		o = s.taboption('advanced', form.Value, 'interval', _('Check interval'),
			_('Seconds between modem checks.'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '15';

		o = s.taboption('advanced', form.DynamicList, 'signal_led', _('Signal LEDs'),
			_('LEDs lit as signal bars, weakest first (from /sys/class/leds).'));

		return m.render().then(mapEl => {
			poll.add(refresh, 5);

			return E([], [
				E('h2', {}, _('Mobile Modem')),
				E('div', { class: 'cbi-map-descr' },
					_('Signal, connection status and APN settings of the LTE modem.')),
				E('div', { class: 'cbi-section' }, [
					E('h3', {}, _('Status')),
					body,
					E('div', { class: 'right', style: 'margin-top:1em' }, [
						E('button', {
							class: 'btn cbi-button cbi-button-action',
							click: ui.createHandlerFn(this, () => callConnect().then(res => {
								notifyResult(res, res && res.connected ? _('Data connection is up.') : null);
								if (res && !res.error && !res.connected)
									ui.addNotification(null, E('p', {}, _('The modem did not report a data connection yet.')), 'warning');
								return refresh();
							}))
						}, _('Reconnect')),
						' ',
						E('button', {
							class: 'btn cbi-button cbi-button-negative',
							click: ui.createHandlerFn(this, () => {
								if (!confirm(_('Restart the modem? The connection drops for about a minute.')))
									return;

								return callRestart().then(res => notifyResult(res, _('Modem is restarting.')));
							})
						}, _('Restart modem'))
					])
				]),
				mapEl
			]);
		});
	}
});
