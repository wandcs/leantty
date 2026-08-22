import paneModelTest from './PaneModel.test';
import connectionControlTest from './ConnectionControl.test';
import sshBehaviorTest from './SshBehavior.test';
import localCommandBehaviorTest from './LocalCommandBehavior.test';
import fileTransferBehaviorTest from './FileTransferBehavior.test';
import keyManagementBehaviorTest from './KeyManagementBehavior.test';
import terminalInteractionTest from './TerminalInteraction.test';
import workspaceInteractionTest from './WorkspaceInteraction.test';
import terminalFormattingTest from './TerminalFormatting.test';
import keySafetyTest from './KeySafety.test';
import durableAssetFormatTest from './DurableAssetFormat.test';
import sshEnvironmentPreparationTest from './SshEnvironmentPreparation.test';
import sshConfigImportTest from './SshConfigImport.test';
import keyCommentCommitTest from './KeyCommentCommit.test';
import keyPairDeletionTest from './KeyPairDeletion.test';
import sshControlEventTest from './SshControlEvent.test';
import sshSessionLifecycleTest from './SshSessionLifecycle.test';
import workspaceOwnershipTest from './WorkspaceOwnership.test';

export default function testsuite() {
  paneModelTest();
  connectionControlTest();
  sshBehaviorTest();
  localCommandBehaviorTest();
  fileTransferBehaviorTest();
  keyManagementBehaviorTest();
  terminalInteractionTest();
  workspaceInteractionTest();
  terminalFormattingTest();
  keySafetyTest();
  durableAssetFormatTest();
  sshEnvironmentPreparationTest();
  sshConfigImportTest();
  keyCommentCommitTest();
  keyPairDeletionTest();
  sshControlEventTest();
  sshSessionLifecycleTest();
  workspaceOwnershipTest();
}
