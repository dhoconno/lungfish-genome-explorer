"""Credential configuration and supervision; uses disposable fake tools only."""
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.module = importlib.import_module('scripts.release.release_profiles')

    def test_legacy_profile_remains_usable_without_rewrite(self):
        path = self.root / 'legacy.json'
        raw = json.dumps(dict(schemaVersion=1, repository='Example/Product', signingIdentity='Developer ID Application: Example (TEAM123456)', teamId='TEAM123456', notaryProfile='example-notary'))
        path.write_text(raw); path.chmod(0o600)
        p = self.module.load_release_profile(path, expected_repository='example/product')
        self.assertEqual(p.sparkle_account, 'ed25519')
        self.assertEqual(p.schema_version, 1)
        self.assertEqual(path.read_text(), raw)

    def test_v2_roundtrip_and_no_overwrite(self):
        p = self.module.ReleaseProfile('example/product', 'Developer ID Application: Example (TEAM123456)', 'TEAM123456', 'example-notary', signing_keychain='/private/example.keychain-db', certificate_sha1='A' * 40, notary_keychain='/private/notary.keychain-db', sparkle_account='example.product', schema_version=2)
        path = self.root / 'nested' / 'profile.json'
        self.module.write_release_profile(path, p)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.module.load_release_profile(path), p)
        with self.assertRaises(self.module.ProfileError): self.module.write_release_profile(path, p)
        with self.assertRaises(self.module.ProfileError): self.module.load_release_profile(path, expected_repository='other/product')
        path.chmod(0o644)
        with self.assertRaises(self.module.ProfileError): self.module.load_release_profile(path)

    def test_rejects_unknown_secret_fields_and_symlink_parents(self):
        p = dict(schemaVersion=2, repository='example/product', signing=dict(identity='Developer ID Application: Example (TEAM123456)', teamId='TEAM123456', keychainPath=None, certificateSha1=None), notary=dict(profile='notary', keychainPath=None), sparkle=dict(account='example.product'))
        path = self.root / 'profile.json'
        p['notary']['password'] = 'test-placeholder'
        path.write_text(json.dumps(p)); path.chmod(0o600)
        with self.assertRaises(self.module.ProfileError): self.module.load_release_profile(path)
        alias = self.root / 'alias'; alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(self.module.ProfileError): self.module.load_release_profile(alias / 'profile.json')


