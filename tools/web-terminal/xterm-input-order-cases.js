// Public synthetic text, real DOM listeners and timers, no private overrides.
// These controlled schedules are not natural IME evidence.
globalThis.runXtermInputOrderCases = async function (Terminal) {
  const barrier = () => new Promise(resolve => setTimeout(resolve, 0));
  const results = [];
  async function test(name, expected, run, options = {}) {
    const container = document.createElement('div');
    document.body.appendChild(container);
    const terminal = new Terminal({ cols: 40, rows: 3, ...options });
    let output = '';
    terminal.open(container);
    const listener = terminal.onData(data => { output += data; });
    const textarea = terminal.textarea;
    textarea.focus();
    const key = (type, text = 'a', code = type === 'keydown' ? 229 : 65, extra = {}) =>
      textarea.dispatchEvent(new KeyboardEvent(type, { key: text, keyCode: code,
        charCode: type === 'keypress' ? code : 0, bubbles: true, cancelable: true,
        composed: true, ...extra }));
    const input = (data, inputType = 'insertText', isComposing = false) => {
      textarea.dispatchEvent(new InputEvent('beforeinput', { data, inputType,
        isComposing, bubbles: true, composed: true, cancelable: true }));
      if (inputType === 'deleteContentBackward') textarea.value = textarea.value.slice(0, -1);
      else textarea.value += data;
      textarea.dispatchEvent(new InputEvent('input', { data, inputType,
        isComposing, bubbles: true, composed: true }));
    };
    const composition = (type, data = '') => textarea.dispatchEvent(
      new CompositionEvent(type, { data, bubbles: true }));
    try {
      await run({ terminal, textarea, key, input, composition, barrier });
      await barrier();
      await barrier();
      results.push({ name, expected, actual: output, exact: expected === output });
    } finally { listener.dispose(); terminal.dispose(); container.remove(); }
  }
  await test('keydown-input-before-timer', 'a', async ({ key, input }) => {
    key('keydown'); input('a'); key('keyup');
  });
  await test('keydown-timer-before-input', 'a', async ({ key, input, barrier }) => {
    key('keydown'); await barrier(); input('a'); key('keyup');
  });
  await test('early-keyup-before-input', 'a', async ({ key, input }) => {
    key('keydown'); key('keyup'); input('a');
  });
  for (const text of ['jk', 'aa', 'a😀']) {
    for (const schedule of ['tight', 'early-keyup', 'timer-between', 'slow']) {
      await test(`rollover-${schedule}-${text}`, text, async ({ key, input, barrier }) => {
        const chars = Array.from(text);
        input(chars[0]); key('keydown', chars[0]);
        if (schedule === 'early-keyup' || schedule === 'slow') key('keyup', chars[0]);
        if (schedule === 'timer-between' || schedule === 'slow') await barrier();
        input(chars[1]); key('keydown', chars[1]);
        key('keyup', chars[0]); key('keyup', chars[1]);
      });
    }
  }
  await test('input-only-multiple-characters', 'ab😀', async ({ input }) => input('ab😀'));
  await test('several-pending-keydowns', 'aa', async ({ key, input }) => {
    key('keydown'); key('keydown'); input('a'); input('a'); key('keyup');
  });
  await test('legacy-no-input-event', 'a', async ({ key, textarea }) => {
    key('keydown'); textarea.value = 'a'; key('keyup');
  });
  await test('legacy-delete', '\x7f', async ({ key, textarea }) => {
    textarea.value = 'a'; key('keydown', 'Backspace'); textarea.value = ''; key('keyup');
  });
  await test('delete-then-text-before-timers', '\x7fb', async ({ key, input, textarea }) => {
    textarea.value = 'a'; key('keydown', 'Backspace'); input(null, 'deleteContentBackward');
    key('keydown', 'b'); input('b'); key('keyup');
  });
  await test('legacy-same-length-replacement', 'b', async ({ key, textarea }) => {
    textarea.value = 'a'; key('keydown'); textarea.value = 'b'; key('keyup');
  });
  await test('keypress-not-duplicated', 'a', async ({ key, input }) => {
    // xterm deliberately defers A-Z keydown to keypress for IME/caps-lock.
    key('keydown', 'A', 65); key('keypress', 'a', 97); input('a'); key('keyup');
  });
  await test('control-keys-unchanged', '\x03\r\x7f', async ({ key }) => {
    key('keydown', 'c', 67, { ctrlKey: true }); key('keyup');
    key('keydown', 'Enter', 13); key('keyup');
    key('keydown', 'Backspace', 8); key('keyup');
  });
  for (const inputType of ['insertCompositionText', 'insertText']) {
    await test(`composition-${inputType}`, '中', async ({ key, input, composition, barrier }) => {
      key('keydown'); composition('compositionstart');
      composition('compositionupdate', '中'); input('中', inputType, true);
      await barrier(); composition('compositionend', '中'); key('keyup');
    });
  }
  await test('text-after-composition-before-final-timer', '中a', async ({ key, input, composition, barrier }) => {
    composition('compositionstart'); composition('compositionupdate', '中');
    input('中', 'insertCompositionText', true); await barrier();
    composition('compositionend', '中'); input('a'); key('keyup');
  });
  await test('composition-cancel', '', async ({ textarea, composition, barrier }) => {
    composition('compositionstart'); composition('compositionupdate', '中');
    textarea.value = '中'; await barrier(); textarea.value = ''; composition('compositionend');
  });
  await test('disabled-input', '', async ({ key, input }) => {
    key('keydown'); input('a'); key('keyup');
  }, { disableStdin: true });
  await test('screen-reader-legacy-input', 'a', async ({ key, input }) => {
    key('keydown'); input('a'); key('keyup');
  }, { screenReaderMode: true });
  await test('public-paste-unchanged', 'ab\rcd', async ({ terminal }) => terminal.paste('ab\ncd'));
  await test('textarea-security-clear-between-keys', 'ab', async ({ key, input, textarea, barrier }) => {
    key('keydown'); input('a'); key('keyup'); await barrier(); textarea.value = '';
    key('keydown'); input('b'); key('keyup');
  });
  await test('disposed-owner-no-late-output', '', async ({ key, textarea, terminal }) => {
    key('keydown'); textarea.value = 'a'; terminal.dispose();
  });
  return results;
};
