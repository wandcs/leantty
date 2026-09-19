// Real configuration, command and completion owners; replace only platform I/O.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../entry/src/main/ets');
const tests = [];
const test = (name, run) => tests.push({ name, run });
function fixture() {
  const modules = new Map();
  let projection = '', durable = '', failCommit = false;
  let permission = Promise.resolve(), exported = '';
  const context = { filesDir: '/test' };
  const stubs = {
    'common/utils/FileUtils.ets': { FileUtils: {
      getSshDir: () => '/test/.ssh', ensureDir() {},
      readTextFile: () => projection, writeTextFile() {},
    } },
    'common/logger/Logger.ets': { Logger: class { info() {} warn() {} } },
    'model/ssh/SshKeyManager.ets': { SshKeyManager: {} },
    'model/ssh/KnownHostsManager.ets': {},
    'model/transfer/DownloadsAccessManager.ets': { DownloadsAccessManager: { ensure: () => permission } },
    'model/persistence/DurableStateManager.ets': { DurableStateManager: {
      commitSshConfig(_context, content) {
        load('model/persistence/SshConfigCommitPolicy.ets').SshConfigCommitPolicy.commit(
          durable, content, v => { projection = v; }, v => {
            if (failCommit) throw new Error('controlled durable write failure');
            durable = v;
          }, () => { projection = ''; });
      },
    } },
  };
  function load(relative) {
    relative = relative.replaceAll('\\', '/');
    if (relative in stubs) return stubs[relative];
    if (modules.has(relative)) return modules.get(relative);
    const result = ts.transpileModule(fs.readFileSync(path.join(root, relative), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
      fileName: relative.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    });
    assert.equal((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
    const exports = {}; modules.set(relative, exports);
    vm.runInNewContext(result.outputText, { exports, require(name) {
      if (name === '@kit.AbilityKit' || name === '@kit.CoreFileKit') return {};
      assert.ok(name.startsWith('.'), `Unexpected platform import: ${name}`);
      return load(path.normalize(path.join(path.dirname(relative), name + '.ets')));
    }, Uint8Array, Error, Promise, console });
    return exports;
  }
  const { SshConfig } = load('model/ssh/SshConfig.ets');
  const { CommandBarViewModel } = load('viewmodel/CommandBarViewModel.ets');
  const { CommandParser } = load('model/command/CommandParser.ets');
  const { KeyCommandService } = load('model/command/KeyCommandService.ets');
  // The fixed input represents a validated Downloads read, not real user files.
  SshConfig.readDownloadsText = () => 'Host imported\n  HostName imported.example\n  User fixture\n';
  SshConfig.writeDownloadsText = (_name, content) => { exported = content; };
  const pane = () => { const p = new CommandBarViewModel(); p.loadSshConfig(context); return p; };
  async function command(p, text) {
    const output = [];
    const parsed = CommandParser.parseInput(text, p.getSshConfig());
    assert.ok(parsed); assert.equal(parsed.errorMessage, '');
    await KeyCommandService.execute(parsed, { context, sshConfig: p.getSshConfig(),
      writeOutput: text => output.push(text), writeError: text => { throw new Error(text); } });
    return output.join('');
  }
  return { pane, command, context, SshConfig, CommandParser,
    text: () => durable, projection: () => projection, exported: () => exported,
    fail: value => { failCommit = value; },
    pauseDownloads() { let resume; permission = new Promise(r => { resume = r; }); return resume; },
  };
}
test('existing Panes see add/update/remove in completion, resolution and subsequent writes', async () => {
  const f = fixture(), a = f.pane(), b = f.pane();
  await f.command(a, 'host add alpha fixture@alpha.example:2222');
  b.setInputText('ssh al');
  assert.deepEqual(Array.from(b.tryTabComplete()), ['ssh alpha']);
  assert.equal(f.CommandParser.parseCommand('ssh alpha', b.getSshConfig()).host, 'alpha.example');
  assert.match(await f.command(b, 'host list'), /alpha/);
  await f.command(b, 'host add beta fixture@beta.example');
  await f.command(a, 'host set alpha fixture@updated.example:2223');
  assert.match(f.text(), /Host beta\n/);
  assert.equal(f.CommandParser.parseCommand('ssh alpha', b.getSshConfig()).port, 2223);
  assert.equal(f.CommandParser.parseInput('mosh alpha', b.getSshConfig()).host, 'updated.example');
  assert.equal(f.CommandParser.parseInput('get alpha:/tmp/file result.txt', b.getSshConfig()).host, 'updated.example');
  await f.command(b, 'host rm alpha');
  a.setInputText('ssh al'); assert.equal(a.tryTabComplete().length, 0);
  assert.equal(a.getSshConfig().findHost('alpha'), null);
  assert.notEqual(f.pane().getSshConfig().findHost('beta'), null);
  a.addToHistory('host list'); b.addToHistory('ssh beta');
  assert.equal(a.navigateHistory(-1), 'host list');
  assert.equal(b.navigateHistory(-1), 'ssh beta');
});
test('failed save rolls back the shared view as well as the durable projection', async () => {
  const f = fixture(), a = f.pane(), b = f.pane();
  await f.command(a, 'host add keep fixture@keep.example');
  const previous = f.text(); f.fail(true);
  await assert.rejects(f.command(b, 'host set keep fixture@wrong.example'), /controlled durable write failure/);
  assert.equal(a.getSshConfig().findHost('keep').hostname, 'keep.example');
  await assert.rejects(f.command(b, 'host add lost fixture@lost.example'), /controlled durable write failure/);
  assert.equal(a.getSshConfig().findHost('lost'), null);
  await assert.rejects(f.command(b, 'host rm keep'), /controlled durable write failure/);
  assert.notEqual(a.getSshConfig().findHost('keep'), null);
  assert.equal(f.text(), previous); assert.equal(f.projection(), previous);
  f.fail(false); await f.command(a, 'host add after fixture@after.example');
  assert.doesNotMatch(f.text(), /wrong\.example|Host lost\n/);
});
test('import and export observe commits made while Downloads authorization is pending', async () => {
  const f = fixture(), a = f.pane(), b = f.pane();
  const resume = f.pauseDownloads();
  const importing = a.getSshConfig().importFromDownloads(f.context, 'fixture.conf');
  await f.command(b, 'host add during fixture@during.example');
  resume(); await importing;
  assert.notEqual(b.getSshConfig().findHost('imported'), null);
  assert.match(f.text(), /Host during\n/);
  const resumeExport = f.pauseDownloads();
  const exporting = a.getSshConfig().exportToDownloads(f.context, 'out.conf');
  await f.command(b, 'host set during fixture@latest.example');
  resumeExport(); await exporting;
  assert.match(f.exported(), /latest\.example/);
  const previous = f.text(); f.fail(true);
  await assert.rejects(a.getSshConfig().importFromDownloads(f.context, 'fixture.conf', true));
  assert.equal(b.getSshConfig().getConfigText(), previous);
});
(async () => {
  let failed = 0;
  for (const { name, run } of tests) {
    try { await run(); console.log('PASS ' + name); }
    catch (e) { failed++; console.error('FAIL ' + name + ': ' + e.stack); }
  }
  if (failed) process.exitCode = 1;
})();
