import type { ControlEvent as NativeControlEvent } from 'libleantty_ssh.so'
import { SshError, SshErrorCode } from '../../common/types/SshTypes'

export class HostKeyChangedInfo {
  layer: string = ''
  algorithm: string = ''
  oldFingerprint: string = ''
  newFingerprint: string = ''
  host: string = ''
  port: number = 22
}

export class SshControlEventPolicy {
  static isCurrent(
    expectedSessionId: string,
    expectedGeneration: number,
    event: NativeControlEvent
  ): boolean {
    return expectedSessionId.length > 0 && event.sessionId === expectedSessionId &&
      event.generation === expectedGeneration
  }

  static isLayer(layer: string): boolean {
    return layer === 'jump' || layer === 'target'
  }

  static error(event: NativeControlEvent): SshError | null {
    if (event.kind !== 'error' || !SshControlEventPolicy.isLayer(event.layer) ||
      event.stage.length === 0 || event.detail.length === 0) {
      return null
    }
    let code: SshErrorCode
    if (event.code === 'network') { code = SshErrorCode.Network }
    else if (event.code === 'auth') { code = SshErrorCode.Auth }
    else if (event.code === 'host_key') { code = SshErrorCode.HostKey }
    else if (event.code === 'channel') { code = SshErrorCode.Channel }
    else if (event.code === 'protocol') { code = SshErrorCode.Protocol }
    else if (event.code === 'internal') { code = SshErrorCode.Internal }
    else { return null }
    return new SshError(code, event.detail, event.detail, event.layer)
  }

  static hostKeyChanged(event: NativeControlEvent): HostKeyChangedInfo | null {
    if (event.kind !== 'host_key_changed' || !SshControlEventPolicy.isLayer(event.layer) ||
      event.algorithm.length === 0 || event.oldFingerprint.length === 0 ||
      event.newFingerprint.length === 0 || event.host.length === 0 ||
      !Number.isInteger(event.port) || event.port < 1 || event.port > 65535) {
      return null
    }
    let info: HostKeyChangedInfo = new HostKeyChangedInfo()
    info.layer = event.layer
    info.algorithm = event.algorithm
    info.oldFingerprint = event.oldFingerprint
    info.newFingerprint = event.newFingerprint
    info.host = event.host
    info.port = event.port
    return info
  }

  static isHostKeyPrompt(event: NativeControlEvent): boolean {
    return event.kind === 'host_key_prompt' && SshControlEventPolicy.isLayer(event.layer) &&
      event.fingerprint.length > 0 && event.knownHostLine.length > 0
  }

  static safeLogLabel(event: NativeControlEvent): string {
    let allowedKinds: string[] = [
      'connected', 'host_key_prompt', 'host_key_changed', 'error', 'warning', 'output_metrics'
    ]
    if (allowedKinds.indexOf(event.kind) < 0) {
      return 'native control event: rejected'
    }
    let label: string = 'native control event: ' + event.kind
    if (SshControlEventPolicy.isLayer(event.layer)) {
      label += ':' + event.layer
    }
    if ((event.kind === 'error' || event.kind === 'warning') && event.stage.length > 0 &&
      event.code.length > 0) {
      label += ':' + event.stage + ':' + event.code
    }
    return label
  }
}
