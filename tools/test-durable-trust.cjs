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
  const T = Object.fromEntries(['ALIAS', 'SECRET', 'ACCESSIBILITY', 'IS_PERSISTENT', 'REQUIRE_ATTR_ENCRYPTED',
    'DATA_LABEL_CRITICAL_1', 'DATA_LABEL_CRITICAL_2', 'DATA_LABEL_CRITICAL_3', 'DATA_LABEL_CRITICAL_4',
    'RETURN_TYPE', 'RETURN_LIMIT', 'RETURN_OFFSET'].map(v => [v, v]));
  const records = new Map(), calls = [], failures = [], pauses = [];
  const text = v => v instanceof Uint8Array ? F.decodeText(v) : v;
  function assetCall(op, query, update) {
    calls.push({ op, query });
    if (op === 'remove' && [...query.keys()].some(k => k.startsWith('DATA_LABEL_CRITICAL_'))) {
      throw Object.assign(new Error('critical-label filters are not accepted by JS remove'), { code: 401 });
    }
    const failure = failures.findIndex(p => p(op, query));
    if (failure >= 0) { failures.splice(failure, 1); throw new Error('injected Asset failure'); }
    if (op === 'add') { const alias = text(query.get(T.ALIAS)); assert.ok(!records.has(alias)); records.set(alias, new Map(query)); return; }
    const found = [...records].filter(([, r]) => [...query].every(([k, v]) => k.startsWith('RETURN_') || text(r.get(k)) === text(v)));
    if (!found.length) throw Object.assign(new Error('not found'), { code: 2 });
    if (op === 'query') { const offset = query.get(T.RETURN_OFFSET) || 0; return found.slice(offset, offset + (query.get(T.RETURN_LIMIT) || found.length)).map(([, r]) => new Map(r)); }
    if (op === 'update') for (const [, r] of found) for (const [k, v] of update) r.set(k, v);
    if (op === 'remove') for (const [alias] of found) records.delete(alias);
  }
  const asset = { Tag: T, Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, ReturnType: { ALL: 1, ATTRIBUTES: 2 }, ErrorCode: { NOT_FOUND: 2 } };
  for (const op of ['add', 'query', 'update', 'remove']) {
    asset[op + 'Sync'] = (...args) => assetCall(op, ...args);
    asset[op] = async (...args) => assetCall(op, ...args);
  }
  const storeModule = compile('model/persistence/DurableAssetStore.ets', {
    '@kit.AssetStoreKit': { asset }, '@ohos.base': {}, './DurableAssetFormat': assetFormat,
  });
  const files = new Map(), fileCalls = [], fileFailures = [], handles = new Map(); let nextFd = 1;
  async function step(op, path) {
    fileCalls.push({ op, path });
    const failed = fileFailures.findIndex(p => p(op, path));
    if (failed >= 0) { fileFailures.splice(failed, 1); throw new Error('injected file failure'); }
    const paused = pauses.findIndex(p => p.match(op, path));
    if (paused >= 0) { const p = pauses.splice(paused, 1)[0]; await p.gate.promise; }
  }
  const fileIo = {
    OpenMode: { CREATE: 1, TRUNC: 2, WRITE_ONLY: 4, READ_ONLY: 0 },
    async readText(p) { await step('read', p); if (!files.has(p)) throw Object.assign(new Error('missing'), { code: 13900002 }); return files.get(p); },
    async open(p, mode) { await step('open', p); const fd = nextFd++; handles.set(fd, p); if (mode) files.set(p, ''); return { fd }; },
    async write(fd, bytes) { const p = handles.get(fd); await step('write', p); files.set(p, F.decodeText(new Uint8Array(bytes))); return bytes.byteLength; },
    async fsync(fd) { await step('fsync', handles.get(fd)); },
    async close(file) { await step('close', handles.get(file.fd)); handles.delete(file.fd); },
    async rename(a, b) { await step('rename', b); files.set(b, files.get(a)); files.delete(a); },
    async unlink(p) { await step('unlink', p); files.delete(p); },
  };
  const FileUtils = { getSshDir: () => '/fixture/.ssh', ensureDir() {} };
  const knownHostsFile = compile('model/persistence/KnownHostsFile.ets', {
    '@kit.CoreFileKit': { fileIo }, '@ohos.base': {}, '../../common/utils/FileUtils': { FileUtils }, './DurableAssetFormat': format,
  });
  const stateModule = compile('model/persistence/DurableStateManager.ets', {
    '@kit.AbilityKit': {}, '../../common/utils/FileUtils': { FileUtils }, './DurableAssetStore': storeModule,
    './KnownHostsFile': knownHostsFile, './SshConfigCommitPolicy': {}, './KeyPairDeletionPolicy': {},
  });
  const state = stateModule.DurableStateManager, store = new storeModule.DurableAssetStore();
  state.store = store; state.context = {};
  const content = () => files.get('/fixture/.ssh/known_hosts');
  return { state, store, storeModule, asset, T, text, records, calls, failures, pauses, files, fileCalls, fileFailures, fileIo, handles, content,
    seed(value) { store.write('ssh/known-hosts', value); }, restart() { state.knownHostsPrepared = false; } };
}
const A = 'a.invalid ssh-ed25519 AAAA', B = 'b.invalid ssh-ed25519 BBBB';

