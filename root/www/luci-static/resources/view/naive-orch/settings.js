'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';

var SUB_CMD = '/usr/libexec/naive-orch/sub-update';
var UOT_SERVER_URL = 'https://raw.githubusercontent.com/FurstFri/naive-orch/main/server/uot-server-install.sh';

function maskProxy(proxy) {
	return (proxy || '').replace(/\/\/[^@]*@/, '//***@');
}

/* The single command to paste on every proxy server. Non-default values are
   passed explicitly; with the default port it is just "| sh". */
function uotServerCommand(socksPort) {
	var env = '';
	if (socksPort && socksPort !== '8389')
		env += "SOCKS_PORT='" + socksPort + "' ";
	return 'wget -qO- ' + UOT_SERVER_URL + ' | ' + env + 'sh';
}

function validateHttpUrl(sectionId, value) {
	if (!/^https?:\/\/\S+$/.test(value || ''))
		return _('Введите полный URL, начинающийся с http:// или https://');
	return true;
}

function validateNaiveProxy(sectionId, value) {
	if (!/^https:\/\/\S+$/.test(value || ''))
		return _('Naive URL должен начинаться с https://');
	return true;
}

function startSubscriptionUpdate(sectionId) {
	return fs.exec(SUB_CMD, [ '--start', sectionId ]).then(function(result) {
		if (result.code !== 0)
			throw new Error(result.stderr || result.stdout || _('Не удалось запустить обновление'));

		ui.addNotification(null, E('p', {}, [
			_('Обновление «%s» запущено. Ход операции показан на вкладке ').format(sectionId),
			E('a', { 'href': L.url('admin/services/naive-orch/overview') }, _('Статус')),
			'.'
		]), 'info');
	}).catch(function(error) {
		ui.addNotification(null, E('p', {}, error.message || String(error)), 'error');
	});
}

