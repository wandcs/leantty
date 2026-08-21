import { describe, it, expect } from '@ohos/hypium'
import { SshKeyManager } from '../main/ets/model/ssh/SshKeyManager'
import {
  algorithmDisplayName, algorithmFromSshName, algorithmToSshName, KeyAlgorithm
} from '../main/ets/common/types/SshKeyTypes'

export default function keySafetyTest() {
  describe('KeySafety', () => {
    it('rejectsSshControlFilesAsKeyNames', 0, () => {
      expect(SshKeyManager.validateKeyName('config') !== null).assertEqual(true)
      expect(SshKeyManager.validateKeyName('config.leantty.bak') !== null).assertEqual(true)
      expect(SshKeyManager.validateKeyName('known_hosts') !== null).assertEqual(true)
      expect(SshKeyManager.validateKeyName('known_hosts.old') !== null).assertEqual(true)
      expect(SshKeyManager.validateKeyName('authorized_keys') !== null).assertEqual(true)
    })

    it('keepsCustomKeyNamesAvailable', 0, () => {
      expect(SshKeyManager.validateKeyName('deploy-prod')).assertEqual(null)
      expect(SshKeyManager.validateKeyName('work.github')).assertEqual(null)
    })

    it('mapsOnlySupportedOpenSshIdentityAlgorithms', 0, () => {
      expect(algorithmFromSshName('ssh-ed25519')).assertEqual(KeyAlgorithm.ED25519)
      expect(algorithmFromSshName('ssh-rsa')).assertEqual(KeyAlgorithm.RSA4096)
      expect(algorithmFromSshName('ecdsa-sha2-nistp256')).assertEqual(KeyAlgorithm.ECDSA_P256)
      expect(algorithmFromSshName('ecdsa-sha2-nistp384')).assertEqual(KeyAlgorithm.ECDSA_P384)
      expect(algorithmFromSshName('ecdsa-sha2-nistp521')).assertEqual(KeyAlgorithm.ECDSA_P521)
      expect(algorithmFromSshName('sk-ecdsa-sha2-nistp256@openssh.com')).assertEqual(null)
      expect(algorithmFromSshName('ssh-dss')).assertEqual(null)
    })

    it('keepsExactCurveNamesForPublicPairValidationAndDisplay', 0, () => {
      expect(algorithmToSshName(KeyAlgorithm.ECDSA_P256)).assertEqual('ecdsa-sha2-nistp256')
      expect(algorithmToSshName(KeyAlgorithm.ECDSA_P384)).assertEqual('ecdsa-sha2-nistp384')
      expect(algorithmToSshName(KeyAlgorithm.ECDSA_P521)).assertEqual('ecdsa-sha2-nistp521')
      expect(algorithmDisplayName(KeyAlgorithm.ECDSA_P256)).assertEqual('ecdsa-p256')
      expect(algorithmDisplayName(KeyAlgorithm.ECDSA_P384)).assertEqual('ecdsa-p384')
      expect(algorithmDisplayName(KeyAlgorithm.ECDSA_P521)).assertEqual('ecdsa-p521')
    })
  })
}
