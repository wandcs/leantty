import assert from 'node:assert/strict';

export const SESSION_BOUNDARY_RESET_SEQUENCE =
  '\u001b[?1049l\u001b[?1047l\u001b[?47l' +
  '\u001b[0m\u001b[?25h\u001b[5 q' +
  '\u001b[?1l\u001b[?66l\u001b>' +
  '\u001b[?2004l\u001b[?1004l' +
  '\u001b[?9l\u001b[?1000l\u001b[?1002l\u001b[?1003l' +
  '\u001b[?1005l\u001b[?1006l\u001b[?1015l\u001b[?1016l' +
  '\u001b[4l\u001b[?6l\u001b[?7h\u001b[?45l\u001b[?5l\u001b[?69l\u001b[20l\u001b[r' +
  '\u001b[?2026l\u001b(B\u001b)B' +
  '\u001b]104\u0007\u001b]110\u0007\u001b]111\u0007\u001b]112\u0007' +
  '\u001b[999;1H';

const REMOTE_SESSION_STATE =
  '\u001b[?1h\u001b[?66h\u001b[?2004h\u001b[?1004h' +
  '\u001b[?1003h\u001b[?1006h' +
  '\u001b[4h\u001b[?6h\u001b[?7l\u001b[?45h\u001b[?5h\u001b[20h' +
  '\u001b[2;3r\u001b[?25l\u001b[2 q' +
  '\u001b]4;1;rgb:ff/00/00\u0007' +
  '\u001b]10;rgb:00/ff/00\u0007' +
  '\u001b]11;rgb:00/00/ff\u0007' +
  '\u001b]12;rgb:ff/ff/00\u0007';

function write(terminal, data) {
  return new Promise(resolve => terminal.write(data, resolve));
}

function normalBufferText(terminal) {
  return normalBufferLines(terminal).join('\n');
}

function normalBufferLines(terminal) {
  const buffer = terminal.buffer.normal;
  const lines = [];
  for (let row = 0; row < buffer.length; row++) {
    lines.push(buffer.getLine(row)?.translateToString(true) ?? '');
  }
  return lines;
}

function observeColorEvents(terminal) {
  const events = [];
  terminal._core._inputHandler.onColor(batch => events.push(...batch));
  return events;
}

function assertRemoteStatePersisted(terminal, cursorShapePersisted = true) {
  assert.equal(terminal.modes.applicationCursorKeysMode, true);
  assert.equal(terminal.modes.applicationKeypadMode, true);
  assert.equal(terminal.modes.bracketedPasteMode, true);
  assert.equal(terminal.modes.sendFocusMode, true);
  assert.equal(terminal.modes.mouseTrackingMode, 'any');
  assert.equal(terminal.modes.insertMode, true);
  assert.equal(terminal.modes.originMode, true);
  assert.equal(terminal.modes.wraparoundMode, false);
  assert.equal(terminal.modes.reverseWraparoundMode, true);
  assert.equal(terminal._core.coreService.isCursorHidden, true);
  if (cursorShapePersisted) {
    assert.equal(terminal._core.coreService.decPrivateModes.cursorStyle, 'block');
    assert.equal(terminal._core.coreService.decPrivateModes.cursorBlink, false);
  }
}

function assertLocalStateRestored(terminal) {
  assert.equal(terminal.buffer.active.type, 'normal');
  assert.equal(terminal.modes.applicationCursorKeysMode, false);
  assert.equal(terminal.modes.applicationKeypadMode, false);
  assert.equal(terminal.modes.bracketedPasteMode, false);
  assert.equal(terminal.modes.sendFocusMode, false);
  assert.equal(terminal.modes.mouseTrackingMode, 'none');
  assert.equal(terminal.modes.insertMode, false);
  assert.equal(terminal.modes.originMode, false);
  assert.equal(terminal.modes.wraparoundMode, true);
  assert.equal(terminal.modes.reverseWraparoundMode, false);
  assert.equal(terminal._core.coreService.isCursorHidden, false);
  assert.equal(terminal._core.coreService.decPrivateModes.cursorStyle, 'bar');
  assert.equal(terminal._core.coreService.decPrivateModes.cursorBlink, true);
  assert.equal(terminal._core.buffers.active.scrollTop, 0);
  assert.equal(terminal._core.buffers.active.scrollBottom, terminal.rows - 1);
}

