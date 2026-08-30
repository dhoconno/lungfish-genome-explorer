"""Behavioral tests for the private release compiler-cache namespace."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts" / "release" / "release_cache_fingerprint.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("release_cache_fingerprint_test", HELPER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fixture_fields() -> dict[str, object]:
    return {
        "repository": "github.com/example/lungfish",
        "repository_key": "a" * 64,
        "xcode_version": "26.6",
        "xcode_build": "17G80",
        "swift_identity": (
            "Apple Swift version 6.2.3 (swiftlang-6.2.3.1 clang-1700.0.10.1)\n"
            "Target: arm64-apple-macosx26.0"
        ),
        "sdk_version": "26.4",
        "sdk_build": "25E5200",
        "architecture": "arm64",
        "deployment_target": "26.0",
        "configuration": "Release",
        "products": ("xcode:Lungfish", "swiftpm:lungfish-cli"),
        "package_resolved_sha256": "b" * 64,
        "release_contract_sha256": "c" * 64,
        "recipe_hashes": {
            "Lungfish-Info.plist": "d" * 64,
            "Lungfish.xcodeproj/project.pbxproj": "e" * 64,
            "Package.swift": "f" * 64,
            "scripts/release/build-notarized-dmg.sh": "1" * 64,
        },
    }


class ReleaseCacheFingerprintTests(unittest.TestCase):
    def test_helper_exposes_only_internal_prepare_and_lock_operations(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), "--help"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prepare", result.stdout)
        self.assertIn("hold-lock", result.stdout)

    def test_helper_exposes_one_canonical_fingerprint_api(self):
        helper = load_helper()
        self.assertTrue(
            all(
                hasattr(helper, name)
                for name in (
                    "build_fingerprint_document",
                    "collect_fingerprint_document",
                    "canonical_json_bytes",
                    "fingerprint",
                    "prepare_cache_namespace",
                    "sha256_bytes",
                    "RECIPE_PATHS",
                )
            )
        )

    def test_canonical_document_binds_exact_compiler_and_recipe_identity(self):
        helper = load_helper()

        document = helper.build_fingerprint_document(**fixture_fields())

        swift_identity = fixture_fields()["swift_identity"]
        self.assertEqual(
            document,
            {
                "schemaVersion": 1,
                "repository": {
                    "canonicalIdentity": "github.com/example/lungfish",
                    "key": "a" * 64,
                },
                "toolchain": {
                    "architecture": "arm64",
                    "sdk": {"build": "25E5200", "version": "26.4"},
                    "swift": {
                        "identity": swift_identity,
                        "identitySha256": helper.sha256_bytes(
                            str(swift_identity).encode("utf-8")
                        ),
                    },
                    "xcode": {"build": "17G80", "version": "26.6"},
                },
                "build": {
                    "configuration": "Release",
                    "deploymentTarget": "26.0",
                    "environment": {
                        "CC": "",
                        "CXX": "",
                        "SDKROOT": "",
                        "SWIFT_EXEC": "",
                        "TOOLCHAINS": "",
                    },
                    "products": ["swiftpm:lungfish-cli", "xcode:Lungfish"],
                    "recipe": {
                        "files": {
                            "Lungfish-Info.plist": "d" * 64,
                            "Lungfish.xcodeproj/project.pbxproj": "e" * 64,
                            "Package.swift": "f" * 64,
                            "scripts/release/build-notarized-dmg.sh": "1" * 64,
                        },
                        "schemaVersion": 1,
                    },
                },
                "inputs": {
                    "packageResolvedSha256": "b" * 64,
                    "releaseContractSha256": "c" * 64,
                },
            },
        )
        canonical = helper.canonical_json_bytes(document)
        self.assertEqual(canonical, json.dumps(document, sort_keys=True, separators=(",", ":")).encode() + b"\n")
        self.assertEqual(helper.fingerprint(document), helper.sha256_bytes(canonical))

    def test_every_build_compatibility_input_changes_the_fingerprint(self):
        helper = load_helper()
        baseline_fields = fixture_fields()
        baseline = helper.fingerprint(helper.build_fingerprint_document(**baseline_fields))
        mutations = {
            "compatible Xcode version": ("xcode_version", "26.4.1"),
            "Xcode build": ("xcode_build", "17F80"),
            "Swift identity": (
                "swift_identity",
                "Apple Swift version 6.2.4 (swiftlang-next)\nTarget: arm64-apple-macosx26.0",
            ),
            "SDK version": ("sdk_version", "26.5"),
            "SDK build": ("sdk_build", "25F10"),
            "lock": ("package_resolved_sha256", "2" * 64),
            "contract": ("release_contract_sha256", "3" * 64),
            "configuration": ("configuration", "Debug"),
            "architecture": ("architecture", "x86_64"),
            "deployment": ("deployment_target", "25.0"),
            "product": ("products", ("xcode:Other", "swiftpm:lungfish-cli")),
            "recipe": (
                "recipe_hashes",
                {
                    **baseline_fields["recipe_hashes"],
                    "Lungfish-Info.plist": "4" * 64,
                },
            ),
        }
        for label, (field, value) in mutations.items():
            with self.subTest(label=label):
                mutated = copy.deepcopy(baseline_fields)
                mutated[field] = value
                observed = helper.fingerprint(
                    helper.build_fingerprint_document(**mutated)
                )
                self.assertNotEqual(observed, baseline)

    def test_checkout_and_xcode_install_relocation_do_not_change_the_key(self):
        helper = load_helper()
        fields = fixture_fields()
        first = helper.build_fingerprint_document(**fields)
        relocated = helper.build_fingerprint_document(**fields)

        self.assertEqual(helper.fingerprint(first), helper.fingerprint(relocated))
        encoded = helper.canonical_json_bytes(first).decode("utf-8")
        self.assertNotIn(str(ROOT), encoded)
        self.assertNotIn("/Applications/", encoded)
        self.assertNotIn(os.environ.get("USER", "__missing_user__"), encoded)

    def test_collection_hashes_the_explicit_release_recipe_without_paths(self):
        helper = load_helper()
        responses = {
            ("xcodebuild", "-version"): "Xcode 26.6\nBuild version 17G80\n",
            ("xcrun", "swift", "--version"): str(
                fixture_fields()["swift_identity"]
            ),
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.4\n",
            (
                "xcrun",
                "--sdk",
                "macosx",
                "--show-sdk-build-version",
            ): "25E5200\n",
            ("uname", "-m"): "arm64\n",
        }

        def command_output(command: list[str]) -> str:
            return responses[tuple(command)]

        with tempfile.TemporaryDirectory() as first_raw, tempfile.TemporaryDirectory() as second_raw:
            first = Path(first_raw) / "alice" / "checkout"
            second = Path(second_raw) / "bob" / "moved-worktree"
            for checkout in (first, second):
                for relative in (
                    *helper.RECIPE_PATHS,
                    "Package.resolved",
                    "config/release-contract.json",
                ):
                    destination = checkout / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / relative, destination)

            first_document = helper.collect_fingerprint_document(
                project_root=first,
                repository="github.com/example/lungfish",
                repository_key="a" * 64,
                deployment_target="26.0",
                command_output=command_output,
            )
            second_document = helper.collect_fingerprint_document(
                project_root=second,
                repository="github.com/example/lungfish",
                repository_key="a" * 64,
                deployment_target="26.0",
                command_output=command_output,
            )

        self.assertEqual(first_document, second_document)
        self.assertEqual(
            set(first_document["build"]["recipe"]["files"]),
            set(helper.RECIPE_PATHS),
        )
        encoded = helper.canonical_json_bytes(first_document).decode("utf-8")
        self.assertNotIn(str(first), encoded)
        self.assertNotIn(str(second), encoded)

    def test_collection_rejects_an_incomplete_recipe(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as raw:
            checkout = Path(raw)
            (checkout / "Package.resolved").write_text("{}\n", encoding="utf-8")
            (checkout / "config").mkdir()
            (checkout / "config/release-contract.json").write_text(
                "{}\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(helper.CacheFingerprintError, "recipe"):
                helper.collect_fingerprint_document(
                    project_root=checkout,
                    repository="github.com/example/lungfish",
                    repository_key="a" * 64,
                    deployment_target="26.0",
                    command_output=lambda _command: "unused",
                )

    def test_private_cache_namespace_is_fingerprint_scoped_and_reused(self):
        helper = load_helper()
        first_document = helper.build_fingerprint_document(**fixture_fields())
        changed_fields = fixture_fields()
        changed_fields["xcode_version"] = "26.4.1"
        second_document = helper.build_fingerprint_document(**changed_fields)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve() / "lungfish-release-cache"
            first = helper.prepare_cache_namespace(
                root, "a" * 64, first_document
            )
            sentinel = first.swiftpm / "reusable.o"
            sentinel.write_bytes(b"compiler intermediate")
            same = helper.prepare_cache_namespace(root, "a" * 64, first_document)
            second = helper.prepare_cache_namespace(root, "a" * 64, second_document)

            self.assertEqual(same, first)
            self.assertTrue(sentinel.is_file())
            self.assertNotEqual(first.namespace, second.namespace)
            self.assertEqual(first.namespace.parent, second.namespace.parent)
            self.assertEqual(first.swiftpm.parent, first.namespace)
            self.assertEqual(first.derived_data.parent, first.namespace)
            self.assertEqual(oct(root.stat().st_mode & 0o777), "0o700")
            self.assertEqual(oct((root / "v1").stat().st_mode & 0o777), "0o700")
            self.assertEqual(oct(first.namespace.stat().st_mode & 0o777), "0o700")
            marker = first.namespace / helper.CACHE_MARKER
            self.assertEqual(oct(marker.stat().st_mode & 0o777), "0o600")
            payload = json.loads(marker.read_text(encoding="utf-8"))
            self.assertEqual(payload["fingerprint"], first.fingerprint)
            self.assertEqual(payload["fields"], first_document)

    def test_cache_reuse_rejects_unsafe_permissions_and_symlink_entries(self):
        helper = load_helper()
        document = helper.build_fingerprint_document(**fixture_fields())
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve() / "cache"
            paths = helper.prepare_cache_namespace(root, "a" * 64, document)
            paths.swiftpm.chmod(0o770)
            with self.assertRaisesRegex(helper.CacheFingerprintError, "permissions"):
                helper.prepare_cache_namespace(root, "a" * 64, document)
            paths.swiftpm.chmod(0o700)
            outside = Path(raw) / "outside"
            outside.mkdir()
            (paths.swiftpm / "escape").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(helper.CacheFingerprintError, "symlink"):
                helper.prepare_cache_namespace(root, "a" * 64, document)

    def test_cache_reuse_rejects_foreign_owner_at_the_security_boundary(self):
        helper = load_helper()
        document = helper.build_fingerprint_document(**fixture_fields())
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve() / "cache"
            helper.prepare_cache_namespace(root, "a" * 64, document)
            with self.assertRaisesRegex(helper.CacheFingerprintError, "owner"):
                helper.prepare_cache_namespace(
                    root,
                    "a" * 64,
                    document,
                    expected_uid=os.geteuid() + 1,
                )

    def test_cache_reuse_rejects_release_artifacts_at_namespace_top_level(self):
        helper = load_helper()
        document = helper.build_fingerprint_document(**fixture_fields())
        for name, directory in (
            ("candidate-receipt.json", False),
            ("Lungfish.dmg", False),
            ("Lungfish.app", True),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw:
                root = Path(raw).resolve() / "cache"
                paths = helper.prepare_cache_namespace(root, "a" * 64, document)
                unexpected = paths.namespace / name
                if directory:
                    unexpected.mkdir(mode=0o700)
                else:
                    unexpected.write_bytes(b"must remain\n")

                with self.assertRaisesRegex(
                    helper.CacheFingerprintError, "top-level"
                ):
                    helper.prepare_cache_namespace(root, "a" * 64, document)

                self.assertTrue(unexpected.exists())

    def test_same_namespace_lock_serializes_builders(self):
        helper = load_helper()
        document = helper.build_fingerprint_document(**fixture_fields())
        with tempfile.TemporaryDirectory() as raw:
            paths = helper.prepare_cache_namespace(
                Path(raw).resolve() / "cache", "a" * 64, document
            )
            first_ready = paths.namespace / (".lock-ready." + "a" * 48)
            second_ready = paths.namespace / (".lock-ready." + "b" * 48)
            first_token = "1" * 64
            second_token = "2" * 64
            common = [
                sys.executable,
                str(HELPER),
                "hold-lock",
                "--namespace",
                str(paths.namespace),
                "--parent-pid",
                str(os.getpid()),
            ]
            first = subprocess.Popen(
                [
                    *common,
                    "--ready-file",
                    str(first_ready),
                    "--ready-token",
                    first_token,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            second = None
            try:
                self.assertTrue(self._wait_for_token(first_ready, first_token, 3.0))
                second = subprocess.Popen(
                    [
                        *common,
                        "--ready-file",
                        str(second_ready),
                        "--ready-token",
                        second_token,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                time.sleep(0.2)
                self.assertFalse(second_ready.exists())
                first.terminate()
                first.wait(timeout=3)
                self.assertTrue(
                    self._wait_for_token(second_ready, second_token, 3.0)
                )
            finally:
                if first.poll() is None:
                    first.terminate()
                    first.wait(timeout=3)
                if second is not None and second.poll() is None:
                    second.terminate()
                    second.wait(timeout=3)

    def test_lock_rejects_a_precreated_readiness_channel(self):
        helper = load_helper()
        document = helper.build_fingerprint_document(**fixture_fields())
        with tempfile.TemporaryDirectory() as raw:
            paths = helper.prepare_cache_namespace(
                Path(raw).resolve() / "cache", "a" * 64, document
            )
            ready = paths.namespace / (".lock-ready." + "c" * 48)
            ready.write_text("3" * 64 + "\n", encoding="utf-8")
            ready.chmod(0o600)

            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "hold-lock",
                    "--namespace",
                    str(paths.namespace),
                    "--ready-file",
                    str(ready),
                    "--ready-token",
                    "3" * 64,
                    "--parent-pid",
                    str(os.getpid()),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("top-level", result.stderr)

    @staticmethod
    def _wait_for(path: Path, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return True
            time.sleep(0.02)
        return False

    @staticmethod
    def _wait_for_token(path: Path, token: str, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if path.read_text(encoding="utf-8") == token + "\n":
                    return True
            except OSError:
                pass
            time.sleep(0.02)
        return False


if __name__ == "__main__":
    unittest.main()
