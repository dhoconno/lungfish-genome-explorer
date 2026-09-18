"""Fake-only end-to-end signing stage recovery; never invokes credential tools."""
import importlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from scripts.release.release_profiles import ReleaseProfile


class SigningPipelineTests(unittest.TestCase):
    def setUp(self):
        self.m = importlib.import_module('scripts.release.signing_pipeline')
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / 'unsigned' / 'Example.app'
        (self.source / 'Contents/MacOS').mkdir(parents=True)
        (self.source / 'Contents/MacOS/lungfish-cli').write_bytes(b'fake cli')
        (self.source / 'Contents/Info.plist').write_bytes(b'fake info')
        self.receipt = self.root / 'candidate.json'; self.receipt.write_text('{}')
        self.entitlements = self.root / 'entitlements'; self.entitlements.write_text('fake')
        self.output = self.root / 'signed/Example.app'
        self.dmg = self.root / 'Example.dmg'
        self.tx = self.root / 'transaction'
        self.profile = ReleaseProfile('example/product', 'Developer ID Application: Example (TEAM123456)', 'TEAM123456', 'notary', signing_keychain='/fake/keychain', certificate_sha1='A' * 40, schema_version=2)
        self.calls = []

    def run_tool(self, argv, **kwargs):
        self.calls.append(argv)
        name = Path(argv[0]).name
        if name == 'ditto':
            if '-c' in argv: Path(argv[-1]).write_bytes(b'fixed signed zip')
            else: shutil.copytree(argv[-2], argv[-1])
        elif name == 'hdiutil': Path(argv[-1]).write_bytes(b'fixed dmg')
        elif name == 'codesign':
            if '--display' in argv: return subprocess.CompletedProcess(argv, 0, '', 'TeamIdentifier=TEAM123456\n')
            if '--sign' in argv:
                self.assertEqual(argv[argv.index('--sign') + 1], 'A' * 40)
                self.assertIn('/fake/keychain', argv)
                path = Path(argv[-1])
                if path.is_dir(): (path / 'signed-marker').write_text('sealed')
                else: path.write_bytes(path.read_bytes() + b'-signed')
        elif name == 'xcrun':
            self.assertEqual(argv[1], 'stapler')
            if argv[2] == 'staple':
                path = Path(argv[-1])
                if path.is_dir(): (path / 'ticket').write_text('ticket')
                else: path.write_bytes(path.read_bytes() + b'-stapled')
        elif name == 'file': return subprocess.CompletedProcess(argv, 0, 'Mach-O 64-bit executable', '')
        else: self.fail('unexpected tool: ' + name)
        return subprocess.CompletedProcess(argv, 0, '', '')

    def pipeline(self, notary):
        return self.m.sign_and_notarize(self.source, self.receipt, self.output, self.dmg, self.tx, self.profile,
            entitlements=self.entitlements, volume_name='Example', public_key='public-key', run=self.run_tool, notary=notary)

    def test_pending_resume_never_resigns_or_recreates_notarized_inputs(self):
        stage = ['app-pending']
        def notary(artifact, state, profile, **kwargs):
            if artifact.suffix == '.zip' and stage[0] == 'app-pending': return {'status':'In Progress'}
            if artifact.suffix == '.dmg' and stage[0] != 'complete': return {'status':'In Progress'}
            return {'status':'Accepted'}
        self.assertEqual(self.pipeline(notary)['status'], 'In Progress')
        signing_calls = len([c for c in self.calls if '--sign' in c])
        zip_calls = len([c for c in self.calls if '-c' in c])
        stage[0] = 'dmg-pending'
        self.assertEqual(self.pipeline(notary)['status'], 'In Progress')
        self.assertEqual(len([c for c in self.calls if '-c' in c]), zip_calls)
        self.assertEqual(len([c for c in self.calls if '--sign' in c]), signing_calls + 1)
        original = (self.tx / 'input.dmg').read_bytes()
        stage[0] = 'complete'
        self.assertEqual(self.pipeline(notary)['status'], 'Accepted')
        self.assertEqual((self.tx / 'input.dmg').read_bytes(), original)
        self.assertEqual(self.dmg.read_bytes(), original + b'-stapled')
        before = list(self.calls)
        self.assertEqual(self.pipeline(notary)['status'], 'Accepted')
        self.assertEqual(self.calls, before)

    def test_hdiutil_output_is_outside_retained_transaction_and_then_adopted(self):
        self.assertEqual(
            self.pipeline(lambda *a, **kw: {'status':'Accepted'})['status'],
            'Accepted',
        )
        create = next(call for call in self.calls if Path(call[0]).name == 'hdiutil')
        self.assertIn('-size', create)
        capacity = create[create.index('-size') + 1]
        self.assertRegex(capacity, r'^[1-9][0-9]*m$')
        self.assertGreaterEqual(int(capacity[:-1]), 129)
        temporary_dmg = Path(create[-1])
        self.assertNotEqual(temporary_dmg.parent, self.tx)
        self.assertFalse(temporary_dmg.is_relative_to(self.tx))
        self.assertTrue((self.tx / 'input.dmg').is_file())
        self.assertEqual((self.tx / 'input.dmg').read_bytes(), b'fixed dmg-signed')

    def test_dmg_capacity_counts_sparse_logical_size(self):
        stage = self.root / 'stage'; stage.mkdir()
        with (stage / 'sparse').open('wb') as payload:
            payload.truncate(200 * 1024 * 1024)
        self.assertEqual(self.m._dmg_capacity_mib(stage), 429)

    def test_dmg_capacity_does_not_follow_external_symlink(self):
        stage = self.root / 'stage'; stage.mkdir()
        outside = self.root / 'outside'; outside.mkdir()
        with (outside / 'large').open('wb') as payload:
            payload.truncate(2 * 1024 * 1024 * 1024)
        (stage / 'Applications').symlink_to(outside)
        self.assertLessEqual(self.m._dmg_capacity_mib(stage), 130)

    def test_dmg_capacity_adds_bounded_headroom_for_small_source(self):
        stage = self.root / 'stage'; stage.mkdir()
        capacity = self.m._dmg_capacity_mib(stage)
        self.assertGreaterEqual(capacity, 129)
        self.assertLessEqual(capacity, 130)

    def test_enospc_dmg_retry_reuses_signed_app_and_app_notary_payload(self):
        original = self.run_tool
        attempts = [0]
        app_notary_payloads = []
        def fail_first_dmg_create(argv, **kwargs):
            if Path(argv[0]).name == 'hdiutil':
                attempts[0] += 1
                if attempts[0] == 1:
                    return subprocess.CompletedProcess(argv, 28, '', 'No space left on device')
            return original(argv, **kwargs)
        def notary(artifact, *args, **kwargs):
            if artifact.suffix == '.zip': app_notary_payloads.append(artifact.read_bytes())
            return {'status': 'Accepted'}
        self.run_tool = fail_first_dmg_create
        with self.assertRaises(self.m.SigningError): self.pipeline(notary)
        signed_app_copies = len([c for c in self.calls if Path(c[0]).name == 'ditto' and Path(c[-1]) == self.output])
        app_zip_creates = len([c for c in self.calls if Path(c[0]).name == 'ditto' and '-c' in c])
        signing_calls = len([c for c in self.calls if '--sign' in c])
        self.assertEqual(self.pipeline(notary)['status'], 'Accepted')
        self.assertEqual(attempts[0], 2)
        self.assertEqual(len([c for c in self.calls if Path(c[0]).name == 'ditto' and Path(c[-1]) == self.output]), signed_app_copies)
        self.assertEqual(len([c for c in self.calls if Path(c[0]).name == 'ditto' and '-c' in c]), app_zip_creates)
        self.assertEqual(len([c for c in self.calls if '--sign' in c]), signing_calls + 1)
        self.assertEqual(len(app_notary_payloads), 2)
        self.assertEqual(app_notary_payloads[0], app_notary_payloads[1])

    def test_changed_candidate_or_retained_signed_payload_blocks_before_tools(self):
        self.pipeline(lambda *a, **kw: {'status':'In Progress'})
        before = list(self.calls)
        self.receipt.write_text('{"changed":true}')
        with self.assertRaises(self.m.SigningError): self.pipeline(lambda *a, **kw: {'status':'Accepted'})
        self.assertEqual(self.calls, before)

    def test_preexisting_outputs_without_transaction_are_never_removed(self):
        self.dmg.write_bytes(b'irreplaceable')
        with self.assertRaises(self.m.SigningError): self.pipeline(lambda *a, **kw: {'status':'Accepted'})
        self.assertEqual(self.dmg.read_bytes(), b'irreplaceable')
        self.assertFalse(self.calls)

    def test_failed_staple_does_not_mark_partial_pipeline_complete(self):
        original = self.run_tool
        failed = [False]
        def fail_once(argv, **kwargs):
            if argv[1:3] == ['stapler', 'staple'] and not failed[0]:
                failed[0] = True
                return subprocess.CompletedProcess(argv, 124, '', '')
            return original(argv, **kwargs)
        self.run_tool = fail_once
        with self.assertRaises(self.m.SigningError): self.pipeline(lambda *a, **kw: {'status':'Accepted'})
        self.assertFalse(self.dmg.exists())
        self.assertEqual(self.pipeline(lambda *a, **kw: {'status':'Accepted'})['status'], 'Accepted')
        self.assertTrue(self.dmg.is_file())

    def test_changed_retained_app_blocks_before_any_new_tool_or_notary_call(self):
        self.pipeline(lambda *a, **kw: {'status':'In Progress'})
        before = list(self.calls)
        app_input = self.tx / 'Example.app/Contents/MacOS/lungfish-cli'
        app_input.write_bytes(b'changed retained executable')
        with self.assertRaises(self.m.SigningError):
            self.pipeline(lambda *a, **kw: self.fail('changed input must not reach notarization'))
        self.assertEqual(self.calls, before)
        self.assertEqual(json.loads((self.tx / 'transaction.json').read_text())['status'], 'Blocked')

    def test_actual_signed_app_team_must_match_selected_profile(self):
        original = self.run_tool
        def wrong_team(argv, **kwargs):
            if '--display' in argv: return subprocess.CompletedProcess(argv, 0, '', 'TeamIdentifier=OTHERTEAM1\n')
            return original(argv, **kwargs)
        self.run_tool = wrong_team
        with self.assertRaises(self.m.SigningError):
            self.pipeline(lambda *a, **kw: self.fail('wrong team must not reach notarization'))
