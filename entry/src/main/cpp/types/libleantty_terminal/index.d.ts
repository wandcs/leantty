export interface TerminalHandle {}
export interface TerminalEventCallback {
  (kind: string, sequence: number, owner: number, text: string): void;
}
export const create: (regular: ArrayBuffer, bold: ArrayBuffer, callback: TerminalEventCallback) => TerminalHandle;
export const write: (handle: TerminalHandle, bytes: ArrayBuffer, owner: number) => number;
export const barrier: (handle: TerminalHandle, owner: number) => number;
export const positionSessionOutput: (handle: TerminalHandle) => number;
export const page: (handle: TerminalHandle, temporary: boolean, owner: number) => number;
export const attach: (handle: TerminalHandle, surfaceId: string, width: number, height: number, fontPixels: number, generation: number, insetPixels: number, cursorStrokePixels: number) => number;
export const detach: (handle: TerminalHandle) => number;
export const key: (handle: TerminalHandle, keyCode: number, modifiers: number, owner: number, text: string, unshiftedCodepoint: number) => number;
export const paste: (handle: TerminalHandle, text: string, owner: number) => number;
export const pointer: (handle: TerminalHandle, action: number, button: number, x: number, y: number, modifiers: number, owner: number) => number;
export const hover: (handle: TerminalHandle, modifiers: number, owner: number) => number;
export const scroll: (handle: TerminalHandle, lines: number, owner: number, local: boolean) => number;
export const copy: (handle: TerminalHandle, action: number, owner: number, revision: number) => number;
export const search: (handle: TerminalHandle, needle: string, direction: number, generation: number) => number;
export const cursor: (handle: TerminalHandle, owner: number, x: number, y: number, height: number) => void;
export const focus: (handle: TerminalHandle, focused: boolean) => number;
export const visibility: (handle: TerminalHandle, visible: boolean, generation: number) => number;
export const ime: (handle: TerminalHandle, context: Object, owner: number, x: number, y: number, height: number, masked: boolean) => void;
export const blur: (handle: TerminalHandle) => void;
export const close: (handle: TerminalHandle) => Promise<void>;
