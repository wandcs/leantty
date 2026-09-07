
    // Test-build diagnostic only. No input contents leave this bounded observer.
    // Uses the original xterm methods, forwarding every callback once at its original delay.
    var acceptanceInputAttribution = null;
    function observeAcceptanceChainData(data) {
      var trace = acceptanceInputAttribution;
      if (!trace || !trace.chain) return;
      trace.output += data;
      trace.row(5, { data: data });
    }
    function observeAcceptanceChainPost(kind, data) {
      var trace = acceptanceInputAttribution;
      if (trace && trace.chain) trace.row(kind, { data: data });
    }
    function focusAcceptanceInputAttribution() {
      if (!acceptanceInputAttribution || !acceptanceInputAttribution.plain) return false;
      acceptanceInputAttribution.target.focus();
      return true;
    }
    function armAcceptanceInputAttribution(token, mode) {
      if (!/^[1-9][0-9]{6}$/.test(token) || !Number.isInteger(mode) || mode < 0 || mode > 4 ||
          acceptanceInputOrderUsed || secureInput || restoringSnapshot || !term || !term.textarea) return false;
      var core = term._core, helper = core && core._compositionHelper;
      if (!helper || typeof helper._handleAnyTextareaChanges !== 'function') return false;
      acceptanceInputOrderUsed = true;
      var chain = mode === 4, plain = !chain && mode % 2 === 0;
      var sample = chain ? 'ssh-keygen -R [127.0.0.1]:2223'.repeat(6) : '0123456789abcdefghijklmnopqrstu';
      var label = document.createElement('div');
      label.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:1000;background:#242438;color:white;padding:12px;font:16px monospace;';
      label.textContent = 'INPUT DIAGNOSTIC: ' + (plain ? 'plain textarea' : 'xterm') +
        ' / ' + (mode < 2 || chain ? 'UiTest' : 'real keyboard') + ' / ' + sample + ' (no Enter)';
      document.body.appendChild(label);
      var target = plain ? document.createElement('textarea') : term.textarea;
      if (plain) {
        target.setAttribute('aria-label', 'LeanTTY input attribution');
        target.style.cssText = 'position:fixed;top:60px;left:20px;width:80%;height:100px;z-index:1001;background:#242438;color:white;font:20px monospace;';
        document.body.appendChild(target);
      }
      target.value = '';
      var trace = { token: token, mode: mode, chain: chain, plain: plain, sample: sample, target: target,
        label: label, core: core, helper: helper, original: helper._handleAnyTextareaChanges,
        started: performance.now(), duration: mode < 2 || chain ? 20000 : 60000,
        limit: chain ? 4096 : 256, keyCount: 0, diffId: 0,
        rows: [], output: '', domInput: '', listeners: [], timer: 0, dataListener: null };
      acceptanceInputAttribution = trace;
      function row(kind, event, detail) {
        if (acceptanceInputAttribution !== trace) return;
        if (secureInput || restoringSnapshot) { stopAcceptanceInputAttribution(3); return; }
        if (performance.now() - trace.started >= trace.duration) { stopAcceptanceInputAttribution(1); return; }
        var data = event && typeof event.data === 'string' ? event.data : '';
        if (kind === 2 && event.inputType === 'insertText') trace.domInput += data;
        // sequence,time,kind,keyCategory,composed,composing,inputType,dataUnits,
        // textareaUnits,keyDownSeen,onDataUnits,onDataExactPrefix
        trace.rows.push([trace.rows.length, Math.floor((performance.now() - trace.started) * 10), kind,
          detail ? detail[0] : event && typeof event.keyCode === 'number' ? (event.keyCode === 229 ? 1 : 2) : 0,
          detail ? detail[1] : event && event.composed ? 1 : 0, event && event.isComposing ? 1 : 0,
          event && event.inputType ? (event.inputType === 'insertText' ? 1 : 2) : 0,
          data.length, target.value.length, core._keyDownSeen ? 1 : 0, trace.output.length,
          sample.startsWith(trace.output) ? 1 : 0]);
        if (trace.rows.length === trace.limit - 1) stopAcceptanceInputAttribution(2);
      }
      trace.row = row;
      ['beforeinput', 'input', 'keydown', 'keyup', 'compositionstart', 'compositionend'].forEach(function(name, index) {
        var listener = function(event) {
          if (event.target !== target) return;
          row(index < 4 ? index + 1 : index + 6, event);
          if (!chain) return;
          if (name === 'keydown' && (event.keyCode === 229 ||
              typeof event.key === 'string' && event.key.length === 1)) {
            trace.keyCount++;
            row(15, null, [trace.keyCount, 0]);
          }
          if (name === 'input') {
            row(16, event, [trace.keyCount, trace.keyCount > 0 &&
              event.data === sample.charAt(trace.keyCount - 1) ? 1 : 0]);
          }
        };
        window.addEventListener(name, listener, true);
        trace.listeners.push([name, listener]);
      });
      if (!chain) trace.dataListener = term.onData(function(data) {
        if (acceptanceInputAttribution !== trace) return;
        trace.output += data;
        row(5, { data: data });
      });
      if (!plain) {
        helper._handleAnyTextareaChanges = function() {
          var savedTimeout = window.setTimeout;
          window.setTimeout = function(callback, delay) {
            var args = Array.prototype.slice.call(arguments, 2);
            var detail = chain ? [++trace.diffId, target.value.length] : null;
            row(6, null, detail);
            return savedTimeout.call(window, function() {
              row(7, null, detail);
              try { return callback.apply(this, arguments); }
              finally { row(8, null, detail); }
            }, delay, ...args);
          };
          try { return trace.original.apply(this, arguments); }
          finally { window.setTimeout = savedTimeout; }
        };
      }
      trace.timer = setTimeout(function() { stopAcceptanceInputAttribution(1); }, trace.duration);
      target.focus();
      sendBridgeControl('acceptanceInputOrder', token + ';0;0;0;');
      return true;
    }
    function stopAcceptanceInputAttribution(reason) {
      var trace = acceptanceInputAttribution;
      if (!trace) return;
      acceptanceInputAttribution = null;
      clearTimeout(trace.timer);
      trace.helper._handleAnyTextareaChanges = trace.original;
      trace.listeners.forEach(function(pair) { window.removeEventListener(pair[0], pair[1], true); });
      if (trace.dataListener) trace.dataListener.dispose();
      // Summary: sequence,time,9,mode,expected,actual,exact,domInputUnits,
      // finalTextareaUnits,textareaExact,domIsFullVector,domIsLettersOnly.
      var actual = trace.plain ? trace.target.value : trace.output;
      trace.rows.push([trace.rows.length, Math.min(600000, Math.floor((performance.now() - trace.started) * 10)),
        9, trace.mode, trace.sample.length, actual.length, actual === trace.sample ? 1 : 0,
        trace.domInput.length, trace.target.value.length, trace.target.value === trace.sample ? 1 : 0,
        trace.domInput === trace.sample ? 1 : 0, !trace.chain && trace.domInput === trace.sample.slice(10) ? 1 : 0]);
      if (trace.plain) trace.target.remove();
      trace.label.remove();
      var chunks = Math.ceil(trace.rows.length / 16);
      for (var chunk = 0; chunk < chunks; chunk++) {
        sendBridgeControl('acceptanceInputOrder', trace.token + ';' + reason + ';' + chunk + ';' + chunks + ';' +
          trace.rows.slice(chunk * 16, (chunk + 1) * 16).map(function(values) { return values.join(','); }).join('/'));
      }
      trace.output = ''; trace.domInput = '';
      if (reason === 1 && trace.plain && term) term.focus();
    }
