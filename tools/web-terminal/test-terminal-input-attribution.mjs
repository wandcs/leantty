import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('./acceptance-input-attribution.js', import.meta.url), 'utf8');
const sample = '0123456789abcdefghijklmnopqrstu';
function fixture() {
  const timers = new Map(), listeners = new Map(), reports = [], elements = [];
  let now = 0, timerId = 0, dataCallback;
  const element = () => ({ value: '', style: {}, setAttribute() {}, focus() {},
    remove() { this.removed = true; } });
  const textarea = element();
  const context = vm.createContext({ secureInput: false, restoringSnapshot: false,
    acceptanceInputOrderUsed: false, performance: { now: () => now },
    document: { createElement: element, body: { appendChild(e) { elements.push(e); } } },
    setTimeout(fn, delay, ...args) { timers.set(++timerId, { fn, delay, args }); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener(name, fn) { if (listeners.get(name) === fn) listeners.delete(name); },
    sendBridgeControl(kind, payload) { reports.push({ kind, payload }); }
  });
  context.window = context;
  context.term = { textarea, _core: { _keyDownSeen: false, _compositionHelper: {} },
    focus() {}, onData(fn) { dataCallback = fn; return { dispose() { dataCallback = null; } }; } };
  vm.runInContext(`term._core._compositionHelper._handleAnyTextareaChanges = function() {
    const before = term.textarea.value;
    return setTimeout(function(arg) { callbackArg = arg;
      if (term.textarea.value !== before) emit(term.textarea.value.replace(before, ''));
    }, 0, 42);
  };`, context);
  context.emit = data => {
    if (context.acceptanceInputAttribution?.chain) context.observeAcceptanceChainData(data);
    else dataCallback?.(data);
  };
  const original = context.term._core._compositionHelper._handleAnyTextareaChanges;
  vm.runInContext(source, context);
  return { context, reports, timers, elements, original, listeners,
    event(name, data = '', keyCode = 229) {
      const target = context.acceptanceInputAttribution.target;
      listeners.get(name)?.({ target, data, inputType: 'insertText', keyCode,
        composed: true, isComposing: false, get key() {
          if (keyCode === 16) return 'Shift';
          throw Error('key content forbidden');
        } });
    },
    fire(id, ms = 0) { const timer = timers.get(id); timers.delete(id); now += ms;
      timer.fn(...timer.args); },
    stop(ms = 20000) { now = ms; context.stopAcceptanceInputAttribution(1); },
    rows() { return reports.slice(1).flatMap(r => r.payload.split(';')[4].split('/').map(v => v.split(',').map(Number))); }
  };
}
for (const mode of [0, 1, 2, 3]) {
  const f = fixture();
  assert.equal(f.context.armAcceptanceInputAttribution('1234567', mode), true);
  assert.equal(f.reports.length, 1);
  assert.equal(f.context.focusAcceptanceInputAttribution(), mode % 2 === 0,
    'Pane focus must preserve only the explicitly armed plain-textarea owner');
  const target = f.context.acceptanceInputAttribution.target;
  target.value = sample; f.event('input', sample);
  if (mode % 2) f.context.emit(sample);
  f.stop(mode < 2 ? 20000 : 60000);
  const summary = f.rows().at(-1);
  assert.deepEqual(summary.slice(2, 7), [9, mode, 31, 31, 1]);
  assert.equal(f.context.acceptanceInputAttribution, null);
  assert.equal(f.context.focusAcceptanceInputAttribution(), false, 'normal focus restored after probe');
  assert.equal(f.context.term._core._compositionHelper._handleAnyTextareaChanges, f.original);
  assert.equal(f.listeners.size, 0);
  assert.ok(f.elements.every(e => e.removed));
  assert.equal(f.context.armAcceptanceInputAttribution('7654321', mode), false);
  for (const report of f.reports) assert.match(report.payload, /^[0-9;,/]+$/);
}
for (const early of [false, true]) {
  const f = fixture(); f.context.armAcceptanceInputAttribution('1234567', 1);
  const savedTimeout = f.context.setTimeout;
  f.context.term._core._keyDownSeen = true;
  f.event('keydown');
  const id = f.context.term._core._compositionHelper._handleAnyTextareaChanges();
  assert.equal(f.context.setTimeout, savedTimeout, 'global timer restored synchronously');
  if (early) f.fire(id, 1);
  f.context.term.textarea.value = 'a'; f.event('input', 'a');
  if (!early) f.fire(id, 1);
  assert.equal(f.context.callbackArg, 42, 'callback arguments forwarded');
  f.stop();
  const kinds = f.rows().map(r => r[2]);
  assert.ok(kinds.indexOf(7) < kinds.indexOf(2) === early);
  assert.equal(f.rows().at(-1)[5], early ? 0 : 1);
  assert.equal(kinds.filter(k => k === 7).length, 1, 'callback executed exactly once');
}
for (const boundary of ['secureInput', 'restoringSnapshot']) {
  const f = fixture(); f.context.armAcceptanceInputAttribution('1234567', 1);
  f.context[boundary] = true; f.event('input', 'private-sentinel');
  assert.equal(f.context.acceptanceInputAttribution, null);
  assert.ok(f.reports.slice(1).every(r => r.payload.startsWith('1234567;3;')));
  assert.ok(f.reports.every(r => !r.payload.includes('private-sentinel')));
}
const cap = fixture(); cap.context.armAcceptanceInputAttribution('1234567', 1);
for (let i = 0; i < 260; i++) if (cap.context.acceptanceInputAttribution) cap.event('keydown');
assert.equal(cap.rows().length, 256);
assert.equal(cap.rows().at(-1)[2], 9, 'capacity always leaves room for summary');
const missing = fixture(); missing.context.term._core._compositionHelper = null;
assert.equal(missing.context.armAcceptanceInputAttribution('1234567', 1), false);
const other = fixture(); assert.equal(other.reports.length, 0, 'unarmed Pane silent');
const chainSample = 'ssh-keygen -R [127.0.0.1]:2223'.repeat(6);
const chain = fixture(); chain.context.armAcceptanceInputAttribution('1234567', 4);
assert.equal(chain.context.focusAcceptanceInputAttribution(), false);
for (const character of chainSample) {
  if (chain.context.term.textarea.value.length % 15 === 0) {
    chain.event('keydown', '', 16); chain.event('keyup', '', 16);
  }
  chain.event('keydown');
  const id = chain.context.term._core._compositionHelper._handleAnyTextareaChanges();
  chain.event('beforeinput', character);
  chain.context.term.textarea.value += character;
  chain.event('input', character); chain.fire(id, 1);
  chain.context.observeAcceptanceChainPost(12, character);
  chain.context.observeAcceptanceChainPost(13, character);
  chain.event('keyup');
  chain.event('keyup'); // The device trace includes an additional physical release.
}
chain.stop();
const chainRows = chain.rows();
assert.deepEqual(chainRows.at(-1).slice(2, 7), [9, 4, 180, 180, 1]);
assert.equal(chainRows.length, 2365, '13 rows per character plus non-text key pairs fit before capacity stop');
assert.equal(chainRows.filter(r => r[2] === 16 && r[4] === 1).length, 180);
assert.equal(chainRows.filter(r => r[2] === 7).length, 180);
assert.equal(chainRows.findLast(r => r[2] === 6)[3], 180);
assert.equal(chainRows.findLast(r => r[2] === 6)[4], 179);
assert.equal(chainRows.filter(r => r[2] === 12).reduce((n, r) => n + r[7], 0), 180);
assert.equal(chainRows.filter(r => r[2] === 13).length, 180);
chain.context.observeAcceptanceChainData('private-late');
assert.equal(chain.rows().length, chainRows.length);
assert.equal(chain.context.term._core._compositionHelper._handleAnyTextareaChanges, chain.original);
assert.ok(chain.reports.every(r => /^[0-9;,/]+$/.test(r.payload)));
const noPort = fixture(); noPort.context.armAcceptanceInputAttribution('1234567', 4);
noPort.context.observeAcceptanceChainData('private-sentinel');
noPort.context.observeAcceptanceChainPost(14, 'private-sentinel'); noPort.stop();
assert.equal(noPort.rows().filter(r => r[2] === 14)[0][7], 16);
assert.equal(noPort.rows().at(-1)[6], 0);
assert.ok(noPort.reports.every(r => !r.payload.includes('private-sentinel')));
const chainCap = fixture(); chainCap.context.armAcceptanceInputAttribution('1234567', 4);
for (let i = 0; i < 4100; i++) chainCap.context.observeAcceptanceChainPost(12, 'x');
assert.equal(chainCap.rows().length, 4096);
assert.equal(chainCap.reports.length, 257, 'ready plus at most 256 chunks');
assert.ok(chainCap.reports.slice(1).every(r => r.payload.startsWith('1234567;2;')));
// Execute the actual small ArkTS owner methods after erasing only primitive types.
const transform = readFileSync(new URL('../acceptance-source.ps1', import.meta.url), 'utf8');
const ownerSource = transform.match(/\$observerMethods = @'\r?\n([\s\S]*?)\r?\n'@/)[1]
  .replace(/\bprivate /g, '').replace(/: (?:boolean|string|number|void)\b/g, '');
const ownerReports = [], ownerTimers = new Map(), webArms = [];
const ownerContext = vm.createContext({ ACCEPTANCE_TESTS: true, TerminalMode: { IDLE: 0 },
  setTimeout(fn, delay) { assert.equal(delay, 23000); ownerTimers.set(fn, fn); return fn; },
  clearTimeout(id) { ownerTimers.delete(id); } });
vm.runInContext('class Owner { ' + ownerSource + ' }; globalThis.Owner = Owner;', ownerContext);
function createOwner() {
  const owner = new ownerContext.Owner(); owner.mode = 0;
  owner.terminalSurface = { armInputOrderForAcceptance: (...args) => webArms.push(args) };
  owner.commandLine = { getText: () => chainSample };
  owner.logger = { info: text => ownerReports.push(text) };
  return owner;
}
for (const profile of [5, 6, 7]) {
  const owner = createOwner(), armsBefore = webArms.length;
  owner.armAcceptanceObserver('1234567', profile);
  assert.equal(owner.acceptanceObserverQuiet, profile !== 5);
  assert.equal(webArms.length - armsBefore, profile === 7 ? 1 : 0, 'unarmed controls never touch Web handlers');
  const callback = owner.acceptanceObserverTimer;
  assert.equal(ownerReports.at(-1), `ACCEPTANCE_OBSERVER_READY 1234567;${profile}`);
  callback();
  assert.equal(ownerReports.at(-1), `ACCEPTANCE_OBSERVER_FINAL 1234567;${profile};1;180;1;0`);
  assert.equal(owner.acceptanceObserverQuiet, false);
  const count = ownerReports.length; callback(); assert.equal(ownerReports.length, count);
}
const syntheticOwner = createOwner();
syntheticOwner.commandLine.getText = () => 'a'.repeat(30);
syntheticOwner.armAcceptanceObserver('1234567', 8);
assert.deepEqual(webArms.at(-1), ['1234567', 8]);
syntheticOwner.acceptanceObserverTimer();
assert.equal(ownerReports.at(-1), 'ACCEPTANCE_OBSERVER_FINAL 1234567;8;1;30;0;31');
const stoppedOwner = createOwner(); stoppedOwner.armAcceptanceObserver('1234567', 6);
const late = stoppedOwner.acceptanceObserverTimer;
stoppedOwner.stopAcceptanceObserver(); const countBeforeLate = ownerReports.length; late();
assert.equal(ownerReports.length, countBeforeLate, 'cancelled owner rejects late summary');
const secretOwner = createOwner(); secretOwner.armAcceptanceObserver('1234567', 6);
secretOwner.mode = 2; secretOwner.commandLine.getText = () => { throw Error('must not read non-idle buffer'); };
secretOwner.acceptanceObserverTimer();
assert.equal(ownerReports.at(-1), 'ACCEPTANCE_OBSERVER_FINAL 1234567;6;0;0;0;1');
assert.equal(ownerTimers.size, 0);
assert.match(transform, /!this.acceptanceObserverQuiet\) \{\r?\n\s*this.logger.info\('ACCEPTANCE_IDLE_ACTION/);
assert.match(transform, /!this.acceptanceObserverQuiet\) \{\r?\n\s*this.logger.info\('ACCEPTANCE_IDLE_RESULT/);
console.log('Input attribution observer: five modes, timer forwarding, Bridge counters, boundaries, capacity and privacy passed.');
