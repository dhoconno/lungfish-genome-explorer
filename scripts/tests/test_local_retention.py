import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


class LocalRetentionTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('local_retention', Path(__file__).parents[1] / 'local-retention.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def candidate(self, number, status=None):
        path = self.root / 'build/Release/preview' / f'{number:040x}'
        path.mkdir(parents=True)
        (path / 'unsigned-candidate-receipt.json').write_text(json.dumps({
            'source': {'commit': path.name}, 'release': {'build': str(number), 'channel': 'preview', 'version': f'2026.9.{number}'},
            'wrapper': {'filename': 'Lungfish Preview.app'}}))
        (path / 'Lungfish Preview.app').mkdir()
        (path / 'logs').mkdir()
        (path / 'logs/run.log').write_text('evidence')
        (path / 'sample.lungfish').mkdir()
        if status:
            (path / 'signing-transaction').mkdir()
            (path / 'signing-transaction/transaction.json').write_text(json.dumps({'status': status}))
        return path

    def test_keeps_two_recent_and_preserves_evidence_and_unknown_data(self):
        old = self.candidate(1)
        self.candidate(2)
        self.candidate(3)
        paths, held = self.module.candidates(self.root, 2)
        self.assertEqual(paths, [old / 'Lungfish Preview.app'])

    def test_holds_unfinished_signing_and_symlinked_candidates(self):
        pending = self.candidate(1, 'Preparing')
        recent = self.candidate(3)
        link = recent.parent / ('f' * 40)
        link.symlink_to(pending, target_is_directory=True)
        paths, held = self.module.candidates(self.root, 1)
        self.assertEqual(paths, [])
        self.assertTrue(any('signing' in reason for reason in held))

    def test_rejects_invalid_keep(self):
        with self.assertRaises(ValueError):
            self.module.candidates(self.root, 0)

    def test_notary_acceptance_alone_does_not_authorize_removal(self):
        old = self.candidate(1, 'Accepted')
        self.candidate(2)
        paths, held = self.module.candidates(self.root, 1)
        self.assertEqual(paths, [])
        self.assertTrue(any('published' in reason for reason in held))
        paths, held = self.module.candidates(self.root, 1, {('v2026.9.1', 'preview'): old.name})
        self.assertEqual(paths, [old / 'Lungfish Preview.app'])

    def test_snapshot_changes_when_nested_file_changes(self):
        p = self.root / 'payload'
        p.mkdir()
        f = p / 'object.o'
        f.write_bytes(b'one')
        before = self.module.snapshot(p)
        f.write_bytes(b'longer')
        self.assertNotEqual(before, self.module.snapshot(p))

    def test_payload_symlink_is_not_selected(self):
        old = self.candidate(1)
        (old / 'Lungfish Preview.app').rmdir()
        (old / 'Lungfish Preview.app').symlink_to(self.root)
        self.candidate(2)
        paths, held = self.module.candidates(self.root, 1)
        self.assertEqual(paths, [])


if __name__ == '__main__':
    unittest.main()
