// Real SshClient owner with a controlled N-API boundary; no device or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../entry/src/main/ets');
function compile(relative, imports) {
  const result = ts.transpileModule(fs.readFileSync(path.join(root, relative), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    fileName: relative.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
  });
  assert.equal((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const exports = {};
  vm.runInNewContext(result.outputText, { exports, Uint8Array, Error, Promise, require(name) {
    assert.ok(name in imports, `Unmodeled import: ${name}`); return imports[name];
  } });
  return exports;
}
const types = compile('common/types/SshTypes.ets', {});
const policy = compile('model/ssh/SshControlEventPolicy.ets', { '../../common/types/SshTypes': types });
const sessions = new Map(), logs = [];
let nextId = 1;
const native = {
  sshConnect(...args) {
    const id = String(nextId++);
    sessions.set(id, { id, generation: args.at(-4), transport: args.at(-3), control: args.at(-2) });
    return id;
  },
  sshDisconnect() {},
};
const { SshClient } = compile('model/ssh/SshClient.ets', {
  '../../common/types/SshTypes': types, './SshControlEventPolicy': policy,
  '../../common/logger/Logger': { Logger: class { info(v) { logs.push(v); } warn(v) { logs.push(v); } error(v) { logs.push(v); } } },
  'libleantty_ssh.so': { default: native },
});
async function fixture(verbose = true) {
  const client = new SshClient(), events = [];
  client.onEvent(e => events.push(e));
  const options = new types.SshConnectOptions(); options.verbose = verbose;
  await client.connect(options);
  return { client, events, session: sessions.get(String(nextId - 1)) };
}
function failure(session, fields = {}) {
  return { kind: 'error', sessionId: session.id, generation: session.generation, layer: 'target',
    stage: 'connect', code: 'network', detail: 'PRIVATE_SENTINEL',
    diagnosticStatus: 'failed', diagnosticReason: 'tcp_refused', ...fields };
}
let checks = 0;
async function test(name, run) { await run(); checks++; process.stdout.write(`PASS ${name}\n`); }
(async () => {
  await test('terminal failure carries its diagnostic before closing without another callback', async () => {
    const f = await fixture();
    f.session.control(failure(f.session));
    assert.deepEqual(f.events.map(e => e.kind), ['DIAGNOSTIC', 'ERROR']);
    assert.equal(f.events[0].diagnostic.reason, 'tcp_refused');
    assert.equal(f.client.hasActiveSession(), false);
    f.session.transport({ kind: 'diagnostic', layer: 'target', stage: 'connect', status: 'failed', reason: 'tcp_refused' });
    assert.equal(f.events.length, 2, 'late transport diagnostic must remain ignored');
  });
  for (const fields of [
    { layer: 'jump' },
    { stage: 'authentication', code: 'auth', diagnosticReason: '' },
    { stage: 'channel', code: 'channel', diagnosticStatus: 'timed_out', diagnosticReason: '' },
  ]) await test(`failure metadata retains ${fields.layer || fields.stage} boundary`, async () => {
    const f = await fixture(); f.session.control(failure(f.session, fields));
    assert.deepEqual(f.events.map(e => e.kind), ['DIAGNOSTIC', 'ERROR']);
    const expected = failure(f.session, fields);
    assert.equal(f.events[0].diagnostic.layer, expected.layer);
    assert.equal(f.events[0].diagnostic.stage, expected.stage);
    assert.equal(f.events[0].diagnostic.status, expected.diagnosticStatus);
  });
  for (const fields of [
    { diagnosticReason: 'PRIVATE_SENTINEL' },
    { diagnosticStatus: 'started' },
    { stage: 'authentication', diagnosticReason: 'tcp_refused' },
  ]) await test(`invalid diagnostic metadata does not hide the error (${JSON.stringify(fields)})`, async () => {
    const f = await fixture(); f.session.control(failure(f.session, fields));
    assert.deepEqual(f.events.map(e => e.kind), ['ERROR']);
    assert.equal(f.client.hasActiveSession(), false);
  });
  await test('normal SSH and errors without diagnostic metadata remain non-verbose', async () => {
    for (const verbose of [false, true]) {
      const f = await fixture(verbose);
      f.session.control(failure(f.session, verbose ? { diagnosticStatus: '', diagnosticReason: '' } : {}));
      assert.deepEqual(f.events.map(e => e.kind), ['ERROR']);
    }
  });
  await test('stale, wrong-session and duplicate failures cannot end the current Session', async () => {
    const f = await fixture();
    f.session.control(failure(f.session, { generation: f.session.generation + 1 }));
    f.session.control(failure(f.session, { sessionId: 'other' }));
    assert.equal(f.events.length, 0); assert.equal(f.client.hasActiveSession(), true);
    f.session.control(failure(f.session)); f.session.control(failure(f.session));
    assert.deepEqual(f.events.map(e => e.kind), ['DIAGNOSTIC', 'ERROR']);
  });
  await test('another Pane and a reconnected Session retain independent callback ownership', async () => {
    const a = await fixture(), b = await fixture();
    a.session.control(failure(a.session));
    assert.equal(b.events.length, 0); assert.equal(b.client.hasActiveSession(), true);
    const options = new types.SshConnectOptions();
    await a.client.connect(options); a.events.length = 0;
    a.session.control(failure(a.session));
    assert.equal(a.events.length, 0); assert.equal(a.client.hasActiveSession(), true);
    const current = sessions.get(String(nextId - 1)); current.control(failure(current));
    assert.deepEqual(a.events.map(e => e.kind), ['ERROR']);
  });
  assert.equal(logs.some(v => v.includes('PRIVATE_SENTINEL')), false);
  process.stdout.write(`SSH owner contracts: ${checks}/${checks}; host-only, no model/device calls\n`);
})().catch(error => { process.stderr.write(String(error.stack || error) + '\n'); process.exitCode = 1; });
