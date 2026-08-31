'use strict';
'require view';
'require fs';
'require dom';
'require ui';
'require poll';
'require uci';

var STATUS_CMD = '/usr/libexec/naive-orch/status';
var SUB_CMD = '/usr/libexec/naive-orch/sub-update';
var INIT_CMD = '/etc/init.d/naive-orch';
var SERVERS = '/var/run/naive-orch/servers.txt';

function parseExecJson(result) {
	if (!result || result.code !== 0)
		throw new Error((result && result.stderr) || _('Команда завершилась с ошибкой'));

	try {
		return JSON.parse(result.stdout || '{}');
	}
	catch (e) {
		throw new Error(_('Получен некорректный ответ от сервиса'));
	}
}

function readStatus(refresh) {
	return fs.exec(STATUS_CMD, [ refresh ? '--refresh' : '--json' ])
		.then(parseExecJson);
}

function readOperation() {
	return fs.exec(SUB_CMD, [ '--status' ]).then(parseExecJson);
}

function serviceRunning() {
	return fs.exec(INIT_CMD, [ 'running' ]).then(function(result) {
		return result.code === 0;
	}).catch(function() {
		return false;
	});
}

function badge(status, labels) {
	var colors = {
		healthy: '#2e7d32', down: '#c62828', degraded: '#ef6c00',
		unknown: '#777', running: '#1565c0', applying: '#6a1b9a',
		success: '#2e7d32', error: '#c62828', idle: '#777'
	};
	return E('span', {
		'style': 'display:inline-block;color:#fff;background:' + (colors[status] || '#777') +
			';padding:3px 9px;border-radius:12px;font-size:90%;white-space:nowrap'
	}, (labels && labels[status]) || status || _('неизвестно'));
}

function formatTime(epoch) {
	if (!epoch)
		return '—';
	try {
		return new Date(epoch * 1000).toLocaleString();
	}
	catch (e) {
		return String(epoch);
	}
}

function renderStatus(data, running) {
	var labels = {
		healthy: _('работает'), down: _('не отвечает'),
		degraded: _('нестабильно'), unknown: _('неизвестно')
	};

	if (!running)
		return E('div', { 'class': 'alert-message warning' }, [
			E('strong', {}, _('Сервис остановлен. ')),
			_('Нажмите «Запустить», чтобы поднять SOCKS-прокси и проверки.')
		]);

	var ids = Object.keys(data || {}).filter(function(id) {
		return id.charAt(0) !== '_';
	});

	if (!ids.length)
		return E('div', { 'class': 'alert-message notice' }, [
			E('strong', {}, _('Пока нет результатов. ')),
			_('Добавьте узел или подписку в настройках, затем запустите проверку.')
		]);

	var healthy = 0;
	var tbl = E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Узел')),
			E('th', { 'class': 'th' }, _('Состояние')),
			E('th', { 'class': 'th' }, _('SOCKS')),
			E('th', { 'class': 'th' }, _('Задержка')),
			E('th', { 'class': 'th' }, _('Проверено')),
			E('th', { 'class': 'th' }, _('Ошибка'))
		])
	]);

	ids.sort().forEach(function(id) {
		var node = data[id] || {};
		if (node.status === 'healthy')
			healthy++;
		tbl.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, [
				E('strong', {}, node.label || id),
				(node.label && node.label !== id) ? E('div', { 'style': 'color:#888;font-size:90%' }, id) : ''
			]),
			E('td', { 'class': 'td' }, badge(node.status, labels)),
			E('td', { 'class': 'td' }, '127.0.0.1:' + (node.port != null ? node.port : '—')),
			E('td', { 'class': 'td' }, node.latency_ms != null ? node.latency_ms + ' мс' : '—'),
			E('td', { 'class': 'td' }, formatTime(node.last_check)),
			E('td', { 'class': 'td' }, node.last_error || '—')
		]));
	});

	return E('div', {}, [
		E('p', { 'style': 'margin:.2em 0 1em' },
			_('Доступно узлов: %s из %s').format(healthy, ids.length)),
		tbl
	]);
}

function operationText(op) {
	var total = Number(op.total || 0);
	var completed = Number(op.completed || 0);
	var nodes = Number(op.nodes || 0);

	if (op.state === 'running')
		return op.current
			? _('Загружается «%s» — %s из %s').format(op.current, completed + 1, total || '?')
			: (op.message || _('Подготовка обновления…'));
	if (op.state === 'applying')
		return _('Сохраняются %s узлов и перезапускается сервис…').format(nodes);
	if (op.state === 'success')
		return _('Готово: обработано подписок — %s, импортировано узлов — %s.').format(completed, nodes);
	if (op.state === 'error')
		return op.message || _('Обновление завершилось с ошибкой.');
	return _('Обновления ещё не запускались.');
}

function renderOperation(op) {
	op = op || { state: 'idle' };
	var labels = {
		idle: _('ожидание'), running: _('обновление'), applying: _('применение'),
		success: _('готово'), error: _('ошибка')
	};
	var busy = op.state === 'running' || op.state === 'applying';
	var total = Number(op.total || 0);
	var completed = Number(op.completed || 0);
	var children = [
		E('div', { 'style': 'display:flex;gap:.7em;align-items:center;flex-wrap:wrap' }, [
			badge(op.state || 'idle', labels),
			E('span', {}, operationText(op))
		])
	];

	if (busy && total > 0)
		children.push(E('progress', {
			'value': Math.min(completed, total),
			'max': total,
			'style': 'width:100%;margin-top:.8em'
		}));

	if (!busy && op.finished_at)
		children.push(E('div', { 'style': 'color:#777;margin-top:.5em;font-size:90%' },
			_('Завершено: %s').format(formatTime(op.finished_at))));

	return E('div', {}, children);
}

