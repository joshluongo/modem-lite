'use strict';
'require view';
'require form';
'require rpc';
'require ui';

const callTest = rpc.declare({ object: 'modem-lite', method: 'slack_test' });

return view.extend({
	render() {
		const m = new form.Map('modem-lite', _('Slack Forwarding'),
			_('Post incoming SMS to a Slack channel through an <a href="%s" target="_blank" rel="noreferrer">incoming webhook</a>. Messages already on the modem when forwarding is enabled are not posted.')
				.format('https://api.slack.com/messaging/webhooks'));
		let s, o;

		s = m.section(form.NamedSection, 'slack', 'slack');
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Forward new messages'));
		o.rmempty = false;

		o = s.option(form.Value, 'webhook', _('Webhook URL'),
			_('Looks like https://hooks.slack.com/services/…'));
		o.password = true;
		o.validate = (id, v) => (!v || /^https:\/\/[^\s'"]+$/.test(v)) ? true : _('Expecting an https:// URL');

		o = s.option(form.Value, 'label', _('Device label'),
			_('Shown under each message, e.g. "Shed Modem (+61400000000)". Default: the router\'s hostname.'));

		o = s.option(form.Flag, 'delete', _('Delete after forwarding'),
			_('Remove each message from the modem once Slack accepted it, so storage does not fill up.'));
		o.rmempty = false;

		o = s.option(form.Button, '_test', _('Test'),
			_('Sends a test message using the saved webhook URL. Save first after changing it.'));
		o.inputtitle = _('Send test message');
		o.inputstyle = 'action';
		o.onclick = () => callTest().then(res => {
			if (res && res.error)
				ui.addNotification(null, E('p', {}, res.error), 'danger');
			else
				ui.addTimeLimitedNotification(null, E('p', {}, _('Slack accepted the test message.')), 5000, 'info');
		});

		return m.render();
	}
});
