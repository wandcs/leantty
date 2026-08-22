import { createHash } from 'node:crypto';

const COLOR_ATTRIBUTE_MASK = 0x03FFFFFF;
const AUDITED_BACKGROUND_READ = 'u=e.cells[c+n.RENDER_MODEL_BG_OFFSET]';

/**
 * Local compatibility patch for xterm.js 6.0.0 RectangleRenderer.updateBackgrounds.
 *
 * Upstream source:
 * https://github.com/xtermjs/xterm.js/blob/6.0.0/addons/addon-webgl/src/RectangleRenderer.ts
 *
 * Readable equivalent:
 *
 *   bg = model.cells[modelIndex + RENDER_MODEL_BG_OFFSET]
 *     & (Attributes.CM_MASK | Attributes.RGB_MASK);
 *
 * The render model packs background color and non-color cell flags into the
 * same integer. RectangleRenderer only needs the color mode and color payload
 * when deciding whether a non-default background rectangle exists. Keeping
 * DIM, ITALIC, HAS_EXTENDED, PROTECTED, and OVERLINE in that decision turns
 * default-background text into an opaque theme-background rectangle.
 *
 * Remove this patch when the pinned upstream source makes that distinction, or
 * re-audit the single equivalent read when upgrading xterm. Version, complete
 * input hash, and exact match count deliberately make upgrades fail closed.
 */
export const XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH = Object.freeze({
  packageName: '@xterm/addon-webgl',
  packageVersion: '0.19.0',
  upstreamTag: '6.0.0',
  upstreamCommit: 'f447274f430fd22513f6adbf9862d19524471c04',
  upstreamSource: 'addons/addon-webgl/src/RectangleRenderer.ts',
  inputSha256: 'b85f8d4b3e9756bebb757e3fe47134d70f03ea3d6b187624426d2e2b65dec06c',
  target: AUDITED_BACKGROUND_READ,
  replacement: `u=${COLOR_ATTRIBUTE_MASK}&e.cells[c+n.RENDER_MODEL_BG_OFFSET]`
});

export function normalizeWebglBackgroundAttribute(attribute) {
  return attribute & COLOR_ATTRIBUTE_MASK;
}

export function applyXtermWebglDefaultBackgroundPatch(content, packageVersion) {
  const metadata = XTERM_WEBGL_DEFAULT_BACKGROUND_PATCH;
  if (packageVersion !== metadata.packageVersion) {
    throw new Error(
      `Expected ${metadata.packageName} ${metadata.packageVersion}, received ${packageVersion}. ` +
      'Review or remove the local WebGL default-background patch before upgrading.'
    );
  }

  const inputSha256 = createHash('sha256').update(content, 'utf8').digest('hex');
  if (inputSha256 !== metadata.inputSha256) {
    throw new Error(
      `Expected ${metadata.packageName} ${metadata.packageVersion} input SHA-256 ` +
      `${metadata.inputSha256}, received ${inputSha256}. Review the audited upstream asset.`
    );
  }

  const matches = content.split(metadata.target).length - 1;
  if (matches !== 1) {
    throw new Error(
      `Expected one audited RectangleRenderer background read, found ${matches}. ` +
      'Review the pinned upstream source before generating assets.'
    );
  }

  return content.replace(metadata.target, metadata.replacement);
}
