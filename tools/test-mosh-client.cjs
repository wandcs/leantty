// Executes current ArkTS owners with a substituted N-API boundary. This is a
// host contract test, not an ArkTS compiler, queue-saturation or device test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const ts = require(process.argv[2]);
const sourceRoot = 'entry/src/main/ets/';

function compile(relative, imports) {
  const result = ts.transpileModule(fs.readFileSync(path.join(root, relative), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    fileName: relative.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
  });
  assert.equal((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const exports = {};
  vm.runInNewContext(result.outputText, {
    exports, require(name) {
      if (!(name in imports)) throw new Error(`Unmodeled import: ${name}`);
      return imports[name];
    }, Uint8Array, Promise, Number, Error,
    // UI observation is not exercised; only the real TerminalMode values are used.
    Observed: value => value,
  }, { filename: relative });
  return exports;
}

const policy = compile(sourceRoot + 'model/ssh/SshControlEventPolicy.ets', { '../../common/types/SshTypes': {} });
const escape = compile(sourceRoot + 'model/mosh/MoshEscapeParser.ets', {});
const terminalTypes = compile(sourceRoot + 'common/types/TerminalTypes.ets', {});
const logs = [];
const logger = { Logger: class { info() {} error(message) { logs.push(message); }
  warn(message) { logs.push(message); } } };
const nativeSessions = new Map();
let nextId = 1;
const native = {
  moshConnect(...args) {
    const id = String(nextId++);
    nativeSessions.set(id, { transport: args.at(-3), control: args.at(-2), generation: args.at(-4),
      writes: [], disconnects: 0, rejectWrite: false, rejectClose: false, closeDuringRequest: false });
    return id;
  },
  moshWrite(id, data) {
    const session = nativeSessions.get(id);
    if (!session) throw new Error('Mosh session not found');
    if (session.rejectWrite) throw new Error('private native failure and input must not be shown');
    session.writes.push(data);
  },
  moshDisconnect(id) {
    const session = nativeSessions.get(id);
    // Real native idempotency is separately covered by mosh_disconnect_* Rust
    // tests. Removing its map entry cannot complete the ArkTS callback owner.
    if (!session) return;
    session.disconnects++;
    if (session.rejectClose) throw new Error('private close failure');
    if (session.closeDuringRequest) close(session);
  },
};
const mosh = compile(sourceRoot + 'model/mosh/MoshClient.ets', {
  'libleantty_ssh.so': { default: native }, '../../common/logger/Logger': logger,
  '../ssh/SshClient': {}, '../ssh/SshControlEventPolicy': policy,
});

async function fixture() {
  const client = new mosh.MoshClient();
  const events = [], output = [];
  client.onEvent(event => events.push(event));
  client.onData(data => output.push(...data));
  await client.connect({ jumpHost: '', host: 'fixture.invalid', port: 22, username: 'fixture',
    privateKeyPath: '', privateKeyRequiresPassphrase: false, knownHostsPath: '',
    connectTimeoutMs: 15000, serverAliveIntervalSeconds: 0, serverAliveCountMax: 3 }, '', 0, 0, 'adaptive', 80, 24);
  const id = String(nextId - 1), session = nativeSessions.get(id);
  session.id = id;
  connected(session);
  assert.equal(client.isConnected(), true);
  events.length = 0;
  return { client, session, events, output };
}
function connected(s) { s.control({ kind: 'connected', sessionId: s.id, generation: s.generation }); }
function close(s) { s.transport({ kind: 'close', code: '', detail: 'local_closed', exitCode: 0 }); }
function data(s, bytes) { s.transport({ kind: 'data', data: new Uint8Array(bytes) }); }
function failure(s) {
  s.control({ kind: 'error', sessionId: s.id, generation: s.generation,
    layer: 'target', code: 'input', stage: 'mosh_udp', detail: 'input failed' });
}
async function flush() { for (let i = 0; i < 8; i++) await Promise.resolve(); }
const cases = [];
function test(name, run) { cases.push({ name, run }); }

test('accepts ordered input exactly once', async () => {
  const f = await fixture();
  assert.equal(f.client.write('first'), true);
  assert.equal(f.client.write('second'), true);
  assert.deepEqual(f.session.writes, ['first', 'second']);
  assert.equal(f.events.length, 0);
  close(f.session);
});

test('one close request completes every overlapping waiter after final output', async () => {
  const f = await fixture();
  let first = false, second = false;
  f.client.disconnect().then(() => { first = true; });
  f.client.disconnect().then(() => { second = true; });
  await flush();
  assert.equal(first || second, false);
  assert.equal(f.session.disconnects, 1);
  assert.equal(f.client.write('not admitted'), false);
  connected(f.session);
  assert.equal(f.client.isConnected(), false);
  data(f.session, [65]);
  close(f.session);
  await flush();
  assert.equal(first && second, true);
  assert.deepEqual(f.output, [65]);
  assert.equal(f.events.length, 1);
  data(f.session, [66]);
  close(f.session);
  assert.deepEqual(f.output, [65]);
  assert.equal(f.events.length, 1);
});

test('native close request rejection and synchronous close both settle', async () => {
  for (const key of ['rejectClose', 'closeDuringRequest']) {
    const f = await fixture(); f.session[key] = true;
    let done = false;
    f.client.disconnect().then(() => { done = true; });
    await flush();
    assert.equal(done, true);
    assert.equal(f.client.hasActiveSession(), false);
  }
});

test('local admission failure blocks further input and drains before a safe error', async () => {
  const f = await fixture();
  f.session.rejectWrite = true;
  assert.equal(f.client.write('not admitted'), false);
  assert.equal(f.client.isConnected(), false);
  assert.equal(f.client.hasActiveSession(), true);
  assert.equal(f.events.length, 0);
  f.session.rejectWrite = false;
  assert.equal(f.client.write('\r'), false);
  assert.deepEqual(f.session.writes, []);
  let closing = false;
  f.client.disconnect().then(() => { closing = true; });
  assert.equal(f.session.disconnects, 1);
  // A late control error must not cut ahead of output on the transport callback.
  failure(f.session);
  data(f.session, [65, 66]);
  close(f.session);
  await flush();
  assert.equal(closing, true);
  assert.deepEqual(f.output, [65, 66]);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0].kind, mosh.MoshClientEvent.ERROR);
  assert.equal(f.events[0].error.code, mosh.MoshErrorCode.INPUT_REJECTED);
  assert.equal(f.client.hasActiveSession(), false);
  assert.doesNotMatch(JSON.stringify(f.events) + logs.join(''), /private native|private close|not admitted/);
});

