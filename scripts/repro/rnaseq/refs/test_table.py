"""Tests for table.py, run from the repository root with
python3 -m unittest discover -s scripts/repro/rnaseq/refs -p 'test_*.py' -v
"""
import unittest

import table


class MitoCellTest(unittest.TestCase):
    def test_a_found_contig_names_its_rule(self):
        a = {"mito_contig": "NC_005943.1", "mito_contig_source": "assembly report", "report_mito_records": "-"}
        self.assertEqual(table.mito_cell(a), "`NC_005943.1` (assembly report)")

    def test_a_missing_contig_says_what_the_report_lists(self):
        a = {"mito_contig": "-", "mito_contig_source": "none", "report_mito_records": "chrMT/CM111681.1/na/16553"}
        self.assertEqual(table.mito_cell(a), "none in FASTA or GTF, the report lists chrMT (CM111681.1, RefSeq na, 16553 bp)")

    def test_a_missing_contig_with_no_record_in_the_report(self):
        a = {"mito_contig": "-", "mito_contig_source": "none", "report_mito_records": "-"}
        self.assertEqual(table.mito_cell(a), "none in FASTA or GTF")

    def test_an_answer_made_before_the_report_row_existed(self):
        a = {"mito_contig": "MT", "mito_contig_source": "contig name"}
        self.assertEqual(table.mito_cell(a), "`MT` (contig name)")
        self.assertEqual(table.mito_cell({"mito_contig": "-", "mito_contig_source": "none"}), "none in FASTA or GTF")


if __name__ == "__main__":
    unittest.main()
