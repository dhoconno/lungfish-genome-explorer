import csv
import importlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
import uuid

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "Sources/LungfishWorkflow/Resources/PrimerDesignAdapters/v1"
sys.path.insert(0, str(ADAPTER))

from common import (  # noqa: E402
    AdapterError,
    accept_pair_length,
    adapter_sha256,
    sha256_file,
    validate_request,
)
from olivar_adapter import (  # noqa: E402
    build_msa_projection,
    install_pair_guard,
    normalize_olivar_outputs,
)
from varvamp_adapter import (  # noqa: E402
    build_gap_projection,
    generate_varvamp_config,
    normalize_varvamp_outputs,
)


ANALYSIS_ID = "11111111-1111-4111-8111-111111111111"
RUN_ID = "22222222-2222-4222-8222-222222222222"
RESULT_ID = "33333333-3333-4333-8333-333333333333"
INPUT_ID = "44444444-4444-4444-8444-444444444444"


def fasta(path: Path, rows=("ACGTACGT", "ACGTACGT")):
    path.write_text("".join(f">row{i}\n{seq}\n" for i, seq in enumerate(rows)), encoding="utf-8")


def base_request(root: Path, *, engine="olivar", mode="tiled", grouping="perInput"):
    input_path = root / "input.fasta"
    fasta(input_path)
    return {
        "schemaVersion": 1,
        "engine": engine,
        "engineVersion": "1.3.3" if engine == "olivar" else "1.3.2",
        "analysisID": ANALYSIS_ID,
        "runID": RUN_ID,
        "resultID": RESULT_ID,
        "mode": mode,
        "grouping": grouping,
        "inputs": [{"id": INPUT_ID, "label": "synthetic", "path": str(input_path)}],
        "outputDirectory": str(root / "output"),
        "options": {
            "nominalAmpliconLength": 200,
            "minimumAmpliconLength": 180,
            "maximumAmpliconLength": 220,
            "workers": 1,
        },
    }


