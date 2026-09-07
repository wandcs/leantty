import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Exercise the exact acceptance-only collector, not a second implementation.
const source = readFileSync(new URL('../acceptance-source.ps1', import.meta.url), 'utf8');
const method = source.match(/\$acceptanceInputMetricsMethod = @'\r?\n([\s\S]*?)\r?\n'@/);
assert.ok(method, 'content-free input collector must be owned by the test build');
const handlers = new Map();
const timers = new Map();
const reports = [];
let nextTimer = 0;
const textarea = {
  value: '',
  addEventListener(name, handler) { handlers.set(name, handler); }
};
const context = vm.createContext({
  secureInput: false, term: { textarea },
  setTimeout(callback) { timers.set(++nextTimer, callback); return nextTimer; },
  clearTimeout(id) { timers.delete(id); },
  sendBridgeControl(kind, payload) { reports.push({ kind, payload }); }
});
vm.runInContext(method[1], context);
context.installAcceptanceInputMetrics();
context.resetAcceptanceInputMetrics();
context.observeAcceptanceData('not-a-credential');
assert.equal(timers.size, 0, 'ordinary input is outside this masked collector');
assert.equal(reports.length, 0);
context.secureInput = true;
context.resetAcceptanceInputMetrics();
assert.equal(reports.pop().payload, '0,0,0,0,0,0,0,0,0,0,0,0');
const sample = '0123456789abcdefghijklmnopqrstuv';
for (const key of sample) handlers.get('keydown')({ key, keyCode: 65 });
context.observeAcceptanceData(sample.slice(1));
context.observeAcceptanceInput(9, 1);
context.observeAcceptanceInput(10, 0);
assert.equal(timers.size, 1, 'burst observations coalesce without per-character bridge traffic');
for (const callback of [...timers.values()]) callback();
timers.clear();
assert.equal(reports.at(-1).payload, '32,0,0,0,0,0,31,0,0,1,0,0',
  'DOM delivery and xterm output must be independent counters');
context.observeAcceptanceData('\x7f\x08\r');
handlers.get('keydown')({ key: 'Unidentified', keyCode: 229 });
handlers.get('input')({ data: sample });
handlers.get('compositionstart')();
textarea.value = sample;
for (const callback of [...timers.values()]) callback();
timers.clear();
assert.equal(reports.at(-1).payload, '32,1,0,1,32,1,31,2,1,1,0,32');
for (const report of reports) {
  assert.equal(report.kind, 'acceptanceInputMetrics');
  assert.match(report.payload, /^\d+(?:,\d+){11}$/);
  assert.ok(!report.payload.includes(sample));
}
context.secureInput = false;
context.resetAcceptanceInputMetrics();
assert.equal(timers.size, 0, 'leaving masked mode cancels pending telemetry');
assert.equal(context.acceptanceInputMetrics, null);
context.secureInput = true;
context.resetAcceptanceInputMetrics();
assert.equal(reports.at(-1).payload, '0,0,0,0,0,0,0,0,0,0,0,0',
  'the next prompt must not inherit previous input counters');
console.log('Content-free masked input collector tests passed.');
