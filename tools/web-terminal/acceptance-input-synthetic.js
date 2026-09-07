    // Test-build only: fixed synthetic ordering in the actual idle terminal.
    // Public DOM events/timers only; never patch xterm handlers or callback delays.
    var acceptanceInputSynthetic = null;
    var acceptanceInputSyntheticUsed = false;
    function stopAcceptanceInputSynthetic(reason) {
      var run = acceptanceInputSynthetic;
      if (!run) return;
      acceptanceInputSynthetic = null;
      clearTimeout(run.deadline);
      window.removeEventListener('keydown', run.interference, true);
      window.removeEventListener('input', run.interference, true);
      if (run.listener) run.listener.dispose();
      if (run.plain) run.plain.remove();
      // Do not refocus or touch a replacement/masked Surface on cancellation.
      run.rows.push([run.rows.length, Math.floor((performance.now() - run.started) * 10),
        9, 8, 40, run.units, run.units === 40 ? 1 : 0, run.domUnits, 0, 0, 0, 0]);
      var chunks = Math.ceil(run.rows.length / 16);
      for (var part = 0; part < chunks; part++) {
        sendBridgeControl('acceptanceInputOrder', run.token + ';' + reason + ';' + part + ';' +
          chunks + ';' + run.rows.slice(part * 16, (part + 1) * 16).map(function(row) {
            return row.join(',');
          }).join('/'));
      }
    }
    function armAcceptanceInputSynthetic(token) {
      if (!/^[1-9][0-9]{6}$/.test(token) || acceptanceInputSyntheticUsed || secureInput ||
          restoringSnapshot || !term || !term.textarea || acceptanceInputAttribution || acceptanceInputOrder) return false;
      acceptanceInputSyntheticUsed = true;
      var run = { token: token, started: performance.now(), rows: [], units: 0, domUnits: 0,
        textarea: term.textarea, listener: null, plain: null, deadline: 0, interference: null };
      acceptanceInputSynthetic = run;
      function valid() {
        if (acceptanceInputSynthetic !== run) throw new Error('Synthetic run cancelled');
        if (secureInput || restoringSnapshot || !term || term.textarea !== run.textarea ||
            performance.now() - run.started >= 10000) {
          throw new Error('Synthetic owner unavailable');
        }
      }
      var barrier = function() { return new Promise(function(resolve) { setTimeout(resolve, 0); }); };
      run.interference = function(event) {
        if (event.isTrusted) stopAcceptanceInputSynthetic(3);
      };
      run.deadline = setTimeout(function() { stopAcceptanceInputSynthetic(2); }, 10000);
      sendBridgeControl('acceptanceInputOrder', token + ';0;0;0;');
      // Setup pacing lets the arming command's physical keyup finish. The verdict
      // comes from completed cases, not this delay or the deadline.
      setTimeout(async function() {
        try {
          valid();
          window.addEventListener('keydown', run.interference, true);
          window.addEventListener('input', run.interference, true);
          for (var repeat = 0; repeat < 10; repeat++) {
            for (var caseId = 0; caseId < 5; caseId++) {
              valid();
              var plain = caseId === 4;
              var target = plain ? document.createElement('textarea') : run.textarea;
              if (plain) {
                run.plain = target;
                document.body.appendChild(target);
              }
              target.focus();
              target.value = '';
              await barrier();
              valid();
              if (document.activeElement !== target || (!plain && term._core._keyDownSeen)) {
                throw new Error('Synthetic start state is not neutral');
              }
              var output = '';
              if (!plain) run.listener = term.onData(function(data) { output += data; });
              var key = function(type) {
                valid();
                var code = type === 'keydown' ? 229 : 65;
                var event = new KeyboardEvent(type, { key: 'a', code: 'KeyA', keyCode: code,
                  bubbles: true, cancelable: true, composed: true });
                if (event.keyCode !== code || event.isTrusted) throw new Error('Synthetic key contract unsupported');
                target.dispatchEvent(event);
              };
              var keyDownBeforeInput = 0;
              var insert = function() {
                valid();
                keyDownBeforeInput = !plain && term._core._keyDownSeen ? 1 : 0;
                target.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'a',
                  bubbles: true, composed: true, cancelable: true }));
                target.value += 'a';
                var event = new InputEvent('input', { inputType: 'insertText', data: 'a',
                  bubbles: true, composed: true });
                if (event.isTrusted || !event.composed) throw new Error('Synthetic input contract unsupported');
                target.dispatchEvent(event);
              };
              if (caseId === 3) {
                insert();
              } else {
                key('keydown');
                if (caseId !== 0) { await barrier(); valid(); }
                if (caseId === 2) key('keyup');
                insert();
                await barrier(); valid();
                if (caseId !== 2) key('keyup');
              }
              await barrier(); valid();
              var actual = plain ? target.value : output;
              if (!plain) { run.units += output.length; run.domUnits += target.value.length; }
              // kind 17: case, repeat, DOM units/equality, output units/equality,
              // keyDownSeen immediately before input, synthetic trusted count, valid.
              run.rows.push([run.rows.length, Math.floor((performance.now() - run.started) * 10),
                17, caseId, repeat, target.value.length, target.value === 'a' ? 1 : 0,
                actual.length, actual === 'a' ? 1 : 0, keyDownBeforeInput, 0, 1]);
              if (run.listener) { run.listener.dispose(); run.listener = null; }
              if (plain) { target.remove(); run.plain = null; term.focus(); }
            }
          }
          stopAcceptanceInputSynthetic(1);
        } catch (_) { stopAcceptanceInputSynthetic(3); }
      }, 1000);
      return true;
    }
