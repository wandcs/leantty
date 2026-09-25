// Signing bridge only: Hvigor owns encrypted DevEco credentials; the SDK owns HAP signing.
// These two internal SDK entry points (module setup and credentials) are explicit.
// SDK upgrades require the
// real signing/verification check; no alternate decryption implementations exist here.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Never let SDK diagnostics, exceptions or child command arguments expose credentials.
process.stdout.write = () => true;
process.stderr.write = () => true;
let stage = 'configuration';
try {
  const [sdk, configPath, input, output, compatibleVersion] = process.argv.slice(2);
  if (!sdk || !configPath || !input || !output || !/^\d+$/.test(compatibleVersion) ||
      fs.existsSync(output) || path.resolve(input) === path.resolve(output)) throw new Error();
  const material = JSON.parse(fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, '')).material;
  for (const name of ['certpath', 'profile', 'storeFile']) {
    if (!path.isAbsolute(material[name]) || !fs.statSync(material[name]).isFile()) throw new Error();
  }
  for (const name of ['keyPassword', 'storePassword']) {
    if (typeof material[name] !== 'string' || !/^(?:[a-fA-F0-9]{2}){32,}$/.test(material[name])) throw new Error();
  }
  if (!material.keyAlias || !material.signAlg) throw new Error();
  stage = 'SDK credential module';
  process.chdir(path.dirname(configPath));
  require(path.join(sdk, 'tools/hvigor/hvigor/src/cli/wrapper/prepare-node-path.js')).initNodePath();
  const { DecipherUtil } = require(path.join(sdk, 'tools/hvigor/hvigor-ohos-plugin/src/utils/decipher-util.js'));
  stage = 'SDK credential decryption';
  const directory = path.dirname(material.storeFile);
  const keyPassword = DecipherUtil.decryptPwd(directory, material.keyPassword, 'keyPassword');
  const storePassword = DecipherUtil.decryptPwd(directory, material.storePassword, 'storePassword');
  if (typeof keyPassword !== 'string' || typeof storePassword !== 'string' || !keyPassword || !storePassword) throw new Error();
  stage = 'SDK sign-app';
  const result = spawnSync(path.join(sdk, 'jbr/bin/java.exe'), [
    '-jar', path.join(sdk, 'sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar'),
    'sign-app', '-mode', 'localSign', '-keyAlias', material.keyAlias,
    '-keyPwd', keyPassword, '-appCertFile', material.certpath,
    '-profileFile', material.profile, '-profileSigned', '1', '-inFile', input,
    '-signAlg', material.signAlg, '-keystoreFile', material.storeFile,
    '-keystorePwd', storePassword, '-outFile', output,
    '-compatibleVersion', compatibleVersion, '-signCode', '1'
  ], { stdio: 'ignore', windowsHide: true });
  if (result.error || result.status !== 0 || !fs.existsSync(output)) throw new Error();
} catch {
  // Do not serialize the exception: spawn failures can include secret arguments.
  process.exitCode = 1;
  fs.writeSync(2, `Review signing failed at ${stage}.\n`);
}
