import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class ReleaseSmokeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.script = self.root / "scripts" / "smoke-test-release-tools.sh"
        self.lockfile_script = self.root / "scripts" / "check-package-resolved-consistency.sh"

    def test_smoke_test_fails_when_app_icon_resource_is_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_path = self._make_minimal_app(Path(temp_dir))

            result = subprocess.run(
                ["/bin/bash", str(self.script), str(app_path), "--portability-only"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("app icon missing", result.stderr)

    def test_smoke_test_accepts_app_icon_resource_and_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_path = self._make_minimal_app(Path(temp_dir), include_icon=True)

            result = subprocess.run(
                ["/bin/bash", str(self.script), str(app_path), "--portability-only"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS portability", result.stdout)

    def test_smoke_test_runs_embedded_cli_and_provenance_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_path = self._make_minimal_app(Path(temp_dir), include_icon=True, include_cli=True)

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
            "/Users/alice/project",
            "/private/tmp/lungfish",
            "/var/folders/abc/lungfish",
            "/tmp/lungfish",
            "DerivedData/Lungfish",
            ".worktrees/codebase-quality",
            "/.tmp/lungfish",
        ]
        for marker in leak_markers:
            with self.subTest(marker=marker):
                with tempfile.TemporaryDirectory() as temp_dir:
                    app_path = self._make_minimal_app(Path(temp_dir), include_icon=True)
                    leak_file = app_path / "Contents" / "Resources" / "leak.txt"
                    leak_file.write_text(f"debug path: {marker}\n", encoding="utf-8")

                    result = subprocess.run(
                        ["/bin/bash", str(self.script), str(app_path), "--portability-only"],
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=False,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(marker, result.stderr)

    def test_package_resolved_guard_fails_when_xcode_lockfile_diverges(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            self._write_package_resolved(repo / "Package.resolved", revision="root")
            self._write_package_resolved(
                repo / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
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

    def test_package_resolved_guard_accepts_matching_xcode_lockfile(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            self._write_package_resolved(repo / "Package.resolved", revision="same")
            self._write_package_resolved(
                repo / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
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

    def test_release_script_checks_lockfiles_before_reusing_archive(self):
        release_script = (self.root / "scripts" / "release" / "build-notarized-dmg.sh").read_text()
        lines = release_script.splitlines()
        guard_index = self._line_index(
            lines,
            '/bin/bash "$PROJECT_ROOT/scripts/check-package-resolved-consistency.sh" --repair "$PROJECT_ROOT"',
        )
        reuse_index = self._line_index(lines, "printf 'Reusing existing archive: %s\\n' \"$ARCHIVE_PATH\"")

        self.assertLess(guard_index, reuse_index)

    def _make_minimal_app(self, root, include_icon=False, include_cli=False):
        app_path = root / "Lungfish.app"
        macos = app_path / "Contents" / "MacOS"
        resources = app_path / "Contents" / "Resources"
        tools = resources / "LungfishGenomeBrowser_LungfishWorkflow.bundle" / "Tools"
        tools.mkdir(parents=True)

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
        (tools / "tool-versions.json").write_text('{"tools":[{"name": "micromamba"}]}\n', encoding="utf-8")
        (tools / "VERSIONS.txt").write_text("- micromamba: 1.0\n", encoding="utf-8")

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

    def _line_index(self, lines, marker):
        for index, line in enumerate(lines):
            if marker in line:
                return index
        self.fail(f"missing line containing {marker!r}")


if __name__ == "__main__":
    unittest.main()
