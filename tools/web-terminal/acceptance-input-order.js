    // Test-build only. Rows: sequence, elapsed 0.1ms, kind, key category,
    // composed, isComposing, inputType category, data/textarea units, printable/delete/other.
    // Kinds: beforeinput=1, input=2, keydown=3, keyup=4, onData=5. No contents/keys retained.
    var acceptanceInputOrder = null;
    var acceptanceInputOrderUsed = false;
    function stopAcceptanceInputOrder(reason) {
      if (typeof stopAcceptanceInputSynthetic === 'function') stopAcceptanceInputSynthetic(reason);
      if (typeof stopAcceptanceInputAttribution === 'function') stopAcceptanceInputAttribution(reason);
      var trace = acceptanceInputOrder;
      if (!trace) return;
      acceptanceInputOrder = null;
      clearTimeout(trace.timer);
      var chunks = Math.max(1, Math.ceil(trace.rows.length / 16));
      for (var chunk = 0; chunk < chunks; chunk++) {
        sendBridgeControl('acceptanceInputOrder', trace.token + ';' + reason + ';' + chunk + ';' +
          chunks + ';' + trace.rows.slice(chunk * 16, (chunk + 1) * 16).map(function(row) {
            return row.join(',');
          }).join('/'));
      }
    }
    function armAcceptanceInputOrder(token, attributionMode) {
      if (attributionMode === 8) return armAcceptanceInputSynthetic(token);
      if (attributionMode >= 0 && typeof armAcceptanceInputAttribution === 'function') {
        return armAcceptanceInputAttribution(token, attributionMode);
      }
      if (!/^[1-9][0-9]{6}$/.test(token) || acceptanceInputOrderUsed || secureInput ||
          restoringSnapshot || !term || !term.textarea) return false;
      acceptanceInputOrderUsed = true;
      acceptanceInputOrder = { token: token, started: performance.now(), rows: [], timer: 0 };
      acceptanceInputOrder.timer = setTimeout(function() { stopAcceptanceInputOrder(1); }, 20000);
      sendBridgeControl('acceptanceInputOrder', token + ';0;0;0;');
      return true;
    }
    function acceptanceInputOrderActive() {
      if (!acceptanceInputOrder) return false;
      if (secureInput || restoringSnapshot || !term || !term.textarea) {
        stopAcceptanceInputOrder(3); return false;
      }
      if (performance.now() - acceptanceInputOrder.started >= 20000) {
        stopAcceptanceInputOrder(1); return false;
      }
      return true;
    }
    function appendAcceptanceInputOrder(values) {
      var trace = acceptanceInputOrder;
      trace.rows.push([trace.rows.length, Math.floor((performance.now() - trace.started) * 10)].concat(values));
      if (trace.rows.length === 256) stopAcceptanceInputOrder(2);
    }
    function observeAcceptanceInputOrderData(data) {
      if (!acceptanceInputOrderActive()) return;
      var printable = 0, deletes = 0, other = 0;
      for (var index = 0; index < data.length; index++) {
        var code = data.charCodeAt(index);
        if (code >= 32 && code <= 126) printable++;
        else if (code === 8 || code === 127) deletes++;
        else other++;
      }
      appendAcceptanceInputOrder([5, 0, 0, 0, 0, data.length, term.textarea.value.length,
        printable, deletes, other]);
    }
    function installAcceptanceInputOrder() {
      ['beforeinput', 'input', 'keydown', 'keyup'].forEach(function(name, index) {
        // Ancestor capture precedes xterm textarea listeners even when installed later.
        window.addEventListener(name, function(event) {
          if (!acceptanceInputOrderActive() || event.target !== term.textarea) return;
          appendAcceptanceInputOrder([index + 1, index >= 2 ? (event.keyCode === 229 ? 1 : 2) : 0,
            event.composed ? 1 : 0, event.isComposing ? 1 : 0,
            index < 2 ? (event.inputType === 'insertText' ? 1 : 2) : 0,
            typeof event.data === 'string' ? event.data.length : 0, term.textarea.value.length, 0, 0, 0]);
        }, true);
      });
      window.addEventListener('pagehide', function() { stopAcceptanceInputOrder(4); });
    }
