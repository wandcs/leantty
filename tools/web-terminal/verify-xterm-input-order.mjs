import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

// Reuse the existing local Playwright runtime; no product dependency.
const [modulePath, assetKind, outputPath] = process.argv.slice(2);
assert.ok(modulePath && ['upstream', 'packaged'].includes(assetKind) && outputPath,
  'Usage: node verify-xterm-input-order.mjs <absolute playwright index.mjs> <upstream|packaged> <output-directory>');
assert.ok(path.isAbsolute(modulePath));
const repo = fileURLToPath(new URL('../../', import.meta.url));
const asset = path.join(repo, assetKind === 'upstream'
  ? 'tools/web-terminal/node_modules/@xterm/xterm/lib/xterm.js'
  : 'entry/src/main/resources/rawfile/xterm.js');
const cases = fileURLToPath(new URL('./xterm-input-order-cases.js', import.meta.url));
const sha256 = file => createHash('sha256').update(readFileSync(file)).digest('hex');
const report = { kind: 'xterm-input-order-regression', assetKind, acceptanceEligible: false,
  naturalFailureCauseProven: false, assetSha256: sha256(asset), casesSha256: sha256(cases),
  runnerSha256: sha256(fileURLToPath(import.meta.url)), result: 'invalid', cases: [], browserClosed: false };
const { chromium } = await import(pathToFileURL(modulePath));
let browser;
try {
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  report.browserVersion = browser.version();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/*', route => route.abort());
  await page.setContent('<!doctype html><html lang="en"><body></body></html>');
  await page.addStyleTag({ path: path.join(repo, 'entry/src/main/resources/rawfile/xterm.css') });
  await page.addScriptTag({ path: asset });
  await page.addScriptTag({ path: cases });
  report.cases = await page.evaluate(() => runXtermInputOrderCases(Terminal));
  assert.deepEqual(errors, [], 'Browser errors invalidate the run');
  const failures = report.cases.filter(item => !item.exact);
  report.result = failures.length ? 'failed' : 'passed';
  assert.equal(failures.length, 0, JSON.stringify(failures));
} catch (error) { report.failure = error.message; process.exitCode = 1; }
finally {
  if (browser) { await browser.close(); report.browserClosed = true; }
  mkdirSync(outputPath, { recursive: true });
  writeFileSync(path.join(outputPath, 'result.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report));
}
