import { describe, it, expect } from '@ohos/hypium'
import { SshKeyManager } from '../main/ets/model/ssh/SshKeyManager'
import {
  algorithmDisplayName, algorithmFromSshName, algorithmToSshName, KeyAlgorithm, KeyPairInfo
} from '../main/ets/common/types/SshKeyTypes'

function keyNamed(name: string): KeyPairInfo {
  let key: KeyPairInfo = new KeyPairInfo()
  key.filePath = '/data/storage/el2/base/files/.ssh/' + name
  return key
}

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

    it('selectsOnlySupportedDefaultIdentitiesInStablePriorityOrder', 0, () => {
      let ecdsa: KeyPairInfo = keyNamed('id_ecdsa')
      let rsa: KeyPairInfo = keyNamed('id_rsa')
      let ed25519: KeyPairInfo = keyNamed('id_ed25519')
      let securityKey: KeyPairInfo = keyNamed('id_ed25519_sk')

      expect(SshKeyManager.selectDefaultKey([ecdsa, rsa, ed25519])).assertEqual(ed25519)
      expect(SshKeyManager.selectDefaultKey([ecdsa, rsa])).assertEqual(rsa)
      expect(SshKeyManager.selectDefaultKey([securityKey, ecdsa])).assertEqual(ecdsa)
      expect(SshKeyManager.selectDefaultKey([securityKey])).assertEqual(null)
      expect(SshKeyManager.selectDefaultKey([keyNamed('deploy-prod')])).assertEqual(null)
      expect(SshKeyManager.selectDefaultKey([])).assertEqual(null)
    })
  })
}
