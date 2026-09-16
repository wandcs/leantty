// Actual injected Session owner with a controlled async boundary; no platform IO.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const mode = process.argv[3];
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/viewmodel/SessionViewModel.ets'), 'utf8',
);

if (mode === 'production') {
  assert.doesNotMatch(
    source,
    /ACCEPTANCE_COMMAND_OWNER|ACCEPTANCE_KNOWN_HOST_COMPLETE|acceptanceCommandFailed|acceptanceCommandReturned/,
  );
  console.log('Known-host completion: production source excludes instrumentation.');
  process.exit(0);
}

function fixture(enabled = true, behaviour = 'success', pane = 'pane-a') {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const events = [];
  const thrownFailure = new Error('fixture throw');
  const imports = Object.fromEntries(
    ts.preProcessFile(source, true).importedFiles.map(item => [item.fileName, {}]),
  );
  imports.BuildProfile = { ACCEPTANCE_TESTS: enabled };
  imports['../common/types/TerminalTypes'] = { TerminalMode: { IDLE: 0 } };

  const policySource = fs.readFileSync(
    path.join(root, 'entry/src/main/ets/common/security/TerminalTextPolicy.ets'), 'utf8',
  );
  const policyOutput = ts.transpileModule(policySource, {
    compilerOptions: { module: ts.ModuleKind.CommonJS },
  });
  const policy = {};
  vm.runInNewContext(policyOutput.outputText, { exports: policy });
  imports['../common/security/TerminalTextPolicy'] = policy;
  imports['../model/command/CommandParser'] = {
    KeyCommandKind: { HOST_KEY_REMOVE: 'remove', HOST_KEY_FIND: 'find' },
  };
  imports['../model/command/KeyCommandService'] = {
    KeyCommandService: {
      async execute(result, ctx) {
        await gate;
        if (behaviour === 'handled-error') ctx.writeError('fixture failure');
        if (behaviour === 'throw') throw thrownFailure;
      },
    },
  };

  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    fileName: 'SessionViewModel.ts',
    reportDiagnostics: true,
  });
  assert.equal(
    output.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length,
    0,
  );
  const exports = {};
  vm.runInNewContext(output.outputText, {
    exports,
    require: name => imports[name],
    Observed: value => value,
    Map, Set, Date, Promise, setTimeout, clearTimeout,
  });

  const owner = Object.create(exports.SessionViewModel.prototype);
  Object.assign(owner, {
    context: {},
    paneId: pane,
    terminalBoundaryGeneration: 4,
    acceptanceInputSequence: 0,
    commandLine: { getText: () => 'ssh-keygen -R [192.0.2.1]:32123' },
    commandBarVm: { getSshConfig: () => ({}) },
    writeError() {},
    writeTerminal() {},
    logger: {
      info(message) {
        if (message.startsWith('ACCEPTANCE_KNOWN_HOST_COMPLETE')) {
          assert.equal(owner.knownHostsCommandPending, false);
        }
        events.push(message);
      },
    },
  });
  return { owner, release, events, thrownFailure };
}

(async () => {
  let count = 0;
  for (const behaviour of [
    'success', 'handled-error', 'throw', 'cancelled', 'closed', 'disposed', 'disabled',
  ]) {
    const f = fixture(behaviour !== 'disabled', behaviour);
    f.owner.logAcceptanceInputSubmit('command');
    const operation = f.owner.executeKeyCommand({ kind: 'remove' });
    assert.equal(f.owner.knownHostsCommandPending, true);
    assert.equal(f.events.filter(event => event.includes('KNOWN_HOST_COMPLETE')).length, 0);

    if (behaviour === 'cancelled') f.owner.terminalBoundaryGeneration++;
    if (behaviour === 'closed' || behaviour === 'disposed') {
      Object.assign(f.owner, {
        hostKeyDecisionGeneration: 0,
        transferLifecycle: { isActive: () => false },
        moshClient: null,
        sshClient: { hasActiveSession: () => false },
        session: { markDisconnected() {} },
        clearAuthChallenge() {},
        keyPassphraseChangeStage: 0,
        keyCommentChangeStage: 0,
        clearKeyPassphraseChangeState() {},
        clearKeyCommentChangeState() {},
        setMode() {},
        terminalSurface: null,
        notifyStateChange() {},
      });
      if (behaviour === 'disposed') {
        const paneSource = fs.readFileSync(
          path.join(root, 'entry/src/main/ets/viewmodel/PaneRuntime.ets'), 'utf8',
        );
        const paneOutput = ts.transpileModule(paneSource, {
          compilerOptions: { module: ts.ModuleKind.CommonJS },
        });
        const paneExports = {};
        vm.runInNewContext(paneOutput.outputText, {
          exports: paneExports,
          require: name => name.includes('Logger') ? { Logger: class { warn() {} } } : {},
          Observed: value => value,
        });
        const pane = Object.create(paneExports.PaneRuntime.prototype);
        Object.assign(pane, {
          disposed: false,
          viewModel: f.owner,
          detachSurface() { this.detached = true; },
        });
        await pane.dispose();
        assert.equal(pane.isDisposed(), true);
        assert.equal(pane.detached, true);
      } else {
        await f.owner.disconnect();
      }
      assert.equal(f.owner.terminalBoundaryGeneration, 5);
    }

    f.release();
    if (behaviour === 'throw') {
      await assert.rejects(operation, error => error === f.thrownFailure);
    } else {
      await operation;
    }
    assert.equal(f.owner.knownHostsCommandPending, false);
    if (behaviour === 'disabled') {
      assert.deepEqual(f.events, []);
    } else {
      assert.match(
        f.events[0],
        /^ACCEPTANCE_COMMAND_OWNER pane=pane-a,generation=4 ACCEPTANCE_INPUT_SUBMIT sequence=1,kind=command,input=/,
      );
      const result = (
        behaviour === 'cancelled' || behaviour === 'closed' || behaviour === 'disposed'
      ) ? 'cancelled' : (behaviour === 'success' ? 'completed' : 'failed');
      assert.equal(
        f.events[1],
        'ACCEPTANCE_KNOWN_HOST_COMPLETE pane=pane-a,generation=4,sequence=1,result=' + result,
      );
    }
    count++;
  }

  const a = fixture(true, 'success', 'pane-a');
  const b = fixture(true, 'success', 'pane-b');
  a.owner.logAcceptanceInputSubmit('command');
  b.owner.logAcceptanceInputSubmit('command');
  const ap = a.owner.executeKeyCommand({ kind: 'find' });
  const bp = b.owner.executeKeyCommand({ kind: 'remove' });
  a.owner.terminalBoundaryGeneration++;
  b.release();
  await bp;
  assert.equal(a.events.length, 1);
  assert.match(b.events[1], /pane=pane-b,.*result=completed$/);
  a.release();
  await ap;
  assert.match(a.events[1], /pane=pane-a,.*result=cancelled$/);
  count++;
  console.log('Known-host completion: ' + count + ' actual injected-owner cases passed.');
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
