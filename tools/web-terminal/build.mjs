import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { applyXtermWebglDefaultBackgroundPatch } from './patches/xterm-webgl-default-background.mjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '..', '..');
const outputDir = resolve(repoRoot, 'entry', 'src', 'main', 'resources', 'rawfile');

const assets = [
  ['node_modules/@xterm/xterm/lib/xterm.js', 'xterm.js'],
  ['node_modules/@xterm/xterm/css/xterm.css', 'xterm.css'],
  ['node_modules/@xterm/addon-fit/lib/addon-fit.js', 'addon-fit.js'],
  ['node_modules/@xterm/addon-search/lib/addon-search.js', 'addon-search.js'],
  ['node_modules/@xterm/addon-web-links/lib/addon-web-links.js', 'addon-web-links.js'],
  ['node_modules/@xterm/addon-serialize/lib/addon-serialize.js', 'addon-serialize.js'],
  ['node_modules/@xterm/addon-webgl/lib/addon-webgl.js', 'addon-webgl.js']
];

await mkdir(outputDir, { recursive: true });

const manifest = [];
for (const [sourceRelative, outputName] of assets) {
  const source = resolve(scriptDir, sourceRelative);
  const output = resolve(outputDir, outputName);
  let content = await readFile(source, 'utf8');
  if (outputName === 'addon-webgl.js') {
    const packageMetadata = JSON.parse(await readFile(
      resolve(scriptDir, 'node_modules/@xterm/addon-webgl/package.json'),
      'utf8'
    ));
    content = applyXtermWebglDefaultBackgroundPatch(content, packageMetadata.version);
  }
  content = content.replace(/\n?\/\/# sourceMappingURL=.*\s*$/u, '\n');
  await writeFile(output, content, 'utf8');

  const bytes = await readFile(output);
  manifest.push({
    file: outputName,
    bytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex')
  });
}

const manifestPath = resolve(scriptDir, 'assets-manifest.json');
await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

for (const asset of manifest) {
  console.log(`${asset.file} ${asset.bytes} ${asset.sha256}`);
}
