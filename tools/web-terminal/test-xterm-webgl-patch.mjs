import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

import {
  XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH,
  applyXtermWebglDefaultBackgroundPatch,
  normalizeWebglBackgroundAttribute
} from './patches/xterm-webgl-default-background.mjs';

const upstreamAddon = readFileSync(
  new URL('node_modules/@xterm/addon-webgl/lib/addon-webgl.js', import.meta.url),
  'utf8'
);

assert.equal(XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH.packageName, '@xterm/addon-webgl');
assert.equal(XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH.packageVersion, '0.19.0');
assert.equal(XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH.upstreamTag, '6.0.0');
assert.equal(XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH.upstreamCommit,
  'f447274f430fd22513f6adbf9862d19524471c04');

const patchedAddon = applyXtermWebglDefaultBackgroundPatch(upstreamAddon, '0.19.0');
assert.notEqual(patchedAddon, upstreamAddon,
  'the audited upstream WebGL addon must receive one local transformation');
assert.equal(patchedAddon.split(XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH.replacement).length - 1, 1,
  'the generated addon must contain exactly one color-only background read');
assert.equal(patchedAddon.includes(XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH.target), false,
  'the unmasked background read must be removed from the generated addon');
assert.ok(patchedAddon.includes('d=e.cells[c+n.RENDER_MODEL_FG_OFFSET]'),
  'the patch must leave the adjacent foreground and inverse read unchanged');

assert.throws(
  () => applyXtermWebglDefaultBackgroundPatch(upstreamAddon, '0.20.0'),
  /Expected @xterm\/addon-webgl 0\.19\.0, received 0\.20\.0/,
  'dependency updates must stop for an explicit patch review');
assert.throws(
  () => applyXtermWebglDefaultBackgroundPatch(upstreamAddon.replace('updateBackgrounds', 'changed'), '0.19.0'),
  /input SHA-256/,
  'any change to the audited upstream input must stop the build');
assert.throws(
  () => applyXtermWebglDefaultBackgroundPatch('', '0.19.0'),
  /input SHA-256/,
  'an absent render site must not produce an unpatched asset');

globalThis.self = globalThis;
vm.runInThisContext(readFileSync(
  new URL('../../entry/src/main/resources/rawfile/xterm.js', import.meta.url),
  'utf8'
));

const ESC = String.fromCharCode(27);
const BEL = String.fromCharCode(7);
const styleCases = [
  ['plain', ''],
  ['dim', `${ESC}[2m`],
  ['italic', `${ESC}[3m`],
  ['underline-single', `${ESC}[4m`],
  ['underline-double', `${ESC}[4:2m`],
  ['underline-curly', `${ESC}[4:3m`],
  ['underline-dotted', `${ESC}[4:4m`],
  ['underline-dashed', `${ESC}[4:5m`],
  ['overline', `${ESC}[53m`],
  ['osc8-hyperlink', `${ESC}]8;;https://example.test${BEL}`],
  ['decsca-protected', `${ESC}[1\"q`]
];
const backgroundCases = [
  ['ansi', `${ESC}[44m`],
  ['palette-256', `${ESC}[48;5;123m`],
  ['true-color', `${ESC}[48;2;12;34;56m`]
];

async function cellFor(sequence) {
  const terminal = new globalThis.Terminal({
    allowProposedApi: true,
    cols: 8,
    rows: 2
  });
  await new Promise(resolve => terminal.write(`${sequence}X`, resolve));
  const cell = terminal.buffer.active.getLine(0).getCell(0);
  terminal.dispose();
  return cell;
}

for (const [styleName, styleSequence] of styleCases) {
  const defaultCell = await cellFor(styleSequence);
  assert.equal(normalizeWebglBackgroundAttribute(defaultCell.bg), 0,
    `${styleName} on the default background must not allocate a WebGL background rectangle`);

  for (const [backgroundName, backgroundSequence] of backgroundCases) {
    const baseCell = await cellFor(backgroundSequence);
    const styledCell = await cellFor(`${backgroundSequence}${styleSequence}`);
    assert.notEqual(normalizeWebglBackgroundAttribute(styledCell.bg), 0,
      `${styleName} with ${backgroundName} must retain an explicit WebGL background`);
    assert.equal(
      normalizeWebglBackgroundAttribute(styledCell.bg),
      normalizeWebglBackgroundAttribute(baseCell.bg),
      `${styleName} must not change the explicit ${backgroundName} color identity`
    );
  }
}

const inverseCell = await cellFor(`${ESC}[7m`);
assert.equal(normalizeWebglBackgroundAttribute(inverseCell.bg), 0,
  'inverse with a default background keeps the background attribute default');
assert.ok(inverseCell.isInverse(),
  'inverse remains represented by its foreground flag for the existing WebGL inverse path');

async function erasedCellFor(sequence) {
  const terminal = new globalThis.Terminal({ cols: 8, rows: 2 });
  await new Promise(resolve => terminal.write(sequence, resolve));
  const cell = terminal.buffer.active.getLine(0).getCell(0);
  terminal.dispose();
  return cell;
}

const defaultEraseCell = await erasedCellFor(`${ESC}[2m${ESC}[2K`);
assert.equal(normalizeWebglBackgroundAttribute(defaultEraseCell.bg), 0,
  'erase with a styled default background must remain transparent');
const explicitEraseCell = await erasedCellFor(`${ESC}[44m${ESC}[2K`);
assert.notEqual(normalizeWebglBackgroundAttribute(explicitEraseCell.bg), 0,
  'background-color erase must preserve its explicit ANSI background');

console.log('xterm WebGL default-background patch tests passed');
