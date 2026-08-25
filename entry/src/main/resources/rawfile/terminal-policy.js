(function(global) {
  'use strict';

  var MAX_CLIPBOARD_BYTES = 1024 * 1024;
  var MAX_CLIPBOARD_BASE64_LENGTH = Math.ceil(MAX_CLIPBOARD_BYTES / 3) * 4;
  var MAX_ATTENTION_OSC_BYTES = 1024;

  function rejectOsc52(reason) {
    return { accepted: false, text: '', reason: reason, byteLength: 0 };
  }

  function decodeOsc52(payload) {
    if (typeof payload !== 'string') return rejectOsc52('invalid-payload');
    var separator = payload.indexOf(';');
    if (separator < 0) return rejectOsc52('missing-separator');
    var target = payload.substring(0, separator);
    var encoded = payload.substring(separator + 1);
    // OSC 52 uses an empty selector for the default clipboard. tmux emits
    // this form when copy-mode completes a selection.
    if (target !== '' && target !== 'c') return rejectOsc52('unsupported-target');
    if (encoded === '?') return rejectOsc52('read-not-supported');
    if (encoded.length > MAX_CLIPBOARD_BASE64_LENGTH) return rejectOsc52('encoded-too-large');
    if (encoded.length % 4 === 1 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
      return rejectOsc52('invalid-base64');
    }
    try {
      var binary = global.atob(encoded);
      if (binary.length > MAX_CLIPBOARD_BYTES) return rejectOsc52('decoded-too-large');
      var bytes = new Uint8Array(binary.length);
      for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      var text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
      return { accepted: true, text: text, reason: 'ok', byteLength: bytes.length };
    } catch (ex) {
      return rejectOsc52('invalid-utf8');
    }
  }

  function rejectAttentionOsc(reason) {
    return { accepted: false, reason: reason };
  }

  function createOsc99CapabilityResponse(payload) {
    if (typeof payload !== 'string' || payload.length === 0 ||
        payload.length > MAX_ATTENTION_OSC_BYTES ||
        new TextEncoder().encode(payload).byteLength > MAX_ATTENTION_OSC_BYTES) {
      return '';
    }
    var separator = payload.indexOf(';');
    if (separator < 0 || separator !== payload.length - 1) return '';
    var entries = payload.substring(0, separator).split(':');
    var identifier = '';
    var query = false;
    for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
      var entry = entries[entryIndex];
      var equals = entry.indexOf('=');
      if (equals !== 1 || entry.length <= 2) return '';
      var key = entry.substring(0, 1);
      var value = entry.substring(2);
      if (key === 'i' && identifier.length === 0 &&
          /^[A-Za-z0-9\-_\/+.,(){}\[\]*&^%$#@!`~]+$/.test(value)) {
        identifier = value;
      } else if (key === 'p' && !query && value === '?') {
        query = true;
      } else {
        return '';
      }
    }
    if (identifier.length === 0 || !query) return '';
    return '\x1b]99;i=' + identifier + ':p=?;p=title,body\x1b\\';
  }

  function validateOsc99Attention(payload) {
    var separator = payload.indexOf(';');
    if (separator < 0) return rejectAttentionOsc('missing-separator');
    var metadata = payload.substring(0, separator);
    var content = payload.substring(separator + 1);
    if (content.length === 0) return rejectAttentionOsc('empty-payload');

    var fields = Object.create(null);
    if (metadata.length > 0) {
      var entries = metadata.split(':');
      for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
        var entry = entries[entryIndex];
        var equals = entry.indexOf('=');
        if (equals !== 1 || entry.length <= 2) {
          return rejectAttentionOsc('invalid-metadata');
        }
        var key = entry.substring(0, 1);
        var value = entry.substring(2);
        if (key !== 'i' && key !== 'p' && key !== 'e' && key !== 'd') {
          return rejectAttentionOsc('unsupported-metadata');
        }
        if (fields[key] !== undefined) return rejectAttentionOsc('duplicate-metadata');
        if (!/^[A-Za-z0-9\-_\/+.,(){}\[\]*&^%$#@!`~]+$/.test(value)) {
          return rejectAttentionOsc('invalid-metadata-value');
        }
        fields[key] = value;
      }
    }

    if (fields.p !== undefined && fields.p !== 'title' && fields.p !== 'body') {
      return rejectAttentionOsc('unsupported-payload-type');
    }
    if (fields.d !== undefined && fields.d !== '1') {
      return rejectAttentionOsc('incomplete-notification');
    }
    if (fields.e !== undefined && fields.e !== '1') {
      return rejectAttentionOsc('unsupported-encoding');
    }
    if (fields.e === '1') {
      if (content.length % 4 === 1 ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(content)) {
        return rejectAttentionOsc('invalid-base64');
      }
    } else if (/[\x00-\x1f\x7f]/.test(content)) {
      return rejectAttentionOsc('control-character');
    }
    return { accepted: true, reason: 'ok' };
  }

  function validateAttentionOsc(code, payload) {
    if (code !== 9 && code !== 99 && code !== 777) return rejectAttentionOsc('unsupported-code');
    if (typeof payload !== 'string') return rejectAttentionOsc('invalid-payload');
    if (payload.length === 0) return rejectAttentionOsc('empty-payload');
    if (payload.length > MAX_ATTENTION_OSC_BYTES ||
        new TextEncoder().encode(payload).byteLength > MAX_ATTENTION_OSC_BYTES) {
      return rejectAttentionOsc('payload-too-large');
    }
    if (code === 99) return validateOsc99Attention(payload);
    if (/[\x00-\x1f\x7f]/.test(payload)) return rejectAttentionOsc('control-character');
    if (code === 777) {
      if (payload.indexOf('notify;') !== 0) return rejectAttentionOsc('unsupported-command');
      var titleEnd = payload.indexOf(';', 7);
      if (titleEnd <= 7 || titleEnd === payload.length - 1) {
        return rejectAttentionOsc('invalid-notify-fields');
      }
    }
    return { accepted: true, reason: 'ok' };
  }

  function createWheelState() {
    return {
      pendingLines: 0,
      velocityPixelsPerMs: 0,
      lastEventTime: -1,
      direction: 0
    };
  }

  function createBellAttentionGate() {
    var deliveryPending = false;
    var acknowledgementPending = false;
    return {
      trigger: function() {
        acknowledgementPending = true;
        if (deliveryPending) return false;
        deliveryPending = true;
        return true;
      },
      acknowledge: function() {
        if (!acknowledgementPending) return false;
        acknowledgementPending = false;
        deliveryPending = false;
        return true;
      },
      rearmDelivery: function() {
        if (!deliveryPending) return false;
        deliveryPending = false;
        return true;
      },
      isPending: function() { return acknowledgementPending; }
    };
  }

  function countPerfPayloadBytes(payload) {
    if (typeof payload !== 'string') return 0;
    var count = 0;
    for (var i = 0; i < payload.length; i++) {
      if (payload.charCodeAt(i) === 88) count++;
    }
    return count;
  }

  function wheelGain(speedPixelsPerMs) {
    var speed = Math.abs(speedPixelsPerMs);
    if (speed <= 0.5) return 0.4;
    if (speed <= 1.5) return 0.4 + (speed - 0.5) * 1.6;
    if (speed >= 4) return 8;
    return 2 + (speed - 1.5) / 2.5 * 6;
  }

  function enqueueWheel(state, deltaY, deltaMode, cellHeight, rows, timestamp) {
    if (!state || deltaY === 0) return;
    var safeCellHeight = Math.max(1, cellHeight);
    var safeRows = Math.max(1, rows);
    var deltaPixels = deltaY;
    if (deltaMode === 1) deltaPixels = deltaY * safeCellHeight;
    else if (deltaMode === 2) deltaPixels = deltaY * safeCellHeight * safeRows;
    var direction = deltaPixels < 0 ? -1 : 1;
    var eventTime = typeof timestamp === 'number' ? timestamp : 0;
    var eventGap = state.lastEventTime >= 0 ? eventTime - state.lastEventTime : 0;
    if (eventGap > 80) {
      state.pendingLines = 0;
      state.velocityPixelsPerMs = 0;
      state.direction = 0;
    }
    var elapsed = state.lastEventTime >= 0 ? Math.max(1, Math.min(100, eventGap)) : 16;
    var instantVelocity = deltaPixels / elapsed;
    if (state.direction !== 0 && state.direction !== direction) {
      state.pendingLines = 0;
      state.velocityPixelsPerMs = instantVelocity;
    } else if (state.lastEventTime < 0) {
      state.velocityPixelsPerMs = instantVelocity;
    } else {
      state.velocityPixelsPerMs = state.velocityPixelsPerMs * 0.65 + instantVelocity * 0.35;
    }
    state.direction = direction;
    state.lastEventTime = eventTime;
    var gain = deltaMode === 0 ? wheelGain(state.velocityPixelsPerMs) : 1;
    state.pendingLines += deltaPixels / safeCellHeight * gain;
    var maxPendingLines = safeRows * 8;
    state.pendingLines = Math.max(-maxPendingLines, Math.min(maxPendingLines, state.pendingLines));
  }

  function consumeWheelFrame(state, rows) {
    if (!state || Math.abs(state.pendingLines) < 1) return 0;
    var whole = state.pendingLines < 0 ? Math.ceil(state.pendingLines) : Math.floor(state.pendingLines);
    var maxSteps = Math.max(8, Math.floor(Math.max(1, rows) * 1.25));
    var steps = Math.max(-maxSteps, Math.min(maxSteps, whole));
    state.pendingLines -= steps;
    return steps;
  }

  function hasPendingWheelSteps(state) {
    return !!state && Math.abs(state.pendingLines) >= 1;
  }

  function pendingWheelLines(state) {
    return state ? state.pendingLines : 0;
  }

  function centerGridLeadingPadding(baseLeadingPadding, baseTrailingPadding, containerSize, gridSize) {
    var leading = typeof baseLeadingPadding === 'number' && isFinite(baseLeadingPadding)
      ? Math.max(0, baseLeadingPadding)
      : 0;
    var trailing = typeof baseTrailingPadding === 'number' && isFinite(baseTrailingPadding)
      ? Math.max(0, baseTrailingPadding)
      : 0;
    if (typeof containerSize !== 'number' || !isFinite(containerSize) ||
        typeof gridSize !== 'number' || !isFinite(gridSize)) {
      return leading;
    }
    var unusedSize = containerSize - leading - trailing - Math.max(0, gridSize);
    return leading + Math.max(0, unusedSize) / 2;
  }

  function sessionOutputAnchorRow(buffer, rows) {
    if (!buffer || typeof buffer.baseY !== 'number' || typeof buffer.length !== 'number' ||
        typeof buffer.getLine !== 'function' || typeof rows !== 'number' || !isFinite(rows)) {
      return 1;
    }
    var viewportStart = Math.max(0, Math.floor(buffer.baseY));
    var viewportRows = Math.max(1, Math.floor(rows));
    var viewportEnd = Math.min(buffer.length, viewportStart + viewportRows) - 1;
    for (var row = viewportEnd; row >= viewportStart; row--) {
      var line = buffer.getLine(row);
      if (line && line.translateToString(true).length > 0) {
        return row - viewportStart + 1;
      }
    }
    return 1;
  }

  function isLinkModifierActive(event, mouseTrackingMode) {
    if (!event ||
        event.ctrlKey !== true ||
        event.altKey === true ||
        event.metaKey === true) {
      return false;
    }
    if (mouseTrackingMode === 'none') {
      return event.shiftKey !== true;
    }
    var mouseReportingActive =
      mouseTrackingMode === 'x10' ||
      mouseTrackingMode === 'vt200' ||
      mouseTrackingMode === 'drag' ||
      mouseTrackingMode === 'any';
    return mouseReportingActive && event.shiftKey === true;
  }

  function shouldActivateLink(event, mouseTrackingMode, sameLink, dragged) {
    return !!event &&
      event.button === 0 &&
      sameLink === true &&
      dragged !== true &&
      isLinkModifierActive(event, mouseTrackingMode);
  }

  function shouldRunTerminalSecondaryAction(searchOpen) {
    return searchOpen !== true;
  }

  function searchResultLabel(query, resultIndex, resultCount, highlightLimit) {
    if (typeof query !== 'string' || query.length === 0) return '0/0';
    if (resultCount <= 0) return '0/0';
    if (resultIndex < 0) {
      return resultCount >= highlightLimit ? highlightLimit + '+' : '0/' + resultCount;
    }
    return (resultIndex + 1) + '/' + resultCount;
  }

  function wrappedControlIndex(currentIndex, controlCount, backwards) {
    if (controlCount <= 0) return -1;
    var direction = backwards === true ? -1 : 1;
    var safeIndex = currentIndex >= 0 && currentIndex < controlCount ? currentIndex : 0;
    return (safeIndex + direction + controlCount) % controlCount;
  }

  global.LeanTTYTerminalPolicy = {
    MAX_CLIPBOARD_BYTES: MAX_CLIPBOARD_BYTES,
    MAX_CLIPBOARD_BASE64_LENGTH: MAX_CLIPBOARD_BASE64_LENGTH,
    MAX_ATTENTION_OSC_BYTES: MAX_ATTENTION_OSC_BYTES,
    decodeOsc52: decodeOsc52,
    createOsc99CapabilityResponse: createOsc99CapabilityResponse,
    validateAttentionOsc: validateAttentionOsc,
    countPerfPayloadBytes: countPerfPayloadBytes,
    createBellAttentionGate: createBellAttentionGate,
    createWheelState: createWheelState,
    enqueueWheel: enqueueWheel,
    consumeWheelFrame: consumeWheelFrame,
    hasPendingWheelSteps: hasPendingWheelSteps,
    pendingWheelLines: pendingWheelLines,
    centerGridLeadingPadding: centerGridLeadingPadding,
    sessionOutputAnchorRow: sessionOutputAnchorRow,
    isLinkModifierActive: isLinkModifierActive,
    shouldActivateLink: shouldActivateLink,
    shouldRunTerminalSecondaryAction: shouldRunTerminalSecondaryAction,
    searchResultLabel: searchResultLabel,
    wrappedControlIndex: wrappedControlIndex
  };
})(globalThis);