function assertRemoteColorMutations(events) {
  for (const index of [1, 256, 257, 258]) {
    assert.ok(events.some(event => event.type === 1 && event.index === index),
      `remote OSC color mutation must reach xterm parser index ${index}`);
  }
}

function assertColorResets(events) {
  assert.ok(events.some(event => event.type === 2 && event.index === undefined),
    'OSC 104 must reset the full ANSI palette');
  for (const index of [256, 257, 258]) {
    assert.ok(events.some(event => event.type === 2 && event.index === index),
      `Session reset must restore xterm special color index ${index}`);
  }
}

async function exerciseSessionBoundary(TerminalCtor, SerializeAddonCtor, sessionOutputAnchorRow,
  restoreFromSnapshot) {
  const source = new TerminalCtor({
    cols: 24,
    rows: 4,
    scrollback: 40,
    cursorBlink: true,
    cursorStyle: 'bar',
    theme: {
      foreground: '#cdd6f4',
      background: '#1e1e2e',
      cursor: '#f5e0dc',
      red: '#f38ba8'
    }
  });
  const serializer = new SerializeAddonCtor();
  source.loadAddon(serializer);
  const sourceColorEvents = observeColorEvents(source);

  const normalLines = ['normal-history-marker'];
  for (let index = 0; index < 12; index++) normalLines.push(`normal-line-${index}`);
  normalLines.push('normal-visible-marker');
  await write(source, normalLines.join('\r\n'));
  source.scrollToTop();
  assert.ok(source.buffer.normal.viewportY < source.buffer.normal.baseY,
    'fixture must preserve a user-visible normal-buffer viewport above the bottom');
  await write(source, REMOTE_SESSION_STATE);
  await write(source, '\u001b[?1049hremote-alternate-marker');
  assert.equal(source.buffer.active.type, 'alternate');
  assertRemoteStatePersisted(source);
  assertRemoteColorMutations(sourceColorEvents);

  let terminal = source;
  let resetColorEvents = sourceColorEvents;
  if (restoreFromSnapshot) {
    const snapshot = serializer.serialize({ scrollback: 40 }) +
      (source._core.coreService.isCursorHidden ? '\u001b[?25l' : '');
    terminal = new TerminalCtor({
      cols: 24,
      rows: 4,
      scrollback: 40,
      cursorBlink: true,
      cursorStyle: 'bar',
      theme: {
        foreground: '#cdd6f4',
        background: '#1e1e2e',
        cursor: '#f5e0dc',
        red: '#f38ba8'
      }
    });
    resetColorEvents = observeColorEvents(terminal);
    await write(terminal, snapshot);
    assert.equal(terminal.buffer.active.type, 'alternate');
    assertRemoteStatePersisted(terminal, false);
  }

  await write(terminal, SESSION_BOUNDARY_RESET_SEQUENCE);
  const anchorRow = sessionOutputAnchorRow(terminal.buffer.active, terminal.rows);
  await write(terminal, `\u001b[${anchorRow};1H`);
  await write(terminal, '\r\nConnection closed (exit 0).\r\n\u001b[0mltty> ');
  if (!restoreFromSnapshot) {
    assert.ok(terminal.buffer.active.viewportY < terminal.buffer.active.baseY,
      'reset plus local output must reproduce the stale normal-buffer viewport before restoration');
  }
  terminal.scrollToBottom();
  assert.equal(terminal.buffer.active.viewportY, terminal.buffer.active.baseY,
    'the bounded Session viewport operation must expose the local prompt at the bottom');
  assert.match(normalBufferText(terminal), /Connection closed \(exit\s*0\)\.[\s\S]*ltty>/,
    'the Session boundary must retain local close output and prompt before viewport restoration');
  const orderedBufferText = normalBufferText(terminal);
  assert.ok(orderedBufferText.indexOf('normal-visible-marker') < orderedBufferText.indexOf('Connection closed'),
    'the local close output must be anchored after preserved normal-buffer content');
  assertLocalStateRestored(terminal);
  assertColorResets(resetColorEvents);
  assert.match(normalBufferText(terminal), /normal-history-marker/,
    'session reset must preserve normal-buffer scrollback');
  assert.match(normalBufferText(terminal), /normal-visible-marker/,
    'session reset must preserve normal-buffer visible content');
  assert.doesNotMatch(normalBufferText(terminal), /remote-alternate-marker/,
    'returning to the normal buffer must not copy alternate-buffer content into scrollback');

  source.dispose();
  if (terminal !== source) terminal.dispose();
}

