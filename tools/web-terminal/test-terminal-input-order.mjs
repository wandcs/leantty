import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./acceptance-input-order.js', import.meta.url), 'utf8');
function createPane() {
  const handlers = new Map(), timers = new Map(), reports = [];
  let now = 0, timerId = 0;
  const textarea = { value: '' };
  const context = vm.createContext({ secureInput: false, restoringSnapshot: false, term: { textarea },
    performance: { now: () => now },
    window: { addEventListener(name, fn, capture) {
      if (name !== 'pagehide') assert.equal(capture, true, 'DOM observer is ancestor capture');
      handlers.set(name, fn);
    } },
    setTimeout(fn) { timers.set(++timerId, fn); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    sendBridgeControl(kind, payload) { reports.push({ kind, payload }); }
  });
  vm.runInContext(source, context);
  context.installAcceptanceInputOrder();
  return { context, reports, timers, textarea, handlers,
    event(name, extra = {}) { handlers.get(name)({ target: textarea, keyCode: 229,
      composed: true, isComposing: false, inputType: 'insertText', data: 'private-sentinel',
      get key() { throw Error('must not read key'); }, ...extra }); },
    advance(ms) { now += ms; },
    finish() { now = 20000; for (const fn of [...timers.values()]) fn(); }
  };
}
const a = createPane(), b = createPane();
a.event('input');
assert.equal(a.reports.length, 0, 'disabled by default');
assert.equal(a.context.armAcceptanceInputOrder('1234567'), true);
assert.equal(a.reports.length, 1, 'ready acknowledgement only');
a.event('beforeinput'); a.textarea.value = 'private-sentinel';
a.event('input'); a.context.observeAcceptanceInputOrderData('public'); a.event('keydown'); a.event('keyup');
a.event('input', { target: {} });
b.event('input');
assert.equal(b.reports.length, 0, 'other Pane remains unarmed');
assert.equal(a.reports.length, 1, 'no reporting during measured burst');
a.finish();
const payload = a.reports.at(-1).payload;
assert.match(payload, /^1234567;1;0;1;/);
const rows = payload.split(';')[4].split('/').map(r => r.split(',').map(Number));
assert.deepEqual(rows.map(r => r[2]), [1, 2, 5, 3, 4]);
assert.equal(rows[1][8], 16, 'only textarea length retained');
assert.equal(rows[2][9], 6, 'onData printable units');
assert.equal(rows[3][3], 1, '229 is a category, not a key');
assert.equal(a.context.acceptanceInputOrder, null, 'buffer released after stop');
assert.equal(a.context.armAcceptanceInputOrder('7654321'), false, 'one arm per document');
a.event('input'); a.context.observeAcceptanceInputOrderData('late');
assert.equal(a.reports.length, 2, 'late events cannot revive a completed trace');
for (const report of a.reports) {
  assert.equal(report.kind, 'acceptanceInputOrder');
  assert.match(report.payload, /^[0-9;,/]+$/);
  assert.ok(!report.payload.includes('private-sentinel'));
}
const capped = createPane(); capped.context.armAcceptanceInputOrder('1234567');
for (let i = 0; i < 300; i++) capped.event('input');
assert.equal(capped.reports.length, 17, '256 rows batched into 16 reports');
assert.ok(capped.reports.slice(1).every(r => r.payload.startsWith('1234567;2;')));
assert.equal(capped.timers.size, 0);
for (const boundary of ['secureInput', 'restoringSnapshot']) {
  const pane = createPane(); pane.context.armAcceptanceInputOrder('1234567');
  pane.context[boundary] = true; pane.event('input');
  assert.equal(pane.reports.at(-1).payload, '1234567;3;0;1;');
  assert.equal(pane.context.acceptanceInputOrder, null);
}
const expired = createPane(); expired.context.armAcceptanceInputOrder('1234567');
expired.advance(20001); expired.event('input');
assert.equal(expired.reports.at(-1).payload, '1234567;1;0;1;', 'suspended timer cannot extend capture');
const destroyed = createPane(); destroyed.context.armAcceptanceInputOrder('1234567');
destroyed.handlers.get('pagehide')(); destroyed.event('input');
assert.equal(destroyed.reports.at(-1).payload, '1234567;4;0;1;');
assert.equal(destroyed.timers.size, 0);
const detached = createPane(); detached.context.armAcceptanceInputOrder('1234567');
detached.context.term = null; detached.event('input');
assert.equal(detached.reports.at(-1).payload, '1234567;3;0;1;');
assert.equal(createPane().context.armAcceptanceInputOrder('not-a-token'), false);

// Execute the actual transformed Surface receive guard with stale/other-owner messages.
const transform = readFileSync(new URL('../acceptance-source.ps1', import.meta.url), 'utf8');
const receive = transform.match(/\$surfaceMessageReplacement = @'\r?\n([\s\S]*?)\r?\n'@/)[1];
const metrics = receive.indexOf('msg.kind === BridgeProtocol.KIND_ACCEPTANCE_INPUT_METRICS');
const guard = receive.slice(0, receive.lastIndexOf('    if (ACCEPTANCE_TESTS', metrics));
const bridge = {}, logged = [];
const protocol = { DIRECTION_WEB_TO_NATIVE: 'w2n', CHANNEL_CONTROL: 'control',
  CHANNEL_DATA: 'data', KIND_TERMINAL: 'terminal', KIND_ACCEPTANCE_INPUT_ORDER: 'acceptanceInputOrder' };
const receiveContext = vm.createContext({ ACCEPTANCE_TESTS: true, BridgeProtocol: protocol });
vm.runInContext('function receive(sourceBridge, msg) { ' + guard + ' }', receiveContext);
const owner = { bridge, acceptanceInputOrderToken: '1234567', logger: { info: line => logged.push(line) } };
const msg = { direction: 'w2n', channel: 'control', kind: 'acceptanceInputOrder', payload: '1234567;1;0;1;' };
receiveContext.receive.call(owner, {}, msg);
receiveContext.receive.call(owner, bridge, { ...msg, payload: '7654321;1;0;1;' });
receiveContext.receive.call(owner, bridge, { ...msg, direction: 'n2w' });
assert.equal(logged.length, 0, 'old Bridge, other Pane token and wrong direction rejected');
receiveContext.receive.call(owner, bridge, msg);
assert.equal(logged.length, 1);
owner.acceptanceInputOrderToken = '';
receiveContext.receive.call(owner, bridge, msg);
assert.equal(logged.length, 1, 'mode invalidation rejects late reports');
owner.acceptanceInputOrderToken = '1234567';
owner.acceptanceInputChainActive = true;
owner.acceptanceInputChainPackets = 0; owner.acceptanceInputChainUnits = 0;
const data = { direction: 'w2n', channel: 'data', kind: 'terminal', payload: 'public' };
receiveContext.receive.call(owner, {}, data);
receiveContext.receive.call(owner, bridge, { ...data, direction: 'n2w' });
receiveContext.receive.call(owner, bridge, data);
receiveContext.receive.call(owner, bridge, { ...msg, payload: '1234567;0;0;0;' });
assert.equal(owner.acceptanceInputChainActive, true, 'ready does not end receipt observation');
receiveContext.receive.call(owner, bridge, msg);
assert.ok(logged.includes('ACCEPTANCE_INPUT_CHAIN_NATIVE 1234567;1;6'));
assert.equal(owner.acceptanceInputChainActive, false);
receiveContext.receive.call(owner, bridge, data);
assert.equal(owner.acceptanceInputChainPackets, 1, 'late data cannot alter closed evidence');
console.log('Bounded content-free input order collector tests passed.');
