#!/usr/bin/env python3
"""Zero-model gate failure boundaries; real fork/PTY/exec, no credentials."""
import json
import os
from pathlib import Path
import pty
import select
import signal
import tempfile
import time
import tty
import unittest

from observe_attention import observe, write_json
from start_gate import Gate


class StartGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='leantty-agent-compat-gate-')
        self.root = Path(self.temp.name)
        (self.root / 'captures').mkdir()
        (self.root / 'results').mkdir()
        (self.root / '.leantty-agent-compat').write_text('controlled-pty-capture\n')
        self.gate = Gate(self.root, 'controlled')
        self.gate.output.touch()
        self.pid = self.fd = None

    def tearDown(self):
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(self.pid, 0)
            os.close(self.fd)
        self.temp.cleanup()

    def launch(self, timeout=5):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            tty.setraw(0)
            command = ['python3', '-c',
                       'import os; data=os.read(0,4); os.write(1,b"PUBLIC\\x1b]777;notify;test\\x07"+data)']
            try:
                code = self.gate.hold(command, timeout=timeout)
            except SystemExit as error:
                code = error.code
            os._exit(code)
        deadline = time.monotonic() + 3
        while not self.gate.state.exists():
            self.assertLess(time.monotonic(), deadline, 'gate readiness deadline')
            time.sleep(.01)

    def hidden(self):
        observe(self.root, 'controlled', 'before-minimize')
        observe(self.root, 'controlled', 'after-hidden')

    def test_original_tty_input_and_output_survive_exec(self):
        self.launch()
        os.write(self.fd, b'aZ1\n')  # Already queued before release; gate must not read it.
        self.assertEqual(select.select([self.fd], [], [], .05)[0], [])
        self.hidden()
        self.gate.control('release')
        self.assertTrue(select.select([self.fd], [], [], 3)[0])
        self.assertEqual(os.read(self.fd, 4096), b'PUBLIC\x1b]777;notify;test\x07aZ1\n')
        self.assertEqual(json.loads(self.gate.state.read_text())['status'], 'started')
        with self.assertRaises(ValueError):
            self.gate.control('release')
        with self.assertRaises(ValueError):
            self.gate.control('cancel')

    def test_cancel_before_readiness_prevents_late_launch(self):
        self.gate.control('cancel')
        with self.assertRaises(ValueError):
            self.gate.control('release')
        self.assertEqual(json.loads(self.gate.state.read_text())['status'], 'cancelled')

    def test_cancel_before_release(self):
        self.launch()
        self.gate.control('cancel')
        self.hidden()
        with self.assertRaises(ValueError):
            self.gate.control('release')
        self.assertEqual(json.loads(self.gate.state.read_text())['status'], 'cancelled')

    def test_cancel_released_but_not_consumed(self):
        write_json(self.gate.state, {'status': 'released', 'pid': os.getpid(),
                                    'deadline': time.monotonic() + 5})
        self.gate.control('cancel')
        with self.assertRaises(ValueError):
            self.gate.control('release')

    def test_timeout_fails_closed(self):
        self.launch(timeout=.15)
        deadline = time.monotonic() + 3
        while json.loads(self.gate.state.read_text())['status'] == 'waiting':
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        self.assertEqual(json.loads(self.gate.state.read_text())['status'], 'expired')
        self.hidden()
        with self.assertRaises(ValueError):
            self.gate.control('release')

    def test_hangup_cancels_waiting_gate(self):
        self.launch()
        os.kill(self.pid, signal.SIGHUP)
        deadline = time.monotonic() + 3
        while json.loads(self.gate.state.read_text())['status'] == 'waiting':
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        self.assertEqual(json.loads(self.gate.state.read_text())['status'], 'cancelled')

    def test_release_requires_both_current_capture_checkpoints(self):
        self.launch()
        with self.assertRaises(FileNotFoundError):
            self.gate.control('release')
        observe(self.root, 'controlled', 'before-minimize')
        with self.assertRaises(ValueError):
            self.gate.control('release')
        write_json(self.gate.checkpoints, {'before-minimize': 0, 'after-hidden': 1})
        with self.assertRaises(ValueError):
            self.gate.control('release')
        self.assertEqual(self.gate.control('ready')['status'], 'waiting')

    def test_wrong_name_sentinel_or_path_is_rejected(self):
        with self.assertRaises(ValueError):
            Gate(self.root, '../wrong')
        with self.assertRaises(ValueError):
            Gate(self.root, 'another').control('release')
        (self.root / '.leantty-agent-compat').write_text('wrong\n')
        with self.assertRaises(ValueError):
            Gate(self.root, 'controlled')


if __name__ == '__main__':
    unittest.main()