class RequestContractTests(unittest.TestCase):
    def test_contract_declares_pinned_versions_hashes_and_coordinates(self):
        contract = json.loads((ADAPTER / "contract.json").read_text(encoding="utf-8"))
        self.assertEqual(contract["schemaVersion"], 1)
        self.assertEqual(contract["adapterVersion"], "1.0.0")
        self.assertEqual(contract["coordinateConvention"], "zeroBasedHalfOpen")
        self.assertEqual(contract["engines"]["olivar"]["distributionVersion"], "1.3.3")
        self.assertEqual(contract["engines"]["varvamp"]["distributionVersion"], "1.3.2")
        self.assertEqual(
            contract["engines"]["olivar"]["sourceFiles"]["tiling_helper.py"],
            "2de15defe24df35b7d3eb1af7b83a621dcbc023d97a58d9a7ebd9403a0d31f74",
        )
        self.assertEqual(
            contract["engines"]["varvamp"]["sourceFiles"]["scripts/alignment.py"],
            "8d95252c460eb190dc6a23e7f3edabad48bd2608fc5bc888a990dff9d1e4ae6d",
        )

    def test_unsupported_engine_version_fails(self):
        with tempfile.TemporaryDirectory() as td:
            request = base_request(Path(td))
            request["engineVersion"] = "1.3.4"
            with self.assertRaisesRegex(AdapterError, "unsupported.*version") as raised:
                validate_request(request)
            self.assertEqual(raised.exception.code, "unsupported_version")

    def test_unsafe_existing_or_relative_output_fails(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            request = base_request(root)
            Path(request["outputDirectory"]).mkdir()
            with self.assertRaises(AdapterError) as raised:
                validate_request(request)
            self.assertEqual(raised.exception.code, "unsafe_output_path")

            request["outputDirectory"] = "relative/output"
            with self.assertRaises(AdapterError) as raised:
                validate_request(request)
            self.assertEqual(raised.exception.code, "unsafe_output_path")

    def test_non_finite_options_fail(self):
        with tempfile.TemporaryDirectory() as td:
            for value in (math.nan, math.inf, -math.inf):
                request = base_request(Path(td))
                request["options"]["minimumVariantFrequency"] = value
                with self.assertRaises(AdapterError) as raised:
                    validate_request(request)
                self.assertEqual(raised.exception.code, "invalid_option")

    def test_invalid_mode_and_grouping_fail(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with self.assertRaises(AdapterError) as raised:
                validate_request(base_request(root, engine="olivar", mode="single"))
            self.assertEqual(raised.exception.code, "invalid_mode")

            with self.assertRaises(AdapterError) as raised:
                validate_request(base_request(root, engine="varvamp", mode="tiled", grouping="combined"))
            self.assertEqual(raised.exception.code, "invalid_grouping")

    def test_qpcr_requires_cumulative_threshold_and_reserves_amplicon_config(self):
        with tempfile.TemporaryDirectory() as td:
            request = base_request(Path(td), engine="varvamp", mode="qpcr")
            with self.assertRaises(AdapterError) as raised:
                validate_request(request)
            self.assertEqual(raised.exception.code, "invalid_option")

            request["options"]["cumulativeConsensusThreshold"] = 0.95
            request["options"]["configOverrides"] = {"QAMPLICON_LENGTH": [70, 200]}
            with self.assertRaises(AdapterError) as raised:
                validate_request(request)
            self.assertEqual(raised.exception.code, "invalid_option")

    def test_unknown_keys_and_boolean_integer_are_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            request = base_request(Path(td))
            request["surprise"] = True
            with self.assertRaises(AdapterError) as raised:
                validate_request(request)
            self.assertEqual(raised.exception.code, "invalid_request")

            request = base_request(Path(td))
            request["options"]["workers"] = True
            with self.assertRaises(AdapterError) as raised:
                validate_request(request)
            self.assertEqual(raised.exception.code, "invalid_option")


class OlivarPairGuardTests(unittest.TestCase):
    def test_inclusive_pair_length_guard_and_invalid_range(self):
        self.assertTrue(accept_pair_length(200, minimum=180, maximum=220))
        self.assertFalse(accept_pair_length(179, minimum=180, maximum=220))
        self.assertFalse(accept_pair_length(221, minimum=180, maximum=220))
        with self.assertRaises(AdapterError) as raised:
            accept_pair_length(200, minimum=221, maximum=220)
        self.assertEqual(raised.exception.code, "invalid_amplicon_range")

    def test_guard_filters_before_saddle_and_fails_empty_tile(self):
        events = []

        class Rows:
            def __init__(self, rows):
                self.rows = rows

            def iterrows(self):
                return enumerate(self.rows)

        # The exact pinned candidate-construction fragment is intentional: the
        # adapter refuses to patch any unexpected upstream source.
        def optimize(all_plex_info, config):
            n_pair = []
            for plex_id, plex_info in all_plex_info.items():
                optimize = []
                plex_amp_len = []
                for i, fp in plex_info['fP_candidate'].iterrows():
                    for j, rp in plex_info['rP_candidate'].iterrows():
                        insert_len = plex_info['insert_coords'][1] - plex_info['insert_coords'][0] + 1
                        # check amplicon length
                        amp_len = fp['primer_len'] + fp['dist'] + insert_len + rp['dist'] + rp['primer_len']
                        plex_amp_len.append(amp_len)
                        optimize.append([fp, rp])
                plex_info['optimize'] = optimize
                n_pair.append(len(optimize))
            events.append("SADDLE")
            return all_plex_info, []

        module = types.ModuleType("fake_tiling_helper")
        module.optimize = optimize
        install_pair_guard(module, minimum=180, maximum=220)
        plexes = {
            "tile-1": {
                "fP_candidate": Rows([{"primer_len": 20, "dist": 0}]),
                "rP_candidate": Rows([{"primer_len": 20, "dist": 0}]),
                "insert_coords": (0, 98),  # final span 139
            }
        }
        with self.assertRaises(AdapterError) as raised:
            module.optimize(plexes, {})
        self.assertEqual(raised.exception.code, "no_feasible_design")
        self.assertEqual(events, [], "SADDLE must not run when a tile has no bounded pair")

    def test_guard_passes_only_in_range_pairs_to_saddle(self):
        # A direct candidate-list helper is exposed by the patched function's
        # observable optimize list; no downstream pair is post-filtered.
        class Rows:
            def __init__(self, rows): self.rows = rows
            def iterrows(self): return enumerate(self.rows)

        def optimize(all_plex_info, config):
            n_pair = []
            for plex_id, plex_info in all_plex_info.items():
                optimize = []
                plex_amp_len = []
                for i, fp in plex_info['fP_candidate'].iterrows():
                    for j, rp in plex_info['rP_candidate'].iterrows():
                        insert_len = plex_info['insert_coords'][1] - plex_info['insert_coords'][0] + 1
                        # check amplicon length
                        amp_len = fp['primer_len'] + fp['dist'] + insert_len + rp['dist'] + rp['primer_len']
                        plex_amp_len.append(amp_len)
                        optimize.append([fp, rp])
                plex_info['optimize'] = optimize
                n_pair.append(len(optimize))
            return [p["optimize"] for p in all_plex_info.values()], []

        module = types.ModuleType("fake_tiling_helper_pass")
        module.optimize = optimize
        install_pair_guard(module, minimum=180, maximum=220)
        plexes = {
            "tile": {
                "fP_candidate": Rows([
                    {"primer_len": 20, "dist": 0, "name": "short"},
                    {"primer_len": 30, "dist": 10, "name": "accepted"},
                ]),
                "rP_candidate": Rows([{"primer_len": 20, "dist": 0}]),
                "insert_coords": (0, 129),
            }
        }
        pair_lists, _ = module.optimize(plexes, {})
        self.assertEqual([pair[0]["name"] for pair in pair_lists[0]], ["accepted"])


class ProjectionTests(unittest.TestCase):
    def test_olivar_msa_projection_records_deleted_gap_columns(self):
        projection = build_msa_projection("AC--GT", "ACGT")
        self.assertEqual(
            projection,
            [
                {"generatedStart": 0, "generatedEnd": 2, "sourceStart": 0, "sourceEnd": 2, "kind": "mapped"},
                {"generatedStart": 2, "generatedEnd": 2, "sourceStart": 2, "sourceEnd": 4, "kind": "collapsed"},
                {"generatedStart": 2, "generatedEnd": 4, "sourceStart": 4, "sourceEnd": 6, "kind": "mapped"},
            ],
        )

    def test_varvamp_projection_distinguishes_mapped_and_collapsed_intervals(self):
        blocks = build_gap_projection(source_length=12, gaps=[[3, 4], [8, 11]], deletion_cutoff=4)
        self.assertEqual(
            blocks,
            [
                {"generatedStart": 0, "generatedEnd": 3, "sourceStart": 0, "sourceEnd": 3, "kind": "mapped"},
                {"generatedStart": 3, "generatedEnd": 4, "sourceStart": 3, "sourceEnd": 5, "kind": "collapsed"},
                {"generatedStart": 4, "generatedEnd": 7, "sourceStart": 5, "sourceEnd": 8, "kind": "mapped"},
                {"generatedStart": 7, "generatedEnd": 9, "sourceStart": 8, "sourceEnd": 12, "kind": "collapsed"},
            ],
        )


class VarVAMPConfigTests(unittest.TestCase):
    def test_generated_config_has_validated_literals_and_forced_qpcr_bounds(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "varvamp_config.py"
            resolved = generate_varvamp_config(
                path,
                mode="qpcr",
                minimum=80,
                maximum=160,
                overrides={"PRIMER_SIZES": [19, 25, 22], "QPROBE_DISTANCE": [5, 14]},
            )
            self.assertEqual(resolved["QAMPLICON_LENGTH"], [80, 160])
            namespace = {}
            exec(path.read_text(encoding="utf-8"), {"__builtins__": {}}, namespace)
            self.assertEqual(namespace["QAMPLICON_LENGTH"], (80, 160))
            self.assertEqual(namespace["PRIMER_SIZES"], (19, 25, 22))

    def test_config_rejects_unknown_or_code_shaped_values(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "varvamp_config.py"
            for overrides in (
                {"UNKNOWN": 1},
                {"PRIMER_HAIRPIN": "__import__('os').system('false')"},
                {"PRIMER_SIZES": [18, 24]},
            ):
                with self.assertRaises(AdapterError):
                    generate_varvamp_config(path, mode="tiled", minimum=180, maximum=220, overrides=overrides)


class NativeNormalizationTests(unittest.TestCase):
    def test_olivar_csv_bed_coordinate_agreement_and_membership(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "scheme_ref.fasta").write_text(">ref\n" + "A" * 250 + "\n", encoding="utf-8")
            with (root / "scheme.csv").open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=[
                    "reference", "amplicon_id", "pool", "fP", "rP", "start",
                    "insert_start", "insert_end", "end", "amplicon", "insert", "fP_full", "rP_full",
                ])
                writer.writeheader()
                writer.writerow({
                    "reference": "scheme", "amplicon_id": "scheme_1", "pool": "1",
                    "fP": "ACGTR", "rP": "TGCAY", "start": "11", "insert_start": "16",
                    "insert_end": "204", "end": "208", "amplicon": "A" * 198,
                    "insert": "A" * 189, "fP_full": "ACGTR", "rP_full": "TGCAY",
                })
            (root / "scheme.primer.bed").write_text(
                "scheme\t10\t15\tscheme_1_LEFT_1\t1\t+\tACGTR\n"
                "scheme\t204\t208\tscheme_1_RIGHT_1\t1\t-\tTGCAY\n",
                encoding="utf-8",
            )
            target = normalize_olivar_outputs(
                root, title="scheme", source_input_id=INPUT_ID, target_id=str(uuid.uuid4()),
                label="synthetic", reference_path="native/input/scheme_ref.fasta", minimum=180, maximum=220,
            )
            self.assertEqual((target["assays"][0]["start"], target["assays"][0]["end"]), (10, 208))
            self.assertEqual(set(target["assays"][0]["memberIDs"]), {o["id"] for o in target["oligos"]})
            self.assertEqual([o["role"] for o in target["oligos"]], ["forward", "reverse"])
            self.assertEqual([o["strand"] for o in target["oligos"]], ["+", "-"])

            (root / "scheme.primer.bed").write_text(
                "scheme\t9\t15\tscheme_1_LEFT_1\t1\t+\tACGTR\n"
                "scheme\t204\t208\tscheme_1_RIGHT_1\t1\t-\tTGCAY\n",
                encoding="utf-8",
            )
            with self.assertRaises(AdapterError) as raised:
                normalize_olivar_outputs(
                    root, title="scheme", source_input_id=INPUT_ID, target_id=str(uuid.uuid4()),
                    label="synthetic", reference_path="native/input/scheme_ref.fasta", minimum=180, maximum=220,
                )
            self.assertEqual(raised.exception.code, "native_contract_mismatch")

    def test_varvamp_qpcr_preserves_reverse_probe_and_alternative_assays(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "ambiguous_consensus.fasta").write_text(">vv_ambiguous_consensus\n" + "ACGT" * 60 + "\n", encoding="utf-8")
            (root / "amplicons.bed").write_text(
                "vv_ambiguous_consensus\t10\t100\tvv_0\t1\t.\n"
                "vv_ambiguous_consensus\t110\t200\tvv_1\t2\t.\n",
                encoding="utf-8",
            )
            (root / "primers.bed").write_text(
                "vv_ambiguous_consensus\t10\t30\tvv_0_LEFT\t1\t+\tACGTACGTACGTACGTACGT\n"
                "vv_ambiguous_consensus\t40\t60\tvv_0_PROBE\t1\t-\tACGTACGTACGTACGTACGT\n"
                "vv_ambiguous_consensus\t80\t100\tvv_0_RIGHT\t1\t-\tACGTACGTACGTACGTACGT\n"
                "vv_ambiguous_consensus\t110\t130\tvv_1_LEFT\t2\t+\tACGTACGTACGTACGTACGT\n"
                "vv_ambiguous_consensus\t140\t160\tvv_1_PROBE\t2\t+\tACGTACGTACGTACGTACGT\n"
                "vv_ambiguous_consensus\t180\t200\tvv_1_RIGHT\t2\t-\tACGTACGTACGTACGTACGT\n",
                encoding="utf-8",
            )
            header = "qpcr_scheme\toligo_type\tstart\tstop\tseq\tsize\tgc_best\ttemp_best\tmean_gc\tmean_temp\tpenalty\toff_target_amplicons\n"
            rows = []
            for scheme, start in (("vv_0", 11), ("vv_1", 111)):
                rows.extend([
                    f"{scheme}\tLEFT\t{start}\t{start+19}\tACGTACGTACGTACGTACGT\t20\t50\t60\t50\t60\t1\tNo",
                    f"{scheme}\tPROBE\t{start+30}\t{start+49}\tACGTACGTACGTACGTACGT\t20\t50\t67\t50\t67\t1\tNo",
                    f"{scheme}\tRIGHT\t{start+70}\t{start+89}\tACGTACGTACGTACGTACGT\t20\t50\t60\t50\t60\t1\tNo",
                ])
            (root / "qpcr_primers.tsv").write_text(header + "\n".join(rows) + "\n", encoding="utf-8")
            target = normalize_varvamp_outputs(
                root, mode="qpcr", source_input_id=INPUT_ID, target_id=str(uuid.uuid4()),
                label="synthetic", reference_path="native/input/ambiguous_consensus.fasta", minimum=70, maximum=200,
            )
            self.assertEqual([a["status"] for a in target["assays"]], ["selected", "alternative"])
            self.assertTrue(all(a["pool"] is None for a in target["assays"]))
            reverse_probe = next(o for o in target["oligos"] if o["role"] == "probe" and o["start"] == 40)
            self.assertEqual(reverse_probe["strand"], "-")
            for assay in target["assays"]:
                roles = {o["role"] for o in target["oligos"] if assay["id"] in o["assayIDs"]}
                self.assertEqual(roles, {"forward", "reverse", "probe"})


class NativeEnvironmentTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LUNGFISH_NATIVE_ADAPTER_INTEGRATION") == "1", "native integration opt-in")
    def test_pinned_runtime_source_verification_and_spawned_config(self):
        # This test is run explicitly under each pinned environment. It checks
        # the actual import, source hash verification, and spawn inheritance.
        if importlib.util.find_spec("olivar"):
            from olivar_adapter import verify_runtime as verify_olivar
            verified = verify_olivar()
            self.assertEqual(verified["version"], "1.3.3")
            expected_distribution = "bioconda::olivar=1.3.3=pyhdfd78af_3"
        elif importlib.util.find_spec("varvamp"):
            from varvamp_adapter import verify_runtime as verify_varvamp, spawned_config_probe
            verified = verify_varvamp()
            self.assertEqual(verified["version"], "1.3.2")
            expected_distribution = "bioconda::varvamp=1.3.2=pyhdfd78af_0"
            with tempfile.TemporaryDirectory() as td:
                config = Path(td) / "config.py"
                generate_varvamp_config(config, mode="qpcr", minimum=81, maximum=159, overrides={})
                self.assertEqual(spawned_config_probe(config), [81, 159])
        else:
            self.fail("test must run in a pinned Olivar or varVAMP runtime")
        self.assertEqual(verified["distribution"], expected_distribution)
        self.assertEqual(Path(verified["environmentPrefix"]), Path(sys.prefix).resolve())
        record = verified["condaPackageRecord"]
        self.assertIsNotNone(record)
        record_path = Path(record["path"])
        self.assertEqual(record["sha256"], sha256_file(record_path))
        self.assertEqual(record["byteSize"], record_path.stat().st_size)
        self.assertEqual(record["channel"], "bioconda")
        first_source = verified["sourceVerification"][0]
        self.assertEqual(first_source["byteSize"], Path(first_source["path"]).stat().st_size)

    @unittest.skipUnless(os.environ.get("LUNGFISH_NATIVE_ADAPTER_DESIGN") == "1", "real native design opt-in")
    def test_real_native_adapter_call_publishes_normalized_provenance(self):
        # Deterministic, non-biological in-memory sequence fixture.
        state = 0x5EED
        bases = []
        for _ in range(1200):
            state = (1103515245 * state + 12345) & 0x7FFFFFFF
            bases.append("ACGT"[(state >> 8) & 3])
        sequence = "".join(bases)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            input_path = root / "synthetic.fasta"
            if importlib.util.find_spec("olivar"):
                engine, version, mode = "olivar", "1.3.3", "tiled"
                nominal, minimum, maximum = 220, 180, 260
            elif importlib.util.find_spec("varvamp"):
                engine, version = "varvamp", "1.3.2"
                mode = os.environ.get("LUNGFISH_NATIVE_VARVAMP_MODE", "single")
                self.assertIn(mode, {"single", "tiled", "qpcr"})
                nominal, minimum, maximum = (135, 70, 200) if mode == "qpcr" else (220, 180, 260)
            else:
                self.fail("test must run in a pinned Olivar or varVAMP runtime")
            degenerate = engine == "olivar" and os.environ.get("LUNGFISH_NATIVE_OLIVAR_DEGENERATE") == "1"
            if degenerate:
                second = list(sequence)
                for index in (211, 487, 823, 1019):
                    second[index] = "ACGT"[("ACGT".index(second[index]) + 1) % 4]
                fasta(input_path, (sequence, "".join(second)))
            else:
                fasta(input_path, (sequence, sequence))
            request = {
                "schemaVersion": 1,
                "engine": engine,
                "engineVersion": version,
                "analysisID": ANALYSIS_ID,
                "runID": RUN_ID,
                "resultID": RESULT_ID,
                "mode": mode,
                "grouping": "perInput",
                "inputs": [{"id": INPUT_ID, "label": "synthetic", "path": str(input_path)}],
                "outputDirectory": str(root / "output"),
                "options": {
                    "nominalAmpliconLength": nominal,
                    "minimumAmpliconLength": minimum,
                    "maximumAmpliconLength": maximum,
                    "workers": 1,
                },
            }
            if mode == "qpcr":
                request["options"].update({
                    "cumulativeConsensusThreshold": 0.95,
                    "maximumProbeAmbiguities": 1,
                    "qpcrTestCount": 5,
                })
            if degenerate:
                request["options"]["degenerate"] = True
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(ADAPTER / "run.py"), "--request", str(request_path)],
                text=True,
                capture_output=True,
                timeout=90,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            output = root / "output"
            result = json.loads((output / "adapter-result-v1.json").read_text(encoding="utf-8"))
            provenance = json.loads((output / "provenance-v1.json").read_text(encoding="utf-8"))
            self.assertEqual(provenance["exitStatus"], 0)
            self.assertEqual(provenance["adapterSHA256"], adapter_sha256(ADAPTER))
            self.assertEqual(provenance["outputs"], result["artifacts"])
            self.assertEqual(provenance["runtime"]["environmentPrefix"], str(Path(sys.prefix).resolve()))
            self.assertIsNotNone(provenance["runtime"]["condaPackageRecord"])
            self.assertTrue(provenance["command"]["nativeInvocations"])
            for key in ("MPLCONFIGDIR", "XDG_CACHE_HOME", "TMPDIR"):
                self.assertIn(".adapter-stage-", provenance["command"]["environment"][key])
            self.assertEqual(result["engine"], engine)
            self.assertTrue(result["results"][0]["targets"][0]["assays"])
            for artifact in result["artifacts"]:
                artifact_path = output / artifact["path"]
                self.assertTrue(artifact_path.is_file())
                self.assertEqual(artifact_path.stat().st_size, artifact["byteSize"])


if __name__ == "__main__":
    unittest.main()
