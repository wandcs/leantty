import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { guidePaths, startGuidePreview, sha256 } from './preview-user-guide.mjs';

const args = process.argv.slice(2);
if (args.includes('--help')) {
  console.log('Usage: node review-user-guide.mjs <absolute-playwright-index.mjs> <new-evidence-directory>\n' +
    'Uses installed Chrome, headless. Creates an isolated loopback preview and closes it afterwards.\n' +
    'Automation is an editorial aid, not content approval or HarmonyOS acceptance.');
  process.exit(0);
}
const [modulePath, directory] = args;
assert.ok(args.length === 2 && path.isAbsolute(modulePath ?? '') && directory,
  'Expected a Playwright module and a new evidence directory; use --help');
const output = path.resolve(directory);
mkdirSync(path.dirname(output), { recursive: true });
mkdirSync(output); // Fail rather than overwrite evidence from an earlier run.
const startedAt = Date.now();
const source = readFileSync(guidePaths.source);
const packaged = readFileSync(guidePaths.packaged);
const report = {
  schemaVersion: 1, scenario: 'offline-guide-browser-review', acceptanceEligible: false,
  result: 'invalid/interrupted', editorialReview: 'required-separately',
  nodeVersion: process.version, reducedMotion: 'reduce',
  startedAt: new Date(startedAt).toISOString(), completedAt: null,
  sourceSha256: sha256(source), packagedSha256: sha256(packaged),
  packagedMatchesSource: source.equals(packaged),
  runnerSha256: sha256(readFileSync(fileURLToPath(import.meta.url))),
  previewSha256: sha256(readFileSync(new URL('./preview-user-guide.mjs', import.meta.url))),
  checks: [], screenshots: [], externalRequestCount: 0, pageErrors: [],
  cleanup: { browserClosed: false, serverClosed: false }
};
function saveReport() {
  const temporary = path.join(output, 'result.tmp');
  writeFileSync(temporary, JSON.stringify(report, null, 2) + '\n');
  renameSync(temporary, path.join(output, 'result.json'));
}
async function check(name, action) {
  assert.ok(Date.now() - startedAt < 90000, 'Browser review exceeded its 90-second budget');
  const began = Date.now();
  const item = { name, result: 'failed' };
  report.checks.push(item);
  try { await action(); item.result = 'passed'; }
  catch (error) { item.failure = error.message; throw error; }
  finally { item.durationMs = Date.now() - began; saveReport(); }
}
async function languageVisible(page, language) {
  await page.waitForFunction(lang => {
    const active = document.getElementById(`guide-${lang}`);
    const other = document.getElementById(`guide-${lang === 'zh' ? 'en' : 'zh'}`);
    return active && other && getComputedStyle(active).display !== 'none' &&
      getComputedStyle(other).display === 'none';
  }, language);
}
async function anchorVisible(page, href, language) {
  assert.equal(new URL(page.url()).hash, href);
  await languageVisible(page, language);
  await page.waitForFunction(id => {
    const heading = document.getElementById(id)?.querySelector('h2, h3');
    if (!heading) return false;
    const rect = heading.getBoundingClientRect();
    return rect.width > 0 && rect.top >= 0 && rect.top < innerHeight;
  }, href.slice(1));
}
async function screenshot(page, name) {
  const filename = `${name}.png`;
  await page.screenshot({ path: path.join(output, filename) });
  report.screenshots.push({ file: filename, sha256: sha256(readFileSync(path.join(output, filename))) });
}

async function sectionScreenshot(page, selector, name) {
  const filename = `${name}.png`;
  await page.locator(selector).screenshot({ path: path.join(output, filename) });
  report.screenshots.push({ file: filename, sha256: sha256(readFileSync(path.join(output, filename))) });
}

