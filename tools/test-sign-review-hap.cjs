'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const bridge = fs.readFileSync(path.join(__dirname, 'sign-review-hap.cjs'), 'utf8');
const root = path.resolve(__dirname, '..', 'build', 'signing-fixture');
const production = path.join(root, 'production');
const review = path.join(root, 'cold-review');
const config = path.join(review, 'signing.local.json5');
const input = path.join(production, 'unsigned.hap');
const output = path.join(review, 'signed.hap');
const sdk = path.join(root, 'sdk');
const secret = 'fixture-secret-must-not-appear';

function run(failModule) {
  let cwd = review;
  let signed = false;
  let decryptions = 0;
  const diagnostics = [];
  const fakeProcess = {
    argv: ['node', 'bridge', sdk, config, input, output, '22', production],
    stdout: {}, stderr: {}, chdir: value => { cwd = value; }
  };
  const fakeFs = {
    readFileSync: file => {
      assert.equal(file, config);
      return JSON.stringify({ material: {
        certpath: path.join(root, 'cert'), profile: path.join(root, 'profile'),
        storeFile: path.join(root, 'keystore'), keyPassword: 'ab'.repeat(32),
        storePassword: 'cd'.repeat(32), keyAlias: 'fixture', signAlg: 'SHA256withECDSA'
      } });
    },
    statSync: () => ({ isFile: () => true }),
    existsSync: file => file === output && signed,
    writeSync: (fd, text) => diagnostics.push(text)
  };
  const requireFixture = name => {
    if (name === 'node:fs') return fakeFs;
    if (name === 'node:path') return path;
    if (name.endsWith('prepare-node-path.js')) return { initNodePath() {
      // A fresh review checkout has no modules. Only production was built.
      assert.equal(cwd, production);
      if (failModule) throw new Error(secret);
    } };
    if (name.endsWith('decipher-util.js')) return { DecipherUtil: { decryptPwd() {
      decryptions++;
      return secret;
    } } };
    if (name === 'node:child_process') return { spawnSync(executable, args, options) {
      assert.equal(cwd, production);
      assert.equal(args[args.indexOf('-inFile') + 1], input);
      assert.equal(args[args.indexOf('-outFile') + 1], output);
      assert.equal(options.stdio, 'ignore');
      signed = true;
      return { status: 0 };
    } };
    throw new Error(`Unexpected import: ${name}`);
  };
  vm.runInNewContext(bridge, { require: requireFixture, process: fakeProcess });
  assert.equal(signed, !failModule);
  assert.equal(decryptions, failModule ? 0 : 2);
  assert.equal(fakeProcess.exitCode, failModule ? 1 : undefined);
  assert.equal(diagnostics.join(''), failModule ? 'Review signing failed at SDK credential module.\n' : '');
}

run(false);
run(true);
console.log('Review signing context and fail-closed diagnostics passed.');
