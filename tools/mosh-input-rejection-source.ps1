# Build-only fault trigger. The real Session queue and mosh_write error mapping
# remain the oracle; no synthetic bytes are enqueued and no receiver is stopped.
function Add-LeanTTYMoshInputRejectionNativeSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $nativePath = Join-Path $RepoRoot 'leantty_ssh/src/lib.rs'
    $typesPath = Join-Path $RepoRoot 'entry/src/main/cpp/types/libleantty_ssh/index.d.ts'
    $native = [IO.File]::ReadAllText($nativePath)
    $types = [IO.File]::ReadAllText($typesPath)
    $native = Set-LeanTTYAcceptanceSourceText $native 'struct MoshSession {' @'
struct MoshSession {
    acceptance_reject_input: std::sync::atomic::AtomicBool,
'@
    foreach ($anchor in @("            MoshSession {`n                generation,",
        "            super::MoshSession {`n                generation: 1,",
        "                    super::MoshSession {`n                        generation: 1,")) {
        $indent = if ($anchor.StartsWith('                    ')) { '                        ' } else { '                ' }
        $native = Set-LeanTTYAcceptanceSourceText $native $anchor (
            $anchor + "`n" + $indent + 'acceptance_reject_input: std::sync::atomic::AtomicBool::new(false),')
    }
    $writeAnchor = @'
        .ok_or_else(|| napi_error("Mosh session not found"))?;
    session
        .write_tx
'@
    $writeReplacement = @'
        .ok_or_else(|| napi_error("Mosh session not found"))?;
    // Hold all permits until the unchanged try_send has evaluated. Reserving
    // the full capacity fails closed unless the actual queue is empty and open.
    let _acceptance_input_permits = if session.acceptance_reject_input.swap(false, Ordering::SeqCst) {
        Some(session.write_tx.try_reserve_many(session.write_tx.max_capacity())
            .map_err(|_| napi_error("Acceptance Mosh input queue was not empty and open"))?)
    } else {
        None
    };
    session
        .write_tx
'@
    $native = Set-LeanTTYAcceptanceSourceText $native $writeAnchor $writeReplacement
    $armMethod = @'
#[napi]
pub fn mosh_arm_input_rejection_for_acceptance(session_id: String) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let sessions = get_mosh_sessions().lock()
        .map_err(|_| napi_error("Mosh session map lock poisoned"))?;
    let session = sessions.get(&id).ok_or_else(|| napi_error("Mosh session not found"))?;
    if session.write_tx.is_closed() || session.write_tx.capacity() != session.write_tx.max_capacity() {
        return Err(napi_error("Acceptance Mosh input queue was not empty and open"));
    }
    if session.acceptance_reject_input.swap(true, Ordering::SeqCst) {
        return Err(napi_error("Acceptance Mosh input rejection already armed"));
    }
    Ok(())
}

'@
    $native = Set-LeanTTYAcceptanceSourceText $native "#[napi]`npub fn mosh_write(" (
        $armMethod + "#[napi]`npub fn mosh_write(")
    $tests = @'
    #[test]
    fn mosh_input_acceptance_rejects_once_without_enqueuing_or_crossing_sessions() {
        let (id, mut receiver, _cleanup) = mosh_input_fixture();
        let (peer, mut peer_receiver, _peer_cleanup) = mosh_input_fixture();
        super::mosh_arm_input_rejection_for_acceptance(id.to_string()).unwrap();
        assert!(super::mosh_arm_input_rejection_for_acceptance(id.to_string()).is_err());
        super::mosh_write(peer.to_string(), "peer".into()).unwrap();
        let error = super::mosh_write(id.to_string(), "unaccepted-private-input".into()).unwrap_err();
        assert_eq!(error.reason, "send failed: no available capacity");
        assert!(matches!(receiver.try_recv(), Err(mpsc::error::TryRecvError::Empty)));
        assert_eq!(peer_receiver.try_recv().unwrap(), b"peer");
        super::mosh_write(id.to_string(), "after-release".into()).unwrap();
        assert_eq!(receiver.try_recv().unwrap(), b"after-release");
        assert_eq!(super::get_mosh_sessions().lock().unwrap().get(&id).unwrap().write_tx.capacity(), 64);
    }

    #[test]
    fn mosh_input_acceptance_refuses_busy_closed_and_missing_sessions() {
        let (id, mut receiver, cleanup) = mosh_input_fixture();
        super::mosh_write(id.to_string(), "pending".into()).unwrap();
        assert!(super::mosh_arm_input_rejection_for_acceptance(id.to_string()).is_err());
        assert_eq!(receiver.try_recv().unwrap(), b"pending");
        super::mosh_write(id.to_string(), "not-armed".into()).unwrap();
        assert_eq!(receiver.try_recv().unwrap(), b"not-armed");
        drop(receiver);
        assert!(super::mosh_arm_input_rejection_for_acceptance(id.to_string()).is_err());
        drop(cleanup);
        assert!(super::mosh_arm_input_rejection_for_acceptance(id.to_string()).is_err());
        assert!(super::mosh_arm_input_rejection_for_acceptance("invalid".into()).is_err());
    }

