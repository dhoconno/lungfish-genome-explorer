import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class ReleaseSmokeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.script = self.root / "scripts" / "smoke-test-release-tools.sh"

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


if __name__ == "__main__":
    unittest.main()
