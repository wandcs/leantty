import { createHash } from 'node:crypto';

/**
 * xterm 6.0.0 input-order repair, owned by its existing CompositionHelper.
 * https://github.com/xtermjs/xterm.js/issues/6045
 *
 * Readable equivalent (the composition finalizer itself is unchanged):
 *
 *   get isInputComposing() { return this._isComposing || this._isSendingComposition; }
 *   cancelTextareaChanges() { this._pendingTextareaChange = undefined; }
 *   flushTextareaChanges() { this._pendingTextareaChange?.(); }
 *
 *   _handleAnyTextareaChanges() {
 *     if (this._pendingTextareaChange) return;
 *     const oldValue = this._textarea.value;
 *     const send = () => {
 *       if (this._pendingTextareaChange !== send) return;
 *       this._pendingTextareaChange = undefined;
 *       if (!this._isComposing) {
 *         const newValue = this._textarea.value;
 *         const diff = newValue.replace(oldValue, '');
 *         this._dataAlreadySent = diff;
 *         if (newValue.length > oldValue.length) this._coreService.triggerDataEvent(diff, true);
 *         else if (newValue.length < oldValue.length) this._coreService.triggerDataEvent(C0.DEL, true);
 *         else if (newValue !== oldValue) this._coreService.triggerDataEvent(newValue, true);
 *       }
 *     };
 *     this._pendingTextareaChange = send;
 *     setTimeout(send, 0);
 *   }
 *
 *   _inputEvent(ev) {
 *     if (this.optionsService.rawOptions.screenReaderMode || ev.isComposing ||
 *         this._compositionHelper.isInputComposing) return false;
 *     if (ev.data && ev.inputType === 'insertText') {
 *       this._compositionHelper.cancelTextareaChanges();
 *       if (this._keyPressHandled) return false;
 *       this._unprocessedDeadKey = false;
 *       this.coreService.triggerDataEvent(ev.data, true);
 *       this.cancel(ev);
 *       return true;
 *     }
 *     this._compositionHelper.flushTextareaChanges();
 *     return false;
 *   }
 *
 * compositionstart cancels the pending non-composition diff. _inputEvent:
 * - preserves screenReaderMode's original legacy path;
 * - leaves composing events and the pending finalizer to composition;
 * - insertText cancels the pending diff before the existing keypress guard and
 *   direct emission, instead of using keyDownSeen as a composition proxy;
 * - other non-composing input flushes an existing legacy diff synchronously,
 *   so a deletion cannot be erased by the next insertion's cancellation.
 *
 * One pending callback per helper retains the earliest unconsumed snapshot.
 * Identity invalidation covers every already queued callback without a timing
 * threshold, text-based deduplication, global flag or LeanTTY-side compensation.
 * No new DOM listeners, dependencies or composition-state machine are added.
 *
 * Remove when a pinned upstream release passes the same behavior corpus.
 * On any upstream drift, re-audit or remove; never silently re-match minified JS.
 */
export const XTERM_INPUT_ORDER_PATCH = Object.freeze({
  packageName: '@xterm/xterm',
  packageVersion: '6.0.0',
  upstreamCommit: 'f447274f430fd22513f6adbf9862d19524471c04',
  upstreamSources: ['src/browser/CoreBrowserTerminal.ts', 'src/browser/input/CompositionHelper.ts'],
  inputSha256: '14903579ff54664cd72f8e8699e6961a6272c21863ec1c3b118cdc8af5d4a972'
});

const replacements = [
  ['get isComposing(){return this._isComposing}',
    'get isComposing(){return this._isComposing}get isInputComposing(){return this._isComposing||this._isSendingComposition}cancelTextareaChanges(){this._pendingTextareaChange=void 0}flushTextareaChanges(){this._pendingTextareaChange?.()}'],
  ['compositionstart(){this._isComposing=!0,',
    'compositionstart(){this.cancelTextareaChanges(),this._isComposing=!0,'],
  ['_handleAnyTextareaChanges(){const e=this._textarea.value;setTimeout((()=>{if(!this._isComposing){const t=this._textarea.value,i=t.replace(e,"");this._dataAlreadySent=i,t.length>e.length?this._coreService.triggerDataEvent(i,!0):t.length<e.length?this._coreService.triggerDataEvent(`${a.C0.DEL}`,!0):t.length===e.length&&t!==e&&this._coreService.triggerDataEvent(t,!0)}}),0)}',
    '_handleAnyTextareaChanges(){if(this._pendingTextareaChange)return;const e=this._textarea.value,s=()=>{if(this._pendingTextareaChange!==s)return;this._pendingTextareaChange=void 0;if(!this._isComposing){const t=this._textarea.value,i=t.replace(e,"");this._dataAlreadySent=i,t.length>e.length?this._coreService.triggerDataEvent(i,!0):t.length<e.length?this._coreService.triggerDataEvent(`${a.C0.DEL}`,!0):t.length===e.length&&t!==e&&this._coreService.triggerDataEvent(t,!0)}};this._pendingTextareaChange=s,setTimeout(s,0)}'],
  ['_inputEvent(e){if(e.data&&"insertText"===e.inputType&&(!e.composed||!this._keyDownSeen)&&!this.optionsService.rawOptions.screenReaderMode){if(this._keyPressHandled)return!1;this._unprocessedDeadKey=!1;const t=e.data;return this.coreService.triggerDataEvent(t,!0),this.cancel(e),!0}return!1}',
    '_inputEvent(e){if(this.optionsService.rawOptions.screenReaderMode||e.isComposing||this._compositionHelper.isInputComposing)return!1;if(e.data&&"insertText"===e.inputType){this._compositionHelper.cancelTextareaChanges();if(this._keyPressHandled)return!1;this._unprocessedDeadKey=!1;const t=e.data;return this.coreService.triggerDataEvent(t,!0),this.cancel(e),!0}return this._compositionHelper.flushTextareaChanges(),!1}']
];

export function applyXtermInputOrderPatch(content, version) {
  const metadata = XTERM_INPUT_ORDER_PATCH;
  if (version !== metadata.packageVersion) {
    throw new Error(`Expected ${metadata.packageName} ${metadata.packageVersion}, received ${version}. Review/remove the input-order patch.`);
  }
  const hash = createHash('sha256').update(content, 'utf8').digest('hex');
  if (hash !== metadata.inputSha256) {
    throw new Error(`Input-order patch input SHA-256 mismatch: ${hash}. Re-audit the upstream asset.`);
  }
  for (const [target, replacement] of replacements) {
    const matches = content.split(target).length - 1;
    if (matches !== 1) throw new Error(`Input-order patch expected one audited site, found ${matches}.`);
    content = content.replace(target, replacement);
  }
  return content;
}
