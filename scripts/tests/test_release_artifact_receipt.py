import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleasePortabilityScannerTests(unittest.TestCase):
    def setUp(self):
        self.scanner = ROOT / "scripts" / "release" / "scan-release-portability.py"

    def run_scanner(self, app: Path, scratch: Path | str):
        return subprocess.run(
            [
                str(ROOT / ".ci-python" / "bin" / "python"),
                str(self.scanner),
                str(app),
                "--allowed-swiftpm-fallback",
                str(scratch),
            ],
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
            prefix = b"\x00\xff" + b"x" * (1024 * 1024 - 3)
            payload = (
                prefix + b"\x00TOP-SECRET-BINARY-BYTES\x00" + b"\x00".join(markers)
            )
            binary.write_bytes(payload)

            result = self.run_scanner(app, root / "scratch")

            self.assertEqual(result.returncode, 1)
            evidence = result.stdout.splitlines()
            self.assertGreaterEqual(len(evidence), len(markers) + 1)
            self.assertTrue(all(line.startswith("Contents/") for line in evidence[:-1]))
            self.assertIn(
                f"Contents/MacOS/fixture:{payload.index(markers[0])}:user-home",
                evidence,
            )
            self.assertIn("FAIL portability findings=7 shown=7", evidence[-1])
            self.assertNotIn("TOP-SECRET", result.stdout + result.stderr)
            self.assertNotIn("alice", result.stdout + result.stderr)
            self.assertLess(len(result.stdout), 4096)

    def test_scan_caps_evidence_at_twenty_records(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app = self._make_app(root)
            binary = app / "Contents" / "MacOS" / "fixture"
            binary.write_bytes(b"\x00".join([b"/Users/private"] * 25))

            result = self.run_scanner(app, root / "scratch")

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
            missing = self.run_scanner(root / "missing.app", root / "scratch")

            self.assertEqual(relative.returncode, 2)
            self.assertIn("must be absolute", relative.stderr)
            self.assertEqual(missing.returncode, 2)
            self.assertIn("app must be a directory", missing.stderr)

    @staticmethod
    def _make_app(root: Path) -> Path:
        app = root / "Lungfish.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "Resources").mkdir(parents=True)
        return app


class ReleaseCandidateReceiptTests(unittest.TestCase):
    def setUp(self):
        self.python = ROOT / ".ci-python" / "bin" / "python"

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
            self.assertEqual(receipt["toolchain"]["architecture"], "arm64")
            self.assertEqual(receipt["toolchain"]["deploymentTarget"], "26.0")
            self.assertEqual(receipt["build"]["scratchPath"], str(fixture["scratch"]))
            self.assertEqual(receipt["inputs"]["micromambaUpstreamSha256"], "a" * 64)
            self.assertEqual(
                receipt["artifacts"]["lungfishCLI"]["sha256"],
                hashlib.sha256(b"transformed cli\n").hexdigest(),
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

    def test_verify_fails_closed_for_each_mutated_bound_receipt_field(self):
        mutations = {
            "commit": lambda value: value["source"].update(commit="0" * 40),
            "channel": lambda value: value["release"].update(channel="preview"),
            "build": lambda value: value["release"].update(build="43"),
            "package lock hash": lambda value: value["inputs"].update(
                packageResolvedSha256="0" * 64
            ),
            "managed lock hash": lambda value: value["inputs"].update(
                managedManifestSha256="0" * 64
            ),
            "contract hash": lambda value: value["inputs"].update(
                releaseContractSha256="0" * 64
            ),
            "builder hash": lambda value: value["inputs"].update(
                builderSha256="0" * 64
            ),
            "toolchain": lambda value: value["toolchain"].update(swiftVersion="6.3"),
            "scratch": lambda value: value["build"].update(
                scratchPath="/private/var/tmp/other"
            ),
            "payload": lambda value: value["artifacts"].update(
                packagedAppPayloadSha256="0" * 64
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp_dir:
                fixture = self._make_fixture(Path(temp_dir))
                self.assertEqual(self._create(fixture).returncode, 0)
                receipt = json.loads(fixture["receipt"].read_text())
                mutate(receipt)
                fixture["receipt"].write_text(
                    json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
                )

                result = self._verify(fixture)

                self.assertEqual(result.returncode, 1)
                self.assertIn("FAIL unsigned candidate receipt", result.stderr)

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
                "XCODE_VERSION=26.4.1\nXCODE_BUILD=17F90\nSWIFT_VERSION=6.2\nSWIFT_BUILD=swiftlang-b\nSDK_VERSION=26.0\nARCH=arm64\n",
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

    def test_receipt_rejects_symlink_escape_and_detects_contained_target_change(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self._make_fixture(Path(temp_dir), include_symlink=True)
            self.assertEqual(self._create(fixture).returncode, 0)
            fixture["link"].unlink()
            fixture["link"].symlink_to("../other.txt")

            changed = self._verify(fixture)

            self.assertEqual(changed.returncode, 1)
            self.assertIn("receipt does not match", changed.stderr)

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

    def _make_fixture(self, root: Path, include_symlink: bool = False):
        root = root.resolve()
        repo = root / "repo"
        release = root / "release"
        scratch = root / "scratch"
        repo.mkdir()
        release.mkdir()
        scratch.mkdir(mode=0o700)

        (repo / "scripts" / "release").mkdir(parents=True)
        for name in (
            "release-candidate-receipt.py",
            "release_contract.py",
            "release_cache_security.py",
        ):
            source = ROOT / "scripts" / "release" / name
            if source.exists():
                shutil.copy2(source, repo / "scripts" / "release" / name)
        builder = repo / "scripts" / "release" / "build-notarized-dmg.sh"
        builder.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        builder.chmod(0o755)
        (repo / "config").mkdir()
        shutil.copy2(ROOT / "config" / "release-contract.json", repo / "config")
        (repo / "Package.resolved").write_text('{"pins":[],"version":2}\n')
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
            "XCODE_VERSION=26.4.1\nXCODE_BUILD=17F90\nSWIFT_VERSION=6.2\nSWIFT_BUILD=swiftlang-a\nSDK_VERSION=26.0\nARCH=arm64\n",
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
            "SUFeedURL": "https://github.test/releases/download/sparkle-stable/appcast-stable.xml",
        }
        with (app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle, sort_keys=True)
        app_executable = macos / "Lungfish"
        app_executable.write_bytes(b"unsigned app executable\n")
        app_executable.chmod(0o755)
        cli = macos / "lungfish-cli"
        cli.write_bytes(b"transformed cli\n")
        cli.chmod(0o755)
        micromamba = tools / "micromamba"
        micromamba.write_bytes(b"transformed micromamba\n")
        micromamba.chmod(0o755)
        link = app / "Contents" / "Resources" / "current.txt"
        if include_symlink:
            (app / "Contents" / "Resources" / "target.txt").write_text("one\n")
            (app / "Contents" / "other.txt").write_text("two\n")
            link.symlink_to("target.txt")

        (repo / ".gitignore").write_text("\n")
        self._git(repo, "init", "-q")
        self._git(repo, "config", "user.email", "receipt@example.test")
        self._git(repo, "config", "user.name", "Receipt Test")
        self._git(repo, "add", ".")
        self._git(repo, "commit", "-q", "-m", "fixture")
        commit = self._git(repo, "rev-parse", "HEAD").stdout.strip()
        receipt = release / "candidate.json"
        return {
            "repo": repo,
            "release": release,
            "app": app,
            "app_executable": app_executable,
            "cli": cli,
            "micromamba": micromamba,
            "link": link,
            "scratch": scratch.resolve(),
            "receipt": receipt,
            "script": repo / "scripts" / "release" / "release-candidate-receipt.py",
            "bin": bin_dir,
            "toolchain": toolchain,
            "commit": commit,
        }

    def _create(self, fixture, scratch=None):
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
            "--scratch-path",
            str(fixture["scratch"]),
        )

    def _run(self, fixture, *arguments):
        environment = os.environ.copy()
        environment["PATH"] = f"{fixture['bin']}:{environment['PATH']}"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["RECEIPT_TOOLCHAIN_FIXTURE"] = str(fixture["toolchain"])
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
