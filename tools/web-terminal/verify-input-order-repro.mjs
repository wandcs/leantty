import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Standalone diagnostic, deliberately outside the product/release regression gate.
// No dependency install, server, virtual timer, DOM stub or xterm patch is needed.
const args = process.argv.slice(2);
if (args.includes('--help')) {
  console.log('node tools/web-terminal/verify-input-order-repro.mjs [--playwright-module <absolute index.mjs>] [--output <directory>]');
  process.exit(0);
}
const options = {};
for (let i = 0; i < args.length; i += 2) {
  assert.ok(['--playwright-module', '--output'].includes(args[i]) && args[i + 1], 'Unknown/incomplete option');
  assert.equal(options[args[i]], undefined, 'Duplicate option');
  options[args[i]] = args[i + 1];
}
const repo = fileURLToPath(new URL('../../', import.meta.url));
const html = fileURLToPath(new URL('./input-order-repro.html', import.meta.url));
// Preserve the original defective baseline even after the packaged asset is repaired.
const bundle = path.join(repo, 'tools/web-terminal/node_modules/@xterm/xterm/lib/xterm.js');
const css = path.join(repo, 'entry/src/main/resources/rawfile/xterm.css');
const output = path.resolve(options['--output'] ?? path.join(repo, 'build/verification/input-order-minimal-' + Date.now()));
assert.ok(!options['--playwright-module'] || path.isAbsolute(options['--playwright-module']), 'Use an absolute module path');
const sha256 = file => createHash('sha256').update(readFileSync(file)).digest('hex');
assert.equal(sha256(bundle), '14903579ff54664cd72f8e8699e6961a6272c21863ec1c3b118cdc8af5d4a972', 'Re-audit on xterm upgrade');
const { chromium } = await import(options['--playwright-module']
  ? pathToFileURL(options['--playwright-module']).href : 'playwright');
mkdirSync(output, { recursive: true });
const report = { kind: 'synthetic-browser-input-order', acceptanceEligible: false, deviceCauseProven: false,
  startedAt: new Date().toISOString(), xtermSha256: sha256(bundle), htmlSha256: sha256(html),
  runnerSha256: sha256(fileURLToPath(import.meta.url)), runs: [], errors: [], result: 'invalid',
  cleanup: { browserClosed: false } };
let browser;
try {
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  report.browserVersion = browser.version();
  const context = await browser.newContext({ viewport: { width: 1100, height: 950 } });
  const allowed = new Set([html, bundle, css].map(file => pathToFileURL(file).href));
  await context.route('**/*', route => allowed.has(route.request().url()) ? route.continue() : route.abort());
  // Fixed 10 fresh pages: determinism check of declared schedules, not device sampling.
  for (let run = 0; run < 10; run++) {
    const page = await context.newPage();
    page.on('pageerror', error => report.errors.push(error.message));
    try {
      await page.goto(pathToFileURL(html).href, { waitUntil: 'networkidle' });
      await page.getByRole('button', { name: 'Run fixed cases', exact: true }).click();
      await page.waitForFunction(() => window.reproResult !== null);
      const observed = await page.evaluate(() => window.reproResult);
      report.runs.push(observed);
      if (run === 0) await page.screenshot({ path: path.join(output, 'repro.png'), fullPage: true });
      assert.equal(observed.deviceCauseProven, false);
      assert.deepEqual(observed.results.map(item => item.name), ['xterm-normal', 'xterm-delayed-input',
        'xterm-keyup-before-input', 'xterm-input-only', 'textarea-delayed-input']);
      for (const item of observed.results) {
        assert.equal(item.domValue, 'a', 'Insertion must actually reach the DOM');
        assert.equal(item.actual, item.name === 'xterm-delayed-input' ? '' : 'a', item.name);
      }
    } finally { await page.close(); }
  }
  assert.deepEqual(report.errors, []);
  report.result = 'candidate-mechanism-reproduced';
} catch (error) {
  report.failure = error.message;
  process.exitCode = 1;
} finally {
  if (browser) {
    await browser.close();
    report.cleanup.browserClosed = true;
  }
  report.completedAt = new Date().toISOString();
  writeFileSync(path.join(output, 'result.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ result: report.result, runs: report.runs.length,
    failure: report.failure, deviceCauseProven: false, cleanup: report.cleanup, evidence: output }));
}
