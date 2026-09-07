// Embedded only in maintainer debug HAPs. Public fixture data, bounded state.
    var perfActiveActionsEnabled = false;
    var perfActive = false;
    var perfEnded = false;
    var perfCaseId = '';
    var perfPending = '';
    var perfLines = 0;
    var perfWidth = 0;
    var perfLineIndex = 0;
    var perfReceivedBytes = 0;
    var perfMismatches = 0;
    var perfStartedAt = 0;
    var perfParsedAt = 0;
    var perfObserverMs = 0;
    var perfAwaitingPaint = false;
    var perfPaintFrameScheduled = false;
    var perfInputSequence = 0;
    var perfInputPending = null;
    var perfInputSamples = [];
    var perfEchoBytes = 0;
    var perfContextTrigger = 'not-requested';

    function perfExpectedLine(index) {
      var prefix = 'LTTY_PERF_' + perfCaseId + '_' + String(index).padStart(5, '0') + ' ';
      return prefix + 'X'.repeat(Math.max(0, perfWidth - prefix.length));
    }

    function sendPerfInputProbe(caseId) {
      if (!perfActiveActionsEnabled || !perfActive || perfEnded || perfCaseId !== caseId || perfInputPending || perfInputSequence >= 20) return;
      perfInputPending = { sequence: ++perfInputSequence, startedAt: performance.now(), parsed: false };
      // Public xterm input API, then the normal onData/Bridge/native/SSH/fixture
      // echo path. This excludes physical-key and IME dispatch latency.
      term.input('?', true);
    }

    function triggerPerfContextLoss(caseId) {
      if (!perfActiveActionsEnabled || !perfActive || perfEnded || perfCaseId !== caseId) return;
      var canvases = document.querySelectorAll('#terminal-container canvas');
      for (var i = 0; i < canvases.length; i++) {
        var context = canvases[i].getContext('webgl2') || canvases[i].getContext('webgl');
        var extension = context && context.getExtension('WEBGL_lose_context');
        if (extension) {
          perfContextTrigger = 'requested';
          extension.loseContext();
          return;
        }
      }
      perfContextTrigger = 'unavailable';
    }

    function beginPerfSample(match) {
      perfActive = true;
      perfEnded = false;
      perfCaseId = match[1];
      perfLines = Number(match[2]);
      perfWidth = Number(match[3]);
      perfLineIndex = perfReceivedBytes = perfMismatches = 0;
      perfStartedAt = performance.now();
      perfParsedAt = perfObserverMs = 0;
      perfAwaitingPaint = perfPaintFrameScheduled = false;
      perfInputSequence = perfEchoBytes = 0;
      perfInputPending = null;
      perfInputSamples = [];
      perfContextTrigger = 'not-requested';
      var sampleId = perfCaseId;
      if (perfActiveActionsEnabled && /^input[0-9]+$/.test(sampleId)) setTimeout(function() { sendPerfInputProbe(sampleId); }, 20);
      if (perfActiveActionsEnabled && /^contextloss[0-9]+$/.test(sampleId)) setTimeout(function() { triggerPerfContextLoss(sampleId); }, 20);
    }

    function observePerfPacket(bytes) {
      var observedAt = performance.now();
      var packet = { end: '', echo: 0 };
      if (perfActive && perfEnded) return packet;
      if (!perfActive && perfPending.length === 0) {
        var escapeOffset = bytes.indexOf(27);
        if (escapeOffset < 0) return packet;
        bytes = bytes.subarray(escapeOffset);
      }
      var text = new TextDecoder('utf-8').decode(bytes);
      if (!perfActive) {
        perfPending += text;
        var begin = /\x1b\]0;LTTY_PERF_BEGIN__:([a-z0-9_]{1,24}):([1-9][0-9]{0,4}):(48|49|[5-9][0-9]|1[0-5][0-9]|160)\x07/.exec(perfPending);
        if (!begin || Number(begin[2]) > 12000) {
          var prefix = '\x1b]0;LTTY_PERF_BEGIN__:';
          var tail = perfPending.slice(perfPending.lastIndexOf('\x1b'));
          perfPending = tail.length <= 128 && (prefix.indexOf(tail) === 0 || tail.indexOf(prefix) === 0) ? tail : '';
          return packet;
        }
        text = perfPending.slice(begin.index + begin[0].length);
        perfPending = '';
        beginPerfSample(begin);
      }
      // '?' is absent from the exact fixture payload. Only the one outstanding
      // injected input may appear out of band; all other bytes remain checked.
      text = text.replace(/\?/g, function() {
        if (!perfInputPending || packet.echo || perfInputPending.parsed) {
          perfMismatches++;
        } else {
          packet.echo = perfInputPending.sequence;
          perfEchoBytes++;
        }
        return '';
      });
      perfPending += text;
      var endMarker = '\x1b]0;LTTY_PERF_END__:' + perfCaseId + '\x07';
      while (perfPending.length > 0) {
        if (perfPending.indexOf(endMarker) === 0) {
          packet.end = perfCaseId;
          perfEnded = true;
          perfPending = '';
          break;
        }
        if (endMarker.indexOf(perfPending) === 0) break;
        var newline = perfPending.indexOf('\n');
        if (newline < 0) break;
        var line = perfPending.slice(0, newline + 1);
        perfPending = perfPending.slice(newline + 1);
        perfReceivedBytes += new TextEncoder().encode(line).length;
        if (perfLineIndex >= perfLines || line !== perfExpectedLine(perfLineIndex) + '\r\n') perfMismatches++;
        perfLineIndex++;
      }
      if (perfPending.length > 4096) {
        perfMismatches++;
        packet.end = perfCaseId;
        perfEnded = true;
        perfPending = '';
      }
      perfObserverMs += performance.now() - observedAt;
      return packet;
    }

    function perfPacketParsed(packet) {
      if (packet.echo && perfInputPending && packet.echo === perfInputPending.sequence) {
        perfInputPending.parsed = true;
        term.refresh(0, term.rows - 1);
      }
      if (packet.end && packet.end === perfCaseId) {
        perfParsedAt = performance.now();
        perfAwaitingPaint = true;
        term.refresh(0, term.rows - 1);
      }
    }

    function reportPerfAfterPaint() {
      if (!perfActive || perfPaintFrameScheduled ||
        (!perfAwaitingPaint && !(perfInputPending && perfInputPending.parsed))) return;
      perfPaintFrameScheduled = true;
      var paintedCase = perfCaseId;
      requestAnimationFrame(function() {
        perfPaintFrameScheduled = false;
        if (!perfActive || perfCaseId !== paintedCase) return;
        if (perfInputPending && perfInputPending.parsed) {
          perfInputSamples.push({ sequence: perfInputPending.sequence,
            webInputToFrameMs: performance.now() - perfInputPending.startedAt,
            duringLoad: !perfAwaitingPaint });
          perfInputPending = null;
          setTimeout(function() { sendPerfInputProbe(paintedCase); }, 80);
        }
        if (perfAwaitingPaint) reportPerfResult();
      });
    }

    function reportPerfResult() {
      if (!nativePort || !perfActive) return;
      var paintMs = performance.now() - perfStartedAt;
      var parseMs = perfParsedAt - perfStartedAt;
      var expectedBytes = (perfWidth + 2) * perfLines;
      var visible = '';
      var buffer = term.buffer.active;
      for (var i = buffer.viewportY; i < buffer.length; i++) {
        var line = buffer.getLine(i);
        if (line) visible += (line.isWrapped ? '' : '\n') + line.translateToString(true);
      }
      var metric = { schemaVersion: 2, caseId: perfCaseId, expectedBytes: expectedBytes,
        actualBytes: perfReceivedBytes, expectedLines: perfLines, actualLines: perfLineIndex,
        mismatches: perfMismatches, contentOrdered: perfMismatches === 0 && perfLineIndex === perfLines && perfReceivedBytes === expectedBytes,
        visibleTailConfirmed: visible.indexOf(perfExpectedLine(perfLines - 1)) >= 0,
        completenessPercent: Math.round(perfReceivedBytes / expectedBytes * 100000) / 1000,
        parseMs: parseMs, paintMs: paintMs, renderedMs: paintMs,
        parseMbps: perfReceivedBytes * 8 / Math.max(parseMs, 0.001) / 1000,
        renderMbps: perfReceivedBytes * 8 / Math.max(paintMs, 0.001) / 1000,
        observerMs: perfObserverMs, inputSamples: perfInputSamples, inputEchoBytes: perfEchoBytes,
        inputPending: perfInputPending !== null, contextLossTrigger: perfContextTrigger,
        actualRenderer: actualRenderer, contextLossCount: rendererContextLossCount };
      sendBridgeControl('perfRender', JSON.stringify(metric));
      perfActive = perfAwaitingPaint = false;
      perfInputPending = null;
      perfPending = '';
    }
