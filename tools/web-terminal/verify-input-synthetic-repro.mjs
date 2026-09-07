import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

// Diagnostic only: real browser timers/xterm, never part of a correctness gate.
const [modulePath, outputPath, assetKind = 'upstream'] = process.argv.slice(2);
assert.ok(modulePath && outputPath, 'Usage: node verify-input-synthetic-repro.mjs <playwright module> <output>');
assert.ok(['upstream', 'packaged'].includes(assetKind));
const repo = fileURLToPath(new URL('../../', import.meta.url));
const script = readFileSync(new URL('./acceptance-input-synthetic.js', import.meta.url), 'utf8');
const bundle = path.join(repo, assetKind === 'upstream'
  ? 'tools/web-terminal/node_modules/@xterm/xterm/lib/xterm.js'
  : 'entry/src/main/resources/rawfile/xterm.js');
const sha256 = data => createHash('sha256').update(data).digest('hex');
if (assetKind === 'upstream') assert.equal(sha256(readFileSync(bundle)),
  '14903579ff54664cd72f8e8699e6961a6272c21863ec1c3b118cdc8af5d4a972');
const expectedTerminalUnits = assetKind === 'upstream' ? 30 : 40;
const { chromium } = await import(pathToFileURL(modulePath));
const report = { kind: 'synthetic-trigger-software-check', deviceCauseProven: false, result: 'invalid',
  assetKind, scriptSha256: sha256(script), xtermSha256: sha256(readFileSync(bundle)), reports: [], negativeCases: [] };
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  report.browserVersion = browser.version();
  async function fixture() {
    const page = await browser.newPage();
    await page.route('**/*', route => route.abort());
    await page.setContent('<!doctype html><div id="terminal"></div>');
    await page.addScriptTag({ path: bundle });
    await page.evaluate(() => {
      window.term = new Terminal({ cols: 50, rows: 3 }); term.open(document.querySelector('#terminal'));
      window.secureInput = false; window.restoringSnapshot = false;
      window.acceptanceInputOrder = null; window.acceptanceInputAttribution = null;
      window.reports = [];
      window.sendBridgeControl = (kind, payload) => reports.push({ kind, payload });
      window.originalDiff = term._core._compositionHelper._handleAnyTextareaChanges;
      window.originalTimeout = window.setTimeout;
      window.downstream = ''; term.onData(data => { window.downstream += data; });
    });
    await page.addScriptTag({ content: script });
    return page;
  }
  const page = await fixture();
  assert.equal(await page.evaluate(() => armAcceptanceInputSynthetic('1234567')), true);
  await page.waitForFunction(() => reports.some(r => r.payload.startsWith('1234567;1;')), null, { timeout: 15000 });
  report.reports = await page.evaluate(() => reports);
  const rows = report.reports.slice(1).flatMap(r => r.payload.split(';')[4].split('/').map(row => row.split(',').map(Number)));
  assert.equal(rows.length, 51);
  for (const row of rows.slice(0, 50)) {
    assert.equal(row[5], 1); assert.equal(row[6], 1);
    assert.equal(row[7], assetKind === 'upstream' && row[3] === 1 ? 0 : 1);
    assert.equal(row[8], assetKind === 'upstream' && row[3] === 1 ? 0 : 1);
    assert.equal(row[9], row[3] < 2 ? 1 : 0);
    assert.equal(row[10], 0); assert.equal(row[11], 1);
  }
  assert.deepEqual(rows.at(-1).slice(2, 8), [9, 8, 40, expectedTerminalUnits, assetKind === 'upstream' ? 0 : 1, 40]);
  assert.equal(await page.evaluate(() => downstream), 'a'.repeat(expectedTerminalUnits));
  assert.equal(await page.evaluate(() => originalDiff === term._core._compositionHelper._handleAnyTextareaChanges &&
    originalTimeout === window.setTimeout && document.querySelectorAll('textarea').length === 1), true);
  assert.equal(await page.evaluate(() => armAcceptanceInputSynthetic('2345678')), false);
  await page.close();
  for (const boundary of ['secureInput', 'restoringSnapshot', 'cancel', 'owner-replaced']) {
    const negative = await fixture();
    await negative.evaluate(boundary => {
      if (boundary === 'secureInput' || boundary === 'restoringSnapshot') {
        window[boundary] = true;
        if (armAcceptanceInputSynthetic('1234567')) throw new Error('Unsafe arm');
      } else {
        armAcceptanceInputSynthetic('1234567');
        if (boundary === 'cancel') stopAcceptanceInputSynthetic(3);
        else window.term = null;
      }
    }, boundary);
    await negative.waitForTimeout(1200); // lets the delayed entry attempt run, not a success oracle
    const state = await negative.evaluate(() => ({ reports, downstream, active: !!acceptanceInputSynthetic }));
    assert.equal(state.downstream, ''); assert.equal(state.active, false);
    assert.ok(state.reports.every(r => /^[0-9;,/]+$/.test(r.payload)));
    report.negativeCases.push({ boundary, ...state });
    await negative.close();
  }
  report.result = assetKind === 'upstream' ? 'controlled-mechanism-and-boundaries-verified'
    : 'controlled-input-correction-and-boundaries-verified';
} catch (error) { report.failure = error.message; process.exitCode = 1; }
finally {
  await browser.close(); report.browserClosed = true;
  mkdirSync(outputPath, { recursive: true });
  writeFileSync(path.join(outputPath, 'result.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ result: report.result, failure: report.failure, negativeCases: report.negativeCases.length }));
}