class BoundedProcessTests(unittest.TestCase):
    def test_closed_input_and_safe_record_never_emit_tool_output(self):
        m = importlib.import_module('scripts.release.bounded_process')
        result = m.run_bounded([sys.executable, '-c', 'import sys; print("fake-sensitive-output"); print(len(sys.stdin.read()))'], timeout=2)
        self.assertEqual(result.returncode, 0)
        self.assertIn('\n0\n', result.stdout)
        record = json.dumps(m.safe_record(result, phase='probe'))
        self.assertNotIn('fake-sensitive-output', record)
        self.assertNotIn('-c', record)

    def test_cli_only_forwards_explicit_public_stdout_on_success(self):
        helper = Path(__file__).resolve().parents[1] / 'release/bounded_process.py'
        base = [sys.executable, str(helper), '--timeout', '2', '--phase', 'public-api', '--public-stdout', '--']
        result = subprocess.run([*base, sys.executable, '-c', 'print("public-result")'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'public-result\n')
        failed = subprocess.run([*base, sys.executable, '-c', 'print("fake-sensitive-diagnostic"); raise SystemExit(1)'], capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertNotIn('fake-sensitive-diagnostic', failed.stdout + failed.stderr)

    def test_timeout_kills_descendant_that_ignores_term(self):
        m = importlib.import_module('scripts.release.bounded_process')
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / 'survived'
            child = 'import signal,time,pathlib; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(1); pathlib.Path(' + repr(str(marker)) + ').write_text("bad")'
            parent = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); time.sleep(10)'
            result = m.run_bounded([sys.executable, '-c', parent], timeout=.15, terminate_grace=.1)
            self.assertTrue(result.timed_out)
            time.sleep(1)
            self.assertFalse(marker.exists())


class NotaryTests(unittest.TestCase):
    def setUp(self):
        self.m = importlib.import_module('scripts.release.durable_notary')
        self.p = importlib.import_module('scripts.release.release_profiles').ReleaseProfile('example/product', 'Developer ID Application: Example (TEAM123456)', 'TEAM123456', 'notary')
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve(); self.root.chmod(0o700)
        self.artifact = self.root / 'app.zip'; self.artifact.write_bytes(b'fake signed artifact')
        self.state = self.root / 'notary.json'

    def test_submission_id_is_durable_before_poll_and_resume_never_resubmits(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            if 'submit' in argv: return subprocess.CompletedProcess(argv, 0, '{"id":"01234567-89ab-cdef-0123-456789abcdef"}', '')
            self.assertEqual(json.loads(self.state.read_text())['submissionId'], '01234567-89ab-cdef-0123-456789abcdef')
            return subprocess.CompletedProcess(argv, 0, '{"id":"01234567-89ab-cdef-0123-456789abcdef","status":"Accepted"}', '')
        outcome = self.m.notarize(self.artifact, self.state, self.p, run=run, poll_interval=0)
        self.assertEqual(outcome['status'], 'Accepted')
        self.m.notarize(self.artifact, self.state, self.p, run=run)
        self.assertEqual(sum('submit' in argv for argv in calls), 1)
        self.artifact.write_bytes(b'changed')
        with self.assertRaises(self.m.NotaryError): self.m.notarize(self.artifact, self.state, self.p, run=run)
        self.assertEqual(json.loads(self.state.read_text())['status'], 'Blocked')

    def test_ambiguous_upload_is_preserved_and_never_automatically_resubmitted(self):
        def run(argv, **kwargs): return subprocess.CompletedProcess(argv, 124, '', 'fake credential diagnostic must not be persisted')
        outcome = self.m.notarize(self.artifact, self.state, self.p, run=run)
        self.assertEqual(outcome['status'], 'AmbiguousUpload')
        with self.assertRaises(self.m.NotaryError): self.m.notarize(self.artifact, self.state, self.p, run=run)
        self.assertNotIn('credential diagnostic', self.state.read_text())

    def test_pending_timeout_retains_id_and_invalid_is_terminal(self):
        def run(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, '{"id":"01234567-89ab-cdef-0123-456789abcdef"}' if 'submit' in argv else '{"id":"01234567-89ab-cdef-0123-456789abcdef","status":"In Progress"}', '')
        result = self.m.notarize(self.artifact, self.state, self.p, run=run, poll_budget=0)
        self.assertEqual(result['status'], 'In Progress')
        def invalid(argv, **kwargs):
            self.assertNotIn('submit', argv)
            return subprocess.CompletedProcess(argv, 0, '{"id":"01234567-89ab-cdef-0123-456789abcdef","status":"Invalid"}', '')
        result = self.m.notarize(self.artifact, self.state, self.p, run=invalid)
        self.assertEqual(result['status'], 'Invalid')



class SetupReadinessTests(unittest.TestCase):
    def test_setup_evidence_is_bound_and_expired_evidence_fails_closed(self):
        m = importlib.import_module('scripts.release.credential_readiness')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / 'ready.json'
            with self.assertRaises(m.ReadinessError): m.require_setup_receipt(path, 'a' * 64, now=100)
            m.write_setup_receipt(path, 'a' * 64, now=100)
            m.require_setup_receipt(path, 'a' * 64, now=101)
            m.begin_setup(path, 'a' * 64, now=102)
            with self.assertRaises(m.ReadinessError): m.require_setup_receipt(path, 'a' * 64, now=103)
            m.write_setup_receipt(path, 'a' * 64, now=104)
            m.require_setup_receipt(path, 'a' * 64, now=50000)
            with self.assertRaises(m.ReadinessError): m.require_setup_receipt(path, 'b' * 64, now=101)
            with self.assertRaises(m.ReadinessError): m.require_setup_receipt(path, 'a' * 64, now=50000, max_age=3600)

class DoctorCredentialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import importlib.util
        directory = Path(__file__).resolve().parents[1] / 'release'
        sys.path.insert(0, str(directory))
        spec = importlib.util.spec_from_file_location('credentials_test_doctor', directory / 'release-doctor.py')
        cls.m = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.m
        spec.loader.exec_module(cls.m)
        sys.path.pop(0)

    def doctor(self):
        args = self.m.parser().parse_args(['--mode','credentials','--channel','preview'])
        args.sparkle_account = 'example.product'
        args.sparkle_public_ed_key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        args.credential_probe_mode = 'unattended'
        args.setup_receipt = None
        doctor = self.m.Doctor(args)
        doctor.sparkle_tools = {'SPARKLE_GENERATE_KEYS': Path('/fake/generate_keys'), 'SPARKLE_SIGN_UPDATE': Path('/fake/sign_update')}
        return doctor

    def test_wrong_sparkle_key_cannot_pass_with_any_nonempty_output(self):
        doctor = self.doctor()
        doctor.run_command = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 0, 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=', '')
        with self.assertRaises(self.m.CheckFailure): doctor._sparkle_key()

    def test_independent_signature_verifier_uses_expected_public_key(self):
        doctor = self.doctor(); doctor.sparkle_key_file = None
        def run(argv, **kwargs):
            if argv[0] == '/fake/sign_update':
                self.assertIn('--account', argv)
                self.assertNotIn('--verify', argv)
                return subprocess.CompletedProcess(argv, 0, 'A' * 86 + '==', '')
            self.assertEqual(argv[:2], ['xcrun', 'swift'])
            self.assertIn(doctor.args.sparkle_public_ed_key, argv)
            self.assertNotIn('--ed-key-file', argv)
            return subprocess.CompletedProcess(argv, 1, '', 'invalid signature')
        doctor.run_command = run
        with self.assertRaises(self.m.CheckFailure): doctor._sparkle_probe()

    def test_unattended_guard_does_not_probe_any_credential_without_setup(self):
        doctor = self.doctor()
        doctor.run_command = lambda *a, **kw: self.fail('must fail before tools are invoked')
        with self.assertRaises(self.m.CheckFailure): doctor._credential_setup_guard()

    def test_setup_binding_tracks_resolved_repository_without_explicit_repository_flag(self):
        from types import SimpleNamespace
        doctor = self.doctor()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            doctor.args.setup_receipt = root / 'ready.json'
            doctor.args.credential_probe_mode = 'setup'
            doctor.signing_identity = 'Developer ID Application: Example (TEAM123456)'
            doctor.team_id = 'TEAM123456'; doctor.notary_profile = 'notary'
            for name in ('codesign', 'security', 'gh', 'xcrun', 'generate_keys', 'sign_update'):
                path = root / name; path.write_text('fake tool'); path.chmod(0o700)
            doctor.sparkle_tools = {'SPARKLE_GENERATE_KEYS': root / 'generate_keys', 'SPARKLE_SIGN_UPDATE': root / 'sign_update'}
            doctor.environment['PATH'] = str(root)
            doctor.run_command = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 0, 'fake-boot', '')
            doctor._selected_repository_identity = lambda: SimpleNamespace(github_repository='first/product', repository_key='a' * 64)
            doctor._credential_setup_guard()
            first = doctor.setup_binding
            doctor._selected_repository_identity = lambda: SimpleNamespace(github_repository='second/product', repository_key='b' * 64)
            doctor._credential_setup_guard()
            self.assertNotEqual(doctor.setup_binding, first)

    def test_disposable_signing_requires_selected_certificate_keychain_and_actual_team(self):
        doctor = self.doctor()
        doctor.signing_identity = 'Developer ID Application: Example (TEAM123456)'
        doctor.team_id = 'TEAM123456'
        doctor.args.certificate_sha1 = 'A' * 40
        doctor.args.signing_keychain = Path('/fake/selected.keychain-db')
        def run(argv, **kwargs):
            if '--sign' in argv:
                self.assertEqual(argv[argv.index('--sign') + 1], 'A' * 40)
                self.assertEqual(argv[argv.index('--keychain') + 1], '/fake/selected.keychain-db')
                return subprocess.CompletedProcess(argv, 0, '', '')
            if '--display' in argv:
                return subprocess.CompletedProcess(argv, 0, '', 'TeamIdentifier=OTHERTEAM1')
            return subprocess.CompletedProcess(argv, 0, '', '')
        doctor.run_command = run
        with self.assertRaises(self.m.CheckFailure): doctor._signing_probe()

    def test_locked_private_signing_key_fails_disposable_probe(self):
        doctor = self.doctor()
        doctor.signing_identity = 'Developer ID Application: Example (TEAM123456)'
        doctor.team_id = 'TEAM123456'
        doctor.run_command = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 1, '', 'fake locked keychain')
        with self.assertRaises(self.m.CheckFailure): doctor._signing_probe()


