import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from scripts.tests.gate_fixtures import make_gate_fixture, make_app_smoke_fixture
from scripts.release.release_contract import load_contract
from scripts.release.release_identity import identity_plist, prepare_identity_plist
from scripts.tests.test_debug_artifact import executable_bytes


ROOT = Path(__file__).resolve().parents[2]
TRUSTED_SCRATCH = Path(
    "/private/var/tmp/lungfish-release-swiftpm/uid-test/repository/commit"
)
SWIFTPM_RESOURCE_SUFFIX = Path(
    "arm64-apple-macosx/release/" "LungfishGenomeBrowser_LungfishWorkflow.bundle"
)


class ReleasePortabilityScannerTests(unittest.TestCase):
    def setUp(self):
        self.scanner = ROOT / "scripts" / "release" / "scan-release-portability.py"

    def run_scanner(
        self,
        app: Path,
        scratch: Path | str,
        *,
        scratch_root: Path | str | None = None,
    ):
        environment = os.environ.copy()
        if scratch_root is not None:
            environment["LUNGFISH_RELEASE_SCRATCH_ROOT"] = str(scratch_root)
        return subprocess.run(
            [
                sys.executable,
                str(self.scanner),
                str(app),
                "--allowed-swiftpm-fallback",
                str(scratch),
            ],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_binary_scan_reports_exact_offsets_without_emitting_payload_bytes(self):
        markers = (
            b"/Users/alice/lungfish",
            os.fsencode(ROOT),
            b"/tmp/lungfish-random-build",
            b"DerivedData/Lungfish",
            b".worktrees/release-candidate",
            b"/opt/homebrew/Cellar/swift/6.2",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app = self._make_app(root)
            binary = app / "Contents" / "MacOS" / "fixture"
            prefix = b"\x00\xff" + b"x" * (1024 * 1024 - 5)
            payload = prefix + b"\x00".join(markers) + b"\x00TOP-SECRET-BINARY-BYTES"
            binary.write_bytes(payload)

            result = self.run_scanner(app, TRUSTED_SCRATCH)

            self.assertEqual(result.returncode, 1)
            evidence = result.stdout.splitlines()
            self.assertGreaterEqual(len(evidence), len(markers) + 1)
            self.assertTrue(all(line.startswith("Contents/") for line in evidence[:-1]))
            self.assertIn(
                f"Contents/MacOS/fixture:{payload.index(markers[0])}:user-home",
                evidence,
            )
            self.assertEqual(payload.index(markers[0]), 1024 * 1024 - 3)
            self.assertIn(
                f"Contents/MacOS/fixture:{payload.index(markers[1])}:repository-root",
                evidence,
            )
            expected_findings = 7 + int(b".worktrees/" in os.fsencode(ROOT))
            self.assertIn(
                f"FAIL portability findings={expected_findings} shown={expected_findings}",
                evidence[-1],
            )
            self.assertNotIn("TOP-SECRET", result.stdout + result.stderr)
            self.assertNotIn("alice", result.stdout + result.stderr)
            self.assertLess(len(result.stdout), 4096)

    def test_scan_caps_evidence_at_twenty_records(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app = self._make_app(root)
            binary = app / "Contents" / "MacOS" / "fixture"
            binary.write_bytes(b"\x00".join([b"/Users/private"] * 25))

            result = self.run_scanner(app, TRUSTED_SCRATCH)

            self.assertEqual(result.returncode, 1)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 21)
            self.assertEqual(lines[-1], "FAIL portability findings=25 shown=20")

    def test_only_one_exact_cli_swiftpm_resource_fallback_is_allowed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            scratch = Path("/private/var/tmp/lungfish-release-swiftpm/repo/commit")
            app = self._make_app(root)
            cli = app / "Contents" / "MacOS" / "lungfish-cli"
            fallback = (
                scratch
                / "arm64-apple-macosx"
                / "release"
                / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
            )
            cli.write_bytes(b"mach-o\x00" + os.fsencode(fallback) + b"\x00tail")

            result = self.run_scanner(app, scratch)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, "PASS portability\n")

            cli.write_bytes(
                b"mach-o\x00"
                + os.fsencode(fallback)
                + b"\x00"
                + os.fsencode(fallback)
                + b"\x00"
            )
            duplicate = self.run_scanner(app, scratch)
            self.assertEqual(duplicate.returncode, 1)
            self.assertIn("swiftpm-fallback", duplicate.stdout)

    def test_swiftpm_fallback_rejects_home_repo_and_homebrew_scratch_roots(self):
        scratch_paths = (
            Path("/Users/alice/lungfish-release-swiftpm/repo/commit"),
            ROOT / ".build" / "release-swiftpm",
            Path("/opt/homebrew/var/lungfish-release-swiftpm/repo/commit"),
        )
        for scratch in scratch_paths:
            with self.subTest(
                scratch=scratch
            ), tempfile.TemporaryDirectory() as temp_dir:
                app = self._make_app(Path(temp_dir))
                cli = app / "Contents" / "MacOS" / "lungfish-cli"
                fallback = (
                    scratch
                    / "arm64-apple-macosx"
                    / "release"
                    / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
                )
                cli.write_bytes(b"mach-o\x00" + os.fsencode(fallback) + b"\x00")

                result = self.run_scanner(app, scratch)

                self.assertEqual(result.returncode, 2)
                self.assertIn("scratch path is not trusted", result.stderr)
                self.assertNotIn(str(scratch), result.stdout + result.stderr)

    def test_swiftpm_fallback_rejects_case_alias_of_home_scratch_root(self):
        home = Path.home().resolve()
        alias_home = self._case_alias(home)
        if alias_home is None:
            self.skipTest("requires a case-insensitive filesystem")
        with tempfile.TemporaryDirectory(
            prefix="lungfish-scanner-home-", dir=home
        ) as scratch_dir, tempfile.TemporaryDirectory() as app_dir:
            scratch_root = Path(scratch_dir)
            scratch = scratch_root / "repository" / "commit"
            scratch.mkdir(parents=True)
            alias_root = Path(str(scratch_root).replace(str(home), str(alias_home), 1))
            alias_scratch = Path(str(scratch).replace(str(home), str(alias_home), 1))
            self.assertTrue(os.path.samefile(alias_root, scratch_root))
            self.assertTrue(os.path.samefile(alias_scratch, scratch))
            app = self._make_app(Path(app_dir))

            result = self.run_scanner(app, alias_scratch, scratch_root=alias_root)

            self.assertEqual(result.returncode, 2)
            self.assertIn("scratch path is not trusted", result.stderr)
            self.assertNotIn(str(alias_scratch), result.stdout + result.stderr)

    def test_custom_root_requires_one_exact_cli_only_fallback(self):
        with tempfile.TemporaryDirectory(
            prefix="safe-release-root-", dir="/private/var/tmp"
        ) as scratch_dir:
            scratch_root = Path(scratch_dir)
            scratch = scratch_root / "repository" / "commit"
            scratch.mkdir(parents=True)
            alias_root = self._case_alias(scratch_root)
            if alias_root is None:
                self.skipTest("requires a case-insensitive filesystem")
            alias_scratch = Path(
                str(scratch).replace(str(scratch_root), str(alias_root), 1)
            )
            fallback = (
                alias_scratch
                / "arm64-apple-macosx"
                / "release"
                / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
            )
            cases = {
                "duplicate": (
                    "Contents/MacOS/lungfish-cli",
                    b"mach-o\x00"
                    + os.fsencode(fallback)
                    + b"\x00"
                    + os.fsencode(fallback)
                    + b"\x00",
                ),
                "extended": (
                    "Contents/MacOS/lungfish-cli",
                    b"mach-o\x00" + os.fsencode(fallback) + b"/extra\x00",
                ),
                "wrong file": (
                    "Contents/Resources/value.bin",
                    b"data\x00" + os.fsencode(fallback) + b"\x00",
                ),
            }
            for label, (relative, contents) in cases.items():
                with self.subTest(
                    label=label
                ), tempfile.TemporaryDirectory() as app_dir:
                    app = self._make_app(Path(app_dir))
                    target = app / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(contents)

                    result = self.run_scanner(
                        app, alias_scratch, scratch_root=alias_root
                    )

                    self.assertEqual(result.returncode, 1)
                    self.assertIn("swiftpm-fallback", result.stdout)

    def test_custom_private_var_tmp_root_allows_exact_cli_fallback(self):
        with tempfile.TemporaryDirectory(
            prefix="lungfish-custom-", dir="/private/var/tmp"
        ) as scratch_dir, tempfile.TemporaryDirectory() as app_dir:
            scratch_root = Path(scratch_dir)
            scratch = scratch_root / "repository" / "commit"
            scratch.mkdir(parents=True)
            fallback = scratch / SWIFTPM_RESOURCE_SUFFIX
            app = self._make_app(Path(app_dir))
            cli = app / "Contents" / "MacOS" / "lungfish-cli"
            cli.write_bytes(b"mach-o\x00" + os.fsencode(fallback) + b"\x00")

            result = self.run_scanner(app, scratch, scratch_root=scratch_root)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, "PASS portability\n")

    def test_default_release_cache_root_allows_exact_cli_fallback(self):
        with tempfile.TemporaryDirectory(
            prefix="lungfish-release-cache-test-", dir="/private/var/tmp"
        ) as cache_dir, tempfile.TemporaryDirectory() as app_dir:
            cache_root = Path(cache_dir)
            scratch = cache_root / "v1" / "fingerprint" / "namespace" / "swiftpm"
            scratch.mkdir(parents=True)
            fallback = scratch / SWIFTPM_RESOURCE_SUFFIX
            app = self._make_app(Path(app_dir))
            cli = app / "Contents" / "MacOS" / "lungfish-cli"
            cli.write_bytes(b"mach-o\x00" + os.fsencode(fallback) + b"\x00")

            environment = os.environ.copy()
            environment["LUNGFISH_RELEASE_SCRATCH_ROOT"] = str(
                Path("/private/var/tmp/lungfish-release-swiftpm")
            )
            environment["LUNGFISH_RELEASE_CACHE_ROOT"] = str(cache_root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(self.scanner),
                    str(app),
                    "--allowed-swiftpm-fallback",
                    str(scratch),
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, "PASS portability\n")

    def test_custom_fallback_rejects_non_record_boundaries(self):
        with tempfile.TemporaryDirectory(
            prefix="lungfish-custom-", dir="/private/var/tmp"
        ) as scratch_dir:
            scratch_root = Path(scratch_dir)
            scratch = scratch_root / "repository" / "commit"
            scratch.mkdir(parents=True)
            fallback = os.fsencode(scratch / SWIFTPM_RESOURCE_SUFFIX)
            cases = {
                "path prefix": b"/evil" + fallback + b"\x00",
                "colon suffix": b"\x00" + fallback + b":extra\x00",
                "space suffix": b"\x00" + fallback + b" extra\x00",
                "question suffix": b"\x00" + fallback + b"?extra\x00",
                "at suffix": b"\x00" + fallback + b"@extra\x00",
                "non-ASCII prefix": b"\xff" + fallback + b"\x00",
                "non-ASCII suffix": b"\x00" + fallback + b"\xffextra\x00",
            }
            for label, contents in cases.items():
                with self.subTest(
                    label=label
                ), tempfile.TemporaryDirectory() as app_dir:
                    app = self._make_app(Path(app_dir))
                    cli = app / "Contents" / "MacOS" / "lungfish-cli"
                    cli.write_bytes(contents)

                    result = self.run_scanner(app, scratch, scratch_root=scratch_root)

                    self.assertEqual(result.returncode, 1)
                    self.assertIn("swiftpm-fallback", result.stdout)

    def test_custom_fallback_allows_nul_or_file_record_boundaries(self):
        with tempfile.TemporaryDirectory(
            prefix="lungfish-custom-", dir="/private/var/tmp"
        ) as scratch_dir:
            scratch_root = Path(scratch_dir)
            scratch = scratch_root / "repository" / "commit"
            scratch.mkdir(parents=True)
            fallback = os.fsencode(scratch / SWIFTPM_RESOURCE_SUFFIX)
            records = (
                fallback + b"\x00",
                b"\x00" + fallback,
                b"\x00" + fallback + b"\x00",
            )
            for contents in records:
                with self.subTest(
                    contents=contents
                ), tempfile.TemporaryDirectory() as app_dir:
                    app = self._make_app(Path(app_dir))
                    cli = app / "Contents" / "MacOS" / "lungfish-cli"
                    cli.write_bytes(contents)

                    result = self.run_scanner(app, scratch, scratch_root=scratch_root)

                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "PASS portability\n")

    def test_custom_fallback_rejects_invalid_boundaries_across_chunks(self):
        with tempfile.TemporaryDirectory(
            prefix="lungfish-custom-", dir="/private/var/tmp"
        ) as scratch_dir:
            scratch_root = Path(scratch_dir)
            scratch = scratch_root / "repository" / "commit"
            scratch.mkdir(parents=True)
            fallback = os.fsencode(scratch / SWIFTPM_RESOURCE_SUFFIX)
            leading_split = b"z" * (1024 * 1024 - 1) + b"x" + fallback + b"\x00"
            trailing_split = (
                b"z" * (1024 * 1024 - len(fallback)) + fallback + b"?extra\x00"
            )
            overlap = (len(fallback) + 1) * 2
            ownership_split = (
                b"z" * (1024 * 1024 - overlap - 1)
                + b"x"
                + fallback
                + b"\x00"
                + b"z" * overlap
            )
            cases = {
                "leading boundary": leading_split,
                "trailing boundary": trailing_split,
                "leading scan ownership boundary": ownership_split,
            }
            for label, contents in cases.items():
                with self.subTest(
                    label=label
                ), tempfile.TemporaryDirectory() as app_dir:
                    app = self._make_app(Path(app_dir))
                    cli = app / "Contents" / "MacOS" / "lungfish-cli"
                    cli.write_bytes(contents)

                    result = self.run_scanner(app, scratch, scratch_root=scratch_root)

                    self.assertEqual(result.returncode, 1)
                    self.assertIn("swiftpm-fallback", result.stdout)

    def test_exact_custom_fallback_suppression_survives_a_chunk_boundary(self):
        with tempfile.TemporaryDirectory(
            prefix="lungfish-custom-", dir="/private/var/tmp"
        ) as scratch_dir, tempfile.TemporaryDirectory() as app_dir:
            scratch_root = Path(scratch_dir)
            scratch = scratch_root / "repository" / "commit"
            scratch.mkdir(parents=True)
            fallback = os.fsencode(scratch / SWIFTPM_RESOURCE_SUFFIX)
            overlap = (len(fallback) + 1) * 2
            prefix = b"x" * (1024 * 1024 - overlap - 2) + b"\x00"
            app = self._make_app(Path(app_dir))
            cli = app / "Contents" / "MacOS" / "lungfish-cli"
            cli.write_bytes(prefix + fallback + b"\x00" + b"z" * overlap)

            result = self.run_scanner(app, scratch, scratch_root=scratch_root)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, "PASS portability\n")

    def test_private_var_tmp_is_rejected_outside_the_exact_cli_fallback(self):
        cases = {
            "wrong file": (
                "Contents/Resources/value.bin",
                b"/private/var/tmp/lungfish-release-swiftpm/repo/commit/arm64-apple-macosx/release/"
                b"LungfishGenomeBrowser_LungfishWorkflow.bundle\x00",
            ),
            "wrong CLI path": (
                "Contents/MacOS/lungfish-cli",
                b"/private/var/tmp/unapproved/path\x00",
            ),
            "extended fallback": (
                "Contents/MacOS/lungfish-cli",
                b"/private/var/tmp/lungfish-release-swiftpm/repo/commit/arm64-apple-macosx/release/"
                b"LungfishGenomeBrowser_LungfishWorkflow.bundle/extra\x00",
            ),
        }
        scratch = Path("/private/var/tmp/lungfish-release-swiftpm/repo/commit")
        for label, (relative, contents) in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp_dir:
                app = self._make_app(Path(temp_dir))
                target = app / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(contents)

                result = self.run_scanner(app, scratch)

                self.assertEqual(result.returncode, 1)
                self.assertIn("private-var-tmp", result.stdout)

    def test_scan_rejects_non_absolute_fallback_and_non_directory_app(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app = self._make_app(root)
            relative = self.run_scanner(app, "relative/scratch")
            missing = self.run_scanner(root / "missing.app", TRUSTED_SCRATCH)

            self.assertEqual(relative.returncode, 2)
            self.assertIn("must be absolute", relative.stderr)
            self.assertEqual(missing.returncode, 2)
            self.assertIn("app must be a directory", missing.stderr)

    def test_scan_fails_closed_when_a_payload_directory_is_unreadable(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = self._make_app(Path(temp_dir))
            blocked = app / "Contents" / "Resources" / "blocked"
            blocked.mkdir()
            (blocked / "secret.bin").write_bytes(b"/Users/alice/secret")
            blocked.chmod(0)
            try:
                result = self.run_scanner(app, TRUSTED_SCRATCH)
            finally:
                blocked.chmod(0o700)

            self.assertEqual(result.returncode, 2)
            self.assertIn("payload traversal failed", result.stderr)
            self.assertNotIn("alice", result.stdout + result.stderr)

    @staticmethod
    def _make_app(root: Path) -> Path:
        app = root / "Lungfish.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "Resources").mkdir(parents=True)
        return app

    @staticmethod
    def _case_alias(path: Path) -> Path | None:
        raw = str(path)
        for index, character in enumerate(raw):
            if not character.isalpha():
                continue
            alias = Path(raw[:index] + character.swapcase() + raw[index + 1 :])
            try:
                if os.path.samefile(alias, path):
                    return alias
            except OSError:
                continue
        return None


class ReleaseCandidateReceiptTests(unittest.TestCase):
    def setUp(self):
        self.python = Path(sys.executable)

    def test_candidate_cannot_be_created_without_gate_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self._make_fixture(Path(temporary))
            result = self._run(fixture, "create", "--app", str(fixture["app"]),
                               "--output", str(fixture["receipt"]), "--channel", "stable",
                               "--scratch-path", str(fixture["scratch"]))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(fixture["receipt"].exists())

    def test_stable_candidate_requires_retained_real_app_smoke_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self._make_fixture(Path(temporary))
            result = self._create(fixture, include_app_smoke=False)
            self.assertNotEqual(result.returncode, 0,
                "Stable must not authorize a candidate without real graphical app checks")
            self.assertFalse(fixture["receipt"].exists())

    def test_candidate_retains_and_verifies_exact_gate_logs_and_manifest(self):
        for changed in ("manifest.json", "0/runner.log", "0/gate.result.json", "dependency-manifest.json"):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                fixture = self._make_fixture(Path(temporary))
                created = self._create(fixture)
                self.assertEqual(created.returncode, 0, created.stderr)
                receipt = json.loads(fixture["receipt"].read_text())
                self.assertEqual(receipt["gates"]["sha256"], hashlib.sha256(fixture["gate_manifest"].read_bytes()).hexdigest())
                shutil.rmtree(fixture["gate_manifest"].parent)
                self.assertEqual(self._verify(fixture).returncode, 0)
                retained = fixture["release"] / "gate-evidence" / changed
                retained.write_bytes(retained.read_bytes() + b"changed")
                verified = self._verify(fixture)
                self.assertNotEqual(verified.returncode, 0)
                self.assertIn("gate", verified.stderr)

    def test_failing_or_retried_gate_cannot_create_candidate(self):
        for mutation in ("failure", "retry", "wrong_source", "missing_log", "missing_gate", "wrong_filter"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                fixture = self._make_fixture(Path(temporary))
                manifest_path = fixture["gate_manifest"]
                manifest = json.loads(manifest_path.read_text())
                result_path = manifest_path.parent / "0/gate.result.json"
                result = json.loads(result_path.read_text())
                if mutation == "failure":
                    result["attempts"][0]["exitStatus"] = 139
                elif mutation == "retry":
                    result["attempts"].append({**result["attempts"][0], "role": "diagnostic-retry"})
                elif mutation == "wrong_filter":
                    result["options"]["filter"] = "OnlyOneTest"
                elif mutation == "wrong_source":
                    result["source"]["commit"] = "f" * 40
                elif mutation == "missing_log":
                    (manifest_path.parent / "0/runner.log").unlink()
                else:
                    manifest["results"].pop()
                result_path.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
                for records in (manifest["results"], manifest["files"]):
                    for record in records:
                        if record["path"] == "0/gate.result.json":
                            record["sha256"] = hashlib.sha256(result_path.read_bytes()).hexdigest()
                            record["sizeBytes"] = result_path.stat().st_size
                manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
                self.assertNotEqual(self._create(fixture).returncode, 0)
                self.assertFalse(fixture["receipt"].exists())

    def test_create_writes_canonical_receipt_with_all_bound_identities(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))

            result = self._create(fixture)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            receipt_bytes = fixture["receipt"].read_bytes()
            receipt = json.loads(receipt_bytes)
            self.assertEqual(
                receipt_bytes,
                (
                    json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
                ).encode(),
            )
            self.assertEqual(stat.S_IMODE(fixture["receipt"].stat().st_mode), 0o600)
            self.assertEqual(receipt["schemaVersion"], 1)
            self.assertEqual(
                receipt["source"], {"clean": True, "commit": fixture["commit"]}
            )
            self.assertEqual(
                receipt["release"],
                {"build": "42", "channel": "stable", "version": "2026.8.1"},
            )
            self.assertEqual(
                receipt["wrapper"],
                {"executable": "Lungfish", "filename": "Lungfish.app"},
            )
            self.assertEqual(receipt["bundle"]["identifier"], "com.lungfish.browser")
            self.assertEqual(receipt["bundle"]["releaseChannel"], "stable")
            self.assertEqual(receipt["toolchain"]["xcodeVersion"], "26.4.1")
            self.assertEqual(receipt["toolchain"]["xcodeBuildVersion"], "17F90")
            self.assertEqual(receipt["toolchain"]["swiftVersion"], "6.2")
            self.assertEqual(
                receipt["toolchain"].get("swiftCompilerIdentity"),
                "Apple Swift version 6.2 (swiftlang-a)",
            )
            self.assertEqual(receipt["toolchain"]["sdkVersion"], "26.0")
            self.assertIn("sdkBuildVersion", receipt["toolchain"])
            self.assertEqual(receipt["toolchain"]["sdkBuildVersion"], "25A100")
            self.assertEqual(receipt["toolchain"]["architecture"], "arm64")
            self.assertEqual(receipt["toolchain"]["deploymentTarget"], "26.0")
            self.assertEqual(receipt["cache"]["schemaVersion"], 1)
            self.assertRegex(receipt["cache"]["fingerprint"], r"^[0-9a-f]{64}$")
            self.assertEqual(
                receipt["cache"]["fingerprint"],
                hashlib.sha256(
                    (
                        json.dumps(
                            receipt["cache"]["fields"],
                            sort_keys=True,
                            separators=(",", ":"),
                        )
                        + "\n"
                    ).encode()
                ).hexdigest(),
            )
            self.assertEqual(
                receipt["cache"]["fields"]["repository"]["canonicalIdentity"],
                "github.com/" + load_contract(fixture["contract"]).identity.repository,
            )
            self.assertEqual(
                receipt["cache"]["fields"]["toolchain"]["xcode"],
                {"build": "17F90", "version": "26.4.1"},
            )
            self.assertEqual(receipt["build"]["scratchPath"], str(fixture["scratch"]))
            self.assertEqual(receipt["inputs"]["micromambaUpstreamSha256"], "a" * 64)
            self.assertEqual(
                receipt["inputs"]["packageResolvedSha256"],
                hashlib.sha256(fixture["package_lock"].read_bytes()).hexdigest(),
            )
            self.assertEqual(
                receipt["inputs"]["managedManifestSha256"],
                hashlib.sha256(fixture["managed_manifest"].read_bytes()).hexdigest(),
            )
            self.assertEqual(
                receipt["inputs"]["releaseContractSha256"],
                hashlib.sha256(fixture["contract"].read_bytes()).hexdigest(),
            )
            self.assertEqual(
                receipt["inputs"]["builderSha256"],
                hashlib.sha256(fixture["builder"].read_bytes()).hexdigest(),
            )
            self.assertEqual(
                receipt["artifacts"]["lungfishCLI"]["sha256"],
                hashlib.sha256(fixture["cli"].read_bytes()).hexdigest(),
            )
            self.assertEqual(
                receipt["artifacts"]["micromamba"]["sha256"],
                hashlib.sha256(b"transformed micromamba\n").hexdigest(),
            )
            self.assertNotEqual(
                receipt["artifacts"]["micromamba"]["sha256"],
                receipt["inputs"]["micromambaUpstreamSha256"],
            )

            verified = self._verify(fixture)
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
            self.assertEqual(verified.stdout, "PASS unsigned candidate receipt\n")

    def test_create_binds_bootstrap_in_macos_resource_bundle_layout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            legacy = (
                fixture["app"]
                / "Contents"
                / "Resources"
                / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
                / "Contents"
                / "Resources"
                / "Tools"
                / "micromamba"
            )
            legacy.parent.mkdir(parents=True)
            fixture["micromamba"].replace(legacy)

            result = self._create(fixture)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            receipt = json.loads(fixture["receipt"].read_text())
            self.assertEqual(
                receipt["artifacts"]["micromamba"]["path"],
                "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/"
                "Contents/Resources/Tools/micromamba",
            )
            self.assertEqual(self._verify(fixture).returncode, 0)

    def test_receipt_fallback_is_derived_from_the_bound_tool_architecture(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            fixture["toolchain"].write_text(
                "XCODE_VERSION=26.4.1\nXCODE_BUILD=17F90\n"
                "SWIFT_VERSION=6.2\nSWIFT_BUILD=swiftlang-a\n"
                "SDK_VERSION=26.0\nSDK_BUILD=25A100\nARCH=x86_64\n",
                encoding="utf-8",
            )

            result = self._create(fixture)

            self.assertEqual(result.returncode, 1)
            self.assertIn("architecture", result.stderr)

    def test_create_derives_changed_build_and_rejects_alternate_scratch(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            with fixture["info_plist"].open("rb") as handle:
                info = plistlib.load(handle)
            info["CFBundleVersion"] = "43"
            with fixture["info_plist"].open("wb") as handle:
                plistlib.dump(info, handle, sort_keys=True)
            other_scratch = fixture["scratch"].with_name("creation-scratch")
            other_scratch.mkdir(mode=0o700)

            result = self._create(fixture, scratch=other_scratch.resolve())

            self.assertEqual(result.returncode, 1)
            self.assertIn("canonical cache", result.stderr)

            canonical = self._create(fixture)
            self.assertEqual(canonical.returncode, 0, canonical.stderr)
            receipt = json.loads(fixture["receipt"].read_text())
            self.assertEqual(receipt["release"]["build"], "43")

    def test_verify_detects_each_real_provenance_input_mutation(self):
        tracked_mutations = {
            "package lock": (
                "package_lock",
                lambda path: path.write_text('{"pins":[],"version":2}  \n'),
            ),
            "managed manifest": (
                "managed_manifest",
                lambda path: path.write_text(path.read_text() + " \n"),
            ),
            "release contract": (
                "contract",
                lambda path: path.write_text(path.read_text() + " \n"),
            ),
            "builder": (
                "builder",
                lambda path: path.write_text(path.read_text() + "# changed\n"),
            ),
        }
        for label, (key, mutate) in tracked_mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp_dir:
                fixture = self._make_fixture(Path(temp_dir))
                self.assertEqual(self._create(fixture).returncode, 0)
                path = fixture[key]
                self._git(
                    fixture["repo"],
                    "update-index",
                    "--assume-unchanged",
                    str(path.relative_to(fixture["repo"])),
                )
                mutate(path)
                self.assertEqual(
                    self._git(fixture["repo"], "status", "--porcelain").stdout, ""
                )

                result = self._verify(fixture)

                self.assertEqual(result.returncode, 1)
                expected_error = "gate dependency bytes differ" if label == "managed manifest" else "receipt does not match"
                self.assertIn(expected_error, result.stderr)

        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            self.assertEqual(self._create(fixture).returncode, 0)
            with fixture["info_plist"].open("rb") as handle:
                info = plistlib.load(handle)
            info["CFBundleVersion"] = "43"
            with fixture["info_plist"].open("wb") as handle:
                plistlib.dump(info, handle, sort_keys=True)

            changed_build = self._verify(fixture)

            self.assertEqual(changed_build.returncode, 1)
            self.assertRegex(changed_build.stderr, "receipt does not match|app smoke identity")

    def test_verify_detects_each_payload_or_toolchain_mutation(self):
        mutations = {
            "CLI byte": lambda fixture: fixture["cli"].write_bytes(b"changed cli\n"),
            "bootstrap byte": lambda fixture: fixture["micromamba"].write_bytes(
                b"changed micromamba\n"
            ),
            "bootstrap mode": lambda fixture: fixture["micromamba"].chmod(0o644),
            "app byte": lambda fixture: fixture["app_executable"].write_bytes(
                b"changed app\n"
            ),
            "Xcode identity": lambda fixture: fixture["toolchain"].write_text(
                "XCODE_VERSION=26.4.2\nXCODE_BUILD=17F91\nSWIFT_VERSION=6.2\nSWIFT_BUILD=swiftlang-a\nSDK_VERSION=26.0\nARCH=arm64\n",
                encoding="utf-8",
            ),
            "Swift compiler build": lambda fixture: fixture["toolchain"].write_text(
                "XCODE_VERSION=26.4.1\nXCODE_BUILD=17F90\nSWIFT_VERSION=6.2\nSWIFT_BUILD=swiftlang-b\nSDK_VERSION=26.0\nSDK_BUILD=25A100\nARCH=arm64\n",
                encoding="utf-8",
            ),
            "SDK build": lambda fixture: fixture["toolchain"].write_text(
                "XCODE_VERSION=26.4.1\nXCODE_BUILD=17F90\nSWIFT_VERSION=6.2\nSWIFT_BUILD=swiftlang-a\nSDK_VERSION=26.0\nSDK_BUILD=25A101\nARCH=arm64\n",
                encoding="utf-8",
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp_dir:
                fixture = self._make_fixture(Path(temp_dir))
                self.assertEqual(self._create(fixture).returncode, 0)
                mutate(fixture)

                result = self._verify(fixture)

                self.assertEqual(result.returncode, 1)
                self.assertIn("FAIL unsigned candidate receipt", result.stderr)

    def test_verify_rejects_changed_channel_argument_dirty_source_and_commit(self):
        cases = ("channel", "dirty", "commit")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp_dir:
                fixture = self._make_fixture(Path(temp_dir))
                self.assertEqual(self._create(fixture).returncode, 0)
                channel = "stable"
                if case == "channel":
                    channel = "preview"
                elif case == "dirty":
                    (fixture["repo"] / "dirty.txt").write_text("dirty\n")
                else:
                    self._git(fixture["repo"], "commit", "--allow-empty", "-m", "next")

                result = self._verify(fixture, channel=channel)

                self.assertEqual(result.returncode, 1)
                self.assertNotIn(str(fixture["repo"]), result.stderr)

    def test_verify_rejects_unknown_schema_missing_fields_and_noncanonical_json(self):
        cases = {
            "schema": lambda value: value.update(schemaVersion=2),
            "missing": lambda value: value.pop("toolchain"),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp_dir:
                fixture = self._make_fixture(Path(temp_dir))
                self.assertEqual(self._create(fixture).returncode, 0)
                receipt = json.loads(fixture["receipt"].read_text())
                mutate(receipt)
                fixture["receipt"].write_text(json.dumps(receipt) + "\n")

                result = self._verify(fixture)

                self.assertEqual(result.returncode, 1)

        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            self.assertEqual(self._create(fixture).returncode, 0)
            receipt = json.loads(fixture["receipt"].read_text())
            fixture["receipt"].write_text(json.dumps(receipt, indent=2) + "\n")
            result = self._verify(fixture)
            self.assertEqual(result.returncode, 1)
            self.assertIn("canonical", result.stderr)

    def test_verify_recomputes_and_rejects_a_changed_cache_fingerprint(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            self.assertEqual(self._create(fixture).returncode, 0)
            receipt = json.loads(fixture["receipt"].read_text())
            self.assertIn("cache", receipt)
            receipt["cache"]["fingerprint"] = "0" * 64
            fixture["receipt"].write_text(
                json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
            )

            result = self._verify(fixture)

            self.assertEqual(result.returncode, 1)
            self.assertIn("cache fingerprint", result.stderr)

    def test_verify_rejects_self_fulfilling_alternate_private_scratch(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            self.assertEqual(self._create(fixture).returncode, 0)
            alternate = fixture["scratch"].with_name("alternate-private-cache")
            alternate.mkdir(mode=0o700)
            receipt = json.loads(fixture["receipt"].read_text())
            receipt["build"]["scratchPath"] = str(alternate.resolve())
            receipt["build"]["swiftPMResourceFallback"] = str(
                alternate.resolve() / SWIFTPM_RESOURCE_SUFFIX
            )
            fixture["receipt"].write_text(
                json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
            )

            result = self._verify(fixture)

            self.assertEqual(result.returncode, 1)
            self.assertIn("canonical cache", result.stderr)

    def test_receipt_rejects_symlink_escape_and_detects_contained_target_change(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir), include_symlink=True)
            self.assertEqual(self._create(fixture).returncode, 0)
            fixture["link"].unlink()
            fixture["link"].symlink_to("../other.txt")

            changed = self._verify(fixture)

            self.assertEqual(changed.returncode, 1)
            self.assertRegex(changed.stderr, "receipt does not match|app smoke identity")

            fixture["link"].unlink()
            fixture["link"].symlink_to("/etc/passwd")
            escaped = self._verify(fixture)
            self.assertEqual(escaped.returncode, 1)
            self.assertIn("symlink escapes app", escaped.stderr)
            self.assertNotIn("/etc/passwd", escaped.stderr)

    def test_create_refuses_symlink_output_and_non_absolute_scratch(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            alternate = fixture["receipt"].with_name("alternate.json")
            alternate.write_text("keep\n")
            fixture["receipt"].symlink_to(alternate)

            symlinked = self._create(fixture)

            self.assertEqual(symlinked.returncode, 1)
            self.assertEqual(alternate.read_text(), "keep\n")
            fixture["receipt"].unlink()
            relative = self._create(fixture, scratch=Path("relative/scratch"))
            self.assertEqual(relative.returncode, 1)
            self.assertIn("scratch path must be absolute", relative.stderr)

        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            fixture["receipt"] = fixture["app"] / "Contents" / "candidate.json"

            nested = self._create(fixture)

            self.assertEqual(nested.returncode, 1)
            self.assertIn("outside the app", nested.stderr)
            self.assertFalse(fixture["receipt"].exists())

    def test_create_refuses_case_alias_output_inside_app(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir))
            alias_app = fixture["release"] / "lungfish.app"
            try:
                aliases_app = os.path.samefile(alias_app, fixture["app"])
            except FileNotFoundError:
                aliases_app = False
            if not aliases_app:
                self.skipTest("requires a case-insensitive filesystem")
            fixture["receipt"] = alias_app / "Contents" / "case-alias.json"

            result = self._create(fixture)

            self.assertEqual(result.returncode, 1)
            self.assertIn("outside the app", result.stderr)
            self.assertFalse(fixture["receipt"].exists())

    def _make_fixture(self, root: Path, include_symlink: bool = False):
        root = root.resolve()
        repo = root / "repo"
        release = root / "release"
        repo.mkdir()
        release.mkdir()

        (repo / "scripts" / "release").mkdir(parents=True)
        recipe_paths = (
            "Lungfish-Info.plist",
            "LungfishCLI-Info.plist",
            "Sources/LungfishCLIExecutable/EntryPoint.swift",
            "Lungfish.xcodeproj/xcshareddata/xcschemes/Lungfish.xcscheme",
            "scripts/release/release_identity.py",
            "scripts/release/debug_artifact.py",
            "config/test-catalog.json",
            "scripts/testing/catalog.py",
            "scripts/test.py",
            "Lungfish.xcodeproj/project.pbxproj",
            "Package.swift",
            "lungfish-cli.entitlements",
            "scripts/bundle-native-tools.sh",
            "scripts/check-package-resolved-consistency.sh",
            "scripts/release/build-notarized-dmg.sh",
            "scripts/release/release-candidate-receipt.py",
            "scripts/release/gate_evidence.py",
            "scripts/release/app_smoke_gate.py",
            "scripts/full-suite-gate.sh",
            "scripts/release/release_cache_fingerprint.py",
            "scripts/release/release_cache_security.py",
            "scripts/release/release_contract.py",
            "scripts/release/release_repository.py",
            "scripts/release/scan-release-portability.py",
            "scripts/sanitize-bundled-tools.sh",
            "scripts/setup-worktree.sh",
            "scripts/smoke-test-release-tools.sh",
        )
        for relative in recipe_paths:
            source = ROOT / relative
            destination = repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        builder = repo / "scripts" / "release" / "build-notarized-dmg.sh"
        builder.write_text("#!/bin/sh\n    # BEGIN LUNGFISH_COMPILER_RECIPE_V2\n    true # fixture compiler recipe\n    # END LUNGFISH_COMPILER_RECIPE_V2\nexit 0\n", encoding="utf-8")
        builder.chmod(0o755)
        (repo / "config").mkdir(exist_ok=True)
        contract = repo / "config" / "release-contract.json"
        shutil.copy2(ROOT / "config" / "release-contract.json", contract)
        # Retain explicit legacy native-smoke policy boundary coverage with fake evidence.
        fixture_contract = json.loads(contract.read_text())
        fixture_contract["gates"]["appSmokeRequired"] = True
        contract.write_text(json.dumps(fixture_contract))
        selected_contract = load_contract(contract)
        cli_identity_path = prepare_identity_plist(repo, selected_contract, "stable")
        package_lock = repo / "Package.resolved"
        package_lock.write_text('{"pins":[],"version":2}\n')
        managed = (
            repo
            / "Sources"
            / "LungfishWorkflow"
            / "Resources"
            / "ManagedTools"
            / "third-party-tools-lock.json"
        )
        managed.parent.mkdir(parents=True)
        managed.write_text(
            json.dumps(
                {
                    "packID": "fixture-tools", "version": "1", "dependencySet": "fixture",
                    "tools": [{"id": "fixture-tool", "version": "1", "environment": "fixture",
                               "packageSpec": "fixture::fixture-tool=1=build0", "executables": ["fixture-tool"]}],
                    "bootstrap": {
                        "micromamba": {
                            "version": "2.9.0-0",
                            "sha256": {"osx-arm64": "a" * 64},
                        }
                    }
                }
            )
            + "\n"
        )

        toolchain = root / "toolchain.env"
        toolchain.write_text(
            "XCODE_VERSION=26.4.1\nXCODE_BUILD=17F90\nSWIFT_VERSION=6.2\nSWIFT_BUILD=swiftlang-a\nSDK_VERSION=26.0\nSDK_BUILD=25A100\nARCH=arm64\n",
            encoding="utf-8",
        )
        bin_dir = root / "bin"
        bin_dir.mkdir()
        self._write_executable(
            bin_dir / "xcodebuild",
            '#!/bin/sh\n. "$RECEIPT_TOOLCHAIN_FIXTURE"\nprintf "Xcode %s\\nBuild version %s\\n" "$XCODE_VERSION" "$XCODE_BUILD"\n',
        )
        self._write_executable(
            bin_dir / "xcrun",
            '#!/bin/sh\n. "$RECEIPT_TOOLCHAIN_FIXTURE"\n'
            'if [ "$1" = "swift" ]; then printf "Apple Swift version %s (%s)\\n" "$SWIFT_VERSION" "$SWIFT_BUILD"; '
            'elif [ "$3" = "--show-sdk-build-version" ]; then printf "%s\\n" "$SDK_BUILD"; '
            'else printf "%s\\n" "$SDK_VERSION"; fi\n',
        )
        self._write_executable(
            bin_dir / "uname",
            '#!/bin/sh\n. "$RECEIPT_TOOLCHAIN_FIXTURE"\nprintf "%s\\n" "$ARCH"\n',
        )

        app = release / "Lungfish.app"
        macos = app / "Contents" / "MacOS"
        tools = (
            app
            / "Contents"
            / "Resources"
            / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
            / "Tools"
        )
        macos.mkdir(parents=True)
        tools.mkdir(parents=True)
        info = {
            "CFBundleDisplayName": "Lungfish Genome Explorer",
            "CFBundleName": "Lungfish",
            "CFBundleIdentifier": "com.lungfish.browser",
            "CFBundleExecutable": "Lungfish",
            "CFBundleShortVersionString": "2026.8.1",
            "CFBundleVersion": "42",
            "LungfishReleaseChannel": "stable",
            "SUFeedURL": f"https://github.com/{selected_contract.identity.repository}/releases/download/sparkle-stable/appcast-stable.xml",
        }
        info.update(identity_plist(selected_contract, "stable"))
        info.update(SUPublicEDKey=selected_contract.identity.sparklePublicEdKey, SUVerifyUpdateBeforeExtraction=True)
        info_plist = app / "Contents" / "Info.plist"
        with info_plist.open("wb") as handle:
            plistlib.dump(info, handle, sort_keys=True)
        app_executable = macos / "Lungfish"
        app_executable.write_bytes(b"unsigned app executable\n")
        app_executable.chmod(0o755)
        cli = macos / "lungfish-cli"
        cli.write_bytes(executable_bytes(identity_plist(selected_contract, "stable")))
        cli.chmod(0o755)
        micromamba = tools / "micromamba"
        micromamba.write_bytes(b"transformed micromamba\n")
        micromamba.chmod(0o755)
        link = app / "Contents" / "Resources" / "current.txt"
        if include_symlink:
            (app / "Contents" / "Resources" / "target.txt").write_text("one\n")
            (app / "Contents" / "other.txt").write_text("two\n")
            link.symlink_to("target.txt")

        (repo / ".gitignore").write_text(".build/\n")
        self._git(repo, "init", "-q")
        self._git(repo, "config", "user.email", "receipt@example.test")
        self._git(repo, "config", "user.name", "Receipt Test")
        self._git(repo, "add", ".")
        self._git(repo, "commit", "-q", "-m", "fixture")
        self._git(
            repo,
            "remote",
            "add",
            "origin",
            f"https://github.com/{selected_contract.identity.repository}.git",
        )
        commit = self._git(repo, "rev-parse", "HEAD").stdout.strip()
        cache_root = root / "release-cache"
        cache_environment = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "PYTHONDONTWRITEBYTECODE": "1",
            "RECEIPT_TOOLCHAIN_FIXTURE": str(toolchain),
            "LUNGFISH_CLI_INFOPLIST_FILE": str(cli_identity_path),
        }
        prepared = subprocess.run(
            [
                str(self.python),
                str(repo / "scripts/release/release_cache_fingerprint.py"),
                "prepare",
                "--project-root",
                str(repo),
                "--repository",
                f"github.com/{selected_contract.identity.repository}",
                "--repository-key",
                hashlib.sha256(f"github.com/{selected_contract.identity.repository}".encode()).hexdigest(),
                "--deployment-target",
                "26.0",
                "--cache-root",
                str(cache_root),
            ],
            cwd=repo,
            env=cache_environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
        scratch = Path(
            next(
                line.split("=", 1)[1]
                for line in prepared.splitlines()
                if line.startswith("CACHE_SWIFTPM=")
            )
        )
        receipt = release / "candidate.json"
        gate_manifest = make_gate_fixture(root / "staged-gates", {"commit": commit, "clean": True},
                                          modules=json.loads(contract.read_text())["gates"]["focusedReleaseTests"], contract_path=contract)
        return {
            "repo": repo,
            "release": release,
            "app": app,
            "app_executable": app_executable,
            "cli": cli,
            "micromamba": micromamba,
            "link": link,
            "scratch": scratch.resolve(),
            "cache_root": cache_root.resolve(),
            "receipt": receipt,
            "gate_manifest": gate_manifest,
            "script": repo / "scripts" / "release" / "release-candidate-receipt.py",
            "bin": bin_dir,
            "toolchain": toolchain,
            "commit": commit,
            "builder": builder,
            "contract": contract,
            "package_lock": package_lock,
            "managed_manifest": managed,
            "info_plist": info_plist,
        }

    def _create(self, fixture, scratch=None, include_app_smoke=True):
        smoke_args = []
        if include_app_smoke:
            smoke = fixture["release"].parent / "staged-app-smoke" / "app-smoke.result.json"
            if not smoke.exists():
                make_app_smoke_fixture(smoke.parent, {"commit": fixture["commit"], "clean": True}, fixture["app"], fixture["contract"])
            smoke_args = ["--app-smoke", str(smoke), "--app-smoke-sha256", hashlib.sha256(smoke.read_bytes()).hexdigest()]
        return self._run(
            fixture,
            "create",
            "--app",
            str(fixture["app"]),
            "--output",
            str(fixture["receipt"]),
            "--channel",
            "stable",
            "--scratch-path",
            str(scratch if scratch is not None else fixture["scratch"]),
            "--gate-manifest", str(fixture["gate_manifest"]),
            "--gate-manifest-sha256", hashlib.sha256(fixture["gate_manifest"].read_bytes()).hexdigest(),
            *smoke_args,
        )

    def _verify(self, fixture, channel="stable"):
        return self._run(
            fixture,
            "verify",
            "--app",
            str(fixture["app"]),
            "--receipt",
            str(fixture["receipt"]),
            "--channel",
            channel,
        )

    def _run(self, fixture, *arguments):
        environment = os.environ.copy()
        environment["PATH"] = f"{fixture['bin']}:{environment['PATH']}"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["RECEIPT_TOOLCHAIN_FIXTURE"] = str(fixture["toolchain"])
        environment["LUNGFISH_RELEASE_CACHE_ROOT"] = str(fixture["cache_root"])
        return subprocess.run(
            [str(self.python), str(fixture["script"]), *arguments],
            cwd=fixture["repo"],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    @staticmethod
    def _write_executable(path: Path, contents: str):
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    @staticmethod
    def _git(repo: Path, *arguments):
        return subprocess.run(
            ["git", *arguments],
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
