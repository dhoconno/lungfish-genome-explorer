import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class ReleaseSmokeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.script = self.root / "scripts" / "smoke-test-release-tools.sh"
        self.lockfile_script = (
            self.root / "scripts" / "check-package-resolved-consistency.sh"
        )
        self.sanitizer = self.root / "scripts" / "sanitize-bundled-tools.sh"

    def test_sanitizer_adhoc_seals_transformed_vendor_macho_for_execution(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            executable = Path(temp_dir) / "micromamba"
            source = self.root / "Sources/LungfishWorkflow/Resources/Tools/micromamba"
            shutil.copyfile(source, executable)
            executable.chmod(0o755)
            self.assertIn(b"/Users/", executable.read_bytes())

            sanitized = subprocess.run(
                [
                    "/bin/bash",
                    str(self.sanitizer),
                    "--adhoc-seal",
                    str(executable),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(
                sanitized.returncode, 0, sanitized.stdout + sanitized.stderr
            )

            ran = subprocess.run(
                [str(executable), "--version"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertTrue(ran.stdout.strip())
            self.assertNotIn(b"/Users/", executable.read_bytes())

            signature = subprocess.run(
                ["/usr/bin/codesign", "-d", "--verbose=4", str(executable)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(signature.returncode, 0, signature.stderr)
            self.assertIn("Signature=adhoc", signature.stderr)
            self.assertIn("TeamIdentifier=not set", signature.stderr)

    def test_smoke_test_fails_when_app_icon_resource_is_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_path = self._make_minimal_app(Path(temp_dir))

            result = subprocess.run(
                ["/bin/bash", str(self.script), str(app_path), "--portability-only"],
                env={**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("app icon missing", result.stderr)

    def test_smoke_test_accepts_app_icon_resource_and_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_path = self._make_minimal_app(Path(temp_dir), include_icon=True)

            result = subprocess.run(
                ["/bin/bash", str(self.script), str(app_path), "--portability-only"],
                env={**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS portability", result.stdout)

    def test_smoke_test_runs_embedded_cli_and_provenance_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_path = self._make_minimal_app(
                Path(temp_dir), include_icon=True, include_cli=True
            )

            result = subprocess.run(
                ["/bin/bash", str(self.script), str(app_path)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS lungfish-cli-version", result.stdout)
            self.assertIn("PASS lungfish-cli-tools", result.stdout)
            self.assertIn("PASS lungfish-cli-qc-summary", result.stdout)
            self.assertIn("PASS micromamba", result.stdout)

    def test_smoke_test_rejects_generic_local_absolute_paths(self):
        leak_markers = [
            ("/Users/alice/project", "user-home"),
            ("/private/tmp/lungfish", "private-tmp"),
            ("/var/folders/abc/lungfish", "macos-temporary"),
            ("/tmp/lungfish", "random-lungfish-tmp"),
            ("DerivedData/Lungfish", "derived-data"),
            (".worktrees/codebase-quality", "worktree"),
            ("/.tmp/lungfish", "temporary-directory"),
        ]
        for marker, label in leak_markers:
            with self.subTest(marker=marker):
                with tempfile.TemporaryDirectory() as temp_dir:
                    app_path = self._make_minimal_app(Path(temp_dir), include_icon=True)
                    leak_file = app_path / "Contents" / "Resources" / "leak.txt"
                    leak_file.write_text(f"debug path: {marker}\n", encoding="utf-8")

                    result = subprocess.run(
                        [
                            "/bin/bash",
                            str(self.script),
                            str(app_path),
                            "--portability-only",
                        ],
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=False,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(label, result.stdout)
                    self.assertNotIn(marker, result.stdout + result.stderr)

    def test_smoke_test_allows_private_tmp_root_runtime_constant(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_path = self._make_minimal_app(Path(temp_dir), include_icon=True)
            runtime_constant = app_path / "Contents" / "Resources" / "runtime-root.txt"
            runtime_constant.write_text("/private/tmp\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(self.script), str(app_path), "--portability-only"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS portability", result.stdout)

    def test_smoke_test_scans_apps_inside_gitignored_build_directory(self):
        build_root = self.root / "build"
        build_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=build_root) as temp_dir:
            app_path = self._make_minimal_app(Path(temp_dir), include_icon=True)
            leak_file = app_path / "Contents" / "Resources" / ".leak.txt"
            leak_file.write_text(
                "debug path: /Users/runner/project\n", encoding="utf-8"
            )

            result = subprocess.run(
                ["/bin/bash", str(self.script), str(app_path), "--portability-only"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("user-home", result.stdout)
            self.assertNotIn("runner", result.stdout + result.stderr)

    def test_smoke_test_passes_exact_swiftpm_fallback_to_portability_scanner(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            app_path = self._make_minimal_app(
                temp_root, include_icon=True, include_cli=True
            )
            scratch = Path("/private/var/tmp/lungfish-release-swiftpm/repo/commit")
            fallback = (
                scratch
                / "arm64-apple-macosx"
                / "release"
                / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
            )
            cli = app_path / "Contents" / "MacOS" / "lungfish-cli"
            cli.write_bytes(b"mach-o\x00" + os.fsencode(fallback) + b"\x00")
            cli.chmod(0o755)

            result = subprocess.run(
                [
                    "/bin/bash",
                    str(self.script),
                    str(app_path),
                    "--portability-only",
                    "--allowed-swiftpm-fallback",
                    str(scratch),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS portability", result.stdout)

    def test_package_resolved_guard_fails_when_xcode_lockfile_diverges(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            self._write_package_resolved(repo / "Package.resolved", revision="root")
            self._write_package_resolved(
                repo
                / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                revision="xcode",
            )

            result = subprocess.run(
                ["/bin/bash", str(self.lockfile_script), str(repo)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Package.resolved divergence", result.stderr)

    def test_package_resolved_guard_requires_xcode_lockfile(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            self._write_package_resolved(repo / "Package.resolved", revision="root")

            result = subprocess.run(
                ["/bin/bash", str(self.lockfile_script), str(repo)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Xcode workspace Package.resolved missing", result.stderr)

    def test_package_resolved_repair_creates_missing_xcode_lockfile(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            root_lockfile = repo / "Package.resolved"
            xcode_lockfile = (
                repo
                / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            )
            self._write_package_resolved(root_lockfile, revision="root")

            result = subprocess.run(
                ["/bin/bash", str(self.lockfile_script), "--repair", str(repo)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(xcode_lockfile.is_file())
            self.assertEqual(xcode_lockfile.read_bytes(), root_lockfile.read_bytes())

    def test_package_resolved_guard_accepts_matching_xcode_lockfile(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            self._write_package_resolved(repo / "Package.resolved", revision="same")
            self._write_package_resolved(
                repo
                / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                revision="same",
            )

            result = subprocess.run(
                ["/bin/bash", str(self.lockfile_script), str(repo)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS Package.resolved consistency", result.stdout)

    def _make_minimal_app(self, root, include_icon=False, include_cli=False):
        app_path = root / "Lungfish.app"
        macos = app_path / "Contents" / "MacOS"
        resources = app_path / "Contents" / "Resources"
        workflow_bundle = resources / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
        tools = workflow_bundle / "Tools"
        tools.mkdir(parents=True)
        managed_tools = workflow_bundle / "ManagedTools"
        managed_tools.mkdir(parents=True)

        info_plist = app_path / "Contents" / "Info.plist"
        info_plist.parent.mkdir(parents=True, exist_ok=True)
        info_plist.write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
</dict>
</plist>
""",
            encoding="utf-8",
        )

        micromamba = tools / "micromamba"
        micromamba.write_text("#!/bin/sh\necho micromamba 1.0\n", encoding="utf-8")
        os.chmod(micromamba, 0o755)
        (tools / "tool-versions.json").write_text(
            '{"tools":[{"name": "micromamba", "version": "1.0"}]}\n', encoding="utf-8"
        )
        (tools / "VERSIONS.txt").write_text("- micromamba: 1.0\n", encoding="utf-8")
        (managed_tools / "third-party-tools-lock.json").write_text(
            '{"bootstrap":{"micromamba":{"version":"1.0","sha256":{}}}}\n',
            encoding="utf-8",
        )

        if include_icon:
            (resources / "AppIcon.icns").write_bytes(b"icns")

        if include_cli:
            macos.mkdir(parents=True, exist_ok=True)
            cli = macos / "lungfish-cli"
            cli.write_text(
                """#!/bin/sh
set -eu
case "$1" in
  --version)
    echo "lungfish-cli 0.0.0-test"
    ;;
  version)
    if [ "${2:-}" = "--tools" ]; then
      echo "micromamba 1.0"
    else
      exit 2
    fi
    ;;
  fastq)
    if [ "${2:-}" != "qc-summary" ]; then
      exit 2
    fi
    output=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output)
          output="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [ -z "$output" ]; then
      exit 2
    fi
    printf '{"inputs":[]}\n' >"$output"
    printf '{"workflowName":"lungfish fastq qc-summary"}\n' >"$output.lungfish-provenance.json"
    printf '{"workflowName":"lungfish fastq qc-summary"}\n' >"$(dirname "$output")/.lungfish-provenance.json"
    ;;
  *)
    exit 2
    ;;
esac
""",
                encoding="utf-8",
            )
            os.chmod(cli, 0o755)

        return app_path

    def _write_package_resolved(self, path, revision):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"""{{
  "pins" : [
    {{
      "identity" : "swift-argument-parser",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-argument-parser.git",
      "state" : {{
        "revision" : "{revision}",
        "version" : "1.0.0"
      }}
    }}
  ],
  "version" : 2
}}
""",
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
