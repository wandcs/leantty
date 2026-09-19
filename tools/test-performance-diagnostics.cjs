// Execute the real owners; only platform services are stubbed. Public fixtures only.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const enabled = process.argv[3] === 'enabled';
const root = path.resolve(__dirname, '..');
const records = [];
let decodedBytes = 0;
function observationDecoder() {
  const decoder = new TextDecoder();
  return { decodeToString(data, options) {
    decodedBytes += data.length;
    return decoder.decode(data, options);
  } };
}
function compile(relative, overrides = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const result = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
  }, fileName: relative.replace(/\.ets$/, '.ts'), reportDiagnostics: true });
  assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const exports = {};
  vm.runInNewContext(result.outputText, { exports, Observed: value => value,
    require(name) {
      if (name in overrides) return overrides[name];
      return new Proxy({}, { get(_target, key) { throw Error(`Unexpected dependency ${name}.${String(key)}`); } });
    },
  }, { filename: relative });
  return exports;
}
const { Logger } = compile('entry/src/main/ets/common/logger/Logger.ets', {
  '@kit.PerformanceAnalysisKit': { hilog: { info(_domain, _tag, format, message) {
    records.push({ format, message });
  } } },
});
const escape = compile('entry/src/main/ets/model/ssh/SshEscapeParser.ets');
const { SessionViewModel } = compile('entry/src/main/ets/viewmodel/SessionViewModel.ets', {
  '../model/ssh/SshEscapeParser': escape, BuildProfile: { ACCEPTANCE_TESTS: enabled },
  '@ohos.util': { default: { TextDecoder: { create: observationDecoder } } },
});
// Public data through the real output owners; count only the observation decoder,
// not the terminal's required VT decoding. No device performance claim is made.
function outputFixture() {
  const owner = Object.create(SessionViewModel.prototype), delivered = [];
  Object.assign(owner, { acceptingSessionOutput: true, pendingKeypush: false,
    keypushMarker: '', keypushOutputTail: '', keypushTimeoutId: -1,
    keypushOutputDecoder: null,
    perfPingId: '', perfOutputDecoder: null, moshClient: null,
    writeTerminalBytes: data => delivered.push(...data),
    terminalSurface: { writeMoshBytes: data => delivered.push(...data) },
  });
  return { owner, delivered };
}
for (const method of ['onSessionData', 'onMoshData']) {
  const f = outputFixture();
  const raw = Buffer.from([0xe4, 0xb8, 0xad, 0x00, 0xff, 0x1b, 0x5b, 0x32, 0x4a]);
  decodedBytes = 0;
  f.owner[method](raw.subarray(0, 1));
  f.owner[method](raw.subarray(1));
  assert.equal(decodedBytes, 0, `${method}: inactive observers must not decode terminal output`);
  assert.deepEqual(Buffer.from(f.delivered), raw, `${method}: bytes must remain unchanged`);
  f.owner.acceptingSessionOutput = false;
  f.owner[method](raw);
  assert.deepEqual(Buffer.from(f.delivered), raw, `${method}: closed boundary must ignore late bytes`);
}
// Key installation still owns a streaming decoder, but only during its marker
// observation window. Completion is stubbed at the external disconnect boundary.
const installing = outputFixture(), idle = outputFixture();
const statuses = [];
Object.assign(installing.owner, { pendingKeypush: true, keypushMarker: '__PUBLIC_KEYPUSH',
  completeKeypush(status) { statuses.push(status); this.clearKeypushState(); },
});
const keyOutput = Buffer.from('中\r\n__PUBLIC_KEYPUSH:0\r\n');
decodedBytes = 0;
installing.owner.onSessionData(keyOutput.subarray(0, 1));
assert.equal(installing.owner.keypushOutputTail, '', 'incomplete UTF-8 stays in the decoder');
installing.owner.onSessionData(keyOutput.subarray(1, 3));
assert.equal(installing.owner.keypushOutputTail, '中', 'UTF-8 survives packet boundaries');
installing.owner.onSessionData(keyOutput.subarray(3, -2));
assert.deepEqual(statuses, [], 'a marker without its final newline must wait');
idle.owner.onSessionData(keyOutput);
assert.equal(idle.owner.keypushOutputDecoder, null, 'decoders are per owner');
installing.owner.onSessionData(keyOutput.subarray(-2));
assert.deepEqual(statuses, [0]);
assert.equal(decodedBytes, keyOutput.length, 'only the active Keypush consumes output');
assert.equal(installing.owner.keypushOutputDecoder, null, 'completion releases the decoder');
assert.deepEqual(Buffer.from(installing.delivered), keyOutput);
installing.owner.onSessionData(Buffer.from('after completion'));
assert.equal(decodedBytes, keyOutput.length, 'completed observers stop decoding');
for (const marker of ['', '__PUBLIC_KEYPUSH']) {
  Object.assign(installing.owner, { pendingKeypush: true, keypushMarker: marker });
  decodedBytes = 0;
  installing.owner.onMoshData(keyOutput);
  assert.equal(decodedBytes, 0, 'Mosh never feeds the SSH Keypush observer');
  installing.owner.onSessionData(Buffer.from([0xe4]));
  assert.equal(decodedBytes, marker ? 1 : 0, 'pending authentication without a marker does not decode');
  installing.owner.clearKeypushState();
  assert.equal(installing.owner.keypushOutputDecoder, null, 'cancellation discards partial UTF-8');
}
Object.assign(installing.owner, { pendingKeypush: true, keypushMarker: '__PUBLIC_KEYPUSH' });
installing.owner.onSessionData(Buffer.from('fresh'));
assert.equal(installing.owner.keypushOutputTail, 'fresh', 'the next operation has no decoder carryover');
installing.owner.clearKeypushState();
function fixture() {
  const { owner } = outputFixture();
  const writes = [], keypush = [];
  Object.assign(owner, { perfPingId: '', perfPingStartedMs: 0, perfInputBuffer: '',
    perfInputInvalid: false, perfOutputTail: '', logger: new Logger('public-fixture'),
    moshClient: null, sshEscapeParser: new escape.SshEscapeParser(),
    sshClient: { write: data => writes.push(data) },
    pendingKeypush: true, keypushMarker: '__PUBLIC_KEYPUSH',
    observeKeypushOutput: data => keypush.push(data),
  });
  return { owner, writes, keypush };
}
const suffix = 'PUBLIC_CANARY_NOT_A_SECRET';
const invalid = fixture();
const command = `echo LTTY_PERF_PING_case ${suffix}\r`;
invalid.owner.handleConnectedInput(command);
invalid.owner.onSessionData(Buffer.from(command.slice(5)));
assert.equal(invalid.writes.join(''), command, 'diagnostics must not change SSH input');
assert.equal(invalid.keypush.join(''), command.slice(5), 'Keypush observation must survive isolation');
assert.equal(records.length, 0, 'arbitrary command suffix must not reach public hilog');
const marked = fixture(), other = fixture();
marked.owner.handleConnectedInput('echo LTTY_PERF_');
marked.owner.handleConnectedInput('PING_case_01\r');
other.owner.onMoshData(Buffer.from('LTTY_PERF_PING_case_01'));
assert.equal(records.length, 0, 'another Session must not satisfy a pending ping');
marked.owner.onMoshData(Buffer.from('LTTY_PERF_PING_'));
marked.owner.onMoshData(Buffer.from('case_01\r\n'));
assert.equal(records.length, enabled ? 1 : 0, 'only the debug transform may produce ping metrics');
if (enabled) {
  assert.match(records[0].message, /^PERF ping id=LTTY_PERF_PING_case_01 rttMs=\d+$/);
  marked.owner.resetPerfObservation();
  assert.equal(marked.owner.perfOutputTail, '');
  assert.equal(marked.owner.perfInputBuffer, '');
  assert.equal(marked.owner.perfOutputDecoder, null);
  const ping = fixture();
  ping.owner.clearKeypushState();
  ping.owner.handleConnectedInput('echo LTTY_PERF_PING_ssh\r');
  ping.owner.onSessionData(Buffer.from([0xe4]));
  assert.ok(ping.owner.perfOutputDecoder, 'a pending ping lazily owns its decoder');
  ping.owner.resetPerfObservation();
  ping.owner.handleConnectedInput('echo LTTY_PERF_PING_ssh\r');
  ping.owner.onSessionData(Buffer.from('fresh'));
  assert.equal(ping.owner.perfOutputTail, 'fresh', 'a new ping has no partial UTF-8 carryover');
  ping.owner.onSessionData(Buffer.from('LTTY_PERF_PING_ssh'));
  assert.equal(records.length, 2, 'the SSH output hook also completes a ping');
  assert.equal(ping.owner.perfOutputDecoder, null);
  ping.owner.handleConnectedInput('echo LTTY_PERF_PING_expired\r');
  ping.owner.perfPingStartedMs = Date.now() - 31000;
  decodedBytes = 0;
  ping.owner.onSessionData(Buffer.from('LTTY_PERF_PING_expired'));
  assert.equal(decodedBytes, 0, 'expired pings reset before decoding');
  assert.equal(ping.owner.perfOutputDecoder, null);
  assert.equal(records.length, 2, 'expired pings cannot report success');
} else {
  assert.equal(SessionViewModel.prototype.observePerfInput, undefined);
  assert.equal(SessionViewModel.prototype.observePerfOutput, undefined);
}
console.log('Performance Session observer contracts passed');
