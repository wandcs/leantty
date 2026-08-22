import paneModelTest from './PaneModel.test';
import connectionControlTest from './ConnectionControl.test';
import interactionFixesTest from './InteractionFixes.test';
import keySafetyTest from './KeySafety.test';
import durableAssetFormatTest from './DurableAssetFormat.test';
import sshEnvironmentPreparationTest from './SshEnvironmentPreparation.test';
import sshConfigImportTest from './SshConfigImport.test';
import keyCommentCommitTest from './KeyCommentCommit.test';
import keyPairDeletionTest from './KeyPairDeletion.test';
import sshControlEventTest from './SshControlEvent.test';

export default function testsuite() {
  paneModelTest();
  connectionControlTest();
  interactionFixesTest();
  keySafetyTest();
  durableAssetFormatTest();
  sshEnvironmentPreparationTest();
  sshConfigImportTest();
  keyCommentCommitTest();
  keyPairDeletionTest();
  sshControlEventTest();
}
