import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const ICON_CELL_FIXTURE = 'X●X━X╸X─XXXXXXXXX';
const FONT_FILES = [
  'JetBrainsMonoNerdFontMono-Regular.ttf',
  'JetBrainsMonoNerdFontMono-Bold.ttf'
];
const MAX_OUTLINE_OVERSHOOT_RATIO = 0.02;
const MAX_CONNECTOR_OVERSHOOT_RATIO = 0.04;
const CONNECTING_LINE_CODE_POINTS = new Set([0x2500, 0x2501, 0x2578]);

function readTables(font) {
  const tables = new Map();
  const tableCount = font.readUInt16BE(4);
  for (let index = 0; index < tableCount; index++) {
    const entryOffset = 12 + index * 16;
    tables.set(font.toString('ascii', entryOffset, entryOffset + 4), {
      offset: font.readUInt32BE(entryOffset + 8),
      length: font.readUInt32BE(entryOffset + 12)
    });
  }
  return tables;
}

function requireTable(tables, tag) {
  const table = tables.get(tag);
  assert.ok(table, `font must contain the ${tag} table`);
  return table.offset;
}

function findBmpCmap(font, tables) {
  const cmapOffset = requireTable(tables, 'cmap');
  const recordCount = font.readUInt16BE(cmapOffset + 2);
  let fallback = 0;
  for (let index = 0; index < recordCount; index++) {
    const recordOffset = cmapOffset + 4 + index * 8;
    const platformId = font.readUInt16BE(recordOffset);
    const encodingId = font.readUInt16BE(recordOffset + 2);
    const subtableOffset = cmapOffset + font.readUInt32BE(recordOffset + 4);
    if (font.readUInt16BE(subtableOffset) !== 4) continue;
    if (platformId === 3 && encodingId === 1) return subtableOffset;
    if (fallback === 0) fallback = subtableOffset;
  }
  assert.notEqual(fallback, 0, 'font must contain a BMP format 4 cmap');
  return fallback;
}

function glyphIndexForCodePoint(font, cmapOffset, codePoint) {
  const segmentCount = font.readUInt16BE(cmapOffset + 6) / 2;
  const endCodesOffset = cmapOffset + 14;
  const startCodesOffset = endCodesOffset + segmentCount * 2 + 2;
  const idDeltasOffset = startCodesOffset + segmentCount * 2;
  const idRangeOffsetsOffset = idDeltasOffset + segmentCount * 2;

  for (let segment = 0; segment < segmentCount; segment++) {
    const endCode = font.readUInt16BE(endCodesOffset + segment * 2);
    if (codePoint > endCode) continue;
    const startCode = font.readUInt16BE(startCodesOffset + segment * 2);
    if (codePoint < startCode) return 0;
    const delta = font.readInt16BE(idDeltasOffset + segment * 2);
    const rangeOffsetPosition = idRangeOffsetsOffset + segment * 2;
    const rangeOffset = font.readUInt16BE(rangeOffsetPosition);
    if (rangeOffset === 0) return (codePoint + delta) & 0xFFFF;
    const glyphPosition = rangeOffsetPosition + rangeOffset + (codePoint - startCode) * 2;
    const glyphIndex = font.readUInt16BE(glyphPosition);
    return glyphIndex === 0 ? 0 : (glyphIndex + delta) & 0xFFFF;
  }
  return 0;
}

function glyphOffset(font, locaOffset, glyphIndex, longOffsets) {
  return longOffsets
    ? font.readUInt32BE(locaOffset + glyphIndex * 4)
    : font.readUInt16BE(locaOffset + glyphIndex * 2) * 2;
}

function glyphHorizontalMetrics(font, tables, glyphIndex) {
  const headOffset = requireTable(tables, 'head');
  const hheaOffset = requireTable(tables, 'hhea');
  const hmtxOffset = requireTable(tables, 'hmtx');
  const locaOffset = requireTable(tables, 'loca');
  const glyfOffset = requireTable(tables, 'glyf');
  const metricCount = font.readUInt16BE(hheaOffset + 34);
  const advanceWidth = font.readUInt16BE(
    hmtxOffset + Math.min(glyphIndex, metricCount - 1) * 4
  );
  const longOffsets = font.readInt16BE(headOffset + 50) === 1;
  const start = glyphOffset(font, locaOffset, glyphIndex, longOffsets);
  const end = glyphOffset(font, locaOffset, glyphIndex + 1, longOffsets);
  assert.ok(end > start, `glyph ${glyphIndex} must have an outline`);
  return {
    advanceWidth,
    xMin: font.readInt16BE(glyfOffset + start + 2),
    xMax: font.readInt16BE(glyfOffset + start + 6)
  };
}

for (const fontFile of FONT_FILES) {
  const font = readFileSync(
    new URL(`../../entry/src/main/resources/rawfile/${fontFile}`, import.meta.url)
  );
  const tables = readTables(font);
  const cmapOffset = findBmpCmap(font, tables);
  const referenceGlyphIndex = glyphIndexForCodePoint(font, cmapOffset, 'X'.codePointAt(0));
  assert.notEqual(referenceGlyphIndex, 0, `${fontFile} must contain the ASCII X reference glyph`);
  const terminalCellWidth = glyphHorizontalMetrics(font, tables, referenceGlyphIndex).advanceWidth;
  const iconCodePoints = [...ICON_CELL_FIXTURE]
    .filter(character => character !== 'X')
    .map(character => character.codePointAt(0));

  for (const codePoint of iconCodePoints) {
    const glyphIndex = glyphIndexForCodePoint(font, cmapOffset, codePoint);
    assert.notEqual(glyphIndex, 0, `${fontFile} must contain U+${codePoint.toString(16).toUpperCase()}`);
    const metrics = glyphHorizontalMetrics(font, tables, glyphIndex);
    assert.equal(
      metrics.advanceWidth,
      terminalCellWidth,
      `${fontFile} U+${codePoint.toString(16).toUpperCase()} must advance exactly one terminal cell`
    );
    const overshootRatio = CONNECTING_LINE_CODE_POINTS.has(codePoint)
      ? MAX_CONNECTOR_OVERSHOOT_RATIO
      : MAX_OUTLINE_OVERSHOOT_RATIO;
    const allowedOvershoot = Math.ceil(metrics.advanceWidth * overshootRatio);
    assert.ok(
      metrics.xMin >= -allowedOvershoot &&
        metrics.xMax <= metrics.advanceWidth + allowedOvershoot,
      `${fontFile} U+${codePoint.toString(16).toUpperCase()} outline ` +
        `[${metrics.xMin}, ${metrics.xMax}] must fit one ${metrics.advanceWidth}-unit terminal cell ` +
        `within ${allowedOvershoot} units of outline overshoot`
    );
  }
}

console.log('Nerd Font cell-width regression tests passed');