function commandError(result) {
	return new Error((result && (result.stderr || result.stdout)) || _('Команда завершилась с ошибкой'));
}

return view.extend({
	load: function() {
		return Promise.all([
			readStatus(false).catch(function() { return {}; }),
			readOperation().catch(function() { return { state: 'idle' }; }),
			fs.read(SERVERS).catch(function() { return ''; }),
			uci.load('naive-orch'),
			serviceRunning()
		]);
	},

	render: function(data) {
		var statusData = data[0] || {};
		var operation = data[1] || { state: 'idle' };
		var running = data[4];
		var statusBox = E('div', {}, renderStatus(statusData, running));
		var operationBox = E('div', {}, renderOperation(operation));
		var serviceBadge = E('span', {}, badge(running ? 'healthy' : 'down', {
			healthy: _('сервис запущен'), down: _('сервис остановлен')
		}));
		var serversBox = E('pre', {}, (data[2] || '').trim() || _('(список пуст)'));

		var g = (uci.sections('naive-orch', 'global') || [])[0] || {};
		var uotOn = g.udp_over_tcp === '1';
		var uotBadge = badge(uotOn ? 'running' : 'idle', {
			running: _('UDP over TCP включён'), idle: _('UDP over TCP выключен')
		});

		var startButton = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, _('Запустить'));
		var stopButton = E('button', { 'class': 'btn cbi-button cbi-button-reset' }, _('Остановить'));
		var restartButton = E('button', { 'class': 'btn cbi-button cbi-button-action' }, _('Перезапустить'));
		var checkButton = E('button', { 'class': 'btn cbi-button cbi-button-neutral' }, _('Проверить сейчас'));
		var updateButton = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, _('Обновить все подписки'));

		function setRunning(value) {
			running = value;
			dom.content(serviceBadge, badge(running ? 'healthy' : 'down', {
				healthy: _('сервис запущен'), down: _('сервис остановлен')
			}));
			startButton.disabled = running;
			stopButton.disabled = !running;
			restartButton.disabled = !running;
		}

		function setOperation(value) {
			operation = value || { state: 'idle' };
			dom.content(operationBox, renderOperation(operation));
			updateButton.disabled = operation.state === 'running' || operation.state === 'applying';
		}

		function runService(command) {
			startButton.disabled = stopButton.disabled = restartButton.disabled = true;
			return fs.exec(INIT_CMD, [ command ]).then(function(result) {
				if (result.code !== 0)
					throw commandError(result);
				ui.addNotification(null, E('p', {}, _('Команда «%s» выполнена.').format(command)), 'info');
				return Promise.all([ readStatus(false).catch(function() { return {}; }), serviceRunning() ]);
			}).then(function(result) {
				statusData = result[0];
				setRunning(result[1]);
				dom.content(statusBox, renderStatus(statusData, running));
			}).catch(function(error) {
				ui.addNotification(null, E('p', {}, error.message || String(error)), 'error');
				return serviceRunning().then(setRunning);
			});
		}

		startButton.addEventListener('click', function() { return runService('start'); });
		stopButton.addEventListener('click', function() { return runService('stop'); });
		restartButton.addEventListener('click', function() { return runService('restart'); });

		checkButton.addEventListener('click', function() {
			checkButton.disabled = true;
			checkButton.textContent = _('Проверяется…');
			return readStatus(true).then(function(result) {
				statusData = result;
				dom.content(statusBox, renderStatus(statusData, running));
			}).catch(function(error) {
				ui.addNotification(null, E('p', {}, error.message || String(error)), 'error');
			}).then(function() {
				checkButton.disabled = false;
				checkButton.textContent = _('Проверить сейчас');
			});
		});

		updateButton.addEventListener('click', function() {
			updateButton.disabled = true;
			dom.content(operationBox, renderOperation({ state: 'running', total: 0 }));
			return fs.exec(SUB_CMD, [ '--start', '--all' ]).then(function(result) {
				if (result.code !== 0)
					throw commandError(result);
				return readOperation();
			}).then(setOperation).catch(function(error) {
				ui.addNotification(null, E('p', {}, error.message || String(error)), 'error');
				return readOperation().then(setOperation);
			});
		});

		setRunning(running);
		setOperation(operation);

		poll.add(function() {
			return Promise.all([
				readStatus(false).catch(function() { return statusData; }),
				readOperation().catch(function() { return operation; }),
				serviceRunning(),
				fs.read(SERVERS).catch(function() { return ''; })
			]).then(function(result) {
				statusData = result[0];
				setOperation(result[1]);
				setRunning(result[2]);
				dom.content(statusBox, renderStatus(statusData, running));
				dom.content(serversBox, (result[3] || '').trim() || _('(список пуст)'));
			});
		}, 3);

		return E('div', {}, [
			E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;gap:1em;flex-wrap:wrap' }, [
				E('h2', { 'style': 'margin-bottom:.4em' }, _('Naive Orchestrator')),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap' }, [ serviceBadge, uotBadge ])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Состояние узлов')),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin-bottom:1em' }, [
					startButton, stopButton, restartButton, checkButton,
					E('a', {
						'class': 'btn cbi-button cbi-button-neutral',
						'href': L.url('admin/services/naive-orch/settings')
					}, _('Настройки'))
				]),
				statusBox
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Обновление подписок')),
				E('p', {}, _('Обновление выполняется в фоне. Эту страницу можно не держать открытой — итог сохранится до перезагрузки роутера.')),
				E('div', { 'style': 'margin-bottom:1em' }, updateButton),
				operationBox
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Защита от зацикливания')),
				E('p', {}, _('Добавьте эти серверы в Podkop как direct-маршруты и direct-DNS, иначе трафик может попасть в петлю:')),
				serversBox
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
