'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

const callList = rpc.declare({ object: 'modem-lite', method: 'sms_list' });
const callSend = rpc.declare({ object: 'modem-lite', method: 'sms_send', params: [ 'number', 'text' ] });
const callDelete = rpc.declare({ object: 'modem-lite', method: 'sms_delete', params: [ 'indexes' ] });
const callForward = rpc.declare({ object: 'modem-lite', method: 'sms_forward', params: [ 'indexes' ] });

// sms-tool sends GSM 7-bit only: plain ASCII, where these count twice.
const MAX_SEPTETS = 160;

function septets(text) {
	return text.length + (text.match(/[\[\]{}\\^~|]/g) || []).length;
}

function sendError(number, text) {
	const n = number.replace(/[\s()-]/g, '');

	if (!/^\+?[0-9]{3,20}$/.test(n))
		return _('Enter a phone number, e.g. +61412345678.');

	if (n.replace(/^\+/, '').length >= 6 && /^0/.test(n))
		return _('Use the international number format, e.g. +61412345678.');

	if (!text.length)
		return _('Enter a message.');

	if (/[^\n\x20-\x7e]/.test(text.replace(/\r/g, '')))
		return _('Only plain ASCII text can be sent (no accents or emoji).');

	if (septets(text) > MAX_SEPTETS)
		return _('The message is longer than %d characters.').format(MAX_SEPTETS);

	return null;
}

// sms-tool reports the timestamp in UTC.
function localTime(ts) {
	const d = new Date(String(ts || '').replace(' ', 'T') + 'Z');

	return isNaN(d) ? (ts || '-') : d.toLocaleString();
}

function notify(res, okMsg) {
	if (res && res.error) {
		ui.addNotification(null, E('p', {}, res.error), 'danger');
		return false;
	}

	if (okMsg)
		ui.addTimeLimitedNotification(null, E('p', {}, okMsg), 5000, 'info');

	return true;
}

return view.extend({
	load() {
		return callList();
	},

	renderInbox(res) {
		if (res && res.error)
			return E('p', {}, E('em', {}, res.error));

		const msgs = (res && res.messages) || [];

		if (!msgs.length)
			return E('p', {}, E('em', {}, _('No messages on the modem.')));

		return E('table', { class: 'table' }, [
			E('tr', { class: 'tr table-titles' }, [
				E('th', { class: 'th', style: 'width:12em' }, _('Received')),
				E('th', { class: 'th', style: 'width:10em' }, _('From')),
				E('th', { class: 'th' }, _('Message')),
				E('th', { class: 'th right', style: 'width:14em' }, ' ')
			]),
			...msgs.map(m => {
				const idx = m.indexes.join(',');
				const note = m.complete ? '' : ' ' + _('(part %d of %d received)').format(m.parts, m.total);

				return E('tr', { class: 'tr' }, [
					E('td', { class: 'td', 'data-title': _('Received') }, localTime(m.timestamp)),
					E('td', { class: 'td', 'data-title': _('From') }, m.sender || '-'),
					E('td', { class: 'td', 'data-title': _('Message'), style: 'white-space:pre-wrap;word-break:break-word' }, [
						m.text,
						note ? E('em', {}, note) : ''
					]),
					E('td', { class: 'td right' }, [
						E('button', {
							class: 'btn cbi-button cbi-button-action',
							title: _('Post this message to the configured Slack channel'),
							click: ui.createHandlerFn(this, () => callForward(idx).then(r =>
								notify(r, _('Message forwarded to Slack.'))))
						}, _('Forward')),
						' ',
						E('button', {
							class: 'btn cbi-button cbi-button-remove',
							click: ui.createHandlerFn(this, () => {
								if (!confirm(_('Delete this message from the modem?')))
									return;

								return callDelete(idx).then(r => {
									notify(r);
									return this.reload();
								});
							})
						}, _('Delete'))
					])
				]);
			})
		]);
	},

	reload() {
		return callList().then(res => dom.content(this.inbox, this.renderInbox(res)));
	},

	render(res) {
		this.inbox = E('div', {}, this.renderInbox(res));

		const number = E('input', {
			type: 'tel', class: 'cbi-input-text', id: 'sms-number',
			placeholder: '+61412345678', autocomplete: 'off'
		});
		const counter = E('span', { class: 'cbi-value-description' }, '0 / %d'.format(MAX_SEPTETS));
		const text = E('textarea', {
			class: 'cbi-input-textarea', id: 'sms-text', rows: 4, style: 'width:100%',
			input: () => {
				const n = septets(text.value);
				counter.textContent = '%d / %d'.format(n, MAX_SEPTETS);
				counter.style.color = n > MAX_SEPTETS ? '#d9534f' : '';
			}
		});

		const send = () => {
			const err = sendError(number.value, text.value);

			if (err) {
				ui.addNotification(null, E('p', {}, err), 'warning');
				return;
			}

			return callSend(number.value, text.value).then(r => {
				if (notify(r, _('Message sent.'))) {
					text.value = '';
					counter.textContent = '0 / %d'.format(MAX_SEPTETS);
				}
			});
		};

		return E([], [
			E('h2', {}, _('SMS Messages')),
			E('div', { class: 'cbi-map-descr' },
				_('Messages stored on the modem. Received times are shown in your browser\'s time zone.')),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('Send message')),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'sms-number' }, _('To')),
					E('div', { class: 'cbi-value-field' }, [
						number,
						E('div', { class: 'cbi-value-description' }, _('International format.'))
					])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'sms-text' }, _('Message')),
					E('div', { class: 'cbi-value-field' }, [
						text,
						E('div', {}, [ counter, ' ', E('span', { class: 'cbi-value-description' },
							_('Plain ASCII, single message.')) ])
					])
				]),
				E('div', { class: 'right' }, E('button', {
					class: 'btn cbi-button cbi-button-positive',
					click: ui.createHandlerFn(this, send)
				}, _('Send')))
			]),

			E('div', { class: 'cbi-section' }, [
				E('div', { style: 'display:flex;justify-content:space-between;align-items:center' }, [
					E('h3', {}, _('Inbox')),
					E('button', {
						class: 'btn cbi-button',
						click: ui.createHandlerFn(this, 'reload')
					}, _('Refresh'))
				]),
				this.inbox
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
