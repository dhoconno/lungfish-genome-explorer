"""Tests for scripts/repro/rnaseq/stage/stage.py and stage_ena.py.

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_repro_stage.py' -v

Every test works in a temporary folder with local file:// urls, so nothing touches the network or the real
staging root. One test serves a file over a local HTTP server to exercise aria2c when it is installed.
"""
import contextlib
import functools
import hashlib
import http.server
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

STAGE_DIR = Path(__file__).resolve().parents[1] / "repro" / "rnaseq" / "stage"


def load(name):
    spec = importlib.util.spec_from_file_location(name, STAGE_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


stage = load("stage")
stage_ena = load("stage_ena")


def sample(seed, size):
    """Deterministic bytes that are not repetitive."""
    out = bytearray()
    block = hashlib.sha256(seed.encode()).digest()
    while len(out) < size:
        out += block
        block = hashlib.sha256(block).digest()
    return bytes(out[:size])


def bsd_sum(data):
    value = 0
    for byte in data:
        value = (value >> 1) | ((value & 1) << 15)
        value = (value + byte) & 0xFFFF
    return value


class StageCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test_repro_stage_"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.root = self.tmp / "root"
        self.root.mkdir()
        self.src = self.tmp / "src"
        self.src.mkdir()

    def make_source(self, name, data):
        path = self.src / name
        path.write_bytes(data)
        return path.as_uri()

    def run_stage(self, lines, *flags):
        manifest = self.tmp / "manifest.tsv"
        manifest.write_text("\n".join(lines) + "\n")
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = stage.main([str(manifest), "--root", str(self.root), "--min-free-bytes", "1",
                               "--staged-by", "TEST", *flags])
        return code, out.getvalue() + err.getvalue()

    def ledger_rows(self):
        path = self.root / "MANIFEST.tsv"
        if not path.exists():
            return []
        return [line.split("\t") for line in path.read_text().splitlines()]

    def files_under_root(self):
        return sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*"))


class StageDownloadTests(StageCase):
    def test_stages_a_file_url_and_verifies_md5(self):
        data = sample("a", 1_500_000)
        url = self.make_source("reads.fastq.gz", data)
        md5 = hashlib.md5(data).hexdigest()
        code, output = self.run_stage([f"{url}\tstudies/S1/raw/reads.fastq.gz\tmd5\t{md5}\t{len(data)}"])
        self.assertEqual(code, 0, output)
        dest = self.root / "studies/S1/raw/reads.fastq.gz"
        self.assertEqual(dest.read_bytes(), data)
        sha = hashlib.sha256(data).hexdigest()
        self.assertEqual((self.root / "studies/S1/raw/reads.fastq.gz.sha256").read_text(), f"{sha}  reads.fastq.gz\n")
        rows = self.ledger_rows()
        self.assertEqual(rows[0], list(stage.LEDGER_COLUMNS))
        self.assertEqual(len(rows), 2)
        path, row_url, size, ctype, csum, verified, when, who = rows[1]
        self.assertEqual((path, row_url, size, ctype, csum, verified, who),
                         (str(self.root / "studies/S1/raw/reads.fastq.gz"), url, str(len(data)), "sha256", sha,
                          "yes", "TEST"))
        self.assertRegex(when, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertFalse((self.root / "studies/S1/raw/reads.fastq.gz.part").exists())

    def test_sha256_expected_value(self):
        data = sample("b", 70_000)
        url = self.make_source("x.bin", data)
        code, _ = self.run_stage([f"{url}\ttenx/d/x.bin\tsha256\t{hashlib.sha256(data).hexdigest()}\t"])
        self.assertEqual(code, 0)
        self.assertEqual(self.ledger_rows()[1][5], "yes")

    def test_blank_checksum_stages_but_is_not_verified(self):
        data = sample("c", 5_000)
        url = self.make_source("c.txt", data)
        code, _ = self.run_stage([f"{url}\ttenx/d/c.txt\t\t\t"])
        self.assertEqual(code, 0)
        self.assertEqual(self.ledger_rows()[1][5], "no")

    def test_checksum_mismatch_retries_twice_then_fails(self):
        data = sample("d", 20_000)
        url = self.make_source("d.bin", data)
        code, output = self.run_stage([f"{url}\tstudies/S2/raw/d.bin\tmd5\t{'0' * 32}\t{len(data)}"])
        self.assertEqual(code, 1)
        self.assertIn("attempt 3 of 3", output)
        self.assertNotIn("attempt 4", output)
        self.assertEqual(self.files_under_root(), ["studies", "studies/S2", "studies/S2/raw"])
        self.assertEqual(self.ledger_rows(), [])

    def test_wrong_size_fails(self):
        data = sample("e", 20_000)
        url = self.make_source("e.bin", data)
        code, output = self.run_stage([f"{url}\ttenx/d/e.bin\t\t\t{len(data) + 1}"])
        self.assertEqual(code, 1)
        self.assertIn("does not match the expected", output)
        self.assertFalse((self.root / "tenx/d/e.bin").exists())

    def test_a_flaky_first_try_is_retried_and_succeeds(self):
        data = sample("f", 30_000)
        url = self.make_source("f.bin", data)
        real = stage.download
        calls = []

        def flaky(entry, part, use_aria2):
            calls.append(1)
            ok, tool, note = real(entry, part, use_aria2)
            if len(calls) == 1:
                part.write_bytes(data[:-1] + b"X")
            return ok, tool, note

        with mock.patch.object(stage, "download", flaky):
            code, output = self.run_stage([f"{url}\ttenx/d/f.bin\tmd5\t{hashlib.md5(data).hexdigest()}\t{len(data)}"])
        self.assertEqual(code, 0, output)
        self.assertEqual(len(calls), 2)
        self.assertIn("attempt 2 of 3", output)
        self.assertEqual((self.root / "tenx/d/f.bin").read_bytes(), data)
        self.assertEqual(len(self.ledger_rows()), 2)

    def test_several_files_with_parallel_jobs(self):
        lines = []
        for index in range(5):
            data = sample(f"p{index}", 10_000 + index)
            url = self.make_source(f"p{index}.bin", data)
            lines.append(f"{url}\ttenx/many/p{index}.bin\tmd5\t{hashlib.md5(data).hexdigest()}\t{len(data)}")
        code, output = self.run_stage(lines, "--jobs", "3")
        self.assertEqual(code, 0, output)
        rows = self.ledger_rows()
        self.assertEqual(len(rows), 6)
        self.assertEqual(sum(1 for r in rows if r[0] == "path"), 1)
        self.assertEqual({r[5] for r in rows[1:]}, {"yes"})

    def test_rerun_does_not_download_or_duplicate(self):
        data = sample("g", 12_000)
        url = self.make_source("g.bin", data)
        line = f"{url}\ttenx/d/g.bin\tmd5\t{hashlib.md5(data).hexdigest()}\t{len(data)}"
        self.assertEqual(self.run_stage([line])[0], 0)
        code, output = self.run_stage([line])
        self.assertEqual(code, 0)
        self.assertIn("present", output)
        self.assertNotIn("attempt 1", output)
        self.assertEqual(len(self.ledger_rows()), 2)

    def test_existing_file_without_sidecar_is_adopted(self):
        data = sample("h", 9_000)
        url = self.make_source("h.bin", data)
        dest = self.root / "tenx/d/h.bin"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(data)
        code, output = self.run_stage([f"{url}\ttenx/d/h.bin\tmd5\t{hashlib.md5(data).hexdigest()}\t{len(data)}"])
        self.assertEqual(code, 0, output)
        self.assertIn("adopted", output)
        self.assertTrue((self.root / "tenx/d/h.bin.sha256").exists())
        self.assertEqual(self.ledger_rows()[1][5], "yes")

    def test_existing_file_of_the_wrong_size_is_refused_without_force(self):
        data = sample("i", 9_000)
        url = self.make_source("i.bin", data)
        dest = self.root / "tenx/d/i.bin"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(b"short")
        line = f"{url}\ttenx/d/i.bin\t\t\t{len(data)}"
        code, output = self.run_stage([line])
        self.assertEqual(code, 1)
        self.assertIn("--force", output)
        self.assertEqual(dest.read_bytes(), b"short")
        self.assertEqual(self.run_stage([line], "--force")[0], 0)
        self.assertEqual(dest.read_bytes(), data)

    def test_a_file_that_another_process_is_staging_is_skipped(self):
        import fcntl
        data = sample("busy", 8_000)
        url = self.make_source("busy.bin", data)
        dest = self.root / "tenx/d/busy.bin"
        dest.parent.mkdir(parents=True)
        other = open(dest.with_name("busy.bin.lock"), "w")
        self.addCleanup(other.close)
        fcntl.flock(other, fcntl.LOCK_EX)
        code, output = self.run_stage([f"{url}\ttenx/d/busy.bin\t\t\t"])
        self.assertEqual(code, 0, output)
        self.assertIn("another process", output)
        self.assertFalse(dest.exists())
        self.assertEqual(self.ledger_rows(), [])
        self.assertTrue(dest.with_name("busy.bin.lock").exists())
        fcntl.flock(other, fcntl.LOCK_UN)
        self.assertEqual(self.run_stage([f"{url}\ttenx/d/busy.bin\t\t\t"])[0], 0)
        self.assertTrue(dest.exists())
        self.assertFalse(dest.with_name("busy.bin.lock").exists())

    def test_a_dest_outside_the_root_is_refused(self):
        url = self.make_source("j.bin", b"j" * 100)
        code, output = self.run_stage([f"{url}\t../escape/j.bin\t\t\t"])
        self.assertEqual(code, 2)
        self.assertIn("outside the staging root", output)
        self.assertFalse((self.tmp / "escape").exists())

    def test_manifest_refuses_unknown_checksum_type_and_repeated_dest(self):
        url = self.make_source("k.bin", b"k" * 100)
        self.assertEqual(self.run_stage([f"{url}\ttenx/d/k.bin\tcrc32\t1234\t"])[0], 2)
        self.assertEqual(self.run_stage([f"{url}\ttenx/d/k.bin\t\t\t", f"{url}\ttenx/d/k.bin\t\t\t"])[0], 2)

    def test_header_comments_and_blank_lines_are_skipped(self):
        data = sample("l", 4_000)
        url = self.make_source("l.bin", data)
        code, _ = self.run_stage(["# a comment", "url\tdest_path\tchecksum_type\tchecksum\tbytes", "",
                                  f"{url}\ttenx/d/l.bin\t\t\t{len(data)}"])
        self.assertEqual(code, 0)

    def test_a_missing_root_is_refused(self):
        manifest = self.tmp / "m.tsv"
        manifest.write_text("file:///nonexistent\ttenx/x\t\t\t\n")
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = stage.main([str(manifest), "--root", str(self.tmp / "no-such-drive")])
        self.assertEqual(code, 2)
        self.assertIn("is the drive mounted", err.getvalue())


class StageGuardTests(StageCase):
    def line(self, name="m.bin", size=50_000):
        data = sample(name, size)
        return f"{self.make_source(name, data)}\ttenx/d/{name}\tmd5\t{hashlib.md5(data).hexdigest()}\t{len(data)}"

    def test_dry_run_changes_nothing(self):
        code, output = self.run_stage([self.line()], "--dry-run")
        self.assertEqual(code, 0, output)
        self.assertIn("dry run", output)
        self.assertEqual(self.files_under_root(), [])

    def test_the_defaults_are_one_terabyte_and_five_hundred_gigabytes(self):
        self.assertEqual(stage.DEFAULT_CAP_BYTES, 10 ** 12)
        self.assertEqual(stage.DEFAULT_MIN_FREE_BYTES, 5 * 10 ** 11)
        self.assertEqual(stage.DEFAULT_ROOT, "/Volumes/lge_scratch/lge/rnaseq")

    def test_the_cap_counts_the_folder_plus_the_new_bytes(self):
        (self.root / "old").write_bytes(b"x" * 1000)
        line = self.line(size=50_000)
        code, output = self.run_stage([line], "--cap-bytes", "50500")
        self.assertEqual(code, 2)
        self.assertIn("REFUSED", output)
        self.assertEqual(self.files_under_root(), ["old"])
        self.assertEqual(self.run_stage([line], "--cap-bytes", "51000")[0], 0)

    def test_the_free_space_floor_refuses(self):
        manifest = self.tmp / "floor.tsv"
        manifest.write_text(self.line() + "\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = stage.main([str(manifest), "--root", str(self.root), "--min-free-bytes", str(10 ** 18)])
        self.assertEqual(code, 2)
        self.assertIn("under the floor", out.getvalue())
        self.assertEqual(self.files_under_root(), [])

    def test_budget_problems_helper(self):
        self.assertEqual(stage.budget_problems(10, 5, 1000, 100, 10), [])
        self.assertEqual(len(stage.budget_problems(98, 5, 1000, 100, 10)), 1)
        self.assertEqual(len(stage.budget_problems(0, 5, 14, 100, 10)), 1)
        self.assertEqual(len(stage.budget_problems(98, 5, 14, 100, 10)), 2)

    def test_folder_usage_counts_files_and_skips_links(self):
        (self.root / "a").mkdir()
        (self.root / "a/one").write_bytes(b"1" * 300)
        (self.root / "two").write_bytes(b"2" * 200)
        os.symlink(self.root / "two", self.root / "link")
        self.assertEqual(stage.folder_usage(self.root), 500)


class StageLedgerAndLinkTests(StageCase):
    def test_other_agents_rows_stay_and_the_header_is_written_once(self):
        ledger = self.root / "MANIFEST.tsv"
        ledger.write_text("\t".join(stage.LEDGER_COLUMNS) + "\nstudies/X/raw/a.fq.gz\tu\t1\tsha256\tab\tyes\tt\tR1\n")
        data = sample("n", 8_000)
        url = self.make_source("n.bin", data)
        self.assertEqual(self.run_stage([f"{url}\ttenx/d/n.bin\t\t\t"])[0], 0)
        rows = self.ledger_rows()
        self.assertEqual([r[0] for r in rows], ["path", "studies/X/raw/a.fq.gz", str(self.root / "tenx/d/n.bin")])

    def test_prune_ledger_drops_rows_of_missing_files(self):
        (self.root / "keep.bin").write_bytes(b"k")
        ledger = self.root / "MANIFEST.tsv"
        keep_absolute = str(self.root / "keep.bin")
        ledger.write_text("\t".join(stage.LEDGER_COLUMNS) + f"\n{keep_absolute}\tu\t1\tsha256\tab\tyes\tt\tR1\n"
                          "gone.bin\tu\t1\tsha256\tcd\tyes\tt\tR1\n")
        self.assertEqual(stage.prune_ledger(ledger, self.root), 1)
        self.assertEqual([r[0] for r in self.ledger_rows()], ["path", keep_absolute])

    def test_identical_files_become_one_copy_and_a_relative_link(self):
        data = sample("same", 1_300_000)
        first = self.make_source("one.fa.gz", data)
        second = self.make_source("two.fa.gz", data)
        other = sample("other", 1_300_000)
        third = self.make_source("three.fa.gz", other)
        code, output = self.run_stage([f"{first}\trefs/human/ensembl-93/g.fa.gz\t\t\t",
                                       f"{second}\trefs/human/ensembl-98/g.fa.gz\t\t\t",
                                       f"{third}\trefs/human/gencode-49/g.fa.gz\t\t\t"], "--link-duplicates")
        self.assertEqual(code, 0, output)
        regular = [p for p in (self.root / "refs/human").glob("*/g.fa.gz") if not p.is_symlink()]
        links = [p for p in (self.root / "refs/human").glob("*/g.fa.gz") if p.is_symlink()]
        self.assertEqual(len(regular), 2)
        self.assertEqual(len(links), 1)
        self.assertFalse(os.path.isabs(os.readlink(links[0])))
        self.assertEqual(links[0].read_bytes(), data)
        self.assertEqual(len(self.ledger_rows()), 4)
        again, _ = self.run_stage([f"{first}\trefs/human/ensembl-93/g.fa.gz\t\t\t",
                                   f"{second}\trefs/human/ensembl-98/g.fa.gz\t\t\t"])
        self.assertEqual(again, 0)
        self.assertEqual(len(links[0].read_bytes()), 1_300_000)


class VerifierTests(StageCase):
    def test_s3_etag_single_part_and_multipart(self):
        data = sample("etag", 12 * stage.MIB + 123)
        single = hashlib.md5(data).hexdigest()
        tracker = stage.EtagTracker(f'"{single}"', len(data))
        tracker.update(data)
        self.assertEqual(tracker.verdict(), "match")
        parts = [data[i:i + 8 * stage.MIB] for i in range(0, len(data), 8 * stage.MIB)]
        multi = hashlib.md5(b"".join(hashlib.md5(p).digest() for p in parts)).hexdigest() + f"-{len(parts)}"
        tracker = stage.EtagTracker(multi, len(data))
        for start in range(0, len(data), stage.MIB):
            tracker.update(data[start:start + stage.MIB])
        self.assertEqual(tracker.verdict(), "match")
        bad = stage.EtagTracker(multi, len(data))
        bad.update(data[:-1] + b"\x00")
        self.assertEqual(bad.verdict(), "mismatch")
        odd = stage.EtagTracker(single + "-999", len(data))
        odd.update(data)
        self.assertEqual(odd.verdict(), "unverifiable")

    def test_stage_verifies_a_multipart_etag_from_the_manifest(self):
        data = sample("etag2", 9 * stage.MIB)
        parts = [data[i:i + 8 * stage.MIB] for i in range(0, len(data), 8 * stage.MIB)]
        etag = hashlib.md5(b"".join(hashlib.md5(p).digest() for p in parts)).hexdigest() + f"-{len(parts)}"
        url = self.make_source("big.tar", data)
        code, output = self.run_stage([f"{url}\ttenx/d/big.tar\ts3etag\t{etag}\t{len(data)}"])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.ledger_rows()[1][5], "yes")

    @unittest.skipUnless(shutil.which("sum"), "the sum tool is not installed")
    def test_bsd_sum_from_an_ensembl_checksums_file(self):
        data = sample("bsd", 70_000)
        url = self.make_source("bsd.gz", data)
        value = f"{bsd_sum(data)} {(len(data) + 1023) // 1024}"
        code, output = self.run_stage([f"{url}\ttenx/d/bsd.gz\tbsdsum\t{value}\t{len(data)}"])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.ledger_rows()[1][5], "yes")
        wrong = f"{(bsd_sum(data) + 1) & 0xFFFF} 69"
        code, _ = self.run_stage([f"{url}\ttenx/d/bsd2.gz\tbsdsum\t{wrong}\t{len(data)}"])
        self.assertEqual(code, 1)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def end_headers(self):
        path = Path(self.directory) / self.path.lstrip("/")
        if path.is_file():
            self.send_header("ETag", '"' + hashlib.md5(path.read_bytes()).hexdigest() + '"')
        super().end_headers()


@unittest.skipUnless(shutil.which("aria2c"), "aria2c is not installed")
class AriaOverHttpTests(StageCase):
    def serve(self):
        handler = functools.partial(QuietHandler, directory=str(self.src))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def test_aria2c_downloads_over_http_and_etag_fills_the_checksum(self):
        data = sample("http", 3 * stage.MIB + 17)
        (self.src / "h.tar").write_bytes(data)
        base = self.serve()
        code, output = self.run_stage([f"{base}/h.tar\ttenx/h/h.tar\t\t\t"], "--etag")
        self.assertEqual(code, 0, output)
        self.assertIn("with aria2c", output)
        self.assertIn("verified by s3etag", output)
        self.assertEqual((self.root / "tenx/h/h.tar").read_bytes(), data)
        self.assertEqual(self.ledger_rows()[1][5], "yes")
        self.assertFalse(list((self.root / "tenx/h").glob("*.aria2")))


class StageEnaTests(unittest.TestCase):
    REPORT = (
        "run_accession\tfastq_ftp\tfastq_md5\tfastq_bytes\tsubmitted_ftp\tsubmitted_md5\tsubmitted_bytes\n"
        "SRR1\tftp.sra.ebi.ac.uk/vol1/fastq/SRR001/SRR1/SRR1_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/SRR001/SRR1/SRR1_2.fastq.gz"
        "\tAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t100;200"
        "\tftp.sra.ebi.ac.uk/vol1/run/SRR1/s_R1.fastq.gz\tcccccccccccccccccccccccccccccccc\t300\n"
        "SRR2\tftp.sra.ebi.ac.uk/vol1/fastq/SRR002/SRR2/SRR2.fastq.gz\tdddddddddddddddddddddddddddddddd\t50\t\t\t\n"
        "SRR3\t\t\t\t\t\t\n"
    )

    def test_rows_use_https_md5_and_the_study_raw_folder(self):
        rows, skipped = stage_ena.manifest_rows(self.REPORT, "GSE9", "fastq", None)
        self.assertEqual(skipped, ["SRR3"])
        self.assertEqual(rows[0], ["https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR001/SRR1/SRR1_1.fastq.gz",
                                   "studies/GSE9/raw/SRR1_1.fastq.gz", "md5", "a" * 32, "100"])
        self.assertEqual([r[1] for r in rows],
                         ["studies/GSE9/raw/SRR1_1.fastq.gz", "studies/GSE9/raw/SRR1_2.fastq.gz",
                          "studies/GSE9/raw/SRR2.fastq.gz"])

    def test_submitted_files_and_run_filter(self):
        rows, skipped = stage_ena.manifest_rows(self.REPORT, "GSE9", "submitted", {"SRR1"})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][1], "studies/GSE9/raw/s_R1.fastq.gz")
        self.assertEqual(rows[0][4], "300")
        self.assertEqual(skipped, [])

    def test_disagreeing_lists_are_an_error(self):
        bad = ("run_accession\tfastq_ftp\tfastq_md5\tfastq_bytes\n"
               "SRR1\ta.org/x_1.fastq.gz;a.org/x_2.fastq.gz\tabc\t1;2\n")
        with self.assertRaises(SystemExit):
            stage_ena.manifest_rows(bad, "S", "fastq", None)

    def test_main_writes_the_manifest_under_studies_raw_and_stage_reads_it(self):
        tmp = Path(tempfile.mkdtemp(prefix="test_stage_ena_"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        report = tmp / "filereport.tsv"
        report.write_text(self.REPORT)
        with contextlib.redirect_stderr(io.StringIO()):
            code = stage_ena.main([str(report), "--study", "GSE9", "--root", str(tmp)])
        self.assertEqual(code, 0)
        manifest = tmp / "studies/GSE9/raw/manifest.tsv"
        self.assertTrue(manifest.exists())
        entries = stage.parse_manifest(manifest, tmp)
        self.assertEqual(len(entries), 3)
        self.assertEqual({e.ctype for e in entries}, {"md5"})
        self.assertEqual(entries[0].nbytes, 100)
        self.assertEqual(entries[0].rel, "studies/GSE9/raw/SRR1_1.fastq.gz")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(stage_ena.main([str(report), "--study", "GSE9", "--root", str(tmp), "--out", "-",
                                             "--max-bytes", "10"]), 2)


if __name__ == "__main__":
    unittest.main()