class AdditionalCredentialBoundaryTests(unittest.TestCase):
    def test_notary_retains_valid_id_even_when_upload_command_exits_nonzero(self):
        m = importlib.import_module('scripts.release.durable_notary')
        p = importlib.import_module('scripts.release.release_profiles').ReleaseProfile('example/product', 'Developer ID Application: Example (TEAM123456)', 'TEAM123456', 'notary')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); artifact = root / 'app.zip'; artifact.write_bytes(b'payload')
            def run(argv, **kwargs):
                return subprocess.CompletedProcess(argv, 1, '{"id":"01234567-89ab-cdef-0123-456789abcdef"}', '')
            state = m.notarize(artifact, root / 'state.json', p, run=run, poll_budget=0)
            self.assertEqual(state['submissionId'], '01234567-89ab-cdef-0123-456789abcdef')
            self.assertEqual(state['status'], 'In Progress')

    def test_notary_rejects_status_for_another_submission(self):
        m = importlib.import_module('scripts.release.durable_notary')
        p = importlib.import_module('scripts.release.release_profiles').ReleaseProfile('example/product', 'Developer ID Application: Example (TEAM123456)', 'TEAM123456', 'notary')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); artifact = root / 'app.zip'; artifact.write_bytes(b'payload')
            state_path = root / 'state.json'
            def run(argv, **kwargs):
                return subprocess.CompletedProcess(argv, 0, '{"id":"01234567-89ab-cdef-0123-456789abcdef"}' if 'submit' in argv else '{"id":"99999999-89ab-cdef-0123-456789abcdef","status":"Accepted"}', '')
            with self.assertRaises(m.NotaryError): m.notarize(artifact, state_path, p, run=run)
            self.assertEqual(json.loads(state_path.read_text())['status'], 'Blocked')

    def test_notary_rejects_changed_or_replaced_artifact_during_upload(self):
        m = importlib.import_module('scripts.release.durable_notary')
        p = importlib.import_module('scripts.release.release_profiles').ReleaseProfile('example/product', 'Developer ID Application: Example (TEAM123456)', 'TEAM123456', 'notary')
        for replacement in (False, True):
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve(); artifact = root / 'app.zip'; artifact.write_bytes(b'payload')
                state_path = root / 'state.json'
                def run(argv, **kwargs):
                    self.assertIn('submit', argv)
                    if replacement:
                        other = root / 'replacement'; other.write_bytes(b'payload'); other.replace(artifact)
                    else: artifact.write_bytes(b'changed')
                    return subprocess.CompletedProcess(argv, 0, '{"id":"01234567-89ab-cdef-0123-456789abcdef"}', '')
                with self.assertRaises(m.NotaryError): m.notarize(artifact, state_path, p, run=run)
                result = json.loads(state_path.read_text())
                self.assertEqual(result['status'], 'Blocked')
                self.assertEqual(result['submissionId'], '01234567-89ab-cdef-0123-456789abcdef')

    def test_duplicate_json_keys_are_rejected_before_selectors_are_used(self):
        m = importlib.import_module('scripts.release.release_profiles')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / 'profile.json'
            path.write_text('{"schemaVersion":1,"schemaVersion":2}')
            path.chmod(0o600)
            with self.assertRaises(m.ProfileError): m.load_release_profile(path)


if __name__ == '__main__': unittest.main()