test('rejection still reports one safe input error if close cannot be requested', async () => {
  const f = await fixture();
  f.session.rejectWrite = f.session.rejectClose = true;
  assert.equal(f.client.write('x'), false);
  await flush();
  assert.equal(f.client.hasActiveSession(), false);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0].error.code, mosh.MoshErrorCode.INPUT_REJECTED);
});

for (const request of ['input rejection', 'explicit disconnect']) {
  test(`${request} after native cleanup drains queued final output before completion`, async () => {
    const f = await fixture();
    // Native has queued these callbacks but ArkTS is still in an input/UI event.
    const queued = [() => data(f.session, [65, 66]), () => close(f.session)];
    nativeSessions.delete(f.session.id);
    if (request === 'input rejection') assert.equal(f.client.write('late input'), false);
    let first = false, second = false;
    f.client.disconnect().then(() => { first = true; });
    f.client.disconnect().then(() => { second = true; });
    await flush();
    assert.equal(first || second, false);
    assert.equal(f.client.hasActiveSession(), true);
    assert.equal(f.client.isConnected(), false);
    assert.equal(f.client.write('\r'), false);
    assert.equal(f.events.length, 0);
    queued[0]();
    assert.deepEqual(f.output, [65, 66]);
    assert.equal(f.events.length, 0);
    queued[1]();
    await flush();
    assert.equal(first && second, true);
    assert.equal(f.client.hasActiveSession(), false);
    assert.equal(f.events.length, 1);
    assert.equal(f.events[0].kind, request === 'input rejection' ?
      mosh.MoshClientEvent.ERROR : mosh.MoshClientEvent.CLOSE);
    if (request === 'input rejection') {
      assert.equal(f.events[0].error.code, mosh.MoshErrorCode.INPUT_REJECTED);
    }
    data(f.session, [67]); close(f.session);
    assert.deepEqual(f.output, [65, 66]);
    assert.equal(f.events.length, 1);
  });
}

