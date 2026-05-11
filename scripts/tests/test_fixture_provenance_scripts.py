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
REQUIRED_MSA_PAYLOAD_FILES = [
    "alignment/input.unaligned.fasta",
    "alignment/primary.aligned.fasta",
    "alignment/source.original",
    "manifest.json",
    "analysis-metadata.json",
    "metadata/rows.json",
    "metadata/source-row-map.json",
    "metadata/coordinate-maps.json",
    ".viewstate.json",
    "cache/alignment-index.sqlite",
    "metadata/annotations.json",
    "metadata/annotations.sqlite",
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

    def test_audit_fails_when_required_sidecar_fields_have_invalid_types(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            sidecar = fixture / ".lungfish-provenance.json"
            provenance = json.loads(sidecar.read_text(encoding="utf-8"))
            provenance.update(
                {
                    "schemaVersion": "1",
                    "workflowName": "",
                    "toolName": "",
                    "toolVersion": "",
                    "createdAt": "",
                    "argv": "not-an-argv-list",
                    "reproducibleShellCommand": "",
                    "options": "not-options-object",
                    "runtimeIdentity": "not-runtime-object",
                    "exitStatus": "zero",
                    "wallTimeSeconds": "fast",
                    "stderr": 0,
                }
            )
            sidecar.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            for field in [
                "schemaVersion",
                "workflowName",
                "toolName",
                "toolVersion",
                "createdAt",
                "argv",
                "reproducibleShellCommand",
                "options",
                "runtimeIdentity",
                "exitStatus",
                "wallTimeSeconds",
                "stderr",
            ]:
                self.assertIn(f"invalid {field}", result.stderr)

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
                "/Users/dho/Documents/lungfish-genome-explorer/." + "worktrees/alignment" + "-tree-viewers/Tests/Fixtures/input.fasta\n",
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

    def test_audit_fails_when_payload_metadata_contains_tmp_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "taxtriage-2026-01-15T12-00-00"
            payload = fixture / "taxtriage-result.json"
            payload.write_text('{"outputDirectory": "' + "/" + 'tmp/taxtriage-output"}\n', encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stale path marker", result.stderr)
            self.assertIn("taxtriage-result.json", result.stderr)

    def test_audit_fails_when_json_payload_metadata_contains_escaped_tmp_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "taxtriage-2026-01-15T12-00-00"
            payload = fixture / "taxtriage-result.json"
            payload.write_text('{"outputDirectory": "\\/tmp\\/stale"}\n', encoding="utf-8")
            (fixture / ".lungfish-provenance.json").write_text(
                json.dumps(self._valid_sidecar(root, fixture, "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00"), indent=2) + "\n",
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
            self.assertIn("taxtriage-result.json", result.stderr)

    def test_audit_fails_when_sidecar_string_contains_tmp_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "analyses" / "taxtriage-2026-01-15T12-00-00"
            sidecar = fixture / ".lungfish-provenance.json"
            provenance = json.loads(sidecar.read_text(encoding="utf-8"))
            provenance["options"]["debugPath"] = "/" + "tmp/stale-provenance-path"
            sidecar.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stale path marker", result.stderr)
            self.assertIn("options.debugPath", result.stderr)

    def test_audit_fails_when_alignment_sidecar_loses_scientific_workflow_identity(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "alignment" / "sarscov2-mafft-e2e.lungfish"
            sidecar = fixture / ".lungfish-provenance.json"
            provenance = json.loads(sidecar.read_text(encoding="utf-8"))
            provenance["workflowName"] = "analysis-fixture-provenance-historical-backfill"
            provenance["toolName"] = "write-analysis-fixture-provenance.py"
            provenance["historicalBackfill"] = True
            sidecar.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected workflowName", result.stderr)
            self.assertIn("must preserve scientific workflow provenance", result.stderr)

    def test_audit_fails_when_root_alignment_sidecar_omits_mafft_workflow_step(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "alignment" / "sarscov2-mafft-e2e.lungfish"
            sidecar = fixture / ".lungfish-provenance.json"
            provenance = json.loads(sidecar.read_text(encoding="utf-8"))
            provenance["workflowName"] = "sars-cov-2-alignment-fixture-generation"
            provenance["toolName"] = "create_sarscov2_alignment_fixture.py"
            provenance["toolVersion"] = "0.1.0"
            provenance["argv"] = ["python3", "Tests/Fixtures/alignment/create_sarscov2_alignment_fixture.py"]
            provenance["reproducibleCommand"] = "python3 Tests/Fixtures/alignment/create_sarscov2_alignment_fixture.py"
            provenance.pop("workflowSteps", None)
            sidecar.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected workflowName", result.stderr)
            self.assertIn("root alignment provenance must include both fixture generation and lungfish align mafft commands", result.stderr)
            self.assertIn("missing root alignment composite workflowSteps", result.stderr)

    def test_audit_fails_when_nested_mafft_external_invocation_is_incomplete(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = (
                root
                / "Tests"
                / "Fixtures"
                / "alignment"
                / "sarscov2-mafft-e2e.lungfish"
                / "Multiple Sequence Alignments"
                / "sars-cov-2-genomes-mafft.lungfishmsa"
            )
            sidecar = fixture / ".lungfish-provenance.json"
            provenance = json.loads(sidecar.read_text(encoding="utf-8"))
            provenance["externalToolInvocations"][0].update(
                {
                    "argv": "mafft --auto input.fasta",
                    "reproducibleCommand": "",
                    "exitStatus": 1,
                    "wallTimeSeconds": "fast",
                    "stderr": None,
                    "condaEnvironment": "",
                    "executablePath": 42,
                }
            )
            sidecar.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            for message in [
                "invalid MAFFT external invocation argv",
                "invalid MAFFT external invocation reproducibleCommand",
                "invalid MAFFT external invocation exitStatus",
                "invalid MAFFT external invocation wallTimeSeconds",
                "invalid MAFFT external invocation stderr",
                "invalid MAFFT external invocation condaEnvironment",
                "invalid MAFFT external invocation executablePath",
            ]:
                self.assertIn(message, result.stderr)

    def test_audit_fails_when_nested_mafft_input_checksum_or_size_is_wrong(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = (
                root
                / "Tests"
                / "Fixtures"
                / "alignment"
                / "sarscov2-mafft-e2e.lungfish"
                / "Multiple Sequence Alignments"
                / "sars-cov-2-genomes-mafft.lungfishmsa"
            )
            sidecar = fixture / ".lungfish-provenance.json"
            provenance = json.loads(sidecar.read_text(encoding="utf-8"))
            provenance["input"]["fileSize"] = 999
            provenance["input"]["checksumSHA256"] = "wrong"
            provenance["inputFiles"][0]["fileSize"] = 999
            provenance["inputFiles"][0]["checksumSHA256"] = "wrong"
            sidecar.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("MAFFT input fileSize mismatch", result.stderr)
            self.assertIn("MAFFT input checksum mismatch", result.stderr)

    def test_audit_fails_when_nested_mafft_required_payload_file_is_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = (
                root
                / "Tests"
                / "Fixtures"
                / "alignment"
                / "sarscov2-mafft-e2e.lungfish"
                / "Multiple Sequence Alignments"
                / "sars-cov-2-genomes-mafft.lungfishmsa"
            )
            (fixture / "alignment" / "primary.aligned.fasta").unlink()
            (fixture / ".lungfish-provenance.json").write_text(
                json.dumps(
                    self._valid_sidecar(root, fixture, "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa"),
                    indent=2,
                )
                + "\n",
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
            self.assertIn("missing required MAFFT payload file alignment/primary.aligned.fasta", result.stderr)

    def test_audit_fails_when_root_alignment_input_checksum_or_size_is_wrong(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._make_retained_fixtures(root)
            fixture = root / "Tests" / "Fixtures" / "alignment" / "sarscov2-mafft-e2e.lungfish"
            sidecar = fixture / ".lungfish-provenance.json"
            provenance = json.loads(sidecar.read_text(encoding="utf-8"))
            provenance["input"]["fileSize"] = 999
            provenance["input"]["checksumSHA256"] = "wrong"
            sidecar.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("alignment input fileSize mismatch", result.stderr)
            self.assertIn("alignment input checksum mismatch", result.stderr)

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
            self._write_root_alignment_source(root)
            nested_msa = (
                root
                / "Tests"
                / "Fixtures"
                / "alignment"
                / "sarscov2-mafft-e2e.lungfish"
                / "Multiple Sequence Alignments"
                / "sars-cov-2-genomes-mafft.lungfishmsa"
            )
            self._write_complete_msa_payload(nested_msa)
            project_input = (
                root
                / "Tests"
                / "Fixtures"
                / "alignment"
                / "sarscov2-mafft-e2e.lungfish"
                / "Inputs"
            )
            project_input.mkdir()
            (project_input / "sars-cov-2-genomes.fasta").write_text(">alpha\nACGT\n", encoding="utf-8")

            missing_fixture = root / "Tests" / "Fixtures" / "analyses" / "kraken2-2026-01-15T11-00-00"
            (missing_fixture / "reads.kreport").write_text("fixture\n", encoding="utf-8")
            invalid_fixture = root / "Tests" / "Fixtures" / "analyses" / "esviritu-2026-01-15T10-00-00"
            (invalid_fixture / "esviritu-result.json").write_text("{}\n", encoding="utf-8")
            (invalid_fixture / ".lungfish-provenance.json").write_text("{}\n", encoding="utf-8")

            existing_fixture = root / "Tests" / "Fixtures" / "analyses" / "taxtriage-2026-01-15T12-00-00"
            (existing_fixture / "taxtriage-result.json").write_text("{}\n", encoding="utf-8")
            existing_sidecar = existing_fixture / ".lungfish-provenance.json"
            existing_sidecar.write_text(
                json.dumps(self._valid_sidecar(root, existing_fixture, "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00"), indent=2) + "\n",
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
            self.assertNotIn("reproducibleGitCheckout" + "Command", provenance)
            self.assertNotIn("historicalPayloadCheckout" + "Command", provenance)

            repaired = json.loads((invalid_fixture / ".lungfish-provenance.json").read_text(encoding="utf-8"))
            self.assertEqual(repaired["output"]["path"], "Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00")

            root_alignment = json.loads(
                (
                    root
                    / "Tests"
                    / "Fixtures"
                    / "alignment"
                    / "sarscov2-mafft-e2e.lungfish"
                    / ".lungfish-provenance.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(root_alignment["workflowName"], "sars-cov-2-alignment-e2e-fixture-generation")
            self.assertIn("create_sarscov2_alignment_fixture.py", root_alignment["toolName"])
            self.assertIn("lungfish align mafft", root_alignment["toolName"])
            self.assertIn("create_sarscov2_alignment_fixture.py", root_alignment["reproducibleCommand"])
            self.assertIn("lungfish align mafft", root_alignment["reproducibleCommand"])
            step_tools = [step["toolName"] for step in root_alignment["workflowSteps"]]
            self.assertIn("create_sarscov2_alignment_fixture.py", step_tools)
            self.assertIn("lungfish align mafft", step_tools)

            audit = subprocess.run(
                ["/bin/bash", str(AUDIT_SCRIPT), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(audit.returncode, 0, audit.stderr)

    def test_backfill_fails_when_required_alignment_payload_is_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for fixture in RETAINED_FIXTURES:
                (root / fixture).mkdir(parents=True)
            self._write_root_alignment_source(root)
            nested_msa = (
                root
                / "Tests"
                / "Fixtures"
                / "alignment"
                / "sarscov2-mafft-e2e.lungfish"
                / "Multiple Sequence Alignments"
                / "sars-cov-2-genomes-mafft.lungfishmsa"
            )
            self._write_complete_msa_payload(nested_msa)
            (nested_msa / "manifest.json").unlink()
            project_input = root / "Tests" / "Fixtures" / "alignment" / "sarscov2-mafft-e2e.lungfish" / "Inputs"
            project_input.mkdir(parents=True, exist_ok=True)
            (project_input / "sars-cov-2-genomes.fasta").write_text(">alpha\nACGT\n", encoding="utf-8")

            result = subprocess.run(
                [str(BACKFILL_SCRIPT), "--root", str(root), "--created-at", "2026-05-10T12:00:00Z"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "GIT_AUTHOR_NAME": "Test User"},
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing required MAFFT payload file manifest.json", result.stderr)

    def test_backfill_fails_when_root_alignment_source_is_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for fixture in RETAINED_FIXTURES:
                (root / fixture).mkdir(parents=True)
            nested_msa = (
                root
                / "Tests"
                / "Fixtures"
                / "alignment"
                / "sarscov2-mafft-e2e.lungfish"
                / "Multiple Sequence Alignments"
                / "sars-cov-2-genomes-mafft.lungfishmsa"
            )
            self._write_complete_msa_payload(nested_msa)
            project_input = root / "Tests" / "Fixtures" / "alignment" / "sarscov2-mafft-e2e.lungfish" / "Inputs"
            project_input.mkdir(parents=True, exist_ok=True)
            (project_input / "sars-cov-2-genomes.fasta").write_text(">alpha\nACGT\n", encoding="utf-8")

            result = subprocess.run(
                [str(BACKFILL_SCRIPT), "--root", str(root), "--created-at", "2026-05-10T12:00:00Z"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "GIT_AUTHOR_NAME": "Test User"},
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing required scientific input Tests/Fixtures/sarscov2/genome.fasta", result.stderr)

    def _make_retained_fixtures(self, root):
        self._write_root_alignment_source(root)
        for fixture in RETAINED_FIXTURES:
            fixture_path = root / fixture
            fixture_path.mkdir(parents=True)
            payload = fixture_path / "payload.txt"
            payload.write_text(f"{fixture}\n", encoding="utf-8")
            if fixture.endswith(".lungfishmsa"):
                self._write_complete_msa_payload(fixture_path)
                input_dir = root / "Tests" / "Fixtures" / "alignment" / "sarscov2-mafft-e2e.lungfish" / "Inputs"
                input_dir.mkdir(parents=True, exist_ok=True)
                (input_dir / "sars-cov-2-genomes.fasta").write_text(">alpha\nACGT\n", encoding="utf-8")
        for fixture in RETAINED_FIXTURES:
            fixture_path = root / fixture
            sidecar = self._valid_sidecar(root, fixture_path, fixture)
            (fixture_path / ".lungfish-provenance.json").write_text(
                json.dumps(sidecar, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

    def _write_root_alignment_source(self, root):
        source = root / "Tests" / "Fixtures" / "sarscov2"
        source.mkdir(parents=True, exist_ok=True)
        (source / "genome.fasta").write_text(">MT192765.1\nACGT\n", encoding="utf-8")

    def _write_complete_msa_payload(self, fixture_path):
        for relative_path in REQUIRED_MSA_PAYLOAD_FILES:
            path = fixture_path / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.suffix == ".sqlite":
                path.write_bytes(b"SQLite fixture\n")
            elif path.suffix == ".json":
                path.write_text("{}\n", encoding="utf-8")
            elif path.suffix == ".fasta" or path.name == "source.original":
                path.write_text(">alpha\nACGT\n", encoding="utf-8")
            else:
                path.write_text(f"{relative_path}\n", encoding="utf-8")

    def _valid_sidecar(self, root, fixture_path, relative_fixture):
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
        record = {
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
        if relative_fixture == "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish":
            generator_command = "python3 Tests/Fixtures/alignment/create_sarscov2_alignment_fixture.py"
            mafft_command = (
                "lungfish align mafft Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Inputs/sars-cov-2-genomes.fasta "
                "--project Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish "
                "--output 'Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa' "
                "--name sars-cov-2-genomes-mafft --strategy auto --output-order input --sequence-type auto --adjust-direction off --symbols strict --threads 2 --format json"
            )
            record["workflowName"] = "sars-cov-2-alignment-e2e-fixture-generation"
            record["toolName"] = "create_sarscov2_alignment_fixture.py + lungfish align mafft"
            record["toolVersion"] = "0.1.0+0.1.0"
            record["argv"] = ["sh", "-c", f"{generator_command} && {mafft_command}"]
            record["reproducibleShellCommand"] = f"{generator_command} && {mafft_command}"
            record["warnings"] = [
                "Records B-E are deterministic synthetic derivatives for end-to-end testing and are not biological observations."
            ]
            input_path = root / "Tests" / "Fixtures" / "sarscov2" / "genome.fasta"
            input_data = input_path.read_bytes()
            record["input"] = {
                "path": "Tests/Fixtures/sarscov2/genome.fasta",
                "fileSize": len(input_data),
                "checksumSHA256": hashlib.sha256(input_data).hexdigest(),
            }
            record["workflowSteps"] = [
                {
                    "argv": ["python3", "Tests/Fixtures/alignment/create_sarscov2_alignment_fixture.py"],
                    "reproducibleCommand": generator_command,
                    "toolName": "create_sarscov2_alignment_fixture.py",
                    "workflowName": "sars-cov-2-alignment-fixture-generation",
                },
                {
                    "argv": [
                        "lungfish",
                        "align",
                        "mafft",
                        "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Inputs/sars-cov-2-genomes.fasta",
                    ],
                    "reproducibleCommand": mafft_command,
                    "toolName": "lungfish align mafft",
                    "workflowName": "multiple-sequence-alignment-mafft",
                },
            ]
        elif relative_fixture.endswith(".lungfishmsa"):
            record["workflowName"] = "multiple-sequence-alignment-mafft"
            record["toolName"] = "lungfish align mafft"
            record["toolVersion"] = "0.1.0"
            record["externalToolInvocations"] = [
                {
                    "name": "mafft",
                    "version": "7.526",
                    "stderr": "mafft stderr",
                    "argv": ["mafft", "--auto", "alignment/input.unaligned.fasta"],
                    "reproducibleCommand": "mafft --auto alignment/input.unaligned.fasta",
                    "exitStatus": 0,
                    "wallTimeSeconds": 1.0,
                    "condaEnvironment": "lungfish-test",
                    "executablePath": "/usr/bin/mafft",
                }
            ]
            input_path = fixture_path / "alignment" / "source.original"
            input_data = input_path.read_bytes()
            record["input"] = {
                "path": "alignment/source.original",
                "fileSize": len(input_data),
                "checksumSHA256": hashlib.sha256(input_data).hexdigest(),
            }
            project_input_path = root / "Tests" / "Fixtures" / "alignment" / "sarscov2-mafft-e2e.lungfish" / "Inputs" / "sars-cov-2-genomes.fasta"
            project_input_data = project_input_path.read_bytes()
            record["inputFiles"] = [
                {
                    "path": "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Inputs/sars-cov-2-genomes.fasta",
                    "fileSize": len(project_input_data),
                    "checksumSHA256": hashlib.sha256(project_input_data).hexdigest(),
                }
            ]
            record["options"]["name"] = "sars-cov-2-genomes-mafft"
        return record


if __name__ == "__main__":
    unittest.main()
