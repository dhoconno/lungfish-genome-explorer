import json
import os
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

    def test_audit_passes_when_existing_retained_fixtures_have_sidecars(self):
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

    def test_backfill_writes_historical_fixture_provenance_without_overwriting(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for fixture in RETAINED_FIXTURES:
                (root / fixture).mkdir(parents=True)

            missing_fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            (missing_fixture / "reads.kreport").write_text("fixture\n", encoding="utf-8")

            existing_fixture = root / "Tests" / "Fixtures" / "analyses" / "esviritu-2026-01-15T10-00-00"
            existing_sidecar = existing_fixture / ".lungfish-provenance.json"
            existing_sidecar.write_text('{"kept": true}\n', encoding="utf-8")

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
            self.assertEqual(existing_sidecar.read_text(encoding="utf-8"), '{"kept": true}\n')

            provenance = json.loads((missing_fixture / ".lungfish-provenance.json").read_text(encoding="utf-8"))
            self.assertEqual(provenance["schemaVersion"], 1)
            self.assertEqual(provenance["tool"]["version"], "0.4.0-alpha.12")
            self.assertEqual(provenance["output"]["path"], "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00")
            self.assertEqual(provenance["exitStatus"], 0)
            self.assertIn("historical fixture backfill", provenance["warning"])
            self.assertEqual(provenance["files"][0]["path"], "reads.kreport")
            self.assertEqual(provenance["files"][0]["size"], 8)

    def _make_retained_fixtures(self, root):
        for fixture in RETAINED_FIXTURES:
            fixture_path = root / fixture
            fixture_path.mkdir(parents=True)
            (fixture_path / ".lungfish-provenance.json").write_text("{}\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
