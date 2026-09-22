// Runs the real persistence/Session owners with a controllable Asset Store boundary.
// Host evidence only: platform scheduling and visible feedback require the ARM64 PC.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '..');
const src = 'entry/src/main/ets/';
function compile(relative, imports, transform = value => value) {
  const result = ts.transpileModule(transform(fs.readFileSync(path.join(root, src, relative), 'utf8')), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    fileName: relative.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
  });
  assert.equal((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const exports = {};
  vm.runInNewContext(result.outputText, { exports, require(name) {
    assert.ok(name in imports, `Unmodeled import: ${name}`); return imports[name];
  }, Uint8Array, Promise, Error, Map, Date, setTimeout, clearTimeout, Observed: v => v });
  return exports;
}
function emptyImports(relative) {
  const imports = {};
  for (const item of ts.preProcessFile(fs.readFileSync(path.join(root, src, relative), 'utf8'), true).importedFiles) {
    imports[item.fileName] = {};
  }
  return imports;
}
const format = compile('model/persistence/DurableAssetFormat.ets', {});
const F = format.DurableAssetFormat;
const logger = { Logger: class { info() {} warn() {} error() {} } };
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function flush() { for (let i = 0; i < 80; i++) await Promise.resolve(); }
const cases = [];
function test(name, run) { cases.push({ name, run }); }
function fixture(assetFormat = format) {
  const tags = ['ALIAS', 'SECRET', 'ACCESSIBILITY', 'IS_PERSISTENT', 'REQUIRE_ATTR_ENCRYPTED',
    'DATA_LABEL_CRITICAL_1', 'DATA_LABEL_CRITICAL_2', 'DATA_LABEL_CRITICAL_3', 'DATA_LABEL_CRITICAL_4',
    'RETURN_TYPE', 'RETURN_LIMIT', 'RETURN_OFFSET'];
  const T = Object.fromEntries(tags.map(v => [v, v]));
  const records = new Map(), calls = [], failures = [], pauses = [];
  const text = v => v instanceof Uint8Array ? F.decodeText(v) : v;
  const missing = () => Object.assign(new Error('not found'), { code: 2 });
  function matches(record, query) {
    return [...query].every(([k, v]) => k.startsWith('RETURN_') || text(record.get(k)) === text(v));
  }
  async function call(op, query, update) {
    calls.push({ op, query: new Map(query) });
    const fail = failures.findIndex(p => p(op, query));
    if (fail >= 0) { failures.splice(fail, 1); throw new Error('injected storage failure'); }
    const pause = pauses.findIndex(p => p.match(op, query));
    if (pause >= 0) { const p = pauses.splice(pause, 1)[0]; await p.gate.promise; }
    if (op === 'add') { const alias = text(query.get(T.ALIAS)); assert.ok(!records.has(alias)); records.set(alias, new Map(query)); return; }
    const found = [...records].filter(([, r]) => matches(r, query));
    if (!found.length) throw missing();
    if (op === 'query') return found.map(([, r]) => new Map(r));
    if (op === 'update') { for (const [, r] of found) for (const [k, v] of update) r.set(k, v); return; }
    if (op === 'remove') for (const [alias] of found) records.delete(alias);
  }
  const asset = { Tag: T, Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, ReturnType: { ALL: 1, ATTRIBUTES: 2 }, ErrorCode: { NOT_FOUND: 2 } };
  for (const op of ['add', 'query', 'update', 'remove']) {
    asset[op] = (...args) => call(op, ...args);
    asset[op + 'Sync'] = () => { throw new Error('synchronous Asset Store call on the UI path'); };
  }
  const storeModule = compile('model/persistence/DurableAssetStore.ets', {
    '@kit.AssetStoreKit': { asset }, '@ohos.base': {}, './DurableAssetFormat': assetFormat,
    '../../common/logger/Logger': logger,
  });
  const projections = new Map(); let projectionFailure = false;
  const FileUtils = {
    getSshDir: () => '/fixture/.ssh',
    writeTextFile(p, value) { if (projectionFailure) throw new Error('projection failed'); projections.set(p, value); },
  };
  const stateModule = compile('model/persistence/DurableStateManager.ets', {
    '@kit.AbilityKit': {}, '../../common/utils/FileUtils': { FileUtils }, './DurableAssetStore': storeModule,
    './SshConfigCommitPolicy': {}, './KeyPairDeletionPolicy': {},
  });
  const state = stateModule.DurableStateManager, store = new storeModule.DurableAssetStore();
  state.store = store; state.context = {};
  const content = () => projections.get('/fixture/.ssh/known_hosts');
  return { state, store, storeModule, asset, T, text, records, calls, failures, pauses, content, projections,
    failProjection() { projectionFailure = true; }, restoreProjection() { projectionFailure = false; } };
}
const A = 'a.invalid ssh-ed25519 AAAA', B = 'b.invalid ssh-ed25519 BBBB';

test('trust commit yields to the event loop and publishes only after durable commit', async () => {
  const f = fixture(), gate = deferred();
  f.pauses.push({ match: (op, q) => op === 'add' && f.text(q.get(f.T.DATA_LABEL_CRITICAL_2)) === 'chunk', gate });
  let done = false;
  const commit = f.state.commitKnownHostLine({}, A).then(() => { done = true; });
  await flush(); assert.equal(done, false); assert.equal(f.content(), undefined);
  gate.resolve(); await commit; assert.equal(f.content(), A + '\n');
  assert.equal(await f.state.readKnownHosts(), A + '\n');
});
test('concurrent appends and removal read the latest committed authority', async () => {
  const f = fixture();
  await Promise.all([f.state.commitKnownHostLine({}, A), f.state.commitKnownHostLine({}, B),
    f.state.updateKnownHosts({}, current => current.replace(A + '\n', ''))]);
  assert.equal(f.content(), B + '\n'); assert.equal(await f.state.readKnownHosts(), B + '\n');
});
test('no-op removal does not create or rewrite authority', async () => {
  const f = fixture(); await f.state.updateKnownHosts({}, current => current);
  assert.equal(f.calls.some(c => c.op !== 'query'), false); assert.equal(f.content(), undefined);
});
test('failed chunk or pointer commit retains the previous generation and the queue remains usable', async () => {
  for (const stage of ['add', 'update']) {
    const f = fixture(); await f.state.commitKnownHostLine({}, A); await flush();
    f.failures.push(op => op === stage);
    await assert.rejects(f.state.commitKnownHostLine({}, B));
    assert.equal(await f.state.readKnownHosts(), A + '\n'); assert.equal(f.content(), A + '\n');
    await f.state.commitKnownHostLine({}, B); assert.equal(f.content(), A + '\n' + B + '\n');
  }
});
test('read-back corruption never publishes a new pointer', async () => {
  const f = fixture(); await f.state.commitKnownHostLine({}, A); await flush();
  const gate = deferred();
  f.pauses.push({ match: (op, q) => op === 'query' && f.text(q.get(f.T.ALIAS))?.startsWith('leantty.v1.c.') &&
    [...f.records.values()].filter(r => f.text(r.get(f.T.DATA_LABEL_CRITICAL_2)) === 'chunk').length > 1, gate });
  const commit = f.state.commitKnownHostLine({}, B); await flush();
  const latest = [...f.records.values()].filter(r => f.text(r.get(f.T.DATA_LABEL_CRITICAL_2)) === 'chunk').at(-1);
  latest.set(f.T.SECRET, F.encodeText('corrupt')); gate.resolve();
  await assert.rejects(commit); assert.equal(await f.state.readKnownHosts(), A + '\n');
});
test('projection failure reports failure, retains committed authority and can be recovered', async () => {
  const f = fixture(); f.failProjection(); await assert.rejects(f.state.commitKnownHostLine({}, A));
  assert.equal(f.content(), undefined); assert.equal(await f.state.readKnownHosts(), A + '\n');
  f.restoreProjection(); await f.state.commitKnownHostLine({}, B);
  assert.equal(f.content(), A + '\n' + B + '\n');
});
test('slow old-generation cleanup does not delay success or delete later commits', async () => {
  const f = fixture(); await f.state.commitKnownHostLine({}, A); await flush();
  const gate = deferred(); f.pauses.push({ match: op => op === 'remove', gate });
  await f.state.commitKnownHostLine({}, B);
  await f.state.updateKnownHosts({}, current => current.replace(A + '\n', ''));
  gate.resolve(); await flush();
  assert.equal(await f.state.readKnownHosts(), B + '\n');
  assert.equal(f.content(), B + '\n');
  for (const c of f.calls.filter(c => c.op === 'remove')) {
    assert.equal(f.text(c.query.get(f.T.DATA_LABEL_CRITICAL_3)), 'ssh/known-hosts');
    assert.equal(f.text(c.query.get(f.T.DATA_LABEL_CRITICAL_2)), 'chunk');
    assert.ok(f.text(c.query.get(f.T.DATA_LABEL_CRITICAL_4)));
  }
});
test('cleanup failure cannot turn committed trust into failure or affect another asset', async () => {
  const f = fixture(); await f.store.writeAsync('ssh/config', 'Host fixture');
  await f.state.commitKnownHostLine({}, A); f.failures.push(op => op === 'remove');
  await f.state.commitKnownHostLine({}, B); await flush();
  assert.equal(await f.store.readAsync('ssh/config'), 'Host fixture');
  assert.equal(await f.state.readKnownHosts(), A + '\n' + B + '\n');
});
test('background GC waits until the in-flight generation is committed', async () => {
  const f = fixture(), gate = deferred(); let collected = false;
  f.pauses.push({ match: op => op === 'add', gate });
  const commit = f.state.commitKnownHostLine({}, A); await flush();
  f.store.garbageCollect = () => { collected = true; assert.equal(f.content(), A + '\n'); };
  const gc = f.state.collectGarbageOnce(); await flush(); assert.equal(collected, false);
  gate.resolve(); await Promise.all([commit, gc]); assert.equal(collected, true);
});
test('invalid host lines fail before mutation', async () => {
  for (const line of ['', 'missing fields', A + '\n' + B]) {
    const f = fixture(); await assert.rejects(async () => f.state.commitKnownHostLine({}, line));
    assert.equal(f.calls.length, 0);
  }
});
test('large multi-chunk authority is readable by a fresh store after restart', async () => {
  const f = fixture(), content = (A + '\n').repeat(660);
  await f.state.updateKnownHosts({}, () => content);
  const restarted = new f.storeModule.DurableAssetStore();
  assert.equal(await restarted.readAsync('ssh/known-hosts'), content);
  assert.ok(f.calls.filter(c => c.op === 'add').length > 15);
});
test('writes use the supported 1024-byte capacity without extra Asset operations', async () => {
  const f = fixture(), content = 'x'.repeat(4097);
  await f.state.updateKnownHosts({}, () => content);
  const chunks = [...f.records.values()].filter(r => f.text(r.get(f.T.DATA_LABEL_CRITICAL_2)) === 'chunk');
  assert.equal(chunks.length, 5);
  assert.deepEqual(chunks.map(r => r.get(f.T.SECRET).length), [1024, 1024, 1024, 1024, 1]);
  assert.equal(await f.state.readKnownHosts(), content);
});
test('existing 768-byte generations and new 1024-byte generations use the same reader contract', async () => {
  const oldFormat = compile('model/persistence/DurableAssetFormat.ets', {}, value =>
    value.replace(/DURABLE_ASSET_CHUNK_BYTES: number = \d+/, 'DURABLE_ASSET_CHUNK_BYTES: number = 768'));
  const f = fixture(oldFormat), before = (A + '\n').repeat(100), after = before + B + '\n';
  f.store.generationSequence = 100;
  await f.state.updateKnownHosts({}, () => before);
  const currentModule = compile('model/persistence/DurableAssetStore.ets', {
    '@kit.AssetStoreKit': { asset: f.asset }, '@ohos.base': {}, './DurableAssetFormat': format,
    '../../common/logger/Logger': logger,
  });
  const current = new currentModule.DurableAssetStore();
  assert.equal(await current.readAsync('ssh/known-hosts'), before);
  await current.writeAsync('ssh/known-hosts', after);
  assert.equal(await new f.storeModule.DurableAssetStore().readAsync('ssh/known-hosts'), after);
  assert.equal(await new currentModule.DurableAssetStore().readAsync('ssh/known-hosts'), after);
});
test('real removal and query callers wait on serialized trust and preserve other endpoints', async () => {
  const f = fixture();
  const module = compile('model/ssh/KnownHostsManager.ets', {
    '@kit.AbilityKit': {}, '../persistence/DurableStateManager': { DurableStateManager: f.state },
    'libleantty_ssh.so': { default: {
      // Native matching semantics remain covered in Rust; this stub checks the
      // callers' authoritative input and ordering, not hashed-host matching.
      sshRemoveKnownHostEntries(current, host, port) {
        assert.equal(host, 'a.invalid'); assert.equal(port, 22);
        return { removed: current.includes(A) ? 1 : 0, content: current.replace(A + '\n', '') };
      },
      sshFindKnownHostEntries(current) { return { found: current.includes(B) ? 1 : 0, output: current }; },
    } },
  });
  const a = f.state.commitKnownHostLine({}, A), b = f.state.commitKnownHostLine({}, B);
  const removed = module.KnownHostsManager.remove({}, 'a.invalid', 22);
  const found = module.KnownHostsManager.find('b.invalid', 22);
  await Promise.all([a, b]); assert.equal((await removed).removed, 1);
  assert.equal((await found).output, B + '\n'); assert.equal(f.content(), B + '\n');
});

const keyKinds = { HOST_KEY_REMOVE: 'remove', HOST_KEY_FIND: 'find' };
const commandOutput = { status: (a, b) => a + ': ' + b, success: v => v, prompt: () => 'ltty>' };
function keyService(manager) {
  const source = 'model/command/KeyCommandService.ets', imports = emptyImports(source);
  Object.assign(imports, { '../ssh/KnownHostsManager': { KnownHostsManager: manager },
    './CommandParser': { KeyCommandKind: keyKinds }, '../../common/logger/Logger': logger,
    '../terminal/LocalCommandOutput': { LocalCommandOutput: commandOutput },
    '../../common/security/TerminalTextPolicy': compile('common/security/TerminalTextPolicy.ets', {}),
  });
  return compile(source, imports).KeyCommandService;
}
test('remove command shows pending feedback but no success or prompt before commit', async () => {
  const gate = deferred(), output = [], service = keyService({ remove: () => gate.promise });
  const result = service.execute({ kind: 'remove', errorMessage: '', sshHost: 'a.invalid', sshPort: 22 },
    { context: {}, writeOutput: v => output.push(v), writeError: () => assert.fail('unexpected failure') });
  await flush(); assert.match(output.join(''), /Updating/); assert.doesNotMatch(output.join(''), /Removed|ltty>/);
  gate.resolve({ removed: 1, target: 'a.invalid' }); await result;
  assert.match(output.join(''), /Removed 1 host key entry/); assert.match(output.join(''), /ltty>/);
});

const terminalTypes = compile('common/types/TerminalTypes.ets', {});
function sessionFixture(protocol = 'ssh') {
  const gate = deferred(), output = [], answers = [], idleInputs = [];
  const source = 'viewmodel/SessionViewModel.ets';
  const imports = emptyImports(source);
  Object.assign(imports, {
    '../common/types/TerminalTypes': terminalTypes,
    '../model/terminal/TerminalInputParser': { TerminalInputParser: { parse(data) {
      idleInputs.push(data); return [];
    } } },
    '../model/ssh/ConnectionControl': compile('model/ssh/ConnectionControl.ets', {
      '../../common/types/TerminalTypes': terminalTypes,
    }),
    '../model/persistence/DurableStateManager': { DurableStateManager: { commitKnownHostLine: () => gate.promise } },
    '../model/terminal/LocalCommandOutput': { LocalCommandOutput: commandOutput },
    '../model/mosh/MoshClient': { MoshError: class {}, MoshErrorCode: { INTERNAL: 'internal' } },
    '../model/command/CommandParser': { KeyCommandKind: keyKinds },
    '../model/command/KeyCommandService': { KeyCommandService: { execute: async (_result, ctx) => {
      ctx.writeOutput('Updating'); await gate.promise; ctx.writeOutput('Removed');
    } } },
  });
  const { SessionViewModel } = compile(source, imports), owner = Object.create(SessionViewModel.prototype);
  const client = { getPendingKnownHostLine: () => A, verifyHostKey: value => { answers.push(value); return true; }, cancel() {} };
  Object.assign(owner, { mode: terminalTypes.TerminalMode.HOST_KEY_INPUT, hostKeyBuffer: 'yes', context: {},
    hostKeyDecisionGeneration: 0, terminalBoundaryGeneration: 0, terminalSurface: null,
    sshClient: client, moshClient: protocol === 'mosh' ? client : null, transferCancellationRequested: false,
    completionEngine: { finishEditing() {} }, completionRenderer: { reset() {} },
    sshEscapeParser: { reset() {} }, moshEscapeParser: { reset() {} },
    onModeChange: null, notifyTitleChange() {}, notifyStateChange() {},
    activeFileTransferClient: () => protocol === 'transfer' ? client : null,
    session: { resumeConnection() {}, markFailed() {} },
    writeTerminal: v => output.push(v), onInternalSessionError: () => output.push('failed'),
    onMoshError: () => output.push('failed'),
    writeError: v => output.push(v), commandBarVm: { getSshConfig() { return {}; } },
  });
  return { owner, gate, answers, output, idleInputs };
}
test('closing a Pane revokes the trust decision before native disconnect finishes', async () => {
  const f = sessionFixture(), close = deferred();
  f.owner.transferLifecycle = { isActive: () => false };
  f.owner.sshClient.hasActiveSession = () => true;
  f.owner.sshClient.disconnect = () => close.promise;
  Object.assign(f.owner, { clearAuthChallenge() {}, clearKeyPassphraseChangeState() {}, clearKeyCommentChangeState() {},
    releaseDisconnectedFlowControl() {}, session: { markDisconnected() {} }, logger: new logger.Logger(),
  });
  const trust = f.owner.submitHostKeyDecision(), closing = f.owner.disconnect();
  f.gate.resolve(); await trust; assert.deepEqual(f.answers, []);
  close.resolve(); await closing;
});
test('pending trust in two Panes has independent cancellation and output', async () => {
  const a = sessionFixture(), b = sessionFixture('mosh');
  const first = a.owner.submitHostKeyDecision(), second = b.owner.submitHostKeyDecision();
  a.owner.setMode(terminalTypes.TerminalMode.IDLE);
  b.gate.resolve(); await second; assert.deepEqual(b.answers, [true]); assert.deepEqual(a.answers, []);
  a.gate.resolve(); await first; assert.deepEqual(a.answers, []);
});
test('real Ctrl-C dispatch cancels promptly while persistence is suspended', async () => {
  const f = sessionFixture(); let disconnected = false;
  Object.assign(f.owner, { transferLifecycle: { isActive: () => false }, clearAuthChallenge() {},
    clearKeypushState() {}, session: { markDisconnected() {} }, writePrompt() {},
    finishSessionTerminalOwnership(callback) { callback(); },
  });
  f.owner.sshClient.disconnect = () => { disconnected = true; return Promise.resolve(); };
  const commit = f.owner.submitHostKeyDecision(); f.owner.handleTerminalInput('\x03');
  assert.equal(disconnected, true); assert.equal(f.owner.mode, terminalTypes.TerminalMode.IDLE);
  f.gate.resolve(); await commit; assert.deepEqual(f.answers, []);
});
test('closed local command cannot write success into a replacement page', async () => {
  const f = sessionFixture(); f.owner.mode = terminalTypes.TerminalMode.IDLE;
  const operation = f.owner.executeKeyCommand({ kind: 'remove' });
  assert.equal(f.owner.knownHostsCommandPending, true);
  f.owner.handleIdleInput('must not be parsed while pending');
  f.owner.terminalBoundaryGeneration++;
  f.gate.resolve(); await operation;
  assert.deepEqual(f.output, ['Updating']); assert.equal(f.owner.knownHostsCommandPending, false);
});
test('idle Ctrl-C reaches the parser only after asynchronous known-host command completion', async () => {
  const f = sessionFixture(); f.owner.mode = terminalTypes.TerminalMode.IDLE;
  const operation = f.owner.executeKeyCommand({ kind: 'remove' });
  f.owner.handleIdleInput('\x03');
  assert.equal(f.owner.knownHostsCommandPending, true);
  assert.deepEqual(f.idleInputs, []);
  f.gate.resolve(); await operation;
  f.owner.handleIdleInput('\x03');
  assert.equal(f.owner.knownHostsCommandPending, false);
  assert.deepEqual(f.idleInputs, ['\x03']);
});
for (const protocol of ['ssh', 'mosh', 'transfer']) {
  test(`${protocol} waits for durable trust, provides pending feedback and ignores duplicate Enter`, async () => {
    const f = sessionFixture(protocol); const result = f.owner.submitHostKeyDecision();
    assert.deepEqual(f.answers, []); assert.match(f.output.join(''), /Saving/);
    f.owner.hostKeyBuffer = 'yes'; await f.owner.submitHostKeyDecision();
    assert.deepEqual(f.answers, []); f.gate.resolve(); await result;
    assert.deepEqual(f.answers, [true]);
  });
  for (const rejected of [false, true]) {
    test(`${protocol} late ${rejected ? 'failure' : 'success'} after cancellation cannot answer a new prompt`, async () => {
      const f = sessionFixture(protocol), result = f.owner.submitHostKeyDecision();
      // The real mode transitions invalidate the pending operation, including ABA.
      f.owner.setMode(terminalTypes.TerminalMode.IDLE);
      f.owner.setMode(terminalTypes.TerminalMode.HOST_KEY_INPUT);
      const before = f.output.length;
      if (rejected) f.gate.reject(new Error('late private error')); else f.gate.resolve();
      await result; assert.deepEqual(f.answers, []); assert.equal(f.output.length, before);
    });
  }
  test(`${protocol} commit failure never accepts trust`, async () => {
    const f = sessionFixture(protocol), result = f.owner.submitHostKeyDecision();
    f.gate.reject(new Error('private storage detail')); await result;
    assert.deepEqual(f.answers, [false]); assert.doesNotMatch(f.output.join(''), /private storage/);
  });
}

(async () => {
  let failed = 0;
  for (const { name, run } of cases) {
    let deadline;
    try {
      await Promise.race([run(), new Promise((_resolve, reject) => {
        deadline = setTimeout(() => reject(new Error('Contract did not settle within 5 seconds')), 5000);
      })]);
      console.log('PASS ' + name);
    }
    catch (e) { failed++; console.error('FAIL ' + name + '\n' + e.stack); }
    finally { clearTimeout(deadline); }
  }
  console.log(`Durable trust contracts: ${cases.length - failed}/${cases.length} passed`);
  if (failed) process.exitCode = 1;
})();