test('post-admission native failure retains its existing failure classification', async () => {
  const f = await fixture();
  f.client.write('a'); failure(f.session); close(f.session);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0].error.code, mosh.MoshErrorCode.PROTOCOL);
});

test('current native error records safe kind before owner clearing, once', async () => {
  const f = await fixture(), start = logs.length;
  f.session.control({ kind: 'error', sessionId: f.session.id, generation: f.session.generation,
    layer: 'target', code: 'network', stage: 'mosh_udp', detail: 'Session I/O failed: PermissionDenied' });
  f.session.transport({ kind: 'close', code: 'network', detail: 'Session I/O failed: PermissionDenied' });
  const failures = logs.slice(start).filter(line => line.startsWith('Mosh failure '));
  assert.equal(failures.length, 1);
  assert.equal(failures[0], `Mosh failure generation=${f.session.generation},connected=true,closing=false,` +
    'source=control,stage=mosh_udp,nativeCode=network,ioKind=PermissionDenied');
  assert.equal(f.client.hasActiveSession(), false);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0].error.code, mosh.MoshErrorCode.NETWORK);
});

test('failure diagnostics reject arbitrary detail and metadata', () => {
  for (const detail of ['private-key-content', 'Session I/O failed: PrivateSecret',
    'Session I/O failed: TimedOut\nprivate-key-content', 'Session I/O failed: TimedOut ']) {
    const error = new mosh.MoshError(mosh.MoshErrorCode.NETWORK, 'private-message', detail, 'mosh_udp');
    assert.equal(mosh.MoshClient.safeErrorDiagnostic(error, 'control', 'network'),
      'source=control,stage=mosh_udp,nativeCode=network,ioKind=unknown');
  }
  const error = new mosh.MoshError(mosh.MoshErrorCode.AUTH, 'secret',
    'Session I/O failed: TimedOut', 'private-stage');
  assert.equal(mosh.MoshClient.safeErrorDiagnostic(error, 'private-source', 'private-code'),
    'source=unknown,stage=unknown,nativeCode=unknown,ioKind=unknown');
  error.stage = 'authentication';
  assert.match(mosh.MoshClient.safeErrorDiagnostic(error, 'control', 'network'), /ioKind=unknown$/);
});

test('stale control does not emit failure diagnostic or disturb another owner', async () => {
  const f = await fixture(), start = logs.length;
  f.session.control({ kind: 'error', sessionId: f.session.id, generation: f.session.generation + 1,
    layer: 'target', code: 'network', stage: 'mosh_udp', detail: 'Session I/O failed: TimedOut' });
  assert.equal(logs.slice(start).some(line => line.startsWith('Mosh failure ')), false);
  assert.equal(f.client.isConnected(), true);
  assert.equal(f.events.length, 0);
  close(f.session);
});

test('transport and invalid reachability failure origins stay distinguishable', async () => {
  for (const origin of ['transport', 'reachability']) {
    const f = await fixture(), start = logs.length;
    if (origin === 'transport') {
      f.session.transport({ kind: 'close', code: 'callback', detail: 'private callback message' });
    } else {
      f.session.transport({ kind: 'reachability', layer: 'target', stage: 'mosh_udp',
        status: 'private-status', reason: 'private-reason' });
    }
    const recorded = logs.slice(start).join('\n');
    assert.match(recorded, new RegExp(`source=${origin},`));
    assert.doesNotMatch(recorded, /private/);
    assert.equal(f.events.length, 1);
    assert.equal(f.client.hasActiveSession(), false);
  }
});

