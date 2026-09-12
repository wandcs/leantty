#!/usr/bin/env python3
"""Unit evidence only; no Agent, device, credentials or model requests."""
import json
import tempfile
import unittest
from pathlib import Path

from observe_attention import attention_events, observe, summarize


class AttentionObserverTests(unittest.TestCase):
    def test_string_terminators_and_dcs_payload_are_not_bells(self):
        self.assertEqual(attention_events(b'\x1b]2;title\x07\x1bPpayload\x07\x1b\\'), [])
        self.assertEqual(attention_events(b'\x1b]2;unfinished'), [])
        self.assertEqual(attention_events(b'\x1bPunfinished\x07'), [])

    def test_supported_attention_frames(self):
        events = attention_events(b'\x07\x1b]9;public\x07\x1b]777;notify;public\x1b\\\x1b]99;;public\x07')
        self.assertEqual([event['kind'] for event in events], ['bel', 'osc-9', 'osc-777', 'osc-99'])

    def test_split_frame_remains_ambiguous(self):
        data = b'\x07\x1b]9;public\x07\x07'
        result = summarize({'events': attention_events(data), 'bytes': len(data), 'complete': False,
                            'childExitCode': -1}, {'before-minimize': 1, 'after-hidden': 5})
        self.assertEqual((result['beforeMinimizeCount'], result['hideIntervalOrUnorderedCount'],
                          result['afterHiddenCount']), (1, 1, 1))

    def test_checkpoint_live_finish_and_raw_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='leantty-agent-compat-observer-') as directory:
            root = Path(directory)
            (root / '.leantty-agent-compat').write_text('controlled-pty-capture\n')
            (root / 'captures').mkdir()
            (root / 'results').mkdir()
            raw = root / 'captures' / 'controlled.outer-output'
            raw.write_bytes(b'public\x07')
            observe(root, 'controlled', 'before-minimize')
            with raw.open('ab') as stream:
                stream.write(b'\x07')
            observe(root, 'controlled', 'after-hidden')
            with raw.open('ab') as stream:
                stream.write(b'\x07')
            live = observe(root, 'controlled', 'probe')
            self.assertEqual((live['beforeMinimizeCount'], live['hideIntervalOrUnorderedCount'],
                              live['afterHiddenCount']), (1, 1, 1))
            self.assertEqual(live['afterMinimizeStartCount'], 2)
            final = observe(root, 'controlled', 'finish', 130)
            self.assertFalse(raw.exists())
            # Numeric checkpoints are metadata, not raw terminal output.
            self.assertTrue((root / 'captures' / 'controlled.outer-checkpoints').exists())
            self.assertEqual(final['childExitCode'], 130)
            self.assertEqual(observe(root, 'controlled', 'probe'), final)
            for path in (root / 'results').iterdir():
                self.assertNotIn('public', path.read_text())
                json.loads(path.read_text())
            with self.assertRaisesRegex(ValueError, 'cannot be replaced'):
                observe(root, 'controlled', 'after-hidden')

    def test_missing_or_reversed_barrier_is_not_post_hide(self):
        capture = {'events': attention_events(b'\x07'), 'bytes': 1, 'complete': False, 'childExitCode': -1}
        self.assertEqual(summarize(capture, {})['afterHiddenCount'], 0)
        with self.assertRaisesRegex(ValueError, 'out of order'):
            summarize(capture, {'after-hidden': 0})
        with self.assertRaisesRegex(ValueError, 'shrank'):
            summarize(capture, {'before-minimize': 2})

    def test_event_limit_is_bounded(self):
        with self.assertRaisesRegex(ValueError, 'limit exceeded'):
            attention_events(b'\x07' * 4097)

    def test_action_barrier_excludes_frames_started_before_it(self):
        data = b'\x1b]9;public\x07\x07'
        capture = {'events': attention_events(data), 'bytes': len(data), 'complete': True, 'childExitCode': 0}
        result = summarize(capture, {'before-minimize': 3, 'after-hidden': len(data)})
        self.assertEqual(result['afterMinimizeStartCount'], 1)
        self.assertEqual(result['afterHiddenCount'], 0)
        self.assertEqual(summarize(capture, {})['afterMinimizeStartCount'], 0)


if __name__ == '__main__':
    unittest.main()