'@
    $native = Set-LeanTTYAcceptanceSourceText $native (
        "    #[test]`n    fn mosh_input_admission_preserves_order_and_rejects_full_without_sending() {") (
        $tests + "    #[test]`n    fn mosh_input_admission_preserves_order_and_rejects_full_without_sending() {")
    $types = Set-LeanTTYAcceptanceSourceText $types 'export declare function moshWrite(' (
        "export declare function moshArmInputRejectionForAcceptance(sessionId: string): void`n" +
        'export declare function moshWrite(')
    [IO.File]::WriteAllText($nativePath, $native, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($typesPath, $types, [Text.UTF8Encoding]::new($false))
}

function Add-LeanTTYMoshInputRejectionArkTsSource {
    param([Parameter(Mandatory = $true)][hashtable]$Text)

    $Text.moshClient = Set-LeanTTYAcceptanceSourceText $Text.moshClient '  write(data: string): boolean {' @'
  armInputRejectionForAcceptance(): void {
    if (!this.connected || this.sessionId.length === 0) { throw new Error('Mosh probe is not connected') }
    sshNative.moshArmInputRejectionForAcceptance(this.sessionId)
  }

  write(data: string): boolean {
'@
    $Text.moshClient = Set-LeanTTYAcceptanceSourceText $Text.moshClient (
        "      this.logger.warn('Mosh write request rejected')") @'
      this.logger.info('ACCEPTANCE_MOSH_INPUT_REJECTION kind=' +
        (('' + e).indexOf('send failed: no available capacity') >= 0 ? 'full' : 'unexpected'))
      this.logger.warn('Mosh write request rejected')
'@
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session '  private onMoshData(data: Uint8Array): void {' @'
  private acceptanceRejectMoshInput: boolean = false

  armMoshInputRejectionForAcceptance(): void {
    if (!ACCEPTANCE_TESTS || this.moshClient === null || !this.moshClient.isConnected() ||
      !this.acceptingSessionOutput || this.acceptanceRejectMoshInput) { return }
    this.acceptanceRejectMoshInput = true
    this.logger.info('ACCEPTANCE_MOSH_INPUT_REJECTION state=armed')
  }

  private onMoshData(data: Uint8Array): void {
'@
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session '      this.terminalSurface.writeMoshBytes(data)' @'
      this.terminalSurface.writeMoshBytes(data)
      if (ACCEPTANCE_TESTS && this.acceptanceRejectMoshInput && this.moshClient !== null && data.length > 0) {
        this.acceptanceRejectMoshInput = false
        this.logger.info('ACCEPTANCE_MOSH_INPUT_REJECTION receivedBytes=' + data.length.toString())
        try {
          this.moshClient.armInputRejectionForAcceptance()
          this.handleTerminalInput('x\r')
        } catch (e) {
          this.logger.warn('ACCEPTANCE_MOSH_INPUT_REJECTION state=precondition-failed')
        }
      }
'@
    # Disarm on every owner release, including cancel, error and Pane disposal.
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session (
        '  private releaseMoshClient(client: MoshClient): void {') (
        "  private releaseMoshClient(client: MoshClient): void {`n    this.acceptanceRejectMoshInput = false")
    $Text.index = Set-LeanTTYAcceptanceSourceText $Text.index (
        '    let navigationAction: WorkspaceNavigationAction = InteractionPolicy.workspaceNavigationAction(') @'
    if (ACCEPTANCE_TESTS && ctrlKey && altKey && shiftKey && event.keyCode === 2041) {
      let runtime: PaneRuntime | null = this.activePaneRuntime()
      if (runtime !== null) { runtime.viewModel.armMoshInputRejectionForAcceptance() }
      return true
    }
    let navigationAction: WorkspaceNavigationAction = InteractionPolicy.workspaceNavigationAction(
'@
}
