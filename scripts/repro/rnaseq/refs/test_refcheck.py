"""Tests for refcheck.py, run from the repository root with
python3 -m unittest discover -s scripts/repro/rnaseq/refs -p 'test_refcheck.py' -v
"""
import contextlib
import gzip
import hashlib
import io
import tempfile
import unittest
from pathlib import Path

import refcheck

FASTA = (
    ">chr1 first contig\nACGTACGTAC\nGTACGTACGT\n"
    ">MT small circular contig\nACGTAC\n"
    ">chrU unplaced\nAC\n"
)


def row(seq, ftype, attrs):
    return "\t".join([seq, "t", ftype, "1", "100", ".", "+", ".", attrs]) + "\n"


GTF = (
    row("chr1", "gene", 'gene_id "G1"; gene_name "AAA";')
    + row("chr1", "exon", 'gene_id "G1"; transcript_id "T1";')
    + row("chr1", "CDS", 'gene_id "G1"; transcript_id "T1";')
    + row("chr1", "CDS", 'gene_id "G2"; transcript_id "A";')
    + row("chr1", "exon", 'gene_id "G2"; transcript_id "B";')
    + row("MT", "gene", 'gene_id "ND1"; gene_name "ND1";')
    + row("MT", "CDS", 'gene_id "ND1"; transcript_id "ND1-t";')
    + row("MT", "gene", 'gene_id "COX1"; gene_name "COX1";')
    + row("MT", "exon", 'gene_id "COX1"; transcript_id "COX1-t";')
    + row("chrZ", "gene", 'gene_id "GZ"; gene_name "MT-FAKE";')
    + row("chrZ", "exon", 'gene_id "GZ"; transcript_id "TZ";')
    + row("MT", "exon", 'gene_id ""; transcript_id "TT1";')
    + row("MT", "exon", 'gene_id ""; transcript_id "TT2";')
    + row("chr1", "exon", 'transcript_id "TX";')
)
GTF_NO_Z = "".join(line for line in GTF.splitlines(True) if not line.startswith("chrZ"))


class RefcheckTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def write(self, name, text, gz=False):
        path = self.dir / name
        path.write_bytes(gzip.compress(text.encode()) if gz else text.encode())
        return path

    def facts(self, fasta=None, gtf=None, **kw):
        fasta = fasta or self.write("g.fa", FASTA)
        gtf = gtf or self.write("g.gtf", GTF)
        return dict(refcheck.check(str(fasta), str(gtf), **kw))

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = refcheck.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_counts_on_a_small_set(self):
        f = self.facts()
        self.assertEqual(f["fasta_sequences"], "3")
        self.assertEqual(f["fasta_bases"], "28")
        self.assertEqual(f["gtf_lines"], "14")
        self.assertEqual(f["gtf_sequence_names"], "3")
        self.assertEqual(f["gtf_names_missing_from_fasta"], "1")
        self.assertEqual(f["gtf_missing_names"], "chrZ")
        self.assertEqual(f["genes"], "5")
        self.assertEqual(f["gtf_gene_lines"], "4")
        # ND1 has a CDS and no exon. G2 has a CDS in one transcript and an exon in another.
        self.assertEqual(f["genes_with_cds_no_exon"], "1")
        self.assertEqual(f["genes_with_cds_no_exon_on_mito"], "1")
        self.assertEqual(f["genes_with_cds_no_exon_contigs"], "MT:1")
        self.assertEqual(f["genes_with_cds_no_exon_ids"], "ND1")
        self.assertEqual(f["empty_gene_id_features"], "3")
        self.assertEqual(f["empty_gene_id_by_type"], "exon:3")
        self.assertEqual(f["empty_gene_id_on"], "MT:2,chr1:1")

    def test_mitochondrial_genes_come_from_the_contig_never_the_prefix(self):
        f = self.facts()
        self.assertEqual(f["mito_contig"], "MT")
        self.assertEqual(f["mito_contig_source"], "contig name")
        self.assertEqual(f["mito_genes"], "2")  # ND1 and COX1 carry no MT- prefix
        self.assertEqual(f["mito_genes_with_MT_prefix"], "0")
        self.assertEqual(f["genes_with_MT_prefix"], "1")  # GZ sits on chrZ, not on the mitochondrion

    def test_assembly_report_names_the_mitochondrial_contig(self):
        fasta = self.write("g.fa", ">chr1\nACGT\n>X999 odd name\nACGT\n")
        gtf = self.write("g.gtf", row("X999", "gene", 'gene_id "A";') + row("chr1", "gene", 'gene_id "B";'))
        report = self.write(
            "g_assembly_report.txt",
            "# Sequence-Name\tSequence-Role\tAssigned-Molecule\tAssigned-Molecule-Location/Type\tGenBank-Accn\tRelationship\tRefSeq-Accn\n"
            "chr1\tassembled-molecule\t1\tChromosome\tCP1.1\t=\tNC_1.1\n"
            "MT\tassembled-molecule\tMT\tMitochondrion\tCP2.1\t=\tX999\n",
        )
        f = self.facts(fasta=fasta, gtf=gtf, assembly_report=str(report))
        self.assertEqual((f["mito_contig"], f["mito_contig_source"], f["mito_genes"]), ("X999", "assembly report", "1"))

    def test_fasta_header_naming_a_mitochondrion(self):
        fasta = self.write("g.fa", ">chr1\nACGT\n>NC_9.1 Macaca mitochondrion, complete genome\nACGT\n")
        gtf = self.write("g.gtf", row("NC_9.1", "gene", 'gene_id "A";'))
        f = self.facts(fasta=fasta, gtf=gtf)
        self.assertEqual((f["mito_contig"], f["mito_contig_source"], f["mito_genes"]), ("NC_9.1", "FASTA header", "1"))

    def test_an_assembly_without_a_mitochondrial_contig(self):
        fasta = self.write("g.fa", ">chr1\nACGT\n")
        gtf = self.write("g.gtf", row("chr1", "gene", 'gene_id "A"; gene_name "MT-LOOKALIKE";'))
        f = self.facts(fasta=fasta, gtf=gtf)
        self.assertEqual((f["mito_contig"], f["mito_contig_source"], f["mito_genes"]), ("-", "none", "0"))

    def test_an_explicit_mitochondrial_contig_wins(self):
        f = self.facts(mito_contig="chr1")
        self.assertEqual((f["mito_contig"], f["mito_contig_source"], f["mito_genes"]), ("chr1", "argument", "2"))

    def test_gzip_members_and_tiny_chunks_give_the_same_facts_and_the_stored_hash(self):
        plain = self.facts()
        half = len(FASTA) // 2
        packed = gzip.compress(FASTA[:half].encode()) + gzip.compress(FASTA[half:].encode())
        fasta = self.dir / "two_members.fa.gz"
        fasta.write_bytes(packed)
        gtf = self.write("g.gtf.gz", GTF, gz=True)
        for size in (1, 7, 64):
            f = self.facts(fasta=fasta, gtf=gtf, chunk_size=size)
            for key in ("fasta_sequences", "fasta_bases", "gtf_lines", "genes", "genes_with_cds_no_exon", "empty_gene_id_features", "mito_genes"):
                self.assertEqual(f[key], plain[key], (size, key))
            self.assertEqual(f["fasta_sha256"], hashlib.sha256(packed).hexdigest())
            self.assertEqual(f["gtf_sha256"], hashlib.sha256(gtf.read_bytes()).hexdigest())

    def test_the_comment_lines_before_the_first_feature_name_the_build(self):
        gtf = self.write("g.gtf", "##provider: TEST\n#!genome-build Foo_1\n" + GTF + "# late comment\n")
        f = self.facts(gtf=gtf)
        self.assertEqual(f["gtf_header"], "provider: TEST | genome-build Foo_1")
        self.assertEqual(self.facts()["gtf_header"], "-")

    def test_a_fasta_without_a_final_newline(self):
        f = self.facts(fasta=self.write("g.fa", ">chr1\nACGT\nAC"))
        self.assertEqual((f["fasta_sequences"], f["fasta_bases"]), ("1", "6"))

    def test_a_truncated_gzip_is_refused(self):
        packed = gzip.compress(FASTA.encode())
        fasta = self.dir / "cut.fa.gz"
        fasta.write_bytes(packed[:-12])
        with self.assertRaises(refcheck.RefcheckError):
            refcheck.check(str(fasta), str(self.write("g.gtf", GTF)))

    def test_exit_status_is_one_while_a_name_is_missing_and_the_names_are_listed(self):
        fasta, gtf = self.write("g.fa", FASTA), self.write("g.gtf", GTF)
        code, out, _ = self.run_main("--fasta", str(fasta), "--gtf", str(gtf))
        self.assertEqual(code, 1)
        self.assertIn("gtf_names_missing_from_fasta\t1\n", out)
        self.assertIn("gtf_missing_names\tchrZ\n", out)
        self.assertTrue(out.startswith("key\tvalue\n"))

    def test_expect_rows_decide_the_exit_status(self):
        fasta, gtf = self.write("g.fa", FASTA), self.write("ok.gtf", GTF_NO_Z)
        args = ["--fasta", str(fasta), "--gtf", str(gtf)]
        code, out, _ = self.run_main(*args, "--expect", "genes_with_cds_no_exon=1", "--expect", "mito_genes=2")
        self.assertEqual(code, 0, out)
        self.assertTrue(out.endswith("result\tpass\n"))
        code, out, err = self.run_main(*args, "--expect", "mito_genes=13")
        self.assertEqual(code, 1)
        self.assertIn("mito_genes expected 13 got 2", err)
        self.assertTrue(out.endswith("result\tFAIL\n"))

    def test_folder_form_finds_the_files_and_refuses_two_fasta_files(self):
        folder = self.dir / "set"
        folder.mkdir()
        (folder / "x_genomic.fna.gz").write_bytes(gzip.compress(FASTA.encode()))
        (folder / "x_genomic.gtf.gz").write_bytes(gzip.compress(GTF_NO_Z.encode()))
        (folder / "x_cdna.fa.gz").write_bytes(gzip.compress(b">t\nAC\n"))
        (folder / "README").write_text("not data")
        code, out, _ = self.run_main(str(folder))
        self.assertEqual(code, 0, out)
        self.assertIn("x_genomic.fna.gz", out)
        (folder / "y.fa").write_text(FASTA)
        code, _, err = self.run_main(str(folder))
        self.assertEqual(code, 2)
        self.assertIn("--fasta", err)


if __name__ == "__main__":
    unittest.main()