async function exerciseAlternateBufferExit(TerminalCtor, enterMode) {
  const terminal = new TerminalCtor({ cols: 40, rows: 8, scrollback: 20 });
  await write(terminal, 'before\r\ncursor-anchor');
  await write(terminal, `\u001b[?${enterMode}hremote-alternate`);
  assert.equal(terminal.buffer.active.type, 'alternate',
    `DEC private mode ${enterMode} must enter the alternate buffer`);
  await write(terminal, SESSION_BOUNDARY_RESET_SEQUENCE);
  assert.equal(terminal.buffer.active.type, 'normal',
    `the Session reset must exit an alternate buffer entered with mode ${enterMode}`);
  assert.match(normalBufferText(terminal), /before[\s\S]*cursor-anchor/,
    `the Session reset must preserve normal-buffer content after alternate mode ${enterMode}`);
  terminal.dispose();
}

async function exerciseCloseOutputPlacement(TerminalCtor, sessionOutputAnchorRow, enterMode = 0) {
  const terminal = new TerminalCtor({ cols: 40, rows: 8, scrollback: 20 });
  await write(terminal, 'remote-shell$ exit');
  if (enterMode > 0) {
    await write(terminal, `\u001b[?${enterMode}hremote-alternate`);
    assert.equal(terminal.buffer.active.type, 'alternate',
      `DEC private mode ${enterMode} must enter the alternate buffer`);
  }

  await write(terminal, SESSION_BOUNDARY_RESET_SEQUENCE);
  const anchorRow = sessionOutputAnchorRow(terminal.buffer.active, terminal.rows);
  await write(terminal, `\u001b[${anchorRow};1H`);
  await write(terminal, '\r\nConnection closed (exit 0).\r\n\u001b[0mltty> r');
  terminal.scrollToBottom();

  const lines = normalBufferLines(terminal);
  const exitLine = lines.findIndex(line => line.includes('remote-shell$ exit'));
  const closeLine = lines.findIndex(line => line.includes('Connection closed (exit 0).'));
  const promptLine = lines.findIndex(line => line.includes('ltty> r'));
  const label = enterMode > 0 ? `alternate mode ${enterMode}` : 'normal buffer';
  assert.ok(exitLine >= 0 && closeLine >= 0 && promptLine >= 0,
    `${label} must retain the exit line, local close output and first local input`);
  assert.equal(closeLine, exitLine + 1,
    `${label} close output must follow the remote exit without blank terminal rows`);
  assert.equal(promptLine, closeLine + 1,
    `${label} prompt and first local input must immediately follow the close output`);
  assertLocalStateRestored(terminal);
  terminal.dispose();
}

export async function runTerminalSessionResetTests(TerminalCtor, SerializeAddonCtor, sessionOutputAnchorRow) {
  for (const enterMode of [47, 1047, 1049]) {
    await exerciseAlternateBufferExit(TerminalCtor, enterMode);
  }
  await exerciseCloseOutputPlacement(TerminalCtor, sessionOutputAnchorRow);
  for (const enterMode of [47, 1047, 1049]) {
    await exerciseCloseOutputPlacement(TerminalCtor, sessionOutputAnchorRow, enterMode);
  }
  await exerciseSessionBoundary(TerminalCtor, SerializeAddonCtor, sessionOutputAnchorRow, false);
  await exerciseSessionBoundary(TerminalCtor, SerializeAddonCtor, sessionOutputAnchorRow, true);
  console.log('terminal session-boundary reset matrix tests passed');
}
