import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import './test-font-cell-width.mjs';
import { runTerminalSearchTests } from './test-terminal-search.mjs';
import '../../entry/src/main/resources/rawfile/terminal-policy.js';

const policy = globalThis.LeanTTYTerminalPolicy;
const encode = text => `c;${Buffer.from(text, 'utf8').toString('base64')}`;

const packageJson = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf8')
);
const packageLock = JSON.parse(
  readFileSync(new URL('./package-lock.json', import.meta.url), 'utf8')
);
assert.equal(packageLock.lockfileVersion, 3,
  'web terminal dependencies must keep the committed npm lockfile format');
assert.deepEqual(packageLock.packages[''].dependencies, packageJson.dependencies,
  'package.json dependencies must exactly match the lockfile root');
for (const [packageName, version] of Object.entries(packageJson.dependencies)) {
  assert.match(version, /^\d+\.\d+\.\d+$/,
    `${packageName} must use an exact dependency version`);
  const lockedPackage = packageLock.packages[`node_modules/${packageName}`];
  assert.ok(lockedPackage, `${packageName} must exist in package-lock.json`);
  assert.equal(lockedPackage.version, version,
    `${packageName} must resolve to its package.json version`);
  assert.equal(lockedPackage.license, 'MIT',
    `${packageName} must retain its audited MIT license metadata`);
  assert.match(lockedPackage.integrity, /^sha512-/,
    `${packageName} must retain an npm integrity hash`);
}

const assetManifest = JSON.parse(
  readFileSync(new URL('./assets-manifest.json', import.meta.url), 'utf8')
);
const assetPackages = {
  'xterm.js': '@xterm/xterm',
  'xterm.css': '@xterm/xterm',
  'addon-fit.js': '@xterm/addon-fit',
  'addon-search.js': '@xterm/addon-search',
  'addon-serialize.js': '@xterm/addon-serialize',
  'addon-web-links.js': '@xterm/addon-web-links',
  'addon-webgl.js': '@xterm/addon-webgl'
};
assert.deepEqual(
  assetManifest.map(asset => asset.file).sort(),
  Object.keys(assetPackages).sort(),
  'the asset manifest must contain exactly the locally packaged xterm resources'
);
const thirdPartyNotices = readFileSync(
  new URL('../../docs/THIRD_PARTY_NOTICES.md', import.meta.url), 'utf8'
);
for (const asset of assetManifest) {
  const checkedOutBytes = readFileSync(
    new URL(`../../entry/src/main/resources/rawfile/${asset.file}`, import.meta.url),
    'utf8'
  );
  const bytes = Buffer.from(checkedOutBytes.replace(/\r\n/g, '\n'), 'utf8');
  assert.equal(bytes.length, asset.bytes, `${asset.file} normalized byte count must match the asset manifest`);
  assert.equal(
    createHash('sha256').update(bytes).digest('hex'),
    asset.sha256,
    `${asset.file} hash must match the asset manifest`
  );
  const packageName = assetPackages[asset.file];
  assert.ok(thirdPartyNotices.includes(`\`${asset.file}\``),
    `${asset.file} must be listed in the third-party notices`);
  assert.ok(thirdPartyNotices.includes(`\`${packageName} ${packageJson.dependencies[packageName]}\``),
    `${asset.file} must cite its locked package version`);
  assert.ok(thirdPartyNotices.includes(`\`${asset.sha256.toUpperCase()}\``),
    `${asset.file} must cite its packaged SHA-256`);
}

const packagedTerminalHtml = readFileSync(
  new URL('../../entry/src/main/resources/rawfile/terminal.html', import.meta.url), 'utf8'
);
assert.doesNotMatch(packagedTerminalHtml,
  /(?:src|href)\s*=\s*["']https?:\/\//iu,
  'the terminal page must not load scripts or styles from online resources');
assert.doesNotMatch(packagedTerminalHtml,
  /\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|importScripts)\s*\(/u,
  'the terminal page must not fetch runtime resources from the network');

for (const text of ['', 'plain text', '中文 🚀\nsecond line']) {
  const decoded = policy.decodeOsc52(encode(text));
  assert.equal(decoded.accepted, true);
  assert.equal(decoded.text, text);
}
const tmuxSelection = 'copied by tmux';
const decodedTmuxSelection = policy.decodeOsc52(
  `;${Buffer.from(tmuxSelection, 'utf8').toString('base64')}`
);
assert.equal(decodedTmuxSelection.accepted, true);
assert.equal(decodedTmuxSelection.text, tmuxSelection);
assert.equal(policy.decodeOsc52('c;?').reason, 'read-not-supported');
assert.equal(policy.decodeOsc52('p;YQ==').reason, 'unsupported-target');
assert.equal(policy.decodeOsc52('c;%%%').reason, 'invalid-base64');
assert.equal(policy.decodeOsc52(`c;${'A'.repeat(policy.MAX_CLIPBOARD_BASE64_LENGTH + 4)}`).reason, 'encoded-too-large');

const bellAttention = policy.createBellAttentionGate();
let bellAttentionCount = 0;
for (let bellIndex = 0; bellIndex < 61271; bellIndex++) {
  if (bellAttention.trigger()) bellAttentionCount++;
}
assert.equal(bellAttentionCount, 1);
assert.equal(bellAttention.isPending(), true);
assert.equal(bellAttention.rearmDelivery(), true);
assert.equal(bellAttention.isPending(), true);
assert.equal(bellAttention.trigger(), true);
assert.equal(bellAttention.acknowledge(), true);
assert.equal(bellAttention.acknowledge(), false);
assert.equal(bellAttention.isPending(), false);
assert.equal(bellAttention.trigger(), true);

assert.equal(policy.countPerfPayloadBytes('XXX'), 3);
assert.equal(policy.countPerfPayloadBytes('XX\u001b[6nX\r\n'), 3);
assert.equal(policy.countPerfPayloadBytes('中文 🚀'), 0);

const wheel = policy.createWheelState();
policy.enqueueWheel(wheel, 4, 0, 16, 40, 0);
policy.enqueueWheel(wheel, 12, 0, 16, 40, 16);
assert.ok(policy.pendingWheelLines(wheel) < 1);
assert.equal(policy.consumeWheelFrame(wheel, 40), 0);

const separatedSlowWheel = policy.createWheelState();
policy.enqueueWheel(separatedSlowWheel, 12, 0, 16, 40, 0);
policy.enqueueWheel(separatedSlowWheel, 4, 0, 16, 40, 120);
assert.ok(policy.pendingWheelLines(separatedSlowWheel) < 1);
assert.equal(policy.consumeWheelFrame(separatedSlowWheel, 40), 0);

const fastWheel = policy.createWheelState();
policy.enqueueWheel(fastWheel, 80, 0, 16, 40, 0);
policy.enqueueWheel(fastWheel, 160, 0, 16, 40, 16);
assert.ok(policy.pendingWheelLines(fastWheel) > 100);
let fastTotal = 0;
let frameCount = 0;
while (policy.hasPendingWheelSteps(fastWheel)) {
  fastTotal += policy.consumeWheelFrame(fastWheel, 40);
  frameCount++;
  assert.ok(frameCount < 5);
}
assert.ok(fastTotal > 100);
assert.ok(frameCount > 1);

const reversedWheel = policy.createWheelState();
policy.enqueueWheel(reversedWheel, 320, 0, 16, 40, 0);
policy.enqueueWheel(reversedWheel, -32, 0, 16, 40, 16);
assert.ok(policy.pendingWheelLines(reversedWheel) < 0);
assert.ok(policy.consumeWheelFrame(reversedWheel, 40) < 0);

const mouseWheel = policy.createWheelState();
policy.enqueueWheel(mouseWheel, 3, 1, 16, 40, 0);
assert.equal(policy.pendingWheelLines(mouseWheel), 3);

assert.equal(policy.centerGridLeadingPadding(4, 4, 942, 926), 8);
assert.equal(policy.centerGridLeadingPadding(4, 4, 934, 926), 4);
assert.equal(policy.centerGridLeadingPadding(4, 4, 930, 926), 4);

const exactCtrl = {
  button: 0,
  ctrlKey: true,
  altKey: false,
  shiftKey: false,
  metaKey: false
};
const exactCtrlShift = {
  ...exactCtrl,
  shiftKey: true
};
assert.equal(policy.isLinkModifierActive(exactCtrl, 'none'), true);
assert.equal(policy.isLinkModifierActive(exactCtrlShift, 'none'), false);
assert.equal(policy.isLinkModifierActive({ ...exactCtrl, metaKey: true }, 'none'), false);
assert.equal(policy.isLinkModifierActive(exactCtrlShift, 'sgr'), false,
  'mouse encoding names must not be mistaken for xterm mouse tracking modes');
for (const mouseTrackingMode of ['x10', 'vt200', 'drag', 'any']) {
  assert.equal(policy.isLinkModifierActive(exactCtrl, mouseTrackingMode), false,
    `Ctrl alone must remain owned by ${mouseTrackingMode} mouse reporting`);
  assert.equal(policy.isLinkModifierActive(exactCtrlShift, mouseTrackingMode), true,
    `Ctrl+Shift must activate links while Shift bypasses ${mouseTrackingMode} mouse reporting`);
  assert.equal(policy.isLinkModifierActive(
    { ...exactCtrlShift, altKey: true }, mouseTrackingMode), false);
  assert.equal(policy.isLinkModifierActive(
    { ...exactCtrlShift, metaKey: true }, mouseTrackingMode), false);
  assert.equal(policy.shouldActivateLink(
    exactCtrlShift, mouseTrackingMode, true, false), true);
  assert.equal(policy.shouldActivateLink(
    exactCtrlShift, mouseTrackingMode, true, true), false);
}
assert.equal(policy.shouldActivateLink(exactCtrl, 'none', true, false), true);
assert.equal(policy.shouldActivateLink({ ...exactCtrl, button: 1 }, 'none', true, false), false);
assert.equal(policy.shouldActivateLink(exactCtrl, 'none', false, false), false);
assert.equal(policy.shouldActivateLink(exactCtrl, 'none', true, true), false);
assert.equal(policy.shouldRunTerminalSecondaryAction(false), true);
assert.equal(policy.shouldRunTerminalSecondaryAction(true), false,
  'an open search must own secondary clicks until terminal mousedown closes it');
assert.equal(policy.searchResultLabel('', -1, 0, 1000), '0/0');
assert.equal(policy.searchResultLabel('missing', -1, 0, 1000), '0/0');
assert.equal(policy.searchResultLabel('match', 0, 2, 1000), '1/2');
assert.equal(policy.searchResultLabel('match', 1, 2, 1000), '2/2');
assert.equal(policy.searchResultLabel('match', -1, 7, 1000), '0/7');
assert.equal(policy.searchResultLabel('match', -1, 1000, 1000), '1000+');
assert.equal(policy.wrappedControlIndex(0, 4, false), 1);
assert.equal(policy.wrappedControlIndex(3, 4, false), 0);
assert.equal(policy.wrappedControlIndex(0, 4, true), 3);

const terminalHtml = readFileSync(new URL('../../entry/src/main/resources/rawfile/terminal.html', import.meta.url), 'utf8');
assert.match(terminalHtml,
  /fontFamily:\s*"'JetBrains Mono Nerd Font Mono', 'HarmonyOS Sans Mono', monospace"/,
  'xterm must use the single-cell Nerd Font Mono variant before system fallbacks');
assert.match(terminalHtml,
  /url\('JetBrainsMonoNerdFontMono-Regular\.ttf'\)[\s\S]*url\('JetBrainsMonoNerdFontMono-Bold\.ttf'\)/,
  'the embedded regular and bold faces must both use single-cell Nerd Font Mono assets');
assert.doesNotMatch(terminalHtml, /JetBrainsMonoNerdFont-(?:Regular|Bold)\.ttf/,
  'the double-width Nerd Font assets must not return to the terminal font face');
assert.match(terminalHtml, /addEventListener\('wheel', handleAlternateWheel, true\)/,
  'alternate-buffer wheel handling must run during capture before xterm scrolls its inner viewport');
assert.match(terminalHtml, /#terminal-container > \.xterm\s*\{[^}]*padding:\s*4px 2px 4px 10px;/s,
  'terminal padding must offset the scrollbar gutter without changing the total horizontal inset');
assert.match(terminalHtml, /function fitAndCenterTerminalGrid\(\)/,
  'terminal fitting must redistribute unused cell-grid height instead of leaving it all below the grid');
assert.match(terminalHtml,
  /centerGridLeadingPadding\(\s*TERMINAL_BASE_PADDING_TOP,\s*TERMINAL_BASE_PADDING_BOTTOM,/s,
  'terminal fitting must center rows with the tested layout policy');
assert.match(terminalHtml, /var TERMINAL_SCROLLBAR_WIDTH = 8;/,
  'the auto-hiding scrollbar must reserve less than one default terminal cell');
assert.match(terminalHtml, /overviewRuler:\s*\{\s*width:\s*TERMINAL_SCROLLBAR_WIDTH\s*\}/,
  'xterm and FitAddon must share the slim scrollbar width');
assert.match(terminalHtml,
  /\.xterm \.xterm-scrollable-element > \.scrollbar\.vertical > \.slider\s*\{[^}]*border:\s*2px solid transparent;[^}]*background-clip:\s*content-box !important;/s,
  'the scrollbar must keep an eight-pixel hit target with a compact visible thumb');
assert.match(terminalHtml,
  /html, body,[^}]*#terminal-container,[^}]*#terminal-container > \.xterm,[^}]*\.xterm \.xterm-viewport\s*\{[^}]*background(?:-color)?:\s*transparent/s,
  'terminal padding and leftover cell space must expose the single ArkUI surface background');
