"""Public configuration must be reviewable without touching credential services."""
import argparse
import base64
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
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
            self.assertEqual(self.release.run_setup(self.root, self.root / 'private/profile.json'), 0)
        request = operations.return_value.doctor_credentials.call_args.args[0]
        self.assertEqual(request.credential_probe_mode, 'setup')
        operations.return_value.doctor_package.assert_not_called()
        operations.return_value.run_local_gates.assert_not_called()
        operations.return_value.package_only.assert_not_called()

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