test('upgrade migrates verified authority over a stale or missing projection before retirement', async () => {
  for (const projected of [undefined, 'stale']) {
    const f = fixture(), content = (A + '\n').repeat(430);
    f.seed(content); if (projected) f.files.set('/fixture/.ssh/known_hosts', projected);
    await f.state.readKnownHosts();
    assert.equal(f.content(), content); assert.equal(f.records.size, 0);
    f.restart(); assert.equal(await f.state.readKnownHosts(), content);
  }
});
test('corrupt or unreadable legacy authority fails closed without retiring it', async () => {
  for (const corrupt of [false, true]) {
    const f = fixture(); f.seed(A);
    if (corrupt) [...f.records.values()].find(r => f.text(r.get(f.T.DATA_LABEL_CRITICAL_2)) === 'chunk').set(f.T.SECRET, F.encodeText('corrupt'));
    else f.failures.push(op => op === 'query');
    await assert.rejects(f.state.commitKnownHostLine({}, B));
    assert.equal(f.content(), undefined); assert.ok(f.records.size > 0);
  }
});
test('migration file failure retains the old authority and safely retries', async () => {
  const f = fixture(); f.seed(A); f.fileFailures.push(op => op === 'rename');
  await assert.rejects(f.state.commitKnownHostLine({}, B));
  assert.equal(f.store.read('ssh/known-hosts'), A);
  assert.equal(f.content(), undefined); await f.state.commitKnownHostLine({}, B);
  assert.equal(f.content(), A + '\n' + B + '\n'); assert.equal(f.records.size, 0);
});
test('retirement failure blocks new trust; retry preserves the migrated file even after pointer removal', async () => {
  for (const pointer of [true, false]) {
    const f = fixture(); f.seed(A);
    f.failures.push((op, q) => op === 'remove' && f.text(q.get(f.T.ALIAS)).startsWith('leantty.v1.p.') === pointer);
    await assert.rejects(f.state.commitKnownHostLine({}, B)); assert.equal(f.content(), A);
    f.restart(); await f.state.commitKnownHostLine({}, B);
    assert.equal(f.content(), A + '\n' + B + '\n'); assert.equal(f.records.size, 0);
  }
});
test('retirement enumeration failure is retried after pointer removal, including all orphan pages', async () => {
  const f = fixture(); f.seed((A + '\n').repeat(2100));
  assert.ok(f.records.size > 40);
  f.failures.push((op, q) => op === 'query' && q.has(f.T.DATA_LABEL_CRITICAL_3));
  await assert.rejects(f.state.readKnownHosts());
  assert.equal(f.store.read('ssh/known-hosts'), null); assert.ok(f.records.size > 40);
  f.restart(); await f.state.readKnownHosts(); assert.equal(f.records.size, 0);
});
test('retirement removes only known-host records, keeping config and keys intact', async () => {
  const f = fixture(); f.seed(A); f.store.write('ssh/config', 'config'); f.store.write('ssh/keypair/test', 'key');
  await f.state.readKnownHosts(); assert.equal(f.store.read('ssh/config'), 'config'); assert.equal(f.store.read('ssh/keypair/test'), 'key');
});
test('steady state uses the file alone and serializes concurrent append/remove', async () => {
  const f = fixture(); await f.state.readKnownHosts(); f.calls.length = 0;
  await Promise.all([f.state.commitKnownHostLine({}, A), f.state.commitKnownHostLine({}, B),
    f.state.updateKnownHosts({}, current => current.replace(A + '\n', ''))]);
  assert.equal(await f.state.readKnownHosts(), B + '\n'); assert.equal(f.calls.length, 0);
});
test('commit does not finish before file and directory synchronization', async () => {
  const f = fixture(), gate = deferred();
  f.pauses.push({ match: (op, p) => op === 'fsync' && p === '/fixture/.ssh', gate });
  let done = false; const commit = f.state.commitKnownHostLine({}, A).then(() => { done = true; });
  await flush(); assert.equal(done, false); gate.resolve(); await commit;
  assert.equal(f.content(), A + '\n'); assert.equal(f.handles.size, 0);
  assert.ok(f.fileCalls.some(c => c.op === 'fsync' && c.path === '/fixture'));
});
test('permission, short write, file sync and rename failures preserve committed trust and recover', async () => {
  for (const stage of ['open', 'short', 'fsync', 'rename']) {
    const f = fixture(); await f.state.commitKnownHostLine({}, A);
    if (stage === 'short') { const original = f.fileIo.write; f.fileIo.write = async (...a) => { f.fileIo.write = original; return (await original(...a)) - 1; }; }
    else f.fileFailures.push((op, p) => op === stage && (stage === 'rename' || p.endsWith('.tmp')));
    await assert.rejects(f.state.commitKnownHostLine({}, B)); assert.equal(f.content(), A + '\n');
    await f.state.commitKnownHostLine({}, B); assert.equal(f.content(), A + '\n' + B + '\n');
    assert.equal(f.handles.size, 0); assert.equal(f.files.has('/fixture/.ssh/known_hosts.tmp'), false);
  }
});
test('directory sync failure is reported even when the approved file replacement is visible', async () => {
  const f = fixture(); f.fileFailures.push((op, p) => op === 'fsync' && p === '/fixture/.ssh');
  await assert.rejects(f.state.commitKnownHostLine({}, A)); assert.equal(await f.state.readKnownHosts(), A + '\n');
  assert.equal(f.handles.size, 0);
});
test('read failure is not treated as empty; no-op removal does not create a file', async () => {
  const f = fixture(); await f.state.updateKnownHosts({}, current => current); assert.equal(f.content(), undefined);
  f.fileFailures.push(op => op === 'read'); await assert.rejects(f.state.commitKnownHostLine({}, A));
  assert.equal(f.content(), undefined);
});
test('deletion survives restart and later reinstall cannot resurrect retired Asset trust', async () => {
  const f = fixture(); f.seed(A); await f.state.updateKnownHosts({}, () => '');
  f.restart(); assert.equal(await f.state.readKnownHosts(), '');
  f.files.clear(); f.restart(); assert.equal(await f.state.readKnownHosts(), ''); assert.equal(f.records.size, 0);
});
test('old pre-Asset files remain the authority when there is no retained asset', async () => {
  const f = fixture(); f.files.set('/fixture/.ssh/known_hosts', A);
  assert.equal(await f.state.readKnownHosts(), A);
});
test('invalid host lines fail before mutation', async () => {
  for (const line of ['', 'missing fields', A + '\n' + B]) {
    const f = fixture(); await assert.rejects(f.state.commitKnownHostLine({}, line)); assert.equal(f.calls.length, 0);
  }
});
test('other Asset writers keep 1024-byte capacity and legacy 768-byte readability', async () => {
  const oldFormat = compile('model/persistence/DurableAssetFormat.ets', {}, value =>
    value.replace(/DURABLE_ASSET_CHUNK_BYTES: number = \d+/, 'DURABLE_ASSET_CHUNK_BYTES: number = 768'));
  const f = fixture(oldFormat), before = 'x'.repeat(4097); f.seed(before);
  const currentModule = compile('model/persistence/DurableAssetStore.ets', { '@kit.AssetStoreKit': { asset: f.asset }, '@ohos.base': {}, './DurableAssetFormat': format });
  const current = new currentModule.DurableAssetStore(); assert.equal(await current.readAsync('ssh/known-hosts'), before);
  current.write('ssh/config', before);
  assert.deepEqual([...f.records.values()].filter(r => f.text(r.get(f.T.DATA_LABEL_CRITICAL_3)) === 'ssh/config' && f.text(r.get(f.T.DATA_LABEL_CRITICAL_2)) === 'chunk').map(r => r.get(f.T.SECRET).length), [1024, 1024, 1024, 1024, 1]);
});
test('real removal and query callers await the same file authority', async () => {
  const f = fixture();
  const module = compile('model/ssh/KnownHostsManager.ets', {
    '@kit.AbilityKit': {}, '../persistence/DurableStateManager': { DurableStateManager: f.state },
    'libleantty_ssh.so': { default: {
      sshRemoveKnownHostEntries(current) { return { removed: current.includes(A) ? 1 : 0, content: current.replace(A + '\n', '') }; },
      sshFindKnownHostEntries(current) { return { found: current.includes(B) ? 1 : 0, output: current }; },
    } },
  });
  const a = f.state.commitKnownHostLine({}, A), b = f.state.commitKnownHostLine({}, B);
  const removed = module.KnownHostsManager.remove({}, 'a.invalid', 22), found = module.KnownHostsManager.find('b.invalid', 22);
  await Promise.all([a, b]); assert.equal((await removed).removed, 1); assert.equal((await found).output, B + '\n');
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
