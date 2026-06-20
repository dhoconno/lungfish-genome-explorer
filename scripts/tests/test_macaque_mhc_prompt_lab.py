import json
import shlex
import sys
import tempfile
import unittest
from pathlib import Path

from openpyxl import Workbook, load_workbook

from scripts.analysis import macaque_mhc_prompt_lab as lab


class MacaqueMHCPromptLabTests(unittest.TestCase):
    def make_synthetic_snprc_workbook(self, root: Path) -> Path:
        path = root / "synthetic_snprc.xlsx"
        wb = Workbook()
        ws = wb.active
        ws.title = "Full Sequencing Results 1"
        ws.append(["Client ID", None, None, "44470", "44395"])
        ws.append(["GS ID", "Total", "Average", "LC1729", "LC1730"])
        ws.append(["Mapped Read Count", None, None, 1000, 1200])
        ws.append(["total_read_count", None, None, 2000, 2200])
        ws.append(["percent_reads_unmapped", None, None, 50.0, 45.4])
        ws.append(["MHC-A Haplotype 1", None, None, "A002.01", "A008.01"])
        ws.append(["MHC-A Haplotype 2", None, None, "A002.01", "A004.01"])
        ws.append(["MHC-B Haplotype 1", None, None, "B001.01", "B028.01"])
        ws.append(["MHC-B Haplotype 2", None, None, "B001.01", "B012.01"])
        ws.append(["MHC-DRB Haplotype 1", None, None, "DR09.01", "DR06.01"])
        ws.append(["MHC-DRB Haplotype 2", None, None, "DR09.01", "DR01.01"])
        ws.append(["MHC-DQA Haplotype 1", None, None, "26g2", "23_01"])
        ws.append(["MHC-DQA Haplotype 2", None, None, "26g2", "01g2"])
        ws.append(["MHC-DQB Haplotype 1", None, None, "18g3", "06g1"])
        ws.append(["MHC-DQB Haplotype 2", None, None, "18g3", "06g2"])
        ws.append(["MHC-DPA Haplotype 1", None, None, "02g1", "02g3"])
        ws.append(["MHC-DPA Haplotype 2", None, None, "02g1", "02g1"])
        ws.append(["MHC-DPB Haplotype 1", None, None, "15g", "07g1"])
        ws.append(["MHC-DPB Haplotype 2", None, None, "15g", "08_01"])
        ws.append(["Comments", "Subtotal", "# Obs.", None, None])
        ws.append(["Mamu-A Major Alleles", None, None, None, None])
        ws.append(["01_Mamu-A1_002g", 100, 1, 90, None])
        ws.append(["01_Mamu-A1_008g", 100, 1, None, 80])
        ws.append(["01_Mamu-A1_004g", 100, 1, None, 70])
        ws.append(["Mamu-B Major Alleles", None, None, None, None])
        ws.append(["03_Mamu-B_001g1", 100, 1, 75, None])
        ws.append(["03_Mamu-B_028_01_01_01", 100, 1, None, 60])
        ws.append(["03_Mamu-B_012g", 100, 1, None, 55])
        ws.append(["Mamu-DRB1 Alleles", None, None, None, None])
        ws.append(["07_Mamu-DRB1_03_03_01_01", 100, 1, 65, None])
        ws.append(["07_Mamu-DRB1_03_12_01_01", 100, 1, None, 45])
        ws.append(["Mamu-DQA Alleles", None, None, None, None])
        ws.append(["09_Mamu-DQA1_26_01", 100, 1, 100, None])
        ws.append(["09_Mamu-DQA1_23_02", 100, 1, None, 95])
        ws.append(["Mamu-DQB Alleles", None, None, None, None])
        ws.append(["10_Mamu-DQB1_18g3", 100, 1, 110, None])
        ws.append(["10_Mamu-DQB1_06g1", 100, 1, None, 105])
        ws.append(["Mamu-DPA Alleles", None, None, None, None])
        ws.append(["11_Mamu-DPA1_02g1", 100, 1, 120, 30])
        ws.append(["11_Mamu-DPA1_02g3", 100, 1, None, 90])
        ws.append(["Mamu-DPB Alleles", None, None, None, None])
        ws.append(["12_Mamu-DPB1_15g", 100, 1, 125, None])
        ws.append(["12_Mamu-DPB1_07g1", 100, 1, None, 98])
        wb.create_sheet("Full Sequencing Results 2")
        wb.save(path)
        return path

    def test_extract_blinds_truth_and_preserves_read_counts(self):
        with tempfile.TemporaryDirectory() as temp:
            workbook = self.make_synthetic_snprc_workbook(Path(temp))
            extracted = lab.extract_workbook(workbook)

        self.assertEqual([sample["gs_id"] for sample in extracted["samples"]], ["LC1729", "LC1730"])
        truth = extracted["truth_calls"]
        self.assertEqual(truth["LC1729"]["MHC-A"], ["A002.01", "A002.01"])
        self.assertEqual(truth["LC1730"]["MHC-DPB"], ["07g1", "08_01"])
        observations = extracted["prompt_input"]["observations"]
        self.assertIn(
            {
                "sample_id": "LC1729",
                "client_id": "44470",
                "report_locus": "MHC-A",
                "source_locus": "Mamu-A1",
                "genotype": "01_Mamu-A1_002g",
                "reads": 90,
                "sheet": "Full Sequencing Results 1",
                "row": 22,
                "sample_mapped_reads": 1000,
                "read_fraction": 0.09,
            },
            observations,
        )
        prompt_json = json.dumps(extracted["prompt_input"], sort_keys=True)
        self.assertNotIn("A002.01", prompt_json)
        self.assertNotIn("B001.01", prompt_json)
        self.assertNotIn("DR09.01", prompt_json)

    def test_locus_mapping_keeps_report_loci_separate(self):
        cases = {
            "01_Mamu-A1_002g": ("MHC-A", "Mamu-A1"),
            "15_Mamu-AG3_02_A1_028": ("MHC-A", "Mamu-AG3"),
            "03_Mamu-B_001g1": ("MHC-B", "Mamu-B"),
            "06_Mamu-I_01g1": ("MHC-B", "Mamu-I"),
            "07_Mamu-DRB1_03_12_01_01": ("MHC-DRB", "Mamu-DRB1"),
            "09_Mamu-DQA1_26_01": ("MHC-DQA", "Mamu-DQA1"),
            "10_Mamu-DQB1_18g3": ("MHC-DQB", "Mamu-DQB1"),
            "11_Mamu-DPA1_02g1": ("MHC-DPA", "Mamu-DPA1"),
            "12_Mamu-DPB1_15g": ("MHC-DPB", "Mamu-DPB1"),
            "13_Mamu-E_02g1": ("context", "Mamu-E"),
        }
        for genotype, expected in cases.items():
            with self.subTest(genotype=genotype):
                self.assertEqual(lab.locus_from_genotype(genotype), expected)

    def test_extract_rejects_workbook_missing_expected_result_sheet(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "missing_sheet.xlsx"
            wb = Workbook()
            wb.active.title = "Full Sequencing Results 1"
            wb.save(path)

            with self.assertRaisesRegex(ValueError, "missing.*Full Sequencing Results 2"):
                lab.extract_workbook(path)

    def test_extract_rejects_incomplete_truth_slots(self):
        with tempfile.TemporaryDirectory() as temp:
            workbook = self.make_synthetic_snprc_workbook(Path(temp))
            wb = load_workbook(workbook)
            wb["Full Sequencing Results 1"]["D6"] = None
            wb.save(workbook)

            with self.assertRaisesRegex(ValueError, "LC1729.*MHC-A"):
                lab.extract_workbook(workbook)

    def test_extract_cli_writes_artifacts_and_complete_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workbook = self.make_synthetic_snprc_workbook(root)
            output_dir = root / "out"
            argv = ["extract", "--workbook", str(workbook), "--output-dir", str(output_dir)]

            self.assertEqual(lab.main(argv), 0)

            artifact_names = ["prompt_input.json", "truth_calls.json", "samples.json", "extract.provenance.json"]
            for name in artifact_names:
                self.assertTrue((output_dir / name).is_file(), name)

            provenance = json.loads((output_dir / "extract.provenance.json").read_text())
            expected_argv = [str(Path(lab.__file__)), *argv]
            self.assertEqual(provenance["schemaVersion"], 1)
            self.assertEqual(provenance["workflowName"], "extract")
            self.assertEqual(provenance["toolName"], lab.TOOL_NAME)
            self.assertEqual(provenance["toolVersion"], lab.TOOL_VERSION)
            self.assertEqual(provenance["argv"], expected_argv)
            self.assertEqual(
                provenance["reproducibleShellCommand"],
                " ".join(shlex.quote(part) for part in [sys.executable, *expected_argv]),
            )
            self.assertEqual(provenance["options"]["workbook"], str(workbook.resolve()))
            self.assertEqual(provenance["options"]["outputDir"], str(output_dir.resolve()))
            self.assertEqual(provenance["options"]["defaults"]["workbook"], str(lab.DEFAULT_SNPRC_WORKBOOK))
            self.assertEqual(provenance["options"]["defaults"]["prompt"], str(lab.DEFAULT_PROMPT))
            self.assertEqual(provenance["options"]["defaults"]["outputRoot"], str(lab.DEFAULT_OUTPUT_ROOT))
            self.assertEqual(provenance["options"]["defaults"]["reportLoci"], lab.REPORT_LOCI)
            self.assertEqual(provenance["options"]["defaults"]["fullResultSheets"], lab.FULL_RESULT_SHEETS)
            self.assertEqual(provenance["exitStatus"], 0)
            self.assertEqual(provenance["status"], "completed")
            self.assertIsNone(provenance["stderr"])
            self.assertIsInstance(provenance["wallTimeSeconds"], float)
            for key in ["python", "platform", "executable", "condaPrefix", "container"]:
                self.assertIn(key, provenance["runtimeIdentity"])
            self.assertTrue(provenance["runtimeIdentity"]["python"])
            self.assertTrue(provenance["runtimeIdentity"]["platform"])
            self.assertEqual(provenance["runtimeIdentity"]["executable"], sys.executable)

            self.assertEqual(len(provenance["inputs"]), 1)
            input_record = provenance["inputs"][0]
            self.assertEqual(input_record["role"], "input")
            self.assertEqual(input_record["path"], str(workbook.resolve()))
            self.assertEqual(input_record["sha256"], lab.sha256_file(workbook))
            self.assertEqual(input_record["sizeBytes"], workbook.stat().st_size)

            expected_outputs = {
                str((output_dir / "prompt_input.json").resolve()): output_dir / "prompt_input.json",
                str((output_dir / "truth_calls.json").resolve()): output_dir / "truth_calls.json",
                str((output_dir / "samples.json").resolve()): output_dir / "samples.json",
            }
            self.assertEqual({record["path"] for record in provenance["outputs"]}, set(expected_outputs))
            for record in provenance["outputs"]:
                output_path = expected_outputs[record["path"]]
                self.assertEqual(record["role"], "output")
                self.assertEqual(record["sha256"], lab.sha256_file(output_path))
                self.assertEqual(record["sizeBytes"], output_path.stat().st_size)


if __name__ == "__main__":
    unittest.main()
