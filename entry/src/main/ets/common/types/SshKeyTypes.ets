export enum KeyAlgorithm {
  ED25519 = 0,
  RSA4096 = 1,
  ECDSA_P256 = 2,
  ECDSA_P384 = 3,
  ECDSA_P521 = 4
}

export class KeyPairInfo {
  algorithm: KeyAlgorithm
  filePath: string
  pubPath: string
  fingerprint: string
  publicKeyText: string
  hasPassphrase: boolean

  constructor() {
    this.algorithm = KeyAlgorithm.ED25519
    this.filePath = ''
    this.pubPath = ''
    this.fingerprint = ''
    this.publicKeyText = ''
    this.hasPassphrase = false
  }
}

export class KeyGenerationResult {
  privateKey: KeyPairInfo

  constructor() {
    this.privateKey = new KeyPairInfo()
  }
}

export function algorithmToString(algo: KeyAlgorithm): string {
  if (algo === KeyAlgorithm.RSA4096) {
    return 'rsa-4096'
  }
  return 'ed25519'
}

export function algorithmToSshName(algo: KeyAlgorithm): string {
  if (algo === KeyAlgorithm.RSA4096) {
    return 'ssh-rsa'
  }
  if (algo === KeyAlgorithm.ECDSA_P256) {
    return 'ecdsa-sha2-nistp256'
  }
  if (algo === KeyAlgorithm.ECDSA_P384) {
    return 'ecdsa-sha2-nistp384'
  }
  if (algo === KeyAlgorithm.ECDSA_P521) {
    return 'ecdsa-sha2-nistp521'
  }
  return 'ssh-ed25519'
}

export function algorithmFromSshName(s: string): KeyAlgorithm | null {
  if (s === 'ssh-ed25519') {
    return KeyAlgorithm.ED25519
  }
  if (s === 'ssh-rsa') {
    return KeyAlgorithm.RSA4096
  }
  if (s === 'ecdsa-sha2-nistp256') {
    return KeyAlgorithm.ECDSA_P256
  }
  if (s === 'ecdsa-sha2-nistp384') {
    return KeyAlgorithm.ECDSA_P384
  }
  if (s === 'ecdsa-sha2-nistp521') {
    return KeyAlgorithm.ECDSA_P521
  }
  return null
}

export function algorithmDisplayName(algo: KeyAlgorithm): string {
  if (algo === KeyAlgorithm.RSA4096) {
    return 'rsa'
  }
  if (algo === KeyAlgorithm.ECDSA_P256) {
    return 'ecdsa-p256'
  }
  if (algo === KeyAlgorithm.ECDSA_P384) {
    return 'ecdsa-p384'
  }
  if (algo === KeyAlgorithm.ECDSA_P521) {
    return 'ecdsa-p521'
  }
  return 'ed25519'
}

export function algorithmFromString(s: string): KeyAlgorithm {
  if (s === 'rsa-4096' || s === 'rsa' || s === 'rsa4096') {
    return KeyAlgorithm.RSA4096
  }
  if (s === 'ecdsa-p256' || s === 'ecdsa-sha2-nistp256') {
    return KeyAlgorithm.ECDSA_P256
  }
  if (s === 'ecdsa-p384' || s === 'ecdsa-sha2-nistp384') {
    return KeyAlgorithm.ECDSA_P384
  }
  if (s === 'ecdsa-p521' || s === 'ecdsa-sha2-nistp521') {
    return KeyAlgorithm.ECDSA_P521
  }
  return KeyAlgorithm.ED25519
}
