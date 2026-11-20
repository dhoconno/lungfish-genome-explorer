"""Tests of the parsers and rules in truth.py and ledger.py (lane CM-TRUTH of sub-phase 5.5).

Run with the reproduction environment, which holds numpy and scipy:
  /Volumes/lge_scratch/lge/rnaseq/env/bin/python -m unittest discover -s scripts/repro/rnaseq/sc-embed/truth
Every input is a few lines built here, so the tests read no 10x file and no scratch folder.
"""
import hashlib
import importlib.util
import math
import os
import struct
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


truth = load("truth")
ledger = load("ledger")


def float32_from_bits(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def manifest_lines(root):
    with open(os.path.join(root, "MANIFEST.tsv")) as handle:
        return handle.read().splitlines()


class SuffixRuleTests(unittest.TestCase):
    """5.5 I2 and I3 on one sample, with the counts that P1 and P2 print."""

    def test_strip_drops_one_trailing_suffix_only(self):
        self.assertEqual(truth.strip_suffix("AAAC-1"), "AAAC")
        self.assertEqual(truth.strip_suffix("AAAC"), "AAAC")
        self.assertEqual(truth.strip_suffix("AAAC-1-1"), "AAAC-1")

    def test_classify_names_the_count_each_reading_would_match(self):
        bare = ["AAAA", "CCCC", "GGGG"]
        dashed = ["AAAA-1", "CCCC-1", "GGGG-1", "TTTT-1"]
        self.assertEqual(truth.classify(bare, dashed), (0, 3, 0))
        self.assertEqual(truth.classify(dashed, bare), (0, 0, 3))
        self.assertEqual(truth.classify(dashed, dashed), (4, 0, 0))

    def test_resolve_as_given_matches_nothing_across_forms(self):
        found = truth.resolve(["AAAA", "CCCC"], ["AAAA-1", "CCCC-1"], suffix=None)
        self.assertEqual(found.matched, [])
        self.assertEqual(found.not_held, [0, 1])
        self.assertEqual(found.without, [0, 1])

    def test_resolve_with_the_flag_counts_matched_not_held_and_without(self):
        result = ["AAAA", "CCCC", "GGGG", "TTTT", "ACGT"]
        table = ["AAAA-1", "CCCC-1", "STRAY-1", "GGGG-1"]
        found = truth.resolve(result, table, suffix="drop")
        self.assertEqual(found.matched, [(0, 0), (1, 1), (3, 2)])
        self.assertEqual(found.not_held, [2])
        self.assertEqual(found.without, [3, 4])
        self.assertEqual(found.mapped, ["AAAA", "CCCC", "STRAY", "GGGG"])

    def test_resolve_adds_the_suffix_the_other_way(self):
        found = truth.resolve(["AAAA-1", "CCCC-1"], ["CCCC", "AAAA"], suffix="add")
        self.assertEqual(found.matched, [(0, 1), (1, 0)])
        self.assertEqual(found.without, [])

    def test_a_barcode_twice_in_a_table_is_refused(self):
        with self.assertRaises(ValueError):
            truth.resolve(["AAAA"], ["AAAA", "AAAA"], suffix=None)


class ParserTests(unittest.TestCase):
    def test_feature_without_a_type_is_gene_expression(self):
        rows = truth.parse_features(["ENSG1\tA", "ENSG2\tB\tAntibody Capture", "ENSG3\tC\tGene Expression"])
        self.assertEqual(rows, [("ENSG1", "A", "Gene Expression"), ("ENSG2", "B", "Antibody Capture"),
                                ("ENSG3", "C", "Gene Expression")])

    def test_csv_rows_are_kept_as_given(self):
        rows = truth.parse_csv(["Barcode,TSNE-1,TSNE-2", "AAAC-1,16.594893339647868,-20.5"], "Barcode,TSNE-1,TSNE-2")
        self.assertEqual(rows, [["AAAC-1", "16.594893339647868", "-20.5"]])
        with self.assertRaises(ValueError):
            truth.parse_csv(["Barcode,Cluster", "AAAC-1,3"], "Barcode,TSNE-1,TSNE-2")

    def test_find_gene_reads_a_prefixed_name_of_a_two_genome_result(self):
        features = [("hg19_E1", "hg19_LYZ", "Gene Expression"), ("mm10___E2", "mm10___Lyz2", "Gene Expression"),
                    ("E3", "LYZ", "Gene Expression")]
        self.assertEqual(truth.find_gene(features, "LYZ"), [0, 2])
        self.assertEqual(truth.find_gene(features, "CD3E"), [])


class NormalisationTests(unittest.TestCase):
    """The value of 5.5 G1 is log1p(UMIs / total * 10,000), divided first, then multiplied, then rounded once."""

    def test_the_order_of_operations_is_observable(self):
        differ = [(v, s) for v in range(1, 20) for s in range(1, 200) if truth.scaled(v, s) != v * 10000.0 / s]
        self.assertTrue(differ, "dividing first must differ from multiplying first for some pair")
        self.assertEqual(truth.scaled(1, 2), 5000.0)

    def test_norm_f64_is_log1p_of_the_scaled_value(self):
        self.assertEqual(truth.norm_f64(2, 4), math.log1p(5000.0))

    def test_float32_rounding_bits_and_text(self):
        self.assertEqual(truth.f32_bits(1.0), 0x3F800000)
        self.assertEqual(truth.f32(0.1), struct.unpack("<f", struct.pack("<f", 0.1))[0])
        value = truth.f32(math.log1p(1234.5 / 40000 * 10000))
        self.assertEqual(truth.f32(float(truth.f32_text(value))), value)
        self.assertEqual(truth.f32_text(truth.f32(0.1)), "0.1")

    def test_ulp_distance_counts_float32_neighbours(self):
        one, up = 1.0, float32_from_bits(0x3F800001)
        self.assertEqual(truth.ulp_distance(one, one), 0)
        self.assertEqual(truth.ulp_distance(one, up), 1)
        self.assertEqual(truth.ulp_distance(up, float32_from_bits(0x3F800003)), 2)

    def test_the_vector_form_equals_the_scalar_form_bit_for_bit(self):
        import numpy as np
        import scipy.sparse as sp
        dense = np.array([[1, 0, 4], [2, 3, 0], [0, 7, 1]], dtype=np.int64)
        csc = sp.csc_matrix(dense)
        csc.sort_indices()
        totals = np.asarray(csc.sum(axis=0)).ravel()
        got = truth.norm_entries(csc, totals)
        want = []
        for column in range(3):
            for at in range(csc.indptr[column], csc.indptr[column + 1]):
                want.append(truth.norm_f64(int(csc.data[at]), int(totals[column])))
        self.assertEqual(got.view(np.uint64).tolist(), np.array(want).view(np.uint64).tolist())


class SelectionAccountingTests(unittest.TestCase):
    """5.5 S3. Selected, rest and unlabelled UMIs add up to the sample's Gene Expression UMIs."""

    UMIS = [5, 7, 11, 13, 17]
    LABELS = ["1", "1", "2", None, "2"]

    def test_account_splits_the_umis_three_ways(self):
        row = truth.account(self.UMIS, self.LABELS, "1")
        self.assertEqual((row["selected_cells"], row["selected_umis"]), (2, 12))
        self.assertEqual((row["rest_cells"], row["rest_umis"]), (2, 28))
        self.assertEqual((row["unlabelled_cells"], row["unlabelled_umis"]), (1, 13))
        self.assertEqual(row["total_umis"], 53)
        self.assertTrue(row["adds_up"])

    def test_account_with_every_cell_labelled_has_no_unlabelled_umis(self):
        row = truth.account([1, 2, 3], ["a", "b", "b"], "b")
        self.assertEqual((row["unlabelled_cells"], row["unlabelled_umis"], row["rest_cells"]), (0, 0, 1))
        self.assertTrue(row["adds_up"])

    def test_table_text_is_the_pseudobulk_count_table_form(self):
        text = truth.table_text(["g1", "g2"], [("a", [1, 2]), ("b", [3, 4])])
        self.assertEqual(text, "feature_id\ta\tb\ng1\t1\t3\ng2\t2\t4\n")

    def test_groups_under_ten_cells_are_left_out_of_the_table(self):
        kept = truth.kept_groups({"x": 9, "y": 10, "z": 11})
        self.assertEqual(kept, ["y", "z"])


class LedgerTests(unittest.TestCase):
    """The ledger rows are written once under a lock, and a changed file is never silently written over."""

    def make_truth(self, root, files):
        folder = os.path.join(root, "truth")
        os.makedirs(folder)
        sums = []
        for name, data in files.items():
            with open(os.path.join(folder, name), "wb") as handle:
                handle.write(data)
            sums.append(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
        with open(os.path.join(folder, "SHA256SUMS"), "w") as handle:
            handle.write("".join(sums))
        with open(os.path.join(root, "MANIFEST.tsv"), "w") as handle:
            handle.write("path\turl\tbytes\tchecksum_type\tchecksum\tsource_checksum_verified\tdownloaded_at\tstaged_by\n")
        return folder

    def test_rows_are_added_once_and_a_second_call_adds_none(self):
        with tempfile.TemporaryDirectory() as root:
            folder = self.make_truth(root, {"a.tsv": b"one\n", "b.tsv": b"two\n"})
            added, present, conflicts = ledger.add_rows(root, folder, "CM-TRUTH", now="2026-11-19T00:00:00Z")
            self.assertEqual((added, present, conflicts), (2, 0, []))
            rows = manifest_lines(root)
            self.assertEqual(len(rows), 3)
            self.assertTrue(rows[1].startswith(os.path.join(folder, "a.tsv") + "\t"))
            self.assertIn("\tsha256\t" + hashlib.sha256(b"one\n").hexdigest() + "\tderived\t", rows[1])
            self.assertTrue(rows[1].endswith("\tCM-TRUTH"))
            again = ledger.add_rows(root, folder, "CM-TRUTH", now="2026-11-19T00:00:01Z")
            self.assertEqual(again, (0, 2, []))
            self.assertEqual(len(manifest_lines(root)), 3)

    def test_a_changed_file_is_a_conflict_and_nothing_is_written(self):
        with tempfile.TemporaryDirectory() as root:
            folder = self.make_truth(root, {"a.tsv": b"one\n"})
            ledger.add_rows(root, folder, "CM-TRUTH", now="2026-11-19T00:00:00Z")
            with open(os.path.join(folder, "a.tsv"), "wb") as handle:
                handle.write(b"changed\n")
            with open(os.path.join(folder, "SHA256SUMS"), "w") as handle:
                handle.write(f"{hashlib.sha256(b'changed' + bytes([10])).hexdigest()}  a.tsv\n")
            added, present, conflicts = ledger.add_rows(root, folder, "CM-TRUTH", now="2026-11-19T00:00:02Z")
            self.assertEqual((added, present), (0, 0))
            self.assertEqual(conflicts, [os.path.join(folder, "a.tsv")])
            self.assertEqual(len(manifest_lines(root)), 2)

    def test_a_file_that_differs_from_sha256sums_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            folder = self.make_truth(root, {"a.tsv": b"one\n"})
            with open(os.path.join(folder, "a.tsv"), "wb") as handle:
                handle.write(b"edited after the sums\n")
            with self.assertRaises(ValueError):
                ledger.add_rows(root, folder, "CM-TRUTH", now="2026-11-19T00:00:00Z")
            self.assertEqual(len(manifest_lines(root)), 1)


if __name__ == "__main__":
    unittest.main()
