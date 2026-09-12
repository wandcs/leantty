#!/usr/bin/env python3
"""Exercise the real script/PTY/tmux capture owner without Agent or device use."""
import fcntl
import json
import os
import pty
import select
import shlex
import signal
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

from observe_attention import observe
from start_gate import Gate

here = Path(__file__).resolve().parent
harness = here.parent / 'agent-compatibility-wsl.sh'
checks = []
for mode, cancel, scenario in (('direct', False, 'notification'), ('tmux', False, 'notification'),
                               ('tmux', True, 'notification'), ('direct', False, 'interaction')):
    with tempfile.TemporaryDirectory(prefix='leantty-agent-compat-observer-') as directory:
        root = Path(directory)
        subprocess.run(['bash', str(harness), 'prepare', directory], check=True, stdout=subprocess.DEVNULL)
        (root / 'tmux.conf').write_text('set -g bell-action any\nset -g focus-events on\nset -g monitor-bell on\n')
        socket = 'leantty-agent-' + root.name
        producer = ['python3', str(here / 'attention_observer_probe.py'), directory]
        # Replace only the external Agent/npm boundary. Exercise the real launch
        # dispatcher and nested capture, without inspecting auth or invoking a model.
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'npm').write_text('#!/bin/sh\nprintf "%s\\n" ' + shlex.quote(directory) + '\n')
        (bin_dir / 'codex').write_text('#!/bin/sh\nif [ "$1" = login ]; then exit 0; fi\nexec ' + shlex.join(producer) + '\n')
        for executable in bin_dir.iterdir():
            executable.chmod(0o700)
        name = f'codex-{mode}-{scenario}'
        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ['PATH'] = str(bin_dir) + ':' + os.environ['PATH']
            os.execvp('bash', ['bash', str(here / 'capture_notification.sh'), directory, 'codex', mode, scenario])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        def wait_for(condition):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if condition():
                    return
                ready, _, _ = select.select([fd], [], [], .02)
                if ready:
                    try:
                        os.read(fd, 65536)
                    except OSError:
                        pass
            raise AssertionError('actual outer PTY boundary timed out')
        try:
            if scenario == 'notification':
                gate_path = root / 'results' / f'{name}-start-gate.json'
                wait_for(lambda: gate_path.exists() or (root / 'observer-ready').exists())
                assert gate_path.exists(), 'notification child started before the hidden-window gate'
                assert not (root / 'observer-ready').exists(), 'unreleased gate started the child'
                gate = Gate(root, name)
                assert gate.control('ready')['status'] == 'waiting'
                observe(root, name, 'before-minimize')
                observe(root, name, 'after-hidden')
                if cancel:
                    gate.control('cancel')
                    wait_for(lambda: (root / 'results' / f'{name}-outer-final.json').exists())
                    final = observe(root, name, 'probe')
                    assert final['childExitCode'] == 125 and final['attentionCount'] == 0
                    assert not (root / 'observer-ready').exists()
                    assert not (root / 'captures' / f'{name}.outer-output').exists()
                    checks.append({'mode': mode, 'cancelBeforeLaunch': True, 'status': 'passed'})
                    continue
                # Make the first attention immediate, before permitting any child.
                (root / 'observer-early').touch()
                gate.control('release')
            wait_for(lambda: (root / 'observer-ready').exists())
            (root / 'observer-early').touch()
            if scenario == 'interaction':
                (root / 'observer-late').touch()
                (root / 'observer-exit').touch()
                wait_for(lambda: (root / 'results' / f'{name}.json').exists())
                assert not list((root / 'captures').glob('*.outer-*'))
                assert not list((root / 'results').glob('*-outer-*.json'))
                checks.append({'mode': mode, 'scenario': scenario, 'status': 'passed', 'outerObserverStarted': False})
                continue
            wait_for(lambda: observe(root, name, 'probe')['attentionCount'] == 1)
            before = observe(root, name, 'probe')
            assert before['beforeMinimizeCount'] == 0 and before['afterHiddenCount'] == 1
            if not cancel:
                (root / 'observer-late').touch()
                wait_for(lambda: observe(root, name, 'probe')['afterHiddenCount'] == 2)
            (root / 'observer-exit').touch()
            wait_for(lambda: (root / 'results' / f'{name}-outer-final.json').exists())
            final = observe(root, name, 'probe')
            assert final['complete'] and final['childExitCode'] == 0
            assert final['attentionCount'] == (1 if cancel else 2)
            assert not (root / 'captures' / f'{name}.outer-output').exists()
            checks.append({'mode': mode, 'cancelBeforeLate': cancel, 'status': 'passed',
                           'early': final['beforeMinimizeCount'], 'late': final['afterHiddenCount'],
                           'rawDeleted': True})
        finally:
            (root / 'observer-exit').touch(exist_ok=True)
            subprocess.run(['tmux', '-L', socket, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                os.kill(pid, signal.SIGHUP)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
            os.close(fd)
print(json.dumps({'status': 'passed', 'modelRequests': 0, 'checks': checks}))
