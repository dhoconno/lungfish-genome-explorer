"""Tests of scripts/golden/scale_corpus.py on the tiny scale (lane SCALE-SMOKE).

ScaleCorpusTests builds with no BAM, so it needs no tool. ScaleCorpusConformanceTests builds the BAM with samtools.
"""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts.golden import scale_corpus as sc

ROOT = Path(__file__).resolve().parents[2]
PICK = sc.ARCHIVE_PICKS[0]


def fasta_lengths(path):
    lengths, current = [], 0
    for line in Path(path).read_text().splitlines():
        if line.startswith(">"):
            lengths.append(current)
            current = 0
        else:
            current += len(line)
    return lengths[1:] + [current]


class ScaleCorpusTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="scale-corpus-test-"))
        self.addCleanup(shutil.rmtree, self.folder, True)

    def make_archives(self):
        archives = self.folder / "archives"
        archives.mkdir()
        with zipfile.ZipFile(archives / PICK[2], "w") as bundle:
            bundle.writestr(PICK[3] + "/manifest.json", "{}")
            bundle.writestr(PICK[3] + "/genome/sequence.fa", ">a\nACGT\n")
        return archives

    def build(self, name="out", archives=None):
        return sc.build(self.folder / name, sc.TINY, archives, with_bam=False)

    def test_the_lists_hold_the_counts_and_the_one_long_record(self):
        corpus = self.build()
        project = self.folder / "out" / sc.PROJECT
        small = fasta_lengths(project / "scale-fasta-small.fasta")
        self.assertEqual(len(small), sc.TINY.small_records)
        self.assertEqual(small.count(sc.TINY.long_record_bases), 1)
        self.assertEqual(small.index(sc.TINY.long_record_bases), sc.TINY.small_records // 2)
        large = fasta_lengths(project / "scale-fasta-large.fasta")
        self.assertEqual(len(large), sc.TINY.large_records)
        self.assertLess(max(large), 1500)
        self.assertEqual({item["id"] for item in corpus["items"]}, {"fasta-small", "fasta-large", "fastq", "contigs"})

    def test_the_fastq_sidecar_matches_the_reads(self):
        self.build()
        bundle = self.folder / "out" / sc.PROJECT / "Scale FASTQ.lungfishfastq"
        lines = (bundle / "reads.fastq").read_text().splitlines()
        self.assertEqual(len(lines), 4 * sc.TINY.fastq_reads)
        stats = json.loads((bundle / "reads.fastq.lungfish-meta.json").read_text())["computedStatistics"]
        self.assertEqual(stats["readCount"], sc.TINY.fastq_reads)
        self.assertEqual(stats["baseCount"], sum(len(line) for line in lines[1::4]))
        self.assertEqual(sum(stats["readLengthHistogram"].values()), sc.TINY.fastq_reads)

    def test_the_contig_bundle_index_points_at_the_bases(self):
        self.build()
        bundle = self.folder / "out" / sc.PROJECT / "Scale Contigs.lungfishref"
        manifest = json.loads((bundle / "manifest.json").read_text())
        rows = [line.split("\t") for line in (bundle / "genome/sequence.fa.fai").read_text().splitlines()]
        self.assertEqual(len(rows), sc.TINY.contigs)
        self.assertEqual(len(manifest["genome"]["chromosomes"]), sc.TINY.contigs)
        data = (bundle / "genome/sequence.fa").read_bytes()
        for name, length, offset, *_ in (rows[0], rows[len(rows) // 2], rows[-1]):
            length, offset = int(length), int(offset)
            self.assertEqual(data[offset - len(name) - 2:offset], (">" + name + "\n").encode())
            bases = data[offset:offset + length + -(-length // 80) - 1].replace(b"\n", b"").decode()
            self.assertEqual(len(bases), length)
            self.assertRegex(bases, "^[ACGT]+$")

    def test_one_seed_gives_one_corpus_and_verify_sees_a_change(self):
        first, second = self.build("a"), self.build("b")
        self.assertEqual(first["corpusSha256"], second["corpusSha256"])
        self.assertEqual(sc.verify(self.folder / "a"), [])
        (self.folder / "a" / sc.PROJECT / "scale-fasta-small.fasta").write_text(">x\nA\n")
        self.assertTrue(sc.verify(self.folder / "a"))

    def test_an_archive_pick_comes_in_and_an_escaping_member_is_refused(self):
        corpus = self.build(archives=self.make_archives())
        self.assertIn("reference", {item["id"] for item in corpus["items"]})
        self.assertTrue((self.folder / "out" / sc.PROJECT / PICK[4] / "genome/sequence.fa").is_file())
        bad = self.folder / "bad.zip"
        with zipfile.ZipFile(bad, "w") as bundle:
            bundle.writestr("m/../../escape.txt", "x")
        with self.assertRaises(ValueError):
            sc.extract_pick(bad, "m", self.folder / "dest")

    def test_the_command_line_builds_lists_and_verifies(self):
        out = str(self.folder / "cli")
        none = str(self.folder / "none")
        self.assertEqual(sc.main(["build", "--scale", "tiny", "--no-bam", "--archives", none, "--out", out]), 0)
        self.assertEqual(sc.main(["list", "--out", out]), 0)
        self.assertEqual(sc.main(["verify", "--out", out]), 0)

    def test_every_view_switch_kind_is_covered_or_named_uncovered(self):
        corpus = self.build(archives=self.make_archives())
        covered = {item["kind"] for item in corpus["items"]}
        self.assertFalse(covered & set(corpus["uncovered"]))
        self.assertEqual(covered | set(corpus["uncovered"]), set(sc.KINDS))

    def test_the_kind_list_is_the_one_of_view_switch_kinds(self):
        source = (ROOT / "Tests/LungfishAppTests/SafetyNets/ViewSwitchKinds.swift").read_text()
        names = re.findall(r'kind\(\s*"([^"]+)"', source.split("static let all")[1].split("private static func")[0])
        self.assertEqual(names, sc.KINDS)


class ScaleCorpusConformanceTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("samtools"), "needs samtools")
    def test_the_bam_is_sorted_indexed_and_counted_in_the_manifest(self):
        folder = Path(tempfile.mkdtemp(prefix="scale-corpus-bam-"))
        self.addCleanup(shutil.rmtree, folder, True)
        sc.build(folder / "out", sc.TINY, None, "samtools", True)
        bundle = folder / "out" / sc.PROJECT / "Scale BAM.lungfishref"
        manifest = json.loads((bundle / "manifest.json").read_text())
        entry = manifest["alignments"][0]
        bam = bundle / entry["source_path"]
        self.assertTrue((bundle / entry["index_path"]).is_file())
        subprocess.run(["samtools", "quickcheck", str(bam)], check=True)
        header = subprocess.run(["samtools", "view", "-H", str(bam)], check=True, capture_output=True, text=True).stdout
        self.assertIn("SO:coordinate", header)
        count = subprocess.run(["samtools", "view", "-c", str(bam)], check=True, capture_output=True, text=True).stdout
        self.assertEqual(int(count), entry["mapped_read_count"])


if __name__ == "__main__":
    unittest.main()
