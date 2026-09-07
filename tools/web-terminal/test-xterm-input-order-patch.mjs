import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { applyXtermInputOrderPatch } from './patches/xterm-input-order.mjs';

const upstream = readFileSync(new URL('./node_modules/@xterm/xterm/lib/xterm.js', import.meta.url), 'utf8');
const patched = applyXtermInputOrderPatch(upstream, '6.0.0');
const packaged = readFileSync(new URL('../../entry/src/main/resources/rawfile/xterm.js', import.meta.url), 'utf8');
assert.equal(packaged.replace(/\r\n/g, '\n'), patched.replace(/\n?\/\/# sourceMappingURL=.*\s*$/u, '\n'));
assert.throws(() => applyXtermInputOrderPatch(upstream, '6.0.1'), /Expected @xterm\/xterm/);
for (const changed of ['', upstream + '\n', upstream + upstream, patched]) {
  assert.throws(() => applyXtermInputOrderPatch(changed, '6.0.0'), /input SHA-256 mismatch/);
}

// Execute the actual audited generated owner and input method, not a parallel
// implementation. Only DOM/services and scheduling are modeled at L1; the
// sibling browser check exercises actual event dispatch and actual timers.
function fixture(asset = patched) {
  const tasks = [];
  const start = asset.indexOf('get isComposing(){');
  const end = asset.indexOf('};t.CompositionHelper=', start);
  assert.ok(start > 0 && end > start, 'Audited CompositionHelper extraction must be re-reviewed on upgrade');
  const Helper = vm.runInNewContext(`(class{${asset.slice(start, end + 1)})`, {
    setTimeout: callback => tasks.push(callback), a: { C0: { DEL: '\x7f' } }
  });
  const inputStart = asset.indexOf('_inputEvent(e){');
  const inputEnd = asset.indexOf('resize(e,t){', inputStart);
  assert.ok(inputStart > 0 && inputEnd > inputStart);
  const inputMethod = vm.runInNewContext(`({${asset.slice(inputStart, inputEnd)}})._inputEvent`);
  const textarea = { value: '' };
  const output = [];
  const options = { rawOptions: { screenReaderMode: false, disableStdin: false } };
  const service = { triggerDataEvent: data => { if (!options.rawOptions.disableStdin) output.push(data); } };
  const helper = new Helper(textarea, { textContent: '', classList: { add() {}, remove() {} } },
    { buffer: { isCursorInViewport: false } }, options, service, {});
  const core = { _compositionHelper: helper, optionsService: options, coreService: service,
    _keyDownSeen: false, _keyPressHandled: false, cancel() {} };
  return {
    helper, core, textarea, options,
    down() { core._keyDownSeen = true; helper.keydown({ keyCode: 229 }); },
    up() { core._keyDownSeen = false; },
    input(data, inputType = 'insertText', isComposing = false) {
      if (inputType === 'deleteContentBackward') textarea.value = textarea.value.slice(0, -1);
      else textarea.value += data;
      inputMethod.call(core, { data, inputType, composed: true, isComposing });
    },
    flush() { for (let count = 0; tasks.length; count++) {
      assert.ok(count < 100, 'Bounded timer fixture'); tasks.shift()();
    } },
    value() { return output.join(''); }
  };
}
const schedules = [
  ['late-input', 'a', f => { f.down(); f.flush(); f.input('a'); f.up(); }],
  ['early-keyup', 'a', f => { f.down(); f.up(); f.input('a'); }],
  ['rollover-drop', 'jk', f => { f.input('j'); f.down(); f.flush(); f.input('k'); f.down(); f.up(); }],
  ['rollover-duplicate', 'aa', f => { f.input('a'); f.down(); f.up(); f.input('a'); f.down(); f.up(); }],
  ['pending-overlap', 'aa', f => { f.down(); f.down(); f.input('a'); f.input('a'); }],
  ['legacy-overlap', 'a', f => { f.down(); f.down(); f.textarea.value = 'a'; }],
  ['legacy-delete', '\x7f', f => { f.textarea.value = 'a'; f.down(); f.textarea.value = ''; }],
  ['delete-before-insert', '\x7fb', f => {
    f.textarea.value = 'a'; f.down(); f.input(null, 'deleteContentBackward'); f.down(); f.input('b');
  }],
  ['composition-commit', '中', f => {
    f.down(); f.helper.compositionstart(); f.helper.compositionupdate({ data: '中' });
    f.input('中', 'insertCompositionText', true); f.flush(); f.helper.compositionend();
  }],
  ['composition-suffix', '中a', f => {
    f.helper.compositionstart(); f.helper.compositionupdate({ data: '中' });
    f.input('中', 'insertCompositionText', true); f.flush(); f.helper.compositionend(); f.input('a');
  }],
  ['keypress-cancels-diff', '', f => { f.down(); f.core._keyPressHandled = true; f.input('a'); }],
  ['screen-reader', 'a', f => { f.options.rawOptions.screenReaderMode = true; f.down(); f.input('a'); }],
  ['disabled-input', '', f => { f.options.rawOptions.disableStdin = true; f.down(); f.input('a'); }]
];
const red = [];
for (const [name, expected, schedule] of schedules) {
  const original = fixture(upstream); schedule(original); original.flush();
  if (original.value() !== expected) red.push(name);
  const repaired = fixture(); schedule(repaired); repaired.flush();
  assert.equal(repaired.value(), expected, name);
}
assert.ok(red.includes('late-input') && red.includes('rollover-duplicate'), 'Original asset must still expose both defects');
// Two owners overlap while one cancels its pending diff. Neither callback can
// cancel or consume the other Terminal's text.
const left = fixture(), right = fixture();
left.down(); right.down(); left.input('a'); right.textarea.value = 'b';
left.flush(); right.flush();
assert.equal(left.value(), 'a'); assert.equal(right.value(), 'b');
console.log(`xterm input-order patch: ${schedules.length} owner cases + isolation passed; ${red.length} upstream failures retained`);
