import json
import os
import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
AUDIT_SCRIPT = PROJECT_ROOT / "scripts" / "testing" / "audit-fixture-provenance.sh"
BACKFILL_SCRIPT = PROJECT_ROOT / "scripts" / "testing" / "write-analysis-fixture-provenance.py"
RETAINED_FIXTURES = [
    "Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00",
    "Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00",
    "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00",
    "Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00",
    "Tests/Fixtures/analyses/spades-2026-01-15T13-00-00",
    "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00",
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish",
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa",
]


class FixtureProvenanceScriptTests(unittest.TestCase):
    def test_audit_fails_when_retained_fixture_lacks_sidecar(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            (fixture / ".lungfish-provenance.json").unlink()

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing provenance sidecar", result.stderr)
            self.assertIn(str(fixture), result.stderr)

    def test_audit_fails_when_sidecar_is_missing_required_fields(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            (fixture / ".lungfish-provenance.json").write_text("{}\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing required field", result.stderr)
            self.assertIn(".lungfish-provenance.json", result.stderr)

    def test_audit_fails_when_recorded_checksum_or_size_does_not_match(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            payload = fixture / "reads.kreport"
            payload.write_text("changed\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checksum mismatch", result.stderr)

    def test_audit_fails_when_payload_metadata_contains_stale_worktree_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            payload = fixture / "payload.txt"
            payload.write_text(
                "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/alignment-tree-viewers/Tests/Fixtures/input.fasta\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stale path marker", result.stderr)
            self.assertIn("payload.txt", result.stderr)

    def test_audit_passes_when_existing_retained_fixtures_have_valid_sidecars(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("fixture provenance audit passed", result.stdout)

    def test_backfill_repairs_invalid_sidecar_and_preserves_valid_existing_sidecar(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for fixture in RETAINED_FIXTURES:
                (root / fixture).mkdir(parents=True)

            missing_fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            (missing_fixture / "reads.kreport").write_text("fixture\n", encoding="utf-8")
            invalid_fixture = root / "Tests" / "Fixtures" / "analyses" / "esviritu-2026-01-15T10-00-00"
            (invalid_fixture / "esviritu-result.json").write_text("{}\n", encoding="utf-8")
            (invalid_fixture / ".lungfish-provenance.json").write_text("{}\n", encoding="utf-8")

            existing_fixture = root / "Tests" / "Fixtures" / "analyses" / "taxtriage-2026-01-15T12-00-00"
            (existing_fixture / "taxtriage-result.json").write_text("{}\n", encoding="utf-8")
            existing_sidecar = existing_fixture / ".lungfish-provenance.json"
            existing_sidecar.write_text(
                json.dumps(self._valid_sidecar(existing_fixture, "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00"), indent=2) + "\n",
                encoding="utf-8",
            )
            original_existing_sidecar = existing_sidecar.read_text(encoding="utf-8")

            result = subprocess.run(
                [str(BACKFILL_SCRIPT), "--root", str(root), "--created-at", "2026-05-10T12:00:00Z"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "GIT_AUTHOR_NAME": "Test User"},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("backfilled", result.stdout)
            self.assertIn("repaired", result.stdout)
            self.assertEqual(existing_sidecar.read_text(encoding="utf-8"), original_existing_sidecar)

            provenance = json.loads((missing_fixture / ".lungfish-provenance.json").read_text(encoding="utf-8"))
            self.assertEqual(provenance["schemaVersion"], 1)
            self.assertEqual(provenance["tool"]["version"], "0.4.0-alpha.12")
            self.assertEqual(provenance["output"]["path"], "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00")
            self.assertEqual(provenance["output"]["fileSize"], 8)
            self.assertEqual(provenance["exitStatus"], 0)
            self.assertIn("historical fixture backfill", provenance["warning"])
            self.assertEqual(provenance["files"][0]["path"], "reads.kreport")
            self.assertEqual(provenance["files"][0]["fileSize"], 8)

            repaired = json.loads((invalid_fixture / ".lungfish-provenance.json").read_text(encoding="utf-8"))
            self.assertEqual(repaired["output"]["path"], "Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00")

            audit = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(audit.returncode, 0, audit.stderr)

    def _make_retained_fixtures(self, root):
        for fixture in RETAINED_FIXTURES:
            fixture_path = root / fixture
            fixture_path.mkdir(parents=True)
            payload = fixture_path / "payload.txt"
            payload.write_text(f"{fixture}\n", encoding="utf-8")
        for fixture in RETAINED_FIXTURES:
            fixture_path = root / fixture
            sidecar = self._valid_sidecar(fixture_path, fixture)
            (fixture_path / ".lungfish-provenance.json").write_text(
                json.dumps(sidecar, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

    def _valid_sidecar(self, fixture_path, relative_fixture):
        files = []
        for path in sorted(fixture_path.rglob("*")):
            if path.is_file() and path.name != ".lungfish-provenance.json":
                data = path.read_bytes()
                files.append(
                    {
                        "path": path.relative_to(fixture_path).as_posix(),
                        "fileSize": len(data),
                        "checksumSHA256": hashlib.sha256(data).hexdigest(),
                    }
                )
        directory_hash = hashlib.sha256()
        for entry in files:
            directory_hash.update(entry["path"].encode("utf-8"))
            directory_hash.update(b"\0")
            directory_hash.update(str(entry["fileSize"]).encode("utf-8"))
            directory_hash.update(b"\0")
            directory_hash.update(entry["checksumSHA256"].encode("utf-8"))
            directory_hash.update(b"\n")
        return {
            "schemaVersion": 1,
            "workflowName": "test-fixture-provenance",
            "toolName": "test-tool",
            "toolVersion": "0.0.0",
            "createdAt": "2026-05-10T12:00:00Z",
            "argv": ["test-tool", relative_fixture],
            "reproducibleShellCommand": f"test-tool {relative_fixture}",
            "options": {"outputDirectory": relative_fixture},
            "runtimeIdentity": {"pythonVersion": "test"},
            "output": {
                "path": relative_fixture,
                "fileSize": sum(entry["fileSize"] for entry in files),
                "checksumSHA256": directory_hash.hexdigest(),
            },
            "files": files,
            "exitStatus": 0,
            "wallTimeSeconds": 0.0,
            "stderr": None,
        }


if __name__ == "__main__":
    unittest.main()