assert.match(terminalHtml, /document\.documentElement\.style\.setProperty\('--terminal-background', themeObj\.background\)/,
  'theme changes must propagate their background to the Web terminal chrome');
assert.match(terminalHtml,
  /LeanTTYCellBackgroundOpacity = Number\.isFinite\(requestedCellBackgroundOpacity\)[\s\S]*Math\.max\(0, Math\.min\(1, requestedCellBackgroundOpacity\)\)/,
  'theme changes must clamp the renderer-only cell-background opacity');
assert.match(terminalHtml, /delete themeObj\.cellBackgroundOpacity/,
  'LeanTTY renderer metadata must not leak into the upstream xterm theme');
const packagedWebglAddon = readFileSync(
  new URL('../../entry/src/main/resources/rawfile/addon-webgl.js', import.meta.url), 'utf8'
);
assert.match(packagedWebglAddon,
  /globalThis\.LeanTTYCellBackgroundOpacity\?\?1/,
  'the packaged WebGL renderer must use LeanTTY cell-background opacity');
assert.doesNotMatch(packagedWebglAddon,
  /f=\(h>>8&255\)\/255,g=1,this\._addRectangle/,
  'the pinned WebGL renderer must not force explicit cell backgrounds opaque');
assert.match(terminalHtml, /themeObj\.overviewRulerBorder = themeObj\.background/,
  'the width-only overview ruler must not draw a contrasting edge line');
assert.match(terminalHtml,
  /\.xterm\.secure-input \.xterm-helper-textarea\s*\{[^}]*-webkit-text-security:\s*disc;/s,
  'the xterm helper must visually mask only the typed secure-input state');
assert.match(terminalHtml,
  /case 'inputSecurity':[\s\S]*message\.payload !== 'plain'[\s\S]*message\.payload !== 'masked'[\s\S]*classList\.toggle\('secure-input', secureInput\)/,
  'the web terminal must apply masking only for typed secure-input state');
assert.match(terminalHtml,
  /kind === 'inputSecurity' && \(payload === 'plain' \|\| payload === 'masked'\)/,
  'the web-side native-message allowlist must admit only closed input-security payloads');
assert.match(terminalHtml,
  /term\.onKey\(function\(\)[\s\S]*scheduleSecureInputClear\(\)[\s\S]*function scheduleSecureInputClear\(\)[\s\S]*setTimeout\(function\(\)[\s\S]*term\.textarea\.value = ''[\s\S]*\}, 100\)/,
  'secret helper values must be cleared after xterm has emitted the corresponding key event');
assert.match(terminalHtml, /parseTerminalPacket\(e\.data\)/,
  'the MessagePort must accept the original binary terminal packet directly');
assert.doesNotMatch(terminalHtml, /leanttyOutput\.pullOutput|decodePulledTerminalPacket|case 'outputAvailable':/,
  'the rejected synchronous Base64 pull experiment must not remain in the terminal path');
