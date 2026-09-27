import hashlib
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class SignedBootstrapSmokeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.helper = self.root / "scripts/release/smoke_signed_bootstrap.py"

    def test_bootstrap_only_reconciliation_verifies_receipt_provenance_and_second_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self._make_fake_app(Path(directory), plan_extra_environment=False)

            result = subprocess.run(
                ["python3", str(self.helper), str(app)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS signed-bootstrap-reconciliation", result.stdout)

    def test_unexpected_environment_work_fails_closed_before_apply(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self._make_fake_app(Path(directory), plan_extra_environment=True)

            result = subprocess.run(
                ["python3", str(self.helper), str(app)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("bootstrap-only plan", result.stderr)

    def test_apply_failure_reports_bounded_cli_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self._make_fake_app(
                Path(directory),
                plan_extra_environment=False,
                apply_failure="packaged signature rejected",
            )

            result = subprocess.run(
                ["python3", str(self.helper), str(app)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("micromamba: packaged signature rejected", result.stderr)

    def test_packaged_binary_must_differ_from_upstream_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self._make_fake_app(
                Path(directory),
                plan_extra_environment=False,
                matching_upstream_hash=True,
            )

            result = subprocess.run(
                ["python3", str(self.helper), str(app)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pre-signing upstream hash", result.stderr)

    def _make_fake_app(
        self,
        root: Path,
        *,
        plan_extra_environment: bool,
        apply_failure: str | None = None,
        matching_upstream_hash: bool = False,
    ) -> Path:
        app = root / "Lungfish.app"
        resources = (
            app
            / "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources"
        )
        tools = resources / "Tools"
        managed = resources / "ManagedTools"
        macos = app / "Contents/MacOS"
        tools.mkdir(parents=True)
        managed.mkdir(parents=True)
        macos.mkdir(parents=True)

        micromamba = tools / "micromamba"
        micromamba.write_text("#!/bin/sh\necho 2.9.0\n", encoding="utf-8")
        micromamba.chmod(0o755)
        upstream_hash = (
            hashlib.sha256(micromamba.read_bytes()).hexdigest()
            if matching_upstream_hash
            else "0" * 64
        )
        manifest = {
            "dependencySet": "2026.2",
            "packID": "lungfish-tools",
            "bootstrap": {
                "micromamba": {
                    "version": "2.9.0-0",
                    "sha256": {"osx-arm64": upstream_hash},
                }
            },
            "tools": [
                {
                    "id": "samtools",
                    "environment": "samtools",
                    "packageSpec": "bioconda::samtools=1.24=h36b3a25_1",
                }
            ],
        }
        (managed / "third-party-tools-lock.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

        cli = macos / "lungfish-cli"
        cli.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/python3
                import hashlib
                import json
                import os
                import pathlib
                import shutil
                import sys
                from datetime import datetime, timezone

                args = sys.argv[1:]
                storage = pathlib.Path(args[args.index("--storage-root") + 1])
                conda = pathlib.Path(os.environ["LUNGFISH_CONDA_ROOT"])
                destination = conda / "bin/micromamba"
                target = "2.9.0-0"
                dependency_set = "2026.2"
                app = pathlib.Path(sys.argv[0]).parents[2]
                bundled = app / "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools/micromamba"

                def plan():
                    extra = [{{"environment": "unexpected"}}] if {plan_extra_environment!r} else []
                    return {{
                        "bootstrapUpdate": None if destination.exists() else {{"targetVersion": target}},
                        "databaseUpdates": [],
                        "estimatedDownloadBytes": 0,
                        "installEnvironments": extra,
                        "pipelinePrefetch": [],
                        "preservedEnvironments": [],
                        "reinstallEnvironments": [],
                        "removeEnvironments": [],
                        "targetDependencySet": dependency_set,
                    }}

                if args[:3] == ["tools", "update", "--plan"]:
                    current = plan()
                    print(json.dumps(current))
                    raise SystemExit(0 if current["bootstrapUpdate"] is None and not current["installEnvironments"] else 10)

                if args[:4] == ["tools", "update", "--apply", "--yes"]:
                    failure = {apply_failure!r}
                    if failure is not None:
                        report = {{"plan": plan(), "result": {{"succeeded": [], "failed": {{"micromamba": failure}}}}}}
                        print(json.dumps(report))
                        raise SystemExit(1)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(bundled, destination)
                    destination.chmod(0o755)
                    receipt = {{
                        "schemaVersion": 1,
                        "dependencySet": dependency_set,
                        "bootstrap": {{"micromambaVersion": target}},
                    }}
                    (storage / "dependency-receipt.json").write_text(json.dumps(receipt))
                    provenance_dir = storage / "provenance/dependencies"
                    provenance_dir.mkdir(parents=True, exist_ok=True)
                    provenance = {{
                        "workflowName": "dependency-reconcile",
                        "exitStatus": 0,
                        "steps": [{{
                            "toolName": "micromamba",
                            "toolVersion": target,
                            "exitStatus": 0,
                            "argv": ["bootstrap", "micromamba"],
                        }}],
                    }}
                    (provenance_dir / "test.lungfish-provenance.json").write_text(json.dumps(provenance))
                    print(json.dumps({{"plan": plan(), "result": {{"succeeded": ["micromamba"], "failed": {{}}, "receipt": receipt}}}}))
                    raise SystemExit(0)

                raise SystemExit(64)
                """
            ),
            encoding="utf-8",
        )
        cli.chmod(0o755)
        return app


if __name__ == "__main__":
    unittest.main()