return view.extend({
	load: function() {
		return uci.load('naive-orch');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('naive-orch', _('Настройки Naive Orchestrator'),
			_('Обычно достаточно добавить URL подписки. Naive Orchestrator создаёт локальные SOCKS5-порты, а маршрутизацией и DNS продолжает управлять Podkop.'));

		/* ---------------- global: simple first, advanced out of the way -------- */
		s = m.section(form.TypedSection, 'global', _('Основные настройки'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('basic', _('Основное'),
			_('Этих параметров достаточно для обычной установки.'));
		s.tab('advanced', _('Дополнительно'),
			_('Меняйте эти параметры только если понимаете, зачем они нужны.'));
		s.tab('uot', _('UDP over TCP'),
			_('Включите режим и выполните показанную команду на каждом внешнем сервере — больше ничего настраивать не нужно.'));

		o = s.taboption('basic', form.Flag, 'enabled', _('Включить сервис'),
			_('Главный выключатель всех узлов и фоновых проверок.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'check_interval', _('Проверять узлы каждые'),
			_('Интервал автоматической проверки доступности и задержки, в секундах.'));
		o.datatype = 'range(10,3600)';
		o.default = '30';
		o.placeholder = '30';

		o = s.taboption('advanced', form.Value, 'bind_host', _('Адрес SOCKS'),
			_('Оставьте 127.0.0.1, чтобы прокси был доступен только самому роутеру.'));
		o.datatype = 'ipaddr';
		o.default = '127.0.0.1';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'health_url', _('Адрес для проверки'),
			_('Небольшой HTTPS-ресурс, который открывается через каждый SOCKS-прокси.'));
		o.default = 'https://www.gstatic.com/generate_204';
		o.rmempty = false;
		o.validate = validateHttpUrl;

		o = s.taboption('uot', form.Flag, 'udp_over_tcp', _('Включить UDP over TCP'),
			_('TCP идёт через naive, UDP — через тот же туннель до приёмника на сервере. Ключи не нужны.'));
		o.default = '0';

		o = s.taboption('uot', form.DummyValue, '_server_cmd', _('Команда для сервера'),
			_('Выполните один раз на каждом внешнем сервере. Отражает сохранённые значения.'));
		o.depends('udp_over_tcp', '1');
		o.cfgvalue = function(sectionId) {
			return E('pre', {
				'style': 'white-space:pre-wrap;word-break:break-all;user-select:all;margin:0'
			}, uotServerCommand(uci.get('naive-orch', sectionId, 'uot_port') || '8389'));
		};

		o = s.taboption('uot', form.Value, 'uot_port', _('Порт приёмника'),
			_('Socks-приёмник на сервере. Порт 8388 занят legacy-приёмником для мобильных клиентов.'));
		o.datatype = 'port';
		o.default = '8389';
		o.depends('udp_over_tcp', '1');

		o = s.taboption('uot', form.Value, 'uot_offset', _('Смещение внутреннего порта'),
			_('Внутренний порт naive = SOCKS-порт + это значение.'));
		o.datatype = 'range(1,50000)';
		o.default = '1000';
		o.depends('udp_over_tcp', '1');

		/* ---------------- subscriptions: the primary setup path ---------------- */
		s = m.section(form.GridSection, 'subscription', _('Подписки'),
			_('Нажмите «Добавить», задайте понятное имя и вставьте URL. Затем нажмите «Сохранить и применить» внизу страницы и запустите обновление.'));
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;
		s.sectiontitle = function(sectionId) {
			return uci.get('naive-orch', sectionId, 'label_prefix') || sectionId;
		};

		o = s.option(form.Flag, 'enabled', _('Вкл.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('URL подписки'));
		o.rmempty = false;
		o.validate = validateHttpUrl;
		o.placeholder = 'https://example.com/subscription/token';

		o = s.option(form.Value, 'base_port', _('Первый SOCKS-порт'),
			_('Первый узел получит этот порт, следующие — +1, +2 и так далее.'));
		o.datatype = 'port';
		o.default = '1100';

		o = s.option(form.Flag, 'auto_update', _('Автообновление'));
		o.default = '1';

		o = s.option(form.Value, 'update_interval', _('Интервал, ч'),
			_('Как часто автоматически перечитывать подписку.'));
		o.datatype = 'range(1,8760)';
		o.default = '12';
		o.depends('auto_update', '1');

		o = s.option(form.Value, 'resolve', _('Подменить IP домена'),
			_('Необязательно. Аналог curl --resolve для панели за внутренним DNAT; TLS всё равно проверяется по домену URL.'));
		o.datatype = 'ipaddr';
		o.modalonly = true;

		o = s.option(form.Value, 'label_prefix', _('Префикс имён узлов'),
			_('Необязательно. По умолчанию используется имя секции подписки.'));
		o.modalonly = true;

		o = s.option(form.Value, 'concurrency', _('Параллельные соединения'),
			_('Необязательно. 0 оставляет настройку naive по умолчанию.'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.modalonly = true;

		o = s.option(form.Button, '_update', _('Обновить'));
		o.inputtitle = _('Запустить');
		o.inputstyle = 'apply';
		o.onclick = function(event, sectionId) {
			return startSubscriptionUpdate(sectionId);
		};

		/* ---------------- manual nodes ---------------------------------------- */
		s = m.section(form.GridSection, 'node', _('Ручные узлы'),
			_('Используйте этот раздел только для узлов, которых нет в подписке.'));
		s.addremove = true;
		s.anonymous = true;
		s.filter = function(sectionId) {
			return !uci.get('naive-orch', sectionId, 'source');
		};

		o = s.option(form.Flag, 'enabled', _('Вкл.'));
		o.default = '1';

		o = s.option(form.Value, 'label', _('Название'));
		o.placeholder = _('Например, NL-1');

		o = s.option(form.Value, 'listen_port', _('SOCKS-порт'));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Value, 'proxy', _('Naive URL'),
			_('Формат: https://user:password@server:443'));
		o.rmempty = false;
		o.password = true;
		o.validate = validateNaiveProxy;

		o = s.option(form.Flag, 'padding', _('Padding'));
		o.modalonly = true;

		o = s.option(form.Value, 'concurrency', _('Параллельные соединения'));
		o.datatype = 'uinteger';
		o.modalonly = true;

		/* ---------------- imported nodes, deliberately read-only -------------- */
		s = m.section(form.GridSection, 'node', _('Импортированные узлы'),
			_('Этот список управляется подписками. Ручные изменения будут заменены при следующем обновлении.'));
		s.addremove = false;
		s.anonymous = true;
		s.filter = function(sectionId) {
			return !!uci.get('naive-orch', sectionId, 'source');
		};

		o = s.option(form.DummyValue, 'source', _('Подписка'));
		o.cfgvalue = function(sectionId) {
			return (uci.get('naive-orch', sectionId, 'source') || '').replace(/^sub:/, '');
		};
		o = s.option(form.DummyValue, 'label', _('Узел'));
		o = s.option(form.DummyValue, 'listen_port', _('SOCKS'));
		o.cfgvalue = function(sectionId) {
			return '127.0.0.1:' + (uci.get('naive-orch', sectionId, 'listen_port') || '');
		};
		o = s.option(form.DummyValue, 'proxy', _('Сервер'));
		o.cfgvalue = function(sectionId) {
			return maskProxy(uci.get('naive-orch', sectionId, 'proxy'));
		};

		return Promise.resolve(m.render()).then(function(rendered) {
			return E('div', {}, [
				E('div', { 'class': 'alert-message notice', 'style': 'margin-bottom:1em' }, [
					E('strong', {}, _('Быстрый старт: ')),
					_('добавьте подписку → сохраните настройки → откройте «Статус» и нажмите «Обновить все подписки».')
				]),
				rendered
			]);
		});
	}
});
