"""Small, synthetic tests for the opt-in native acceptance harness."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "analysis/validate-primer-pack-mhc.py"
spec = importlib.util.spec_from_file_location("mhc_validation", PATH)
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


class AcceptanceHarnessTests(unittest.TestCase):
    def harness_arguments(self, root, cli_status=0):
        cli = root / "fake-cli"
        cli.write_text(f"#!/bin/sh\nexit {cli_status}\n")
        cli.chmod(0o700)
        project = root / "copy.lungfish"
        msa = project / "Analyses/Multiple Sequence Alignments/test.lungfishmsa"
        msa.mkdir(parents=True)
        (msa / "fixture").write_text("synthetic")
        conda = root / "conda"
        conda.mkdir()
        return [str(PATH), "--cli", str(cli), "--project", str(project),
                "--output", str(root / "results"), "--conda-root", str(conda),
                "--case", "olivar-tiled", "--run"]

    def test_output_cannot_alias_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            argv = self.harness_arguments(root)
            argv[argv.index("--output") + 1] = str(root / "copy.lungfish/nested")
            with patch("sys.argv", argv), self.assertRaises(SystemExit) as raised:
                validation.main()
            self.assertEqual(raised.exception.code, 2)
            self.assertFalse((root / "copy.lungfish/nested").exists())

    def test_exit_zero_without_valid_output_and_failed_command_never_pass(self):
        for code, expected in [(0, "audit-failed"), (7, "native-failed")]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                argv = self.harness_arguments(root, code)
                with patch("sys.argv", argv):
                    self.assertEqual(validation.main(), 1)
                report = json.loads((root / "results/report.json").read_text())
                self.assertTrue(report["inputsUnchanged"])
                self.assertEqual(report["runs"][0]["status"], expected)

    def test_baseline_matrix_covers_three_engines_and_all_varvamp_modes(self):
        cases = validation.cases(False)
        self.assertEqual({(x["engine"], x["mode"]) for x in cases}, {
            ("primalscheme3", "tiled"), ("olivar", "tiled"),
            ("varvamp", "tiled"), ("varvamp", "single"), ("varvamp", "qpcr")})
        q = next(x for x in cases if x["mode"] == "qpcr")
        self.assertEqual((q["minimum"], q["nominal"], q["maximum"]), (70, 135, 200))
        self.assertIn("--consensus-threshold", q["arguments"])

    def test_command_keeps_space_paths_as_single_arguments_and_exact_bounds(self):
        case = validation.cases(False)[0]
        argv = validation.command(Path("/test CLI"), Path("/my input.lungfishmsa"),
                                  Path("/my result.lungfishprimeranalysis"), case, 2)
        self.assertEqual(argv[:4], ["/test CLI", "primers", "design", "primalscheme3"])
        self.assertEqual(argv[argv.index("--msa") + 1], "/my input.lungfishmsa")
        self.assertEqual(argv[argv.index("--amplicon-size-min") + 1], "360")
        self.assertEqual(argv[argv.index("--amplicon-size-max") + 1], "440")

    def test_installed_python_override_uses_exact_engine_environment(self):
        for case in validation.cases(False):
            argv = validation.command(Path("/cli"), Path("/msa"), Path("/out"), case, 2,
                                      installed_python_root=Path("/verified/runtime"))
            if case["engine"] == "primalscheme3":
                self.assertNotIn("--python-path", argv)
            else:
                self.assertEqual(argv[argv.index("--python-path") + 1],
                    f"/verified/runtime/envs/{case['engine']}/bin/python")

    def test_batch_preserves_two_explicit_msa_arguments_and_combined_grouping(self):
        case = next(c for c in validation.cases(True) if c["id"] == "olivar-tiled-combined")
        argv = validation.command(Path("/cli"), [Path("/one.msa"), Path("/two.msa")],
                                  Path("/output"), case, 2)
        self.assertEqual([argv[i + 1] for i, x in enumerate(argv) if x == "--msa"],
                         ["/one.msa", "/two.msa"])
        self.assertEqual(argv[argv.index("--grouping") + 1], "combined")

    def test_safe_file_rejects_escape_and_symlink_outside_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "bundle"
            root.mkdir()
            outside = Path(tmp) / "outside"
            outside.write_text("x")
            (root / "link").symlink_to(outside)
            for path in ("../outside", str(outside), "link"):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    validation.safe_file(root, path)

    def test_artifact_checksum_tampering_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "data").write_text("abc")
            artifact = {"relativePath": "data", "sha256": validation.digest(root / "data"), "byteSize": 3}
            validation.verify_artifact(root, artifact)
            (root / "data").write_text("abd")
            with self.assertRaisesRegex(ValueError, "checksum"):
                validation.verify_artifact(root, artifact)

    def test_qpcr_probe_is_required_and_bounds_include_both_primer_sites(self):
        target = {"referenceLength": 300, "assays": [
            {"id": "a", "start": 10, "end": 110, "memberIDs": ["f", "r", "p"]}],
            "oligos": [
                {"id": "f", "role": "forward", "start": 10, "end": 30, "assayIDs": ["a"]},
                {"id": "r", "role": "reverse", "start": 90, "end": 110, "assayIDs": ["a"]},
                {"id": "p", "role": "probe", "start": 40, "end": 60, "assayIDs": ["a"]}]}
        validation.verify_target(target, "qpcr", 70, 200)
        bad = json.loads(json.dumps(target))
        bad["assays"][0]["memberIDs"].remove("p")
        with self.assertRaises(ValueError):
            validation.verify_target(bad, "qpcr", 70, 200)
        with self.assertRaisesRegex(ValueError, "bounds"):
            validation.verify_target(target, "qpcr", 101, 200)


if __name__ == "__main__":
    unittest.main()
