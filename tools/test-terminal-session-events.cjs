// Execute the real native Surface adapter and Session callbacks. Platform services are
// substituted; this does not prove physical keyboard or renderer behavior.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '..', 'entry/src/main/ets');

function compile(relative, overrides = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const imports = Object.fromEntries(ts.preProcessFile(source, true).importedFiles.map(item => [
    item.fileName, new Proxy({}, { get(_target, key) {
      throw new Error(`Unmodeled dependency: ${item.fileName}.${String(key)}`);
    } }),
  ]));
  Object.assign(imports, overrides);
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    fileName: relative.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
  });
  assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const exports = {};
  vm.runInNewContext(result.outputText, {
    exports, require: name => imports[name], Uint8Array, Number, setTimeout, clearTimeout,
    Observed: value => value,
  }, { filename: relative });
  return exports;
}

const types = compile('common/types/TerminalTypes.ets');
const { TerminalMode } = types;
const control = compile('model/ssh/ConnectionControl.ets', {
  '../../common/types/TerminalTypes': types,
});
const logging = { Logger: class { info() {} warn() {} } };
const { TerminalSurfaceController } = compile('model/terminal/TerminalSurfaceController.ets', {
  './NativeTerminalController': { NativeTerminalController: class { setInputMasked() {} detach() {} } },
  '../../common/logger/Logger': logging,
  '@ohos.util': { default: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
});
const { SessionViewModel } = compile('viewmodel/SessionViewModel.ets', {
  '../common/types/TerminalTypes': types, '../model/ssh/ConnectionControl': control,
});

function fixture() {
  const surface = new TerminalSurfaceController();
  const events = [];
  const owner = Object.create(SessionViewModel.prototype);
  Object.assign(owner, {
    mode: TerminalMode.IDLE, terminalResetPending: false, terminalSurface: null,
    logger: new logging.Logger(), lastCols: 80, lastRows: 24,
    completionEngine: { isActive: () => false },
    sshClient: { isConnected: () => true, resize: (c, r) => events.push(['ssh', c, r]) },
    moshClient: null,
    redrawLocalCommandLine: () => events.push(['redraw']),
    beginSshEnvironmentPreparation: () => events.push(['interactive']),
    onTerminalReady: recovered => events.push(['ready', recovered]),
    applyOutputPause: paused => events.push(['pressure', paused]),
  });
  for (const method of ['handleIdleInput', 'handleConnectedInput', 'handlePasswordInput',
    'handleHostKeyInput', 'handleKeyPassphraseInput', 'handleAuthChallengeInput']) {
    owner[method] = data => events.push([method, data]);
  }
  owner.bindTerminalSurface(surface);
  const native = surface.initializeNative(new ArrayBuffer(0), new ArrayBuffer(0));
  const send = (kind, payload = '') => {
    if (kind === 'terminal') native.onInput(payload);
    else if (kind === 'resize') native.onResize(...payload.split(',').map(Number));
  };
  return { owner, surface, native, events, send };
}

let passed = 0;
function test(name, run) { run(); passed++; console.log(`PASS ${name}`); }

test('idle Surface readiness writes one prompt only for fresh output and preserves recovered output', () => {
  const calls = [];
  const owner = Object.create(SessionViewModel.prototype);
  Object.assign(owner, { mode: TerminalMode.IDLE,
    writePrompt: () => calls.push('prompt'), applyTerminalFocus: () => calls.push('focus'),
    logger: { info: text => calls.push(text) } });
  owner.onTerminalReady(false);
  assert.deepEqual(calls, ['prompt', 'focus', 'Terminal ready without recovered output']);
  calls.length = 0;
  owner.onTerminalReady(true);
  assert.deepEqual(calls, ['focus', 'Terminal ready, terminal output recovered']);
});

test('native session reset positions output before writing and completes after consumption', () => {
  const surface=new TerminalSurfaceController(), calls=[];
  let positioned, consumed;
  surface.native={
    write(bytes,owner) { calls.push(['reset',new TextDecoder().decode(bytes),owner]); },
    positionSessionOutput(done) { calls.push(['position']); positioned=done; },
    barrier(done) { calls.push(['barrier']); consumed=done; },
  };
  surface.resetSessionState(()=>calls.push(['local']),()=>calls.push(['done']));
  assert.ok(calls[0][1].endsWith('\x1b[999;1H')); assert.equal(calls[0][2],0);
  assert.deepEqual(calls.slice(1),[['position']]);
  positioned(); assert.deepEqual(calls.slice(1),[['position'],['local'],['barrier']]);
  consumed(); assert.deepEqual(calls.at(-1),['done']);
});

for (const ending of ['close', 'error']) {
  test(`SSH ${ending} ends remote cursor ownership before local output and rejects late bytes`, () => {
    const f = fixture(), writes = [];
    let positioned, consumed;
    Object.assign(f.owner, {
      mode: TerminalMode.CONNECTED, acceptingSessionOutput: true,
      terminalBoundaryGeneration: 10, terminalResetWaiters: [], pendingKeypush: false,
      clearAuthChallenge() {}, setMode(mode) { this.mode = mode; },
      writePrompt() { this.writeTerminal('local-prompt'); },
      writeError() { this.writeTerminal('local-error'); },
    });
    f.surface.native = {
      write(bytes, owner) { writes.push([new TextDecoder().decode(bytes), owner]); },
      positionSessionOutput(done) { positioned = done; },
      barrier(done) { consumed = done; },
    };
    const remote = new TextEncoder().encode('\x1b[2 q');
    f.owner.onSessionData(remote);
    assert.deepEqual(writes, [['\x1b[2 q', 10]]);
    assert.equal(f.surface.acceptsRemoteEffect(10), true);
    if (ending === 'close') f.owner.onSshClose(0);
    else f.owner.onSshError({layer:'target', detail:'public fixture transport failure'});
    assert.equal(f.owner.terminalBoundaryGeneration, 11);
    assert.equal(f.owner.terminalResetPending, true);
    assert.equal(f.surface.acceptsRemoteEffect(10), false);
    assert.equal(writes.length, 2);
    assert.ok(writes[1][0].includes('\x1b[5 q'));
    assert.equal(writes[1][1], 0);
    f.owner.onSessionData(remote);
    assert.equal(writes.length, 2, 'late remote style cannot follow reset');
    positioned();
    assert.match(writes.at(-1)[0], /^local-/);
    assert.equal(f.owner.terminalResetPending, true);
    consumed();
    assert.equal(f.owner.terminalResetPending, false);
    f.owner.onSessionData(remote);
    assert.match(writes.at(-1)[0], /^local-/, 'closed owner cannot repaint cursor');
  });
}

test('terminal input keeps local, authentication and connected Session ownership', () => {
  const f = fixture();
  const cases = [
    [TerminalMode.IDLE, 'handleIdleInput'], [TerminalMode.CONNECTED, 'handleConnectedInput'],
    [TerminalMode.PASSWORD_INPUT, 'handlePasswordInput'], [TerminalMode.HOST_KEY_INPUT, 'handleHostKeyInput'],
    [TerminalMode.KEY_PASSPHRASE_INPUT, 'handleKeyPassphraseInput'],
    [TerminalMode.AUTH_CHALLENGE_INPUT, 'handleAuthChallengeInput'],
  ];
  for (const [mode, method] of cases) {
    f.owner.mode = mode;
    f.send('terminal', 'public-fixture\u001b[D', 'DATA');
    assert.deepEqual(f.events.pop(), [method, 'public-fixture\u001b[D']);
  }
  f.owner.terminalResetPending = true;
  f.send('terminal', 'must-not-arrive', 'DATA');
  assert.deepEqual(f.events, []);
});

test('resize preserves SSH, Mosh priority and idle completion redraw', () => {
  const f = fixture();
  f.send('resize', '120,40');
  assert.deepEqual(f.events, [['ssh', 120, 40]]);
  assert.deepEqual([f.owner.lastCols, f.owner.lastRows], [120, 40]);
  f.owner.moshClient = { isConnected: () => true, resize: (c, r) => f.events.push(['mosh', c, r]) };
  f.owner.completionEngine.isActive = () => true;
  f.send('resize', '90,30');
  assert.deepEqual(f.events.slice(1), [['redraw'], ['mosh', 90, 30]]);

});


test('display ready and interactive ready remain distinct from pressure', () => {
  const f = fixture();
  f.native.onReady(true);
  f.native.onPressure(true);
  assert.deepEqual(f.events, [['interactive'], ['ready', true], ['pressure', true]]);
});


test('two Panes deliver only to their own Session', () => {
  const a = fixture(), b = fixture();
  a.send('terminal', 'a', 'DATA'); b.send('terminal', 'b', 'DATA');
  b.send('resize', '120,40');
  assert.deepEqual(a.events, [['handleIdleInput', 'a']]);
  assert.deepEqual(b.events, [['handleIdleInput', 'b'], ['ssh', 120, 40]]);
});

test('Mosh first frame before connected notification starts native page before writing', () => {
  const surface = new TerminalSurfaceController(), calls = [], completions = [];
  surface.native = {
    page: begin => calls.push(['page', begin]),
    write: (bytes, owner) => calls.push(['write', Array.from(bytes), owner]),
    barrier: done => completions.push(done),
  };
  // The protocol may publish its initial clear-screen frame before onConnected.
  surface.writeMoshBytes(new Uint8Array([27,99]),17);
  surface.beginMoshSessionPage();
  assert.deepEqual(calls, [['page',true],['write',[27,99],17]]);
  surface.endMoshSessionPage(() => calls.push(['local']), () => calls.push(['ready']));
  assert.deepEqual(calls.at(-1), ['page',false]);
  completions.shift()(); assert.deepEqual(calls.at(-1), ['local']);
  completions.shift()(); assert.deepEqual(calls.at(-1), ['ready']);
  surface.writeMoshBytes(new Uint8Array([65]),18);
  assert.deepEqual(calls.slice(-2), [['page',true],['write',[65],18]]);
});

console.log(`Terminal Session event contracts: ${passed} passed.`);