test('temporary reachability interruption does not reject input or close the Session', async () => {
  const f = await fixture();
  for (const [status, reason] of [['interrupted', 'no_recent_contact'], ['responsive', '']]) {
    f.session.transport({ kind: 'reachability', layer: 'target', stage: 'mosh_udp', status, reason });
    assert.equal(f.client.isConnected(), true);
  }
  assert.equal(f.client.write('a'), true);
  assert.equal(f.session.disconnects, 0);
  assert.equal(f.events.every(event => event.kind === mosh.MoshClientEvent.REACHABILITY), true);
  close(f.session);
});

test('another Session keeps its input and independent close completion', async () => {
  const a = await fixture(), b = await fixture();
  a.session.rejectWrite = true; a.client.write('a');
  assert.equal(b.client.write('b'), true);
  assert.equal(b.client.isConnected(), true);
  assert.deepEqual(b.session.writes, ['b']);
  let bDone = false;
  b.client.disconnect().then(() => { bDone = true; });
  close(a.session); await flush();
  assert.equal(bDone, false);
  close(b.session); await flush();
  assert.equal(bDone, true);
});

// Load the real caller without constructing unrelated platform services. Only
// the input dispatch method is invoked; unexpected dependency use fails closed.
const callerSource = sourceRoot + 'viewmodel/SessionViewModel.ets';
const callerImports = {};
const parsed = ts.preProcessFile(fs.readFileSync(path.join(root, callerSource), 'utf8'), true);
for (const item of parsed.importedFiles) {
  callerImports[item.fileName] = new Proxy({}, { get(_target, key) {
    throw new Error(`Unmodeled caller dependency: ${item.fileName}.${String(key)}`);
  } });
}
Object.assign(callerImports, {
  '../model/mosh/MoshClient': mosh, '../model/mosh/MoshEscapeParser': escape,
  '../common/types/TerminalTypes': terminalTypes,
});
const { SessionViewModel } = compile(callerSource, callerImports);
test('caller stops the entire parsed frame after rejected remote data', async () => {
  const f = await fixture(); f.session.rejectWrite = true;
  const owner = Object.create(SessionViewModel.prototype);
  owner.moshClient = f.client;
  owner.moshEscapeParser = new escape.MoshEscapeParser();
  owner.writeTerminal = () => { throw new Error('help after rejected input must not execute'); };
  owner.handleConnectedInput('a\x1e?b\r');
  assert.equal(f.session.disconnects, 1);
  assert.deepEqual(f.session.writes, []);
  close(f.session);
});

test('caller presents the input failure after page completion without native details', async () => {
  const owner = Object.create(SessionViewModel.prototype);
  let finishPage;
  const messages = [];
  Object.assign(owner, {
    acceptingSessionOutput: true, moshClient: null, terminalSurface: null,
    clearAuthChallenge() {}, setMode() {}, logger: new logger.Logger(),
    finishMoshTerminalOwnership(callback) { finishPage = callback; },
    writeError(title, guidance) { messages.push(title, guidance); },
  });
  owner.onMoshError(new mosh.MoshError(mosh.MoshErrorCode.INPUT_REJECTED,
    'private native text', 'private input', 'client'));
  assert.equal(messages.length, 0);
  finishPage();
  assert.equal(messages[0], 'Mosh input was not accepted.');
  assert.match(messages[1], /remote state.*reconnecting/);
  assert.doesNotMatch(messages.join(''), /private/);
});

(async () => {
  let failed = 0;
  for (const item of cases) {
    try { await item.run(); console.log(`PASS ${item.name}`); }
    catch (error) { failed++; console.error(`FAIL ${item.name}: ${error.message}`); }
  }
  console.log(`Mosh owner contracts: ${cases.length - failed}/${cases.length}; host-only, not device acceptance`);
  process.exitCode = failed === 0 ? 0 : 1;
})().catch(error => { console.error(error); process.exitCode = 1; });
