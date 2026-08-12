import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = Path("scripts/testing/generate-classifier-full-viewer-fixture.py")
PAYLOADS = ("source.sam", "evidence.bam", "evidence.bam.bai")


class GenerateClassifierFullViewerFixtureTests(unittest.TestCase):
    def setUp(self):
        (PROJECT_ROOT / ".build").mkdir(exist_ok=True)

    def test_generation_is_deterministic_and_records_exact_resolved_provenance(self):
        samtools = self._samtools()
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT / ".build") as temp_dir:
            temp_root = Path(temp_dir)
            first = temp_root / "first"
            second = temp_root / "second"
            first_args = self._run_generator(first, samtools)
            self._run_generator(second, samtools)

            for name in PAYLOADS:
                self.assertEqual(self._sha256(first / name), self._sha256(second / name), name)

            provenance = json.loads((first / ".lungfish-provenance.json").read_text(encoding="utf-8"))
            self.assertEqual(provenance["argv"], ["python3", str(GENERATOR), *first_args])
            self.assertEqual(provenance["status"], "completed")
            self.assertEqual(provenance["exitStatus"], 0)
            self.assertTrue(provenance["syntheticData"])
            self.assertEqual(provenance["options"]["requested"]["samtools"], samtools)
            self.assertEqual(
                provenance["options"]["resolved"]["outputDirectory"],
                first.relative_to(PROJECT_ROOT).as_posix(),
            )
            self.assertIn("samtoolsExecutableChecksumSHA256", provenance["runtimeIdentity"])
            self.assertEqual(
                [item["subcommand"] for item in provenance["externalToolInvocations"]],
                ["version", "view", "index"],
            )

    def test_failed_transformation_replaces_stale_outputs_and_records_failure(self):
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT / ".build") as temp_dir:
            temp_root = Path(temp_dir)
            output = temp_root / "failed"
            output.mkdir()
            (output / "evidence.bam").write_bytes(b"stale")
            (output / "evidence.bam.bai").write_bytes(b"stale")
            fake_samtools = temp_root / "samtools"
            fake_samtools.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = \"--version\" ]; then\n"
                "  echo 'samtools 1.0-test'\n"
                "  exit 0\n"
                "fi\n"
                "echo 'intentional synthetic failure' >&2\n"
                "exit 23\n",
                encoding="utf-8",
            )
            os.chmod(fake_samtools, 0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(GENERATOR),
                    "--output-dir",
                    str(output.relative_to(PROJECT_ROOT)),
                    "--samtools",
                    str(fake_samtools),
                ],
                cwd=PROJECT_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 23)
            self.assertIn("intentional synthetic failure", result.stderr)
            self.assertTrue((output / "source.sam").is_file())
            self.assertFalse((output / "evidence.bam").exists())
            self.assertFalse((output / "evidence.bam.bai").exists())
            provenance = json.loads((output / ".lungfish-provenance.json").read_text(encoding="utf-8"))
            self.assertEqual(provenance["status"], "failed")
            self.assertEqual(provenance["exitStatus"], 23)
            self.assertIn("intentional synthetic failure", provenance["stderr"])
            self.assertEqual([item["path"] for item in provenance["files"]], ["source.sam"])
            self.assertEqual(
                [item["subcommand"] for item in provenance["externalToolInvocations"]],
                ["version", "view"],
            )
            self.assertEqual(provenance["externalToolInvocations"][-1]["exitStatus"], 23)

    def test_process_launch_failure_records_attempted_invocation(self):
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT / ".build") as temp_dir:
            temp_root = Path(temp_dir)
            output = temp_root / "launch-failed"
            unlaunchable_samtools = temp_root / "unlaunchable-samtools"
            unlaunchable_samtools.write_text(
                "#!/definitely/missing/interpreter\n",
                encoding="utf-8",
            )
            os.chmod(unlaunchable_samtools, 0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(GENERATOR),
                    "--output-dir",
                    output.relative_to(PROJECT_ROOT).as_posix(),
                    "--samtools",
                    str(unlaunchable_samtools),
                ],
                cwd=PROJECT_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 127)
            provenance = json.loads((output / ".lungfish-provenance.json").read_text(encoding="utf-8"))
            self.assertEqual(provenance["status"], "failed")
            self.assertEqual(provenance["exitStatus"], 127)
            self.assertIn("failed to launch samtools --version", provenance["stderr"])
            self.assertEqual(len(provenance["externalToolInvocations"]), 1)
            invocation = provenance["externalToolInvocations"][0]
            self.assertEqual(invocation["argv"], ["samtools", "--version"])
            self.assertEqual(invocation["reproducibleCommand"], "samtools --version")
            self.assertEqual(invocation["exitStatus"], 127)
            self.assertGreaterEqual(invocation["wallTimeSeconds"], 0)
            self.assertIn("failed to launch", invocation["stderr"])
            self.assertIn("samtoolsExecutableChecksumSHA256", invocation["runtimeIdentity"])
            self.assertEqual([item["path"] for item in provenance["files"]], ["source.sam"])

    def _run_generator(self, output: Path, samtools: str) -> list[str]:
        arguments = [
            "--output-dir",
            output.relative_to(PROJECT_ROOT).as_posix(),
            "--samtools",
            samtools,
        ]
        result = subprocess.run(
            ["python3", str(GENERATOR), *arguments],
            cwd=PROJECT_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return arguments

    def _samtools(self) -> str:
        managed = Path.home() / ".lungfish" / "conda" / "envs" / "samtools" / "bin" / "samtools"
        if managed.is_file() and os.access(managed, os.X_OK):
            return str(managed)
        discovered = shutil.which("samtools")
        self.assertIsNotNone(discovered, "samtools is required for the committed fixture")
        return str(discovered)

    @staticmethod
    def _sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