let browser;
let preview;
try {
  saveReport();
  const { chromium } = await import(pathToFileURL(modulePath));
  preview = await startGuidePreview();
  report.previewUrl = preview.url;
  assert.equal(preview.sha256, report.sourceSha256, 'Guide changed before the review started');
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  report.browserVersion = browser.version();
  const context = await browser.newContext({
    serviceWorkers: 'block', colorScheme: 'dark', reducedMotion: report.reducedMotion
  });
  context.setDefaultTimeout(5000);
  context.setDefaultNavigationTimeout(10000);
  await context.route('**/*', route => {
    const requested = new URL(route.request().url());
    const allowed = new URL(preview.url);
    if (requested.origin === allowed.origin && requested.pathname === allowed.pathname) {
      return route.continue();
    }
    report.externalRequestCount++;
    return route.abort();
  });
  const page = await context.newPage();
  page.on('pageerror', error => report.pageErrors.push(error.message));
  const response = await page.goto(preview.url, { waitUntil: 'networkidle' });
  assert.equal(response.status(), 200, 'Preview document must load successfully');
  await check('all-local-links-resolve-uniquely', async () => {
    const inspection = await page.evaluate(() => {
      const ids = [...document.querySelectorAll('[id]')].map(node => node.id);
      return {
        duplicateIds: ids.filter((id, index) => ids.indexOf(id) !== index),
        brokenLinks: [...document.querySelectorAll('a[href]')].map(a => a.getAttribute('href'))
          .filter(href => !href.startsWith('#') || !document.getElementById(href.slice(1)))
      };
    });
    assert.deepEqual(inspection, { duplicateIds: [], brokenLinks: [] });
  });
  await check('unfragmented-document-default', () => languageVisible(page, 'zh'));

  for (const viewport of [{ width: 1280, height: 900 }, { width: 800, height: 900 }]) {
    await page.setViewportSize(viewport);
    for (const lang of ['zh', 'en']) {
      const prefix = `${lang}-${viewport.width}`;
      await check(`${prefix}-direct-entry`, async () => {
        await page.goto(`${preview.url}#guide-${lang}`, { waitUntil: 'networkidle' });
        await languageVisible(page, lang);
        assert.ok(await page.locator(`#guide-${lang} h1`).isVisible());
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
          'Guide must fit the desktop window without document-level horizontal overflow');
        await screenshot(page, `${prefix}-home`);
      });
      const toc = page.locator(`#guide-${lang} nav.toc`);
      const hrefs = await toc.locator('a').evaluateAll(links => links.map(a => a.getAttribute('href')));
      assert.equal(hrefs.length, 10, 'The ten current task sections must remain reachable');
      for (const href of hrefs) {
        await check(`${prefix}-toc-${href.slice(1)}`, async () => {
          assert.ok(href.startsWith(`#${lang}-`), 'TOC must stay in the selected language');
          await toc.locator(`a[href="${href}"]`).click();
          await anchorVisible(page, href, lang);
        });
      }
      await check(`${prefix}-recovery-disclosures`, async () => {
        const details = page.locator(`#${lang}-recovery details`);
        assert.equal(await details.count(), 8);
        for (const item of await details.all()) {
          if (!(await item.evaluate(node => node.open))) await item.locator('summary').click();
          assert.ok(await item.locator('.details-body').isVisible());
        }
        await sectionScreenshot(page, `#${lang}-recovery-layout`, `${prefix}-recovery-layout`);
        if (viewport.width === 1280) {
          await toc.locator(`a[href="#${lang}-recovery"]`).click();
          await anchorVisible(page, `#${lang}-recovery`, lang);
          await screenshot(page, `${prefix}-recovery`);
        }
      });
      await check(`${prefix}-mosh-link-navigation`, async () => {
        await toc.locator(`a[href="#${lang}-commands"]`).click();
        await page.locator(`#${lang}-commands a[href="#${lang}-mosh"]`).click();
        await anchorVisible(page, `#${lang}-mosh`, lang);
      });
      await check(`${prefix}-key-task-instructions`, async () => {
        // Presence/readability, not execution of these remote commands or approval of all prose.
        for (const [section, commands] of Object.entries({
          start: ['ssh user@example.com', 'host add work user@example.com:2222'],
          trust: ['ssh-keygen -F example.com', 'ssh-copy-id -i id_work user@example.com'],
          agent: ['tmux new -As agent'],
          transfer: ['put report.pdf user@example.com:/incoming/', 'get work:/reports/latest.csv reports/'],
          data: [],
          recovery: ['ssh-keygen -R', 'ssh -G <host-name>']
        })) {
          await toc.locator(`a[href="#${lang}-${section}"]`).click();
          await anchorVisible(page, `#${lang}-${section}`, lang);
          const text = await page.locator(`#${lang}-${section}`).innerText();
          for (const command of commands) assert.ok(text.includes(command), `${lang}-${section}: ${command}`);
          if (viewport.width === 1280 && section === 'start') await screenshot(page, `${prefix}-start`);
          if (section === 'start') {
            const mosh = page.locator(`#${lang}-mosh`);
            assert.ok((await mosh.innerText()).includes('mosh -p 60042 work'));
            await sectionScreenshot(page, `#${lang}-mosh`, `${prefix}-mosh`);
          }
          if (section === 'data') await sectionScreenshot(page, `#${lang}-data`, `${prefix}-data`);
        }
      });
      await check(`${prefix}-language-switch-and-history`, async () => {
        const other = lang === 'zh' ? 'en' : 'zh';
        await page.locator(`#guide-${lang} .language-switch a[href="#guide-${other}"]`).click();
        await languageVisible(page, other);
        await page.goBack();
        assert.equal(new URL(page.url()).hash, `#${lang}-recovery`);
        await languageVisible(page, lang);
        await page.reload({ waitUntil: 'networkidle' });
        assert.equal(new URL(page.url()).hash, `#${lang}-recovery`);
        await languageVisible(page, lang);
        // History owns restored scroll position; clicking the header switch can scroll first.
        // Only an explicit TOC navigation promises to bring the chapter into the viewport.
        await toc.locator(`a[href="#${lang}-recovery"]`).click();
        await anchorVisible(page, `#${lang}-recovery`, lang);
      });
    }
  }
  await check('no-network-or-browser-errors', async () => {
    assert.equal(report.externalRequestCount, 0);
    assert.deepEqual(report.pageErrors, []);
    assert.deepEqual(await context.cookies(), []);
    assert.equal(sha256(readFileSync(guidePaths.source)), report.sourceSha256, 'Source changed during review');
  });
  report.result = 'passed';
} catch (error) {
  report.result = 'failed';
  report.failure = error.message;
  process.exitCode = 1;
} finally {
  // Each cleanup has its own boundary; browser failure must not leave a listener.
  for (const [resource, close] of [
    ['browserClosed', () => browser?.close()], ['serverClosed', () => preview?.close()]
  ]) {
    try { await close(); report.cleanup[resource] = true; }
    catch (error) {
      report.cleanup[resource] = false;
      report.cleanup.failure = error.message;
      report.result = 'invalid/interrupted';
      process.exitCode = 1;
    }
  }
  report.completedAt = new Date().toISOString();
  report.durationMs = Date.now() - startedAt;
  saveReport();
  console.log(JSON.stringify({ result: report.result, checks: report.checks.length,
    screenshots: report.screenshots.length, durationMs: report.durationMs,
    failure: report.failure, cleanup: report.cleanup, evidence: path.join(output, 'result.json') }));
}