assert.match(terminalHtml, /term\.write\(terminalBytes/,
  'the terminal must receive the original Uint8Array bytes rather than a decoded string');
assert.doesNotMatch(terminalHtml,
  /outputBurst|validationMarker|LTTY_(?:BEGIN|END|KEY)_|samplePortDelivery|TERMINAL_RENDERER_MODE/,
  'temporary binary-output and renderer diagnostics must not remain in the terminal runtime');
assert.doesNotMatch(terminalHtml, /replayGate|replayBegin|replayEnd/,
  'the removed raw terminal-history replay protocol must not return');
assert.match(terminalHtml, /<script src="addon-serialize\.js"><\/script>/,
  'the terminal page must load the pinned xterm serialization addon');
assert.match(terminalHtml, /<script src="addon-search\.js"><\/script>/,
  'the terminal page must load the pinned xterm search addon locally');
assert.match(terminalHtml, /id="search-panel"[\s\S]*id="search-input"[\s\S]*id="search-previous"[\s\S]*id="search-next"[\s\S]*id="search-close"/,
  'the terminal surface must own one compact keyboard-search control set');
assert.match(terminalHtml,
  /new SearchAddon\.SearchAddon\(\{ highlightLimit: SEARCH_HIGHLIGHT_LIMIT \}\)[\s\S]*term\.loadAddon\(searchAddon\)/,
  'the current xterm instance must own the bounded official search addon');
assert.match(terminalHtml,
  /regex:\s*false,[\s\S]*wholeWord:\s*false,[\s\S]*caseSensitive:\s*false,[\s\S]*decorations:/,
  'search must use the frozen literal case-insensitive decorated matching options');
assert.match(terminalHtml,
  /compositionstart[\s\S]*searchComposing = true[\s\S]*compositionend[\s\S]*searchComposing = false[\s\S]*runSearch/,
  'IME composition must defer search until committed text is available');
const searchUiStart = terminalHtml.indexOf('function initializeSearchUi()');
const searchUiEnd = terminalHtml.indexOf('function serializeTerminalSnapshot', searchUiStart);
assert.ok(searchUiStart >= 0 && searchUiEnd > searchUiStart,
  'the local search UI initialization body must remain identifiable');
const searchUiBody = terminalHtml.slice(searchUiStart, searchUiEnd);
assert.match(searchUiBody, /input\.addEventListener\('input',[\s\S]*?runSearch\(false, true\)/,
  'committed query input must stay inside the current web terminal search state');
assert.doesNotMatch(searchUiBody, /sendBridgeData|term\.(?:input|paste|write)/,
  'query text and search navigation must never enter the SSH terminal-input bridge');
const searchUiControlKinds = Array.from(
  searchUiBody.matchAll(/sendBridgeControl\('([^']+)'/g), match => match[1]);
assert.deepEqual(Array.from(new Set(searchUiControlKinds)), ['searchState'],
  'search UI may expose only its bounded ownership and composition state');
assert.match(terminalHtml,
  /function closeSearch\(restoreTerminalFocus\)[\s\S]*searchAddon\.clearDecorations\(\)[\s\S]*term\.focus\(\)/,
  'closing search must clear short-lived decorations and optionally restore terminal focus');
assert.match(terminalHtml,
  /var searchOwnsSelection = false;[\s\S]*function closeSearch\(restoreTerminalFocus\)[\s\S]*if \(searchOwnsSelection && term\) term\.clearSelection\(\);/,
  'closing a non-empty search must release only the selection owned by its active match');
assert.doesNotMatch(terminalHtml, /term\.scrollToTop\(\)/,
  'search must not pre-scroll the viewport before the addon locates the first match');
assert.match(terminalHtml,
  /terminalContainer\.addEventListener\('mousedown', function\(event\) \{[\s\S]*?panel\.contains\(event\.target\)[\s\S]*?if \(isSearchOpen\(\)\) closeSearch\(false\);[\s\S]*?true\);/,
  'terminal pointer interaction must release search-owned selection before normal selection, links, or mouse reporting');
const searchPointerRelease = terminalHtml.indexOf("terminalContainer.addEventListener('mousedown', function(event) {");
const existingPointerDispatch = terminalHtml.indexOf(
  "terminalContainer.addEventListener('mousedown', beginLinkClick, true);");
assert.ok(searchPointerRelease >= 0 && searchPointerRelease < existingPointerDispatch,
  'search selection release must run before the existing terminal pointer handlers');
const searchPointerReleaseBody = terminalHtml.slice(searchPointerRelease, existingPointerDispatch);
assert.doesNotMatch(searchPointerReleaseBody, /preventDefault|stopPropagation|stopImmediatePropagation/,
  'search selection release must not consume the pointer event');
assert.match(searchPointerReleaseBody,
  /var panel = searchElement\('search-panel'\);[\s\S]*?panel\.contains\(event\.target\)[\s\S]*?return;/,
  'search controls must remain interactive instead of being treated as terminal pointer input');
assert.match(terminalHtml,
  /function applyTerminalTheme\(themeObj\)[\s\S]*?if \(isSearchOpen\(\)\) closeSearch\(true\);/,
  'theme changes must close short-lived search state before replacing decoration colors');
assert.match(terminalHtml,
  /function handleSecondaryAction\(\)[\s\S]*?shouldRunTerminalSecondaryAction\(isSearchOpen\(\)\)[\s\S]*?copyTerminalSelection\(\)/,
  'secondary action must not copy or paste terminal content while search owns the Surface');
assert.match(terminalHtml,
  /var key = typeof event\.key === 'string' \? event\.key\.toLowerCase\(\) : '';[\s\S]*?var code = typeof event\.code === 'string' \? event\.code : '';[\s\S]*?key === 'v' \|\| code === 'KeyV'[\s\S]*?key !== 'c' && code !== 'KeyC'/,
  'Ctrl+C and Ctrl+V must recognize the standard physical-key code when ArkWeb reports an unidentified key');
assert.match(terminalHtml,
  /window\.addEventListener\('copy', handleTerminalCopy, true\);[\s\S]*?function handleTerminalCopy\(event\) \{[\s\S]*?if \(isSearchOpen\(\)\) return;[\s\S]*?if \(copyTerminalSelection\(\)\) \{[\s\S]*?event\.preventDefault\(\);[\s\S]*?event\.stopPropagation\(\);/,
  'ArkWeb browser-level copy events must copy xterm-owned selection without stealing search-input copy');
assert.match(terminalHtml,
  /kind === 'copyOrInterrupt' && payload\.length === 0[\s\S]*?case 'copyOrInterrupt':[\s\S]*?handleCopyOrInterrupt\(\)[\s\S]*?function handleCopyOrInterrupt\(\)[\s\S]*?copySearchInputSelection\(\)[\s\S]*?copyTerminalSelection\(\)[\s\S]*?sendBridgeData\('terminal', '\\x03'\)/,
  'typed native Ctrl+C routing must copy search or terminal selection before falling back to ETX');
assert.match(terminalHtml,
  /var payload = raw\.substring\(kindEnd \+ 1\);[\s\S]*?!isSupportedNativeMessage\(channel, kind, payload\)/,
  'the web-side bridge parser must validate each native control payload before dispatch');
assert.match(terminalHtml,
  /function isSupportedNativeMessage\(channel, kind, payload\)[\s\S]*?kind === 'searchOpen' \|\| kind === 'searchClose'[\s\S]*?payload\.length === 0/,
  'search open and close must be accepted by the web-side allowlist only with empty payloads');
assert.match(terminalHtml, /term\.buffer\.onBufferChange\(function\(\) \{ closeSearch\(true\); \}\)/,
  'normal and alternate buffer switches must close the local search state');
assert.match(terminalHtml,
  /function openSearch\(\)[\s\S]*?sendBridgeControl\('searchState', 'open'\)[\s\S]*?function closeSearch[\s\S]*?sendBridgeControl\('searchState', 'closed'\)[\s\S]*?compositionstart[\s\S]*?sendBridgeControl\('searchState', 'composing'\)/,
  'the terminal surface must report only its bounded open, composing, or closed search state');
assert.doesNotMatch(terminalHtml, /sendBridgeControl\('search(?:Query|Result)'/,
  'query text and result details must never leave the Terminal Surface');
assert.match(terminalHtml, /serializeAddon = new SerializeAddon\.SerializeAddon\(\)/,
  'terminal recovery checkpoints must use xterm framebuffer serialization');
assert.match(terminalHtml,
  /term\._core\.coreService\.isCursorHidden[\s\S]*?snapshot \+= '\\x1b\[\?25l'/,
  'terminal recovery checkpoints must preserve hidden cursor state');
assert.match(terminalHtml,
  /function requestTerminalSnapshot[\s\S]*?term\.write\('',[\s\S]*?serializeTerminalSnapshot/,
  'snapshot capture must wait for all queued terminal writes to finish');
assert.match(terminalHtml,
  /var scrollback = 0[\s\S]*?snapshot\.length > availableLength[\s\S]*?return bestSnapshot[\s\S]*?Math\.min\(scrollback \* 2, TERMINAL_SCROLLBACK_LINES\)/,
  'checkpoint allocation must grow from the visible screen instead of serializing all scrollback first');
assert.doesNotMatch(terminalHtml, /scrollback = Math\.floor\(scrollback \/ 2\)/,
  'checkpoint bounding must not allocate full scrollback before shrinking');
assert.match(terminalHtml,
  /pendingSnapshotRequestIds\.push[\s\S]*?snapshotCapturePending[\s\S]*?for \(var j = 0; j < requestIds\.length; j\+\+\)/,
  'concurrent checkpoint requests must share one serialized framebuffer');
assert.match(terminalHtml,
  /return bestSnapshot[\s\S]*?if \(snapshot !== null\)[\s\S]*?sendBridgeControl\('snapshot'/,
  'a failed checkpoint must time out without erasing the last successful snapshot');
const snapshotSerializerSource = terminalHtml.match(
  /(function serializeTerminalSnapshot\(availableLength\) \{[\s\S]*?\n    \})\n\n    function requestTerminalSnapshot/);
assert.ok(snapshotSerializerSource,
  'the bounded snapshot serializer must remain executable in the regression harness');
const attemptedScrollbacks = [];
globalThis.TERMINAL_SCROLLBACK_LINES = 10000;
globalThis.term = null;
globalThis.serializeAddon = {
  serialize: ({ scrollback }) => {
    attemptedScrollbacks.push(scrollback);
    return 'x'.repeat(scrollback === 0 ? 100 : scrollback * 2);
  }
};
vm.runInThisContext(snapshotSerializerSource[1]);
const boundedSnapshot = globalThis.serializeTerminalSnapshot(4096);
assert.equal(boundedSnapshot.length, 4096,
  'the snapshot budget must retain the largest successful candidate');
assert.deepEqual(attemptedScrollbacks, [0, 64, 128, 256, 512, 1024, 2048, 4096],
  'snapshot work must grow from the visible screen and stop after one over-budget candidate');
assert.match(terminalHtml,
  /case 'restoreSnapshot':[\s\S]*?restoringSnapshot = true[\s\S]*?restoringSnapshot = false[\s\S]*?sendBridgeControl\('restoreComplete'[\s\S]*?term\.write\(message\.payload, completeRestore\)/,
  'a replacement xterm instance must suppress generated input until restoration completes');
assert.match(terminalHtml,
  /term\.onData\(function\(data\)[\s\S]*?if \(!restoringSnapshot\)[\s\S]*?sendBridgeData\('terminal', data\)/,
  'checkpoint mode restoration must not inject generated input into SSH');
assert.doesNotMatch(terminalHtml, /releaseBuffers|term\.clear\(\)|term\.reset\(\)/,
  'normal disconnect cleanup must not clear the current xterm screen or scrollback');
assert.match(terminalHtml, /term\.onBell\s*\(/,
  'xterm must remain the semantic source for terminal bell events');
assert.match(terminalHtml,
  /term\.onKey\s*\(function\(\)\s*\{\s*acknowledgeBellAttention\(\);/s,
  'the first real keyboard input after BEL must acknowledge the owning pane');
assert.match(terminalHtml,
  /term\.textarea\.addEventListener\('compositionstart',[\s\S]*acknowledgeBellAttention\(\);[\s\S]*term\.textarea\.addEventListener\('input',[\s\S]*acknowledgeBellAttention\(\);[\s\S]*term\.textarea\.addEventListener\('paste', acknowledgeBellAttention\);/s,
  'IME composition, ArkWeb text input, and browser paste must acknowledge the owning pane');
assert.match(terminalHtml,
  /if \(text\.length > 0 && term\) \{\s*acknowledgeBellAttention\(\);\s*term\.paste\(text\);/s,
  'a user paste after BEL must acknowledge the owning pane');
assert.doesNotMatch(terminalHtml,
  /term\.onData\s*\(function\(data\)\s*\{[^}]*acknowledgeBellAttention/s,
  'terminal-generated query responses must not acknowledge pane attention');
assert.match(terminalHtml,
  /case 'focus':[\s\S]*?bellAttentionGate\.rearmDelivery\(\);[\s\S]*?term\.focus\(\);/s,
  'programmatic focus must rearm BEL delivery without acknowledging pane attention');
assert.match(terminalHtml,
  /term\.onBell\s*\(function\(\)\s*\{\s*if\s*\(bellAttentionGate\.trigger\(\)\)\s*\{\s*sendBridgeControl\('bellAttention', ''\)/s,
  'a BEL flood must cross the bridge only after the source-side attention gate accepts it');
assert.doesNotMatch(terminalHtml, /term\.onBell\s*\(function\(\)\s*\{\s*sendBridgeControl\('bellAttention'/s,
  'bell attention must never be sent directly for every parsed BEL');
assert.match(terminalHtml, /term\.onTitleChange\s*\(/,
  'the local performance-marker parser must continue to observe title sequences');
assert.doesNotMatch(terminalHtml, /sendBridgeControl\('title'/,
  'ordinary remote title changes must not cross the bridge when the product does not consume them');
assert.match(terminalHtml, /new WebLinksAddon\.WebLinksAddon\(/,
  'plain HTTP(S) text must use the xterm web-links provider');
assert.match(terminalHtml, /linkHandler:\s*\{[\s\S]*?activate:/,
  'OSC 8 links must use the same native-system activation path as plain links');
assert.match(terminalHtml,
  /shouldActivateLink\([\s\S]*?currentMouseTrackingMode\(\)[\s\S]*?sendBridgeControl\('openUrl', url\)/s,
  'URL activation must use the tested modifier policy, primary click, same link, and no drag');
assert.match(terminalHtml,
  /ctrlKey:\s*linkModifierState\.ctrlKey,[\s\S]*?shiftKey:\s*linkModifierState\.shiftKey/,
  'stationary link feedback must retain both Ctrl and Shift state for mouse-reporting mode changes');
const linkActivationBody = terminalHtml.match(
  /function activateTerminalLink\(event, url\)\s*\{([\s\S]*?)\n    \}/
);
assert.ok(linkActivationBody, 'the shared terminal link activation callback must exist');
assert.doesNotMatch(linkActivationBody[1], /event\.stopPropagation\(\)/,
  'link mouseup must reach xterm document listeners so text-selection drag state is released');
assert.match(terminalHtml, /setCurrentLinkDecorations\(linkModifierActive\)/,
  'pressing or releasing required modifiers while stationary must update the hovered link immediately');
assert.match(terminalHtml, /id="link-preview"/,
  'modifier-hover must expose the real target of an OSC 8 link before opening it');
assert.doesNotMatch(terminalHtml, /window\.open|location\.(?:href|assign|replace)/,
  'the terminal page must never bypass the typed native browser bridge');

const xtermJs = readFileSync(
  new URL('../../entry/src/main/resources/rawfile/xterm.js', import.meta.url), 'utf8');
assert.match(xtermJs,
  /get currentLink\(\)[\s\S]*?Object\.defineProperties\([^)]*decorations[\s\S]*?pointerCursor[\s\S]*?underline/,
  'the pinned xterm build must retain the decoration adapter used for modifier-only link feedback');
assert.match(xtermJs,
  /shouldForceSelection\(e\)\{return [^}]*:e\.shiftKey\}/,
  'the pinned xterm build must retain Shift as the local mouse-reporting bypass');
assert.match(xtermJs,
  /areMouseEventsActive&&!this\._selectionService\.shouldForceSelection\(e\)/,
  'xterm must test the Shift bypass before forwarding mouse events to tmux or another TUI');

const addonSerialize = readFileSync(
  new URL('../../entry/src/main/resources/rawfile/addon-serialize.js', import.meta.url), 'utf8');
assert.match(addonSerialize, /SerializeAddon/,
  'the packaged serialization addon must expose the framebuffer checkpoint implementation');
globalThis.self = globalThis;
vm.runInThisContext(xtermJs);
vm.runInThisContext(addonSerialize);
const sourceTerminal = new globalThis.Terminal({ cols: 20, rows: 4, scrollback: 20 });
const sourceSerializer = new globalThis.SerializeAddon.SerializeAddon();
sourceTerminal.loadAddon(sourceSerializer);
sourceTerminal.write('first\r\n');
sourceTerminal.write('second\r\n');
sourceTerminal.write('third\r\n');
sourceTerminal.write('fourth\r\n');
sourceTerminal.write('fifth\r\n');
sourceTerminal.write('\u001b]0;checkpoint-title\u0007');
sourceTerminal.write('\u001b]52;c;Y2hlY2twb2ludA==\u0007');
sourceTerminal.write('\u001b[31msixth\u001b[0m\u001b[?25l\u001b[?1004h');
await new Promise(resolve => {
  sourceTerminal.write('', resolve);
});
const cursorVisibility = sourceTerminal._core.coreService.isCursorHidden ? '\u001b[?25l' : '';
const serializedSnapshot = sourceSerializer.serialize({ scrollback: 20 }) + cursorVisibility;
assert.doesNotMatch(serializedSnapshot, /\u0007|\u001b\]0;|\u001b\]52;/,
  'framebuffer checkpoints must not retain title, clipboard, or bell side effects');
assert.match(serializedSnapshot, /\u001b\[\?1004h/,
  'the focus-reporting fixture must exercise serializer mode restoration');
const restoredTerminal = new globalThis.Terminal({ cols: 20, rows: 4, scrollback: 20 });
const restoredSerializer = new globalThis.SerializeAddon.SerializeAddon();
restoredTerminal.loadAddon(restoredSerializer);
const forwardedRestoreData = [];
let restoringCheckpoint = true;
restoredTerminal.onData(data => {
  if (!restoringCheckpoint) forwardedRestoreData.push(data);
});
await new Promise(resolve => {
  restoredTerminal.write(serializedSnapshot, () => {
    restoringCheckpoint = false;
    resolve();
  });
});
assert.equal(forwardedRestoreData.length, 0,
  'restoring focus-reporting mode must not emit synthetic input to native');
assert.equal(restoredTerminal._core.coreService.isCursorHidden, true,
  'serialized recovery must preserve hidden cursor state');
await new Promise(resolve => {
  restoredTerminal.write('\u001b[?1004l\u001b[?1004h', resolve);
});
assert.equal(forwardedRestoreData.length, 1,
  'focus reporting must resume after the restore-complete boundary');
await new Promise(resolve => {
  restoredTerminal.write('\r\ndetached-output', resolve);
});
const restoredSnapshot = restoredSerializer.serialize();
assert.match(restoredSnapshot, /first/,
  'serialized recovery must restore lines that have moved into scrollback');
assert.match(restoredSnapshot, /\u001b\[31msixth/,
  'serialized recovery must restore styled terminal content');
assert.equal(restoredSnapshot.match(/detached-output/g)?.length, 1,
  'output produced after the checkpoint must follow restored content exactly once');

const addonSearch = readFileSync(
  new URL('../../entry/src/main/resources/rawfile/addon-search.js', import.meta.url), 'utf8');
vm.runInThisContext(addonSearch);
assert.match(addonSearch,
  /clearDecorations\(e\)\{[\s\S]*?clearHighlightDecorations\(\)[\s\S]*?clearResults\(\)[\s\S]*?clearCachedTerm\(\)/,
  'the pinned addon must expose decoration cleanup separately from xterm selection ownership');
assert.match(addonSearch,
  /_selectResult\(e,t,s\)[\s\S]*?this\._terminal\.select\(e\.col,e\.row,e\.size\)/,
  'the pinned addon active match must continue to use xterm selection');
const searchTerminal = new globalThis.Terminal({
  cols: 24,
  rows: 4,
  scrollback: 20,
  allowProposedApi: true
});
const searchAddon = new globalThis.SearchAddon.SearchAddon({ highlightLimit: 1000 });
searchTerminal.loadAddon(searchAddon);
assert.equal(typeof searchAddon.findNext, 'function');
assert.equal(typeof searchAddon.findPrevious, 'function');
assert.equal(typeof searchAddon.clearDecorations, 'function');
assert.equal(typeof searchAddon.onDidChangeResults, 'function');
const searchMarker = searchTerminal.registerMarker(0);
assert.doesNotThrow(() => {
  searchTerminal.registerDecoration({
    marker: searchMarker,
    width: 1,
    backgroundColor: '#585B70'
  });
}, 'the pinned terminal option must unlock the official addon decoration path');
await runTerminalSearchTests(globalThis.Terminal, globalThis.SearchAddon.SearchAddon);

const terminalBridge = readFileSync(
  new URL('../../entry/src/main/ets/model/bridge/TerminalBridge.ets', import.meta.url), 'utf8');
assert.match(terminalBridge,
  /awaitingRestoreComplete[\s\S]*?KIND_RESTORE_COMPLETE[\s\S]*?notifyReadyHandler/,
  'native focus and ready handling must wait for the web restore acknowledgement');
assert.match(terminalBridge,
  /pendingSearchOpen[\s\S]*private pumpSearchOpen[\s\S]*!this\.ready \|\| this\.awaitingRestoreComplete[\s\S]*BridgeProtocol\.searchOpen\(\)/,
  'search open must wait for the current bridge and framebuffer restore boundary');
assert.match(terminalBridge,
  /closeSearch\(\): void \{[\s\S]*?this\.pendingSearchOpen = false[\s\S]*?BridgeProtocol\.searchClose\(\)/,
  'search close must cancel a pending open and cross the current typed bridge');
assert.match(terminalBridge,
  /blur\(\): void \{\s*this\.pendingSearchOpen = false\s*this\.send\(BridgeProtocol\.blur\(\)\)/,
  'pane or tab blur must cancel a search-open intent queued behind bridge readiness or restore');
assert.match(terminalBridge,
  /setInputMasked\(masked: boolean\)[\s\S]*BridgeProtocol\.inputSecurity\(masked\)/,
  'the native bridge must carry the current helper-input security mode');
assert.match(terminalBridge,
  /copyOrInterrupt\(\): void \{[\s\S]*BridgeProtocol\.copyOrInterrupt\(\)/,
  'the native bridge must expose the typed pre-IME Ctrl+C action');
assert.match(terminalBridge,
  /destroy\(\): void \{[\s\S]*?this\.msgPort\.close\(\)[\s\S]*?this\.onMessageHandler = null[\s\S]*?this\.pendingSearchOpen = false/,
  'destroying an old surface bridge must close its port, remove callbacks, and discard a late search intent');
assert.match(terminalBridge,
  /private pumpSnapshotRequests[\s\S]*?pendingDataHead < this\.pendingData\.length \|\| this\.inFlightMessages > 0/,
  'a checkpoint request must wait until all earlier terminal output is acknowledged');
assert.match(terminalBridge, /postMessageEvent\(packet\.buffer\)/,
  'terminal output must use one raw binary WebMessagePort push path');
assert.match(terminalBridge, /BINARY_HEADER_BYTES:\s*number = 12/,
  'terminal packets must carry only magic, sequence, and payload length');
assert.match(terminalBridge, /inFlightMessages < TerminalBridge\.MAX_IN_FLIGHT_MESSAGES/,
  'normal output must leave queued data in the bridge while xterm drains its bounded pipeline');
assert.doesNotMatch(terminalBridge, /Base64Helper|pullOutput|outputAvailable/,
  'terminal output must not retain the rejected Base64 pull transport');
assert.doesNotMatch(terminalBridge, /TextDecoder|LOSSY_OUTPUT_CHUNK_CHARACTERS/,
  'the native terminal transport must not decode or heuristically rewrite terminal bytes');
assert.doesNotMatch(terminalBridge, /LTTY_(?:BEGIN|END|KEY)_|scanValidationMarkers|sentAtLow32/,
  'temporary cross-layer marker and delivery-timestamp diagnostics must not remain in the bridge');
assert.doesNotMatch(terminalBridge, /replay/i,
  'the bridge must have only one ordered output path and no historical replay state');

const bridgeProtocol = readFileSync(
  new URL('../../entry/src/main/ets/model/bridge/BridgeProtocol.ets', import.meta.url), 'utf8');
assert.match(bridgeProtocol, /KIND_BELL_ATTENTION/,
  'the bridge allowlist must name the coalesced attention state rather than a raw BEL event');
assert.doesNotMatch(bridgeProtocol, /KIND_BELL\b|KIND_TITLE\b/,
  'the bridge allowlist must not restore raw bell or remote-title messages');
assert.doesNotMatch(bridgeProtocol, /replay/i,
  'historical replay must not remain in the bridge protocol allowlist');
assert.doesNotMatch(bridgeProtocol, /releaseBuffers|KIND_RELEASE_BUFFERS/,
  'disconnect cleanup must not expose a bridge command that clears a live terminal surface');
assert.match(bridgeProtocol, /KIND_OPEN_URL:\s*string = 'openUrl'/,
  'browser requests must cross the typed web-to-native control allowlist');
assert.match(bridgeProtocol,
  /KIND_SEARCH_OPEN:\s*string = 'searchOpen'[\s\S]*kind === BridgeProtocol\.KIND_SEARCH_OPEN && payload\.length > 0/,
  'search open must be a typed native-to-web control with an empty payload');
assert.match(bridgeProtocol,
  /KIND_SEARCH_CLOSE:\s*string = 'searchClose'[\s\S]*KIND_SEARCH_STATE:\s*string = 'searchState'[\s\S]*KIND_SEARCH_STATE && payload !== 'open'[\s\S]*?payload !== 'composing' && payload !== 'closed'/,
  'search close and its bounded open, composing, or closed state must use the typed bridge allowlist');

const terminalSurface = readFileSync(
  new URL('../../entry/src/main/ets/model/terminal/TerminalSurfaceController.ets', import.meta.url), 'utf8');
assert.match(terminalSurface,
  /isSearchOpen\(\): boolean[\s\S]*?isSearchComposing\(\): boolean[\s\S]*?closeSearch\(\): void[\s\S]*?bridge\.closeSearch\(\)[\s\S]*?KIND_SEARCH_STATE[\s\S]*?msg\.payload !== 'closed'[\s\S]*?msg\.payload === 'composing'/,
  'the native terminal surface must track web search and composition ownership and expose a bounded close action');

const terminalSearchIndexPage = readFileSync(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
assert.match(terminalSearchIndexPage,
  /event\.keyCode === 2070[\s\S]*?activeRuntime\.surface\.isSearchOpen\(\)[\s\S]*?!activeRuntime\.surface\.isSearchComposing\(\)[\s\S]*?activeRuntime\.surface\.closeSearch\(\)/,
  'physical Escape must close active web search without stealing an IME composition escape');
assert.match(bridgeProtocol,
  /KIND_INPUT_SECURITY:\s*string = 'inputSecurity'[\s\S]*payload !== 'plain' && payload !== 'masked'/,
  'input security must be a typed native-to-web control with a closed payload set');
assert.match(bridgeProtocol,
  /KIND_COPY_OR_INTERRUPT:\s*string = 'copyOrInterrupt'[\s\S]*KIND_COPY_OR_INTERRUPT && payload\.length > 0[\s\S]*copyOrInterrupt\(\): BridgeMessage/,
  'copy-or-interrupt must be a typed empty-payload native-to-web control');

const sessionViewModel = readFileSync(
  new URL('../../entry/src/main/ets/viewmodel/SessionViewModel.ets', import.meta.url), 'utf8');
assert.doesNotMatch(sessionViewModel, /KIND_BELL_ATTENTION|case BridgeProtocol\.KIND_(?:BELL|TITLE)\b/,
  'bell attention belongs to the terminal surface and app shell, not the SSH session');
assert.match(sessionViewModel,
  /private onSshClose[\s\S]*?releaseDisconnectedFlowControl\(\)[\s\S]*?writeTerminal\([\s\S]*?writePrompt\(\)/,
  'disconnect cleanup must release output flow control before appending the local close message and prompt');
assert.match(sessionViewModel,
  /if \(parsed === null\) \{\s*this\.writeError\("Unknown command\. Type 'help' for commands, or use: ssh user@host"\)/,
  'unknown idle commands must point to both local help and the direct SSH path');
assert.match(sessionViewModel,
  /private setMode[\s\S]*setInputMasked\(SessionViewModel\.isSecretInputMode\(newMode\)\)[\s\S]*PASSWORD_INPUT[\s\S]*KEY_PASSPHRASE_INPUT[\s\S]*AUTH_CHALLENGE_INPUT[\s\S]*KEY_PASSPHRASE_CHANGE_INPUT/,
  'only local secret-entry modes may mask the xterm helper input');

const terminalSurfaceController = readFileSync(
  new URL('../../entry/src/main/ets/model/terminal/TerminalSurfaceController.ets', import.meta.url), 'utf8');
assert.match(terminalSurfaceController,
  /msg\.kind === BridgeProtocol\.KIND_BELL_ATTENTION[\s\S]*onBellAttentionHandler/,
  'the terminal surface must consume bell attention before generic session message routing');
assert.match(terminalSurfaceController,
  /msg\.kind === BridgeProtocol\.KIND_OPEN_URL[\s\S]*onOpenUrlHandler/,
  'the terminal surface must consume browser requests before generic SSH session routing');
assert.match(terminalSurfaceController, /openSearch\(\)[\s\S]*this\.bridge\.openSearch\(\)/,
  'the terminal surface must expose only a local search-open intent');
assert.match(terminalSurfaceController,
  /detach\(\): void \{[\s\S]*?this\.bridge\.destroy\(\)[\s\S]*?this\.bridge = null/,
  'surface detach must make the old bridge unable to dispatch into a replacement generation');
assert.doesNotMatch(terminalSurfaceController, /getHistoryChunks|queueReplay|replayedHistory/,
  'the rejected raw byte history replay buffer must not return');
assert.match(terminalSurfaceController,
  /bridge\.restoreSnapshot\(snapshot\)[\s\S]*?takeDetachedChunks/,
  'a replacement surface must restore its checkpoint before detached output');
assert.match(terminalSurfaceController,
  /msg\.kind === BridgeProtocol\.KIND_SNAPSHOT[\s\S]*?requestIdText[\s\S]*?lastCommittedSnapshotRequestId[\s\S]*?replaceSnapshot/,
  'only a sequenced current-bridge checkpoint may replace the session recovery snapshot');
assert.match(terminalSurfaceController, /takeDetachedChunks/,
  'a new terminal surface must take only output produced while no surface was attached');
assert.doesNotMatch(terminalSurfaceController, /releaseBuffers|term\.clear|term\.reset/,
  'disconnect cleanup must not ask a live terminal surface to clear its screen or scrollback');
assert.doesNotMatch(terminalSurfaceController, /terminateRendererForAcceptance|ACCEPTANCE_TESTS/,
  'production terminal-surface source must exclude acceptance-only renderer termination');

const indexPage = readFileSync(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const entryAbility = readFileSync(
  new URL('../../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8');
const themeConstants = readFileSync(
  new URL('../../entry/src/main/ets/view/theme/ThemeConstants.ets', import.meta.url), 'utf8');
const themeManager = readFileSync(
  new URL('../../entry/src/main/ets/view/theme/ThemeManager.ets', import.meta.url), 'utf8');
const userPreferences = readFileSync(
  new URL('../../entry/src/main/ets/model/settings/UserPreferences.ets', import.meta.url), 'utf8');
const chromeBar = readFileSync(
  new URL('../../entry/src/main/ets/view/components/ChromeBar.ets', import.meta.url), 'utf8');
const entryModule = readFileSync(
  new URL('../../entry/src/main/module.json5', import.meta.url), 'utf8');
assert.match(entryAbility, /setWindowBackgroundColor\('#00000000'\)/,
  'the native window must expose the content surface alpha to the compositor');
assert.match(entryAbility, /setWindowContainerColor\('#00000000', '#FF1E1E2E'\)/,
  'the active HarmonyOS PC container must expose the application surface while inactive stays opaque');
assert.match(entryAbility,
  /windowTransparencyAvailable[\s\S]*setWindowContainerColor[\s\S]*windowTransparencyAvailable', true/,
  'content transparency must be enabled only after the platform container accepts transparency');
assert.match(entryModule, /"name": "ohos\.permission\.SET_WINDOW_TRANSPARENT"/,
  'the normal system-grant permission for transparent 2in1 containers must be declared');
assert.match(indexPage,
  /\.backgroundBlurStyle\(this\.backgroundMaterial,[\s\S]*FOLLOWS_WINDOW_ACTIVE_STATE/,
  'one window-root material plane must follow the active window state');
assert.match(indexPage,
  /backgroundMaterial = this\.windowTransparencyAvailable[\s\S]*TransparencyMode\.OFF[\s\S]*BlurStyle\.BACKGROUND_REGULAR : BlurStyle\.NONE/,
  'the fixed Regular material must apply only when platform transparency is active');
assert.doesNotMatch(indexPage,
  /BACKGROUND_THIN|BACKGROUND_THICK|BACKGROUND_ULTRA_THICK|\.backdropBlur\(|\.backgroundEffect\(|filter:\s*blur|Gaussian/,
  'alternative material selectors and raw, CSS, WebGL, or custom Gaussian blur paths must stay out');
assert.match(themeConstants,
  /background: string = 'rgba\(0, 0, 0, 0\)'[\s\S]*surfaceBackground: string = '#D11E1E2E'/,
  'the dark xterm renderer must stay transparent behind the content surface owner');
assert.match(themeConstants,
  /background: string = 'rgba\(0, 0, 0, 0\)'[\s\S]*surfaceBackground: string = '#D1EFF1F5'/,
  'the light xterm renderer must stay transparent behind the content surface owner');
assert.match(themeManager,
  /HIGH = 0[\s\S]*MEDIUM = 1[\s\S]*LOW = 2[\s\S]*OFF = 3[\s\S]*EXTREME = 4/,
  'the five-mode model must preserve the three existing semantic preference values');
assert.match(themeManager,
  /contentOpacity[\s\S]*1\.00[\s\S]*0\.72[\s\S]*0\.90[\s\S]*0\.60[\s\S]*0\.82/,
  'theme authority must own all five approved content opacity values');
assert.match(themeManager,
  /chromeOpacity[\s\S]*1\.00[\s\S]*0\.80[\s\S]*0\.94[\s\S]*0\.70[\s\S]*0\.88/,
  'theme authority must own all five derived Chrome opacity values');
assert.match(userPreferences,
  /TERMINAL_TRANSPARENCY_MODE_KEY[\s\S]*loadTransparencyMode\(\)[\s\S]*saveTransparencyMode\(value: number\)/,
  'the semantic transparency mode must persist in the existing local preferences projection');
assert.match(entryAbility,
  /setTransparencyMode\([\s\S]*TransparencyPolicy\.normalize\(UserPreferences\.loadTransparencyMode\(\)\)/,
  'startup must restore and validate the locally persisted transparency mode');
assert.doesNotMatch(indexPage, /recyclePaneWebViewWhenDrained/,
  'normal disconnect and failure must keep the current terminal surface mounted');
assert.match(indexPage, /runtime\.surface\.setOnOpenUrl\(/,
  'each terminal surface must route URL requests through its owning pane');
assert.match(indexPage,
  /InteractionPolicy\.isTerminalSearchShortcut\([\s\S]*?this\.openActivePaneSearch\(\)/,
  'the exact shortcut must target only the active pane runtime');
assert.match(indexPage,
  /InteractionPolicy\.isTerminalCopyOrInterruptKey\([\s\S]*?runtime\.surface\.copyOrInterrupt\(\)[\s\S]*?return true/,
  'the pre-IME Ctrl+C route must target and consume only the active pane');
assert.match(indexPage,
  /private openActivePaneSearch\(\): void \{[\s\S]*?activePaneRuntime\(\)[\s\S]*?runtime\.surface\.openSearch\(\)/,
  'shortcut and menu search must share the active-pane routing helper');
assert.match(indexPage,
  /private activePaneRuntime\(\): PaneRuntime \| null \{[\s\S]*?this\.appVm\.getActivePane\(\)[\s\S]*?this\.findPaneRuntime\(pane\.id\)/,
  'search routing must resolve the stable active pane id instead of an adjacent runtime or index');
assert.match(indexPage,
  /private deactivateActiveTab[\s\S]*?runtime\.viewModel\.requestBlur\(\)/,
  'tab switches must blur every pane in the departing tab before retaining or evicting its surfaces');
assert.match(indexPage,
  /private restoreActivePaneFocus[\s\S]*?else \{\s*runtime\.viewModel\.requestBlur\(\)/,
  'pane switches must blur every non-active pane in the current tab');
assert.match(indexPage,
  /private recyclePaneWebView[\s\S]*?runtime\.detachSurface\(\)[\s\S]*?runtime\.generation \+= 1/,
  'renderer exit must destroy the old pane surface before creating a new generation');
assert.match(indexPage,
  /private finishTabCheckpoint[\s\S]*?runtime\.detachSurface\(\)/,
  'warm-tab eviction must detach every surface after its checkpoint boundary');
assert.match(indexPage,
  /private async disposeRuntime[\s\S]*?runtime\.detachSurface\(\)/,
  'closing a pane or tab must destroy its terminal surface');
assert.match(indexPage,
  /private onMainWindowVisibilityChanged[\s\S]*?captureMountedTerminalSnapshots\(\)/,
  'backgrounding the window must checkpoint every currently mounted terminal');
assert.match(indexPage,
  /private onMainWindowVisibilityChanged[\s\S]*?if \(this\.mainWindowVisible\) \{[\s\S]*?this\.restoreActivePaneFocus\(\)/,
  'restoring the window must restore focus to the active pane');
assert.match(indexPage,
  /private checkpointAndDestroyTabBridge[\s\S]*?checkpointingTabIds[\s\S]*?runtime\.surface\.captureSnapshot\(\(\) =>[\s\S]*?finishTabCheckpoint/,
  'an idle tab must remain mounted until its asynchronous eviction checkpoint completes');
assert.match(indexPage, /BrowserLauncher\.open\(/,
  'the ArkUI shell must hand validated HTTP(S) links to the HarmonyOS system browser');
assert.doesNotMatch(indexPage, /requestCopySelection|['"]Copy['"]/,
  'the tool menu must not keep a standalone Copy action');
assert.match(indexPage, /const MENU_ACTION_COUNT: number = 6/,
  'the production menu count must exclude acceptance-only actions');
assert.doesNotMatch(indexPage, /Acceptance: Rebuild Renderer|ACCEPTANCE_TESTS|rebuildRendererForAcceptance/,
  'production Index source must exclude the acceptance-only renderer trigger');
const acceptanceSource = readFileSync(
  new URL('../acceptance-source.ps1', import.meta.url), 'utf8');
assert.match(acceptanceSource, /Invoke-WithLeanTTYAcceptanceSource/,
  'debug build transformation wrapper must exist');
assert.match(acceptanceSource, /Acceptance: Rebuild Renderer/,
  'debug build transformation must own the renderer acceptance menu');
assert.match(acceptanceSource,
  /\$downloadsManagerMenuIndex = if \(\$includeNativeFileDescriptorProbe\) \{ 9 \} else \{ 8 \}[\s\S]*?\$transferFixtureMenuIndex = if \(\$includeNativeFileDescriptorProbe\) \{ 10 \} else \{ 9 \}/,
  'debug builds must include the bounded Downloads actions in keyboard menu traversal');
assert.doesNotMatch(acceptanceSource, /Debug Material|Acceptance: Open Search|BACKGROUND_ULTRA_THICK/,
  'debug builds must reuse production material and Search controls');
assert.match(acceptanceSource, /terminateRendererForAcceptance/,
  'debug build transformation must own the renderer termination trigger');
assert.match(acceptanceSource, /pasteClipboardForAcceptance/,
  'debug build transformation must own the clipboard paste trigger');
assert.match(acceptanceSource, /ACCEPTANCE_DOWNLOADS_NOREPLACE/,
  'debug build transformation must own the Downloads no-replace probe');
assert.match(acceptanceSource, /Acceptance: Downloads No-Replace/,
  'debug build transformation must expose the Downloads no-replace probe');
assert.match(acceptanceSource, /Acceptance: Downloads FD Boundary/,
  'native verification builds must expose the Downloads FD boundary probe');
assert.match(acceptanceSource, /Acceptance: Downloads Manager Boundary/,
  'debug verification builds must expose the production Downloads manager boundary probe');
assert.match(acceptanceSource, /finally[\s\S]*WriteAllBytes/,
  'debug build transformation must restore production ArkTS source in finally');
assert.match(indexPage, /for \(let i = 0; i < MENU_ACTION_COUNT; i\+\+\)/,
  'keyboard menu selection must traverse the compile-time action count');
assert.match(indexPage, /\(next \+ direction \+ MENU_ACTION_COUNT\) % MENU_ACTION_COUNT/,
  'keyboard menu selection must wrap across the compile-time action count');
assert.match(indexPage,
  /selected === 4 \|\| selected === 5\) \{ return \}[\s\S]*selected === 3\)[\s\S]*this\.openActivePaneSearch\(\)/,
  'Enter must leave both composite steppers stable while Search opens on the active pane');
assert.match(indexPage,
  /menuRow\(3, '⌕', 'Search'[\s\S]*transparencyMenuRow\(\)[\s\S]*fontSizeMenuRow\(\)/,
  'the rendered menu must place production Search before both composite steppers');
assert.match(indexPage,
  /menuRow\(3, '⌕', 'Search'[\s\S]*\(\) => \{ this\.openActivePaneSearch\(\) \}, true, false\)/,
  'menu Search must close the menu without stealing focus back from the search field');
assert.match(indexPage,
  /Text\('−'\)[\s\S]*Text\(this\.transparencyLabel\)[\s\S]*Text\('\+'\)/,
  'the visible transparency control must keep the fixed label between decrement and increment buttons');
assert.match(indexPage,
  /Text\('−'\)[\s\S]*\.enabled\(TransparencyPolicy\.canDecrease[\s\S]*Text\('\+'\)[\s\S]*\.enabled\(TransparencyPolicy\.canIncrease/,
  'both transparency buttons must expose real disabled states at the range boundaries');
assert.match(indexPage,
  /private adjustTransparency\(direction: number\): void[\s\S]*canDecrease[\s\S]*canIncrease[\s\S]*stepTransparencyMode\(direction\)[\s\S]*this\.transparencyLabel = TransparencyPolicy\.label\(mode\)/,
  'the open transparency row must clamp at both boundaries and update its label in place');
assert.match(indexPage,
  /menuSelectedIndex === 4[\s\S]*accessibilityText\('Transparency, ' \+ this\.transparencyLabel \+[\s\S]*Use left and right arrow keys to adjust/,
  'the composite row must expose the current semantic level and keyboard adjustment guidance');
assert.match(indexPage,
  /menuSelectedIndex === 4 && event\.keyCode === 2014[\s\S]*adjustTransparency\(-1\)/,
  'left must decrease only the selected transparency row');
assert.match(indexPage,
  /menuSelectedIndex === 4 && event\.keyCode === 2015[\s\S]*adjustTransparency\(1\)/,
  'right must increase only the selected transparency row');
assert.match(indexPage,
  /fontSizeMenuRow\(\)[\s\S]*Text\('−'\)[\s\S]*Text\(this\.fontSize\.toString\(\) \+ ' px'\)[\s\S]*Text\('\+'\)/,
  'the visible font control must mirror the transparency stepper interaction');
assert.match(indexPage,
  /\.enabled\(this\.fontSize > InteractionPolicy\.MIN_FONT_SIZE\)[\s\S]*\.enabled\(this\.fontSize < InteractionPolicy\.MAX_FONT_SIZE\)/,
  'both font buttons must expose real disabled states at the range boundaries');
assert.match(indexPage,
  /menuSelectedIndex === 5 && event\.keyCode === 2014[\s\S]*handleFontDecrease\(\)[\s\S]*menuSelectedIndex === 5 && event\.keyCode === 2015[\s\S]*handleFontIncrease\(\)/,
  'left and right must adjust only the selected font-size row');
assert.match(indexPage,
  /transparencyShortcutDirection\([\s\S]*adjustTransparency\(transparencyDirection\)[\s\S]*fontSizeShortcutDirection\([\s\S]*handleFontDecrease\(\)[\s\S]*handleFontIncrease\(\)[\s\S]*if \(this\.menuOpen\)/,
  'global stepper shortcuts must run while the menu is either open or closed');
for (const shortcut of ['Ctrl+Alt+-', 'Ctrl+Alt+=', 'Ctrl+-', 'Ctrl+=']) {
  assert.match(indexPage,
    new RegExp(`bindTips\\('${shortcut.replaceAll('+', '\\+')}', \\{[\\s\\S]*?appearingTime: 300`),
    `${shortcut} must appear in the matching native hover tip`);
}
assert.doesNotMatch(indexPage, /'Font Size \+'|'Reset Font Size'|'Font Size -'/,
  'the production menu must not retain three redundant font-size rows');
assert.match(indexPage,
  /private applyTheme\(\): void[\s\S]*for \(let i = 0; i < this\.paneRuntimes\.length; i\+\+\)[\s\S]*applyTerminalTheme\(themeJson\)/,
  'changing transparency must reuse the theme bridge for every mounted pane');
assert.match(indexPage,
  /contentBg = theme\.background\(this\.windowTransparencyAvailable\)[\s\S]*chromeBg = theme\.chromeBackground\(this\.windowTransparencyAvailable\)/,
  'both non-overlapping ArkUI surface owners must fall back to opaque when transparency is unavailable');
assert.match(indexPage,
  /ChromeBar\(\{[\s\S]*chromeBackground: this\.chromeBg[\s\S]*\.backgroundColor\(this\.contentBg\)/,
  'Chrome and content must receive separate derived background surfaces');
assert.match(chromeBar,
  /@Prop chromeBackground: string[\s\S]*\.backgroundColor\(this\.chromeBackground\)/,
  'ChromeBar must render the derived Chrome surface instead of its opaque palette base');
assert.match(indexPage,
  /@Watch\('onWindowTransparencyAvailabilityChanged'\)[\s\S]*onWindowTransparencyAvailabilityChanged\(\)[\s\S]*this\.applyTheme\(\)/,
  'the initially opaque surface must refresh only after post-load window transparency succeeds');
assert.match(acceptanceSource,
  /if \(ACCEPTANCE_TESTS\) \{[\s\S]*menuRow\(6, '↻', 'Acceptance: Rebuild Renderer'[\s\S]*menuRow\(7, '✓', 'Acceptance: Downloads No-Replace'/,
  'the debug source transformation must add the two bounded acceptance entries');
assert.match(acceptanceSource,
  /private rebuildRendererForAcceptance[\s\S]*?if \(!ACCEPTANCE_TESTS\)[\s\S]*?captureSnapshot\(\(captured: boolean\)[\s\S]*?terminateRendererForAcceptance/,
  'the injected acceptance action must wait for a confirmed production snapshot before terminating the renderer');

const moduleBuildProfile = readFileSync(
  new URL('../../entry/build-profile.json5', import.meta.url), 'utf8');
assert.match(moduleBuildProfile,
  /"name": "debug"[\s\S]*?"ACCEPTANCE_TESTS": true/,
  'debug packages must explicitly enable acceptance test entries');
assert.match(moduleBuildProfile,
  /"name": "release"[\s\S]*?"ACCEPTANCE_TESTS": false[\s\S]*?"branchElimination": true/,
  'release packages must compile out acceptance-only branches');

const terminalPane = readFileSync(
  new URL('../../entry/src/main/ets/view/components/TerminalPane.ets', import.meta.url), 'utf8');
assert.match(terminalPane, /renderMode:\s*RenderMode\.ASYNC_RENDER/,
  'terminal panes must use the normal asynchronous ArkWeb render mode');
assert.doesNotMatch(terminalPane, /paneBackground/,
  'terminal panes must not repeat the workspace alpha beneath ArkWeb');
assert.match(terminalPane,
  /\.backgroundColor\('#00000000'\)/,
  'the ArkWeb graphic surface and pane stack must remain transparent');
assert.match(terminalPane, /\.onlineImageAccess\(false\)/,
  'terminal panes must prevent packaged HTML from loading online images');
assert.match(terminalPane, /sharedRenderProcessToken:\s*'leantty-terminal'/,
  'terminal panes keep the measured shared renderer-process configuration');
assert.doesNotMatch(terminalPane, /\.onRenderProcess(?:NotResponding|Responding)\(/,
  'temporary ArkWeb renderer responsiveness diagnostics must not remain');
assert.doesNotMatch(terminalPane, /\.javaScriptProxy\(/,
  'the terminal pane must not expose the rejected output-pull proxy');
assert.doesNotMatch(terminalPane, /\.border\(\{ width: 2, color: this\.attentionColor \}\)/,
  'bell attention must not draw a full pane warning border');
assert.match(terminalPane, /@Prop closeButtonBackground:[\s\S]*@Prop focusRing:/,
  'the pane close control must use shared light and dark theme tokens');

assert.match(chromeBar, /private tabRenderKey\(tab: TabInfo\): string \{\s*return tab\.id\s*\}/,
  'the tab render key must preserve stable Tab identity across title, attention and animation changes');
assert.match(chromeBar,
  /@Prop @Watch\('onAttentionPulseTokenChanged'\) attentionPulseToken[\s\S]*onAttentionPulseTokenChanged\(\)[\s\S]*startAttentionPulse\(\)/,
  'finite BEL animation must restart through a transient prop without remounting the Tab component');
assert.match(chromeBar,
  /\.constraintSize\(\{\s*maxWidth:\s*'calc\(100% - 172vp\)'\s*\}\)/,
  'the tab strip must use parent layout space left after fixed controls and drag space');
assert.doesNotMatch(chromeBar, /maxWidth:\s*'\d+%'/,
  'the tab strip must not be capped at a fixed percentage of wide windows');
assert.doesNotMatch(chromeBar, /chromeBarWidth|\.onAreaChange\(/,
  'the tab strip must not create a self-measurement feedback loop');
assert.match(chromeBar, /\.fadingEdge\(this\.tabs\.length > 1\)/,
  'the tab strip must use the platform edge fade without adding width measurement state');
assert.match(chromeBar,
  /private surfaceColor\(\): string \{[\s\S]*this\.isActive \|\| this\.hovered[\s\S]*tabActiveBackground[\s\S]*tabBackground/,
  'tabs must map active and inactive states to explicit palette surfaces');
assert.doesNotMatch(chromeBar, /tabInactiveSurfaceOpacity|tabHoverSurfaceOpacity/,
  'tab separation must not depend on alpha that collapses against the Low chrome surface');
assert.match(chromeBar, /attentionPulseCount[\s\S]*isAnimationReduceEnabledSync[\s\S]*pulseIndex/,
  'tab attention must be finite and respect the system reduced-motion preference');
assert.match(chromeBar, /indicatorColor\(\): string \{[\s\S]*?if \(this\.hasAttention\) \{[\s\S]*?return this\.chromeColors\.attention/,
  'persistent attention must reuse the leading tab status dot so overflow cannot clip it');
assert.match(chromeBar, /struct MoreButton[\s\S]*Circle\(\)[\s\S]*Circle\(\)[\s\S]*Circle\(\)[\s\S]*Circle\(\)/,
  'the window menu must retain the HarmonyOS four-dot mark');
assert.doesNotMatch(chromeBar, /\.position\(\{ x: 173\.5, y: 11 \}\)/,
  'inter-tab separation must come from surface contrast without vertical divider lines');
assert.match(chromeBar,
  /Column\(\)[\s\S]*\.width\(1\)[\s\S]*\.height\(18\)[\s\S]*ChromeButton\(\{[\s\S]*symbol: '\+'/,
  'the short divider before the new-tab button must remain visible');
assert.match(chromeBar, /\.height\(36\)[\s\S]*bottomLeft: 0,[\s\S]*bottomRight: 0/,
  'all tab surfaces must meet the terminal baseline without rounded lower corners');

assert.match(terminalHtml, /#search-panel\s*\{[\s\S]*?width:\s*344px;/,
  'the terminal search panel must use the compact desktop width');
assert.match(terminalHtml, /#search-result\s*\{[\s\S]*?width:\s*48px;[\s\S]*?max-width:\s*48px;/,
  'the search result region must not create an elastic gap before navigation controls');
assert.match(terminalHtml, /#search-panel\s*\{[\s\S]*?right:\s*54px;/,
  'the search panel must keep clear of the pane close control');
assert.match(terminalHtml,
  /resultDescription[\s\S]*'Type to search'[\s\S]*'No results'[\s\S]*setAttribute\('aria-label', resultDescription\)/,
  'compact 0/0 feedback must distinguish an empty query from a completed no-results search for accessibility');
assert.match(terminalHtml, /#search-panel button\s*\{[\s\S]*?flex:\s*0 0 26px;[\s\S]*?width:\s*26px;/,
  'search actions must remain compact and equally sized');
assert.match(terminalHtml,
  /id="search-navigation" role="group" aria-label="Search result navigation"[\s\S]*?id="search-previous"[\s\S]*?id="search-next"[\s\S]*?<\/div>[\s\S]*?id="search-close"/,
  'previous and next must share a semantic navigation group while close remains separate');
assert.match(terminalHtml,
  /#search-navigation\s*\{[\s\S]*?border:\s*1px solid var\(--search-border\);[\s\S]*?#search-next\s*\{[\s\S]*?border-left:\s*1px solid var\(--search-border\);[\s\S]*?#search-close\s*\{[\s\S]*?border:\s*1px solid var\(--search-border\);/,
  'search navigation must use one grouped outline and close must keep an independent outline');
for (const [id, shortcut] of [
  ['search-previous', 'Shift+Enter'],
  ['search-next', 'Enter'],
  ['search-close', 'Esc']
]) {
  assert.match(terminalHtml,
    new RegExp(`id="${id}"[\\s\\S]*?data-tip="${shortcut.replaceAll('+', '\\+')}"`),
    `${id} must expose its shortcut through the shared hover-tip treatment`);
}
assert.match(terminalHtml,
  /#search-panel button\[data-tip\]::after[\s\S]*?transition-delay:\s*300ms;/,
  'search shortcut tips must use the same restrained 300 ms hover delay');
assert.match(terminalHtml,
  /#search-panel button:disabled\s*\{\s*color:\s*var\(--search-border\);\s*\}/,
  'disabled navigation must mute only the icon so its shortcut tip stays readable');
assert.doesNotMatch(terminalHtml, /#search-panel button:disabled\s*\{[^}]*opacity:/,
  'disabled navigation must not fade the hover-tip pseudo elements');
assert.doesNotMatch(terminalHtml, /id="search-(?:previous|next|close)"[^>]*\stitle=/,
  'search controls must not stack browser title popups over the shared shortcut tips');
assert.match(terminalHtml,
  /new Terminal\(\{[\s\S]*?allowProposedApi:\s*true,[\s\S]*?allowTransparency:\s*true,/,
  'xterm transparency must be enabled before the terminal opens');
assert.match(terminalHtml,
  /--terminal-background:\s*rgba\(0, 0, 0, 0\);[\s\S]*--terminal-overlay-background:\s*#1E1E2E;/,
  'the terminal canvas must be transparent while short-lived controls retain an opaque surface');
assert.doesNotMatch(terminalHtml,
  /html, body,[\s\S]*?#terminal-container,[\s\S]*?background-color:\s*var\(--terminal-background\)/,
  'DOM ancestors must not compound the workspace alpha before the WebGL canvas');

console.log('terminal policy tests passed');
