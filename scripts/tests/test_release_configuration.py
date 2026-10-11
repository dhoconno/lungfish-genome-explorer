"""Public configuration must be reviewable without touching credential services."""
import argparse
import base64
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
from scripts.tests.developer_id_fixtures import G1, NAME, TEAM, certificate_der, find_identity_output, pem, sha1
from scripts.tests.test_release_frontdoor import load_module, ROOT


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.release = load_module()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'config').mkdir()
        self.contract = self.root / 'config/release-contract.json'
        self.contract.write_bytes((ROOT / 'config/release-contract.json').read_bytes())
        self.repository = mock.patch.object(self.release, 'resolve_repository_identity',
                                             return_value=argparse.Namespace(github_repository='example/fish'))
        self.repository.start()
        self.addCleanup(self.repository.stop)

    def configure(self, **overrides):
        options = dict(repository='example/fish', product_name='Example Fish', namespace='org.example.fish',
                       sparkle_public_key=base64.b64encode(bytes(range(32))).decode(),
                       website='https://example.org', documentation='https://example.org/docs')
        options.update(overrides)
        return self.release.run_configure_fork(self.root, argparse.Namespace(**options))

    def test_configuration_writes_valid_isolated_public_identity_only(self):
        with mock.patch.object(self.release, 'SubprocessRunner', side_effect=AssertionError('no credential commands')):
            self.assertEqual(self.configure(), 0)
        contract = self.release.load_contract(self.contract)
        self.assertEqual(contract.identity.repository, 'example/fish')
        self.assertEqual(contract.channel('preview').bundleIdentifier, 'org.example.fish.preview')
        self.assertEqual(contract.channel('preview').legacyBridgeRelease, '')
        self.assertEqual(set(self.root.iterdir()), {self.root / 'config'})

    def test_invalid_or_wrong_repository_preserves_original_bytes(self):
        original = self.contract.read_bytes()
        for changes in ({'repository': 'other/fish'}, {'product_name': ' Fish '}, {'namespace': 'com.lungfish.fork'}):
            with self.subTest(changes=changes), self.assertRaises((ValueError, self.release.ReleaseError)):
                self.configure(**changes)
            self.assertEqual(self.contract.read_bytes(), original)

    def test_private_configuration_is_create_only_and_does_not_probe(self):
        self.configure()
        path = self.root / 'private/profile.json'
        args = argparse.Namespace(profile=path, signing_identity='Developer ID Application: Example (TEAM123456)',
                                  team_id='TEAM123456', notary_profile='example-notary', signing_keychain=None,
                                  certificate_sha1=None, notary_keychain=None, sparkle_account='example-fish')
        with mock.patch.object(self.release, 'SubprocessRunner', side_effect=AssertionError('no credential commands')):
            self.assertEqual(self.release.run_configure_machine(self.root, args), 0)
            with self.assertRaises(ValueError):
                self.release.run_configure_machine(self.root, args)
        profile = self.release.load_release_profile(path)
        self.assertEqual(profile.schema_version, 2)
        self.assertEqual(profile.sparkle_account, 'example-fish')
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)

    def test_setup_is_explicit_and_bypasses_build_gates(self):
        self.configure()
        profile = self.release.ReleaseProfile('example/fish', 'Developer ID Application: Example (TEAM123456)',
                                             'TEAM123456', 'example-notary')
        with mock.patch.object(self.release, 'load_release_profile', return_value=profile), \
             mock.patch.object(self.release, '_head_commit', return_value='a' * 40), \
             mock.patch.object(self.release, 'LocalReleaseOperations') as operations:
            operations.return_value.select_signing_certificate.side_effect = lambda request: request
            self.assertEqual(self.release.run_setup(self.root, self.root / 'private/profile.json'), 0)
        request = operations.return_value.doctor_credentials.call_args.args[0]
        self.assertEqual(request.credential_probe_mode, 'setup')
        self.assertEqual([call[0] for call in operations.return_value.method_calls],
                         ['select_signing_certificate', 'doctor_credentials'])
        operations.return_value.doctor_package.assert_not_called()
        operations.return_value.run_local_gates.assert_not_called()
        operations.return_value.start_package_build.assert_not_called()
        operations.return_value.finish_package_build.assert_not_called()

    def test_private_configuration_replaces_only_on_request_and_records_the_certificate_choice(self):
        self.configure()
        path = self.root / 'private/profile.json'
        args = argparse.Namespace(profile=path, signing_identity=NAME, team_id=TEAM, notary_profile='example-notary',
                                  signing_keychain=None, certificate_sha1=None, certificate_policy=None,
                                  notary_keychain=None, sparkle_account='example-fish', replace=False)
        with mock.patch.object(self.release, 'SubprocessRunner', side_effect=AssertionError('no credential commands')):
            self.assertEqual(self.release.run_configure_machine(self.root, args), 0)
            args.certificate_policy = 'newest-g2'
            with self.assertRaises(ValueError):
                self.release.run_configure_machine(self.root, args)
            args.replace = True
            self.assertEqual(self.release.run_configure_machine(self.root, args), 0)
            self.assertEqual(self.release.load_release_profile(path).certificate_policy, 'newest-g2')
            args.certificate_policy, args.certificate_sha1 = None, 'c' * 40
            self.assertEqual(self.release.run_configure_machine(self.root, args), 0)
        profile = self.release.load_release_profile(path)
        self.assertEqual((profile.certificate_sha1, profile.certificate_policy), ('C' * 40, None))

    def test_configure_machine_accepts_a_sha1_or_a_policy_but_not_both(self):
        base = ['configure-machine', '--signing-identity', NAME, '--team-id', TEAM, '--notary-profile', 'example-notary']
        parsed = self.release._parser().parse_args(base + ['--certificate-policy', 'newest-g2', '--replace'])
        self.assertEqual((parsed.certificate_policy, parsed.replace, parsed.certificate_sha1), ('newest-g2', True, None))
        with self.assertRaises(SystemExit), mock.patch('sys.stderr'):
            self.release._parser().parse_args(base + ['--certificate-policy', 'newest-g2', '--certificate-sha1', 'A' * 40])

    def test_the_profile_choice_becomes_one_sha1_before_any_doctor_or_builder_runs(self):
        now = datetime.now(timezone.utc)
        old_der = certificate_der(issuer=G1, not_before=now - timedelta(days=200), not_after=now + timedelta(days=90))
        new_der = certificate_der(not_before=now - timedelta(days=1), not_after=now + timedelta(days=364), serial=2)
        listing = find_identity_output([(sha1(old_der), NAME, None), (sha1(new_der), NAME, None)])
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            output = listing if argv[1] == 'find-identity' else pem(old_der) + pem(new_der)
            return subprocess.CompletedProcess(argv, 0, output, '')

        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.runner = mock.Mock(run=run)
        base = replace(self.release._base_request(self.root, 'preview', 'a' * 40, github_repository='example/fish'),
                       signing_identity=NAME, team_id=TEAM)
        resolved = operations.select_signing_certificate(replace(base, certificate_policy='newest-g2'))
        self.assertEqual(resolved.certificate_sha1, sha1(new_der))
        arguments = self.release._credential_arguments(resolved)
        self.assertEqual(arguments[arguments.index('--certificate-sha1') + 1], sha1(new_der))
        self.assertEqual(operations.select_signing_certificate(replace(base, certificate_sha1=sha1(old_der).lower())).certificate_sha1,
                         sha1(old_der))
        self.assertEqual({argv[1] for argv, _ in calls}, {'find-identity', 'find-certificate'})
        self.assertTrue(all(kwargs == {'capture': True, 'check': False} for _, kwargs in calls))
        with self.assertRaises(self.release.SigningSelectionError) as raised:
            operations.select_signing_certificate(base)
        self.assertIn(sha1(old_der), str(raised.exception))
        self.assertIn(sha1(new_der), str(raised.exception))

    def test_doctor_reports_an_unresolved_identity_as_not_ready_with_the_candidates(self):
        self.configure()
        profile = self.release.ReleaseProfile('example/fish', NAME, TEAM, 'example-notary')
        package = mock.Mock(runner=mock.Mock(environment={'DEVELOPER_DIR': '/Applications/Xcode.app'}))
        credentials = mock.Mock()
        message = '2 valid identities are named it, so signing by name is ambiguous: AAAA (G1); BBBB (G2)'
        credentials.select_signing_certificate.side_effect = self.release.SigningSelectionError(message)
        output = []
        with mock.patch.object(self.release, '_head_commit', return_value='a' * 40), \
             mock.patch.object(self.release, 'load_release_profile', return_value=profile), \
             mock.patch.object(self.release, '_resolve_sparkle_generate_appcast'), \
             mock.patch.object(self.release, 'LocalReleaseOperations', side_effect=[package, credentials]), \
             mock.patch('builtins.print', side_effect=lambda value: output.append(value)):
            self.assertEqual(self.release.run_doctor(self.root, self.root / 'private/profile.json'), 1)
        self.assertIn(f'Publish readiness: NOT READY ({message})', output)
        credentials.doctor_credentials.assert_not_called()

    def test_fork_sparkle_floors_allow_initial_feeds_without_legacy_bridge(self):
        self.configure()
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.contract = self.release.load_contract(self.contract)
        operations.runner = mock.Mock(environment={"LUNGFISH_BUILD_NUMBER": "42"})
        for channel, expected_count in (("preview", 1), ("stable", 2)):
            with self.subTest(channel=channel):
                operations.runner.reset_mock()
                request = argparse.Namespace(channel=channel, github_repository="example/fish")
                operations.validate_sparkle_build_number(request)
                commands = [call.args[0] for call in operations.runner.run.call_args_list]
                self.assertEqual(len(commands), expected_count)
                for command in commands:
                    self.assertIn("--allow-http-not-found", command)
                    self.assertIn("https://github.com/example/fish/releases/download/",
                                  command[command.index("--appcast-url") + 1])

    def test_upstream_sparkle_floors_keep_required_legacy_and_preview_feeds(self):
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.contract = self.release.load_contract(self.contract)
        operations.runner = mock.Mock(environment={"LUNGFISH_BUILD_NUMBER": "42"})
        request = argparse.Namespace(channel="stable", github_repository=operations.contract.identity.repository)
        operations.validate_sparkle_build_number(request)
        commands = [call.args[0] for call in operations.runner.run.call_args_list]
        self.assertEqual(len(commands), 3)
        self.assertNotIn("--allow-http-not-found", commands[0])
        self.assertNotIn("--allow-http-not-found", commands[1])
        self.assertIn("--allow-http-not-found", commands[2])

    def test_candidate_reuse_requires_source_and_exact_receipt_verification(self):
        self.configure()
        receipt = self.root / "existing-receipt.json"
        receipt.write_text("{}")
        request = argparse.Namespace(receipt=receipt)
        with mock.patch.object(self.release, "_head_commit", return_value="a" * 40), \
             mock.patch.object(self.release, "_base_request", return_value=request), \
             mock.patch.object(self.release, "LocalReleaseOperations") as factory, \
             mock.patch.object(self.release, "ReleaseCoordinator") as coordinator:
            operations = factory.return_value
            operations.verify_candidate_receipt.return_value = argparse.Namespace(receipt=receipt)
            self.assertEqual(self.release.run_package(self.root, "preview"), 0)
            self.assertEqual(operations.method_calls, [
                mock.call.verify_package_source(request), mock.call.verify_candidate_receipt(request)])
            coordinator.assert_not_called()
            operations.verify_candidate_receipt.side_effect = self.release.ReleaseError("stale fingerprint")
            with self.assertRaisesRegex(self.release.ReleaseError, "stale fingerprint"):
                self.release.run_package(self.root, "preview")
            coordinator.assert_not_called()

    def test_repository_mismatch_fails_before_local_operations(self):
        with mock.patch.object(self.release, "_head_commit", return_value="a" * 40), \
             mock.patch.object(self.release, "LocalReleaseOperations") as operations:
            with self.assertRaises(self.release.ReleaseError):
                self.release.run_package(self.root, "preview")
            operations.assert_not_called()

    def test_network_commands_have_noninteractive_budgets_and_record_failures(self):
        runner = self.release.SubprocessRunner(self.root, {"GH_REPO": "example/fish"})
        result = argparse.Namespace(returncode=124, stdout="", stderr="timeout")
        with mock.patch.object(self.release, "run_bounded", return_value=result) as bounded, \
             mock.patch.object(self.release.subprocess, "run", side_effect=AssertionError("unbounded command")), \
             mock.patch.object(self.release, "_record_timing") as timing:
            for command in (["git", "fetch", "origin"], ["gh", "release", "view", "v1"]):
                with self.assertRaisesRegex(self.release.ReleaseError, "exit 124"):
                    runner.run(command, capture=True)
                arguments = bounded.call_args.kwargs
                self.assertEqual(arguments["timeout"], 180)
                self.assertEqual(arguments["env"]["GIT_TERMINAL_PROMPT"], "0")
                self.assertEqual(arguments["env"]["GH_PROMPT_DISABLED"], "1")
                self.assertIn("BatchMode=yes", arguments["env"]["GIT_SSH_COMMAND"])
                self.assertEqual(timing.call_args.args[2], 124)
            self.assertEqual(bounded.call_args.args[0][:3], ["gh", "--repo", "github.com/example/fish"])

    def test_debug_has_one_assembly_command_and_explicit_portable_budget(self):
        commands, _ = self.release.debug_plan(self.root, portable=True, jobs=3)
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][-3:], ['--portable', '--jobs', '3'])
        with self.assertRaises(self.release.ReleaseError):
            self.release.debug_plan(self.root, jobs=0)


if __name__ == '__main__': unittest.main()
