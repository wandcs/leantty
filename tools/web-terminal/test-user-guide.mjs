import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const sourcePath = path.join(repoRoot, 'docs', 'design', 'LeanTTY-User-Guide.html');
const packagedPath = path.join(repoRoot, 'entry', 'src', 'main', 'resources', 'rawfile',
  'LeanTTY-User-Guide.html');
const source = fs.readFileSync(sourcePath);
const packaged = fs.readFileSync(packagedPath);
const html = source.toString('utf8');
const appManifest = fs.readFileSync(path.join(repoRoot, 'AppScope', 'app.json5'), 'utf8');
const changelog = fs.readFileSync(path.join(repoRoot, 'CHANGELOG.md'), 'utf8');
const versionMatch = appManifest.match(/"versionName"\s*:\s*"([^"]+)"/);

assert.ok(versionMatch, 'the application versionName must be readable');
const version = versionMatch[1];

assert.deepEqual(packaged, source, 'the packaged guide must exactly match the reviewed source');
assert.ok(source.length > 0 && source.length <= 100 * 1024, 'the guide must stay within the 100 KiB limit');
assert.match(html, /<!-- leantty-owned-user-guide -->/);
assert.match(html, /<meta name="leantty-guide-revision" content="\d+">/);
assert.ok(html.includes(`LeanTTY ${version}`), 'the guide must identify the application version');
assert.ok(changelog.includes(`## [${version}] - In development`) ||
  new RegExp(`^## \\[${version.replaceAll('.', '\\.') }\\] - \\d{4}-\\d{2}-\\d{2}$`, 'm').test(changelog),
  'the guide version must have a matching target-version Changelog section');
assert.match(html, /default-src 'none'; style-src 'unsafe-inline'; img-src data:/);
assert.doesNotMatch(html, /<script\b/i, 'the offline guide must not execute scripts');
assert.doesNotMatch(html, /<(?:img|link|iframe|object|embed)\b[^>]*(?:src|href)=["']https?:/i,
  'the offline guide must not load network resources');
assert.doesNotMatch(html, /href=["'](?!#)[^"']+["']/i,
  'the guide must contain only in-document navigation links');

assert.match(html, /id="language-zh" checked/);
assert.match(html, /id="language-en"/);
assert.match(html, /class="guide-page guide-zh" lang="zh-CN"/);
assert.match(html, /class="guide-page guide-en" lang="en"/);
assert.match(html, /#language-en:checked\s*~\s*\.guide-zh\s*\{[^}]*display:\s*none/s);
assert.match(html, /#language-zh:checked\s*~\s*\.guide-en[^}]*display:\s*none/s);

for (const phrase of [
  '选中后直接右键', '无选区时右键粘贴', '按住 Ctrl 点击 URL', '只搜索当前 Pane',
  '首次连接先核对指纹', '长期任务放在远端 tmux',
  'Select, then secondary-click', 'Secondary-click with no selection', 'Hold Ctrl and click a URL',
  'Search only the active pane', 'Check the first fingerprint', 'Keep long jobs in remote tmux'
]) {
  assert.ok(html.includes(phrase), `missing first-section best practice: ${phrase}`);
}

for (const command of [
  'ssh user@example.com', 'host add work user@example.com:2222', 'ssh-keygen -F example.com',
  'ssh-keygen -t ed25519 -f id_work -C work', 'ssh-copy-id -i id_work user@example.com',
  'put report.pdf user@example.com:/incoming/', 'get work:/reports/latest.csv reports/',
  'config import workstation.conf', 'config export workstation-backup.conf'
]) {
  assert.ok(html.includes(command), `missing command example: ${command}`);
}

function luminance(hex) {
  const channels = [1, 3, 5].map((start) => parseInt(hex.slice(start, start + 2), 16) / 255)
    .map((channel) => channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4));
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

function contrast(foreground, background) {
  const light = Math.max(luminance(foreground), luminance(background));
  const dark = Math.min(luminance(foreground), luminance(background));
  return (light + 0.05) / (dark + 0.05);
}

const palettes = [...html.matchAll(/--code-bg:\s*(#[0-9a-f]{6});\s*\n\s*--code-text:\s*(#[0-9a-f]{6})/gi)];
assert.ok(palettes.length >= 2, 'expected explicit code palettes for screen and print themes');
for (const palette of palettes) {
  assert.ok(contrast(palette[2], palette[1]) >= 7,
    `terminal command contrast must be at least WCAG AAA: ${palette[2]} on ${palette[1]}`);
}

console.log(`User guide checks passed (${source.length} bytes, ${palettes.length} code palettes).`);
