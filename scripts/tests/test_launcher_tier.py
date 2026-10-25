#!/usr/bin/env python3
"""Argument handling of scripts/linux/launcher-tier.sh (C5 lane LAUNCH M3).

The Docker run itself is a tier record, not a test. These tests run the script with a stand-in `docker` on PATH that
writes down each call and fails, and read the exit code, the messages, what the script printed and whether it called
Docker or wrote a record. The tests of `run` that go past its refusals put a stand-in run-local.sh in a batch folder and
swap the stand-in `docker` for one that accepts every call, then read the record the script writes.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "linux" / "launcher-tier.sh"
PINS = json.loads((ROOT / "Sources/LungfishWorkflow/Resources/CHTCImage/image.json").read_text())["sif"]

DEFFILE, PARTITION = 0x4001, 0x4004
SQUASHFS, EXT3 = 1, 2
SYSTEM, DATA = 2, 4

# The plan of the stand-in batch pins this executor. The refusal is the sentence that Sources/LungfishExecutor/RunCommand.swift
# (lines 215 and 216) writes when the running executor is not the pinned one.
PLAN_EXECUTOR = {"sha256": "aa", "size": 3}
REFUSAL = (
    "The running executor has SHA-256 aa and 3 bytes, and the plan's executor entry pins bb and 3 bytes. No tool ran."
)


def sif_bytes(descriptors: list[tuple[int, int, int, bool]]) -> bytes:
    """A SIF whose descriptors are (kind, file system, partition type, used), each object 1024 bytes after them."""
    count = len(descriptors)
    descriptor_offset, data_offset = 128, 128 + 585 * count
    head = b"#!/usr/bin/env run-singularity\n".ljust(32, b"\0") + b"SIF_MAGIC\0" + b"01\0" + b"\0\0\0" + b"\0" * 16
    head += struct.pack("<8q", 0, 0, 0, count, descriptor_offset, 585 * count, data_offset, 1024 * count)
    body = b""
    for index, (kind, fs_type, part_type, used) in enumerate(descriptors):
        raw = struct.pack("<i?IIIqqq", kind, used, index + 1, 0, 0, data_offset + 1024 * index, 1024, 1024)
        raw += struct.pack("<4q", 0, 0, 0, 0) + b"\0" * 128
        raw += struct.pack("<ii", fs_type, part_type) + b"\0" * 376
        body += raw
    return head + body + b"\x5a" * (1024 * count)


class LauncherTierArgumentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="launcher-tier-"))
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        self.calls = self.tmp / "docker-calls.txt"
        stand_in = bin_dir / "docker"
        stand_in.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$LAUNCHER_TIER_CALLS"\nexit 1\n')
        stand_in.chmod(0o755)
        path = os.pathsep.join([str(bin_dir), str(Path(sys.executable).parent), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        self.env = dict(os.environ, PATH=path, LAUNCHER_TIER_CALLS=str(self.calls))
        self.record = self.tmp / "tier" / "record.json"

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def run_tier(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args], env=self.env, cwd=self.tmp, capture_output=True, text=True, timeout=120
        )

    def assert_refused_before_docker(self, result: subprocess.CompletedProcess[str], code: int, words: str) -> None:
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertIn(words, result.stderr)
        self.assertFalse(self.calls.exists(), "the script called docker before it refused")
        self.assertFalse(self.record.exists(), "the script wrote a record before it refused")

    def write_sif(self, descriptors: list[tuple[int, int, int, bool]]) -> Path:
        path = self.tmp / "test.sif"
        path.write_bytes(sif_bytes(descriptors))
        return path

    def test_script_parses_and_is_executable(self) -> None:
        result = subprocess.run(["/bin/bash", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.access(SCRIPT, os.X_OK))

    def test_no_step_prints_the_usage_and_exits_64(self) -> None:
        result = self.run_tier()
        self.assert_refused_before_docker(result, 64, "Usage: bash scripts/linux/launcher-tier.sh image --sif <file>")
        self.assertIn("Every path is absolute.", result.stderr)

    def test_an_unknown_step_or_option_exits_64(self) -> None:
        self.assert_refused_before_docker(self.run_tier("build"), 64, "unknown step build.")
        self.assert_refused_before_docker(
            self.run_tier("image", "--sif", "/x.sif", "--record", str(self.record), "--privileged"), 64,
            "unknown argument --privileged.",
        )

    def test_an_option_without_its_value_exits_64(self) -> None:
        self.assert_refused_before_docker(self.run_tier("image", "--sif"), 64, "--sif needs a value.")

    def test_image_needs_a_record_and_absolute_paths(self) -> None:
        self.assert_refused_before_docker(self.run_tier("image", "--sif", "/x.sif"), 64, "image needs --record.")
        self.assert_refused_before_docker(
            self.run_tier("image", "--sif", "lge.sif", "--record", str(self.record)), 64,
            "--sif must be an absolute path, not lge.sif.",
        )

    def test_a_sif_of_another_size_is_refused_before_docker(self) -> None:
        sif = self.write_sif([(PARTITION, SQUASHFS, SYSTEM, True)])
        result = self.run_tier("image", "--sif", str(sif), "--record", str(self.record))
        self.assert_refused_before_docker(result, 2, f"not the {PINS['size']} that image.json pins for {PINS['fileName']}.")

    def test_a_sif_of_the_pinned_size_and_another_digest_is_refused_before_docker(self) -> None:
        sif = self.tmp / "zeros.sif"
        with open(sif, "wb") as handle:
            handle.truncate(PINS["size"])
        result = self.run_tier("image", "--sif", str(sif), "--record", str(self.record))
        self.assert_refused_before_docker(result, 2, f"not the {PINS['sha256']} that image.json pins")

    def test_partition_names_the_one_squashfs_system_partition(self) -> None:
        sif = self.write_sif([(DEFFILE, 0, 0, True), (PARTITION, EXT3, SYSTEM, True), (PARTITION, SQUASHFS, DATA, True),
                              (PARTITION, SQUASHFS, SYSTEM, False), (PARTITION, SQUASHFS, SYSTEM, True)])
        result = self.run_tier("partition", "--sif", str(sif))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [str(128 + 585 * 5 + 1024 * 4), "1024"])
        self.assertFalse(self.calls.exists())

    def test_partition_refuses_a_file_that_is_not_a_sif_or_holds_two_systems(self) -> None:
        other = self.tmp / "other.sif"
        other.write_bytes(b"\0" * 4096)
        self.assert_refused_before_docker(self.run_tier("partition", "--sif", str(other)), 2, "other.sif is not a SIF file.")
        two = self.write_sif([(PARTITION, SQUASHFS, SYSTEM, True), (PARTITION, SQUASHFS, SYSTEM, True)])
        self.assert_refused_before_docker(
            self.run_tier("partition", "--sif", str(two)), 2, "test.sif holds 2 squashfs system partitions, not one."
        )

    def test_run_needs_every_option_and_a_plain_label(self) -> None:
        base = ["run", "--batch", "/b", "--data", "/d", "--image", "lge-tools:eae819829358", "--record", str(self.record)]
        self.assert_refused_before_docker(self.run_tier(*base), 64, "run needs --label.")
        self.assert_refused_before_docker(
            self.run_tier(*base, "--label", "Probe 1"), 64, "--label takes lower-case letters, digits and hyphens, not Probe 1."
        )
        self.assert_refused_before_docker(
            self.run_tier("run", "--batch", "batch", "--data", "/d", "--image", "x", "--record", str(self.record), "--label", "probe"),
            64, "--batch must be an absolute path, not batch.",
        )

    def test_run_refuses_a_folder_without_the_launcher_before_docker(self) -> None:
        batch = self.tmp / "batch"
        batch.mkdir()
        result = self.run_tier(
            "run", "--batch", str(batch), "--data", str(self.tmp), "--image", "x", "--record", str(self.record), "--label", "probe"
        )
        self.assert_refused_before_docker(result, 2, f"The batch folder {batch} holds no run-local.sh.")

    def write_batch(self, launcher: str) -> Path:
        """A batch folder with the one sample `probe`. Its plan pins PLAN_EXECUTOR and `launcher` is the body of its
        run-local.sh, which runs from inside the batch folder. The data folder and the folder of self.record exist, and
        docker now answers every call with success, so `run` gets past `docker image inspect`."""
        batch = self.tmp / "batch"
        (batch / "probe").mkdir(parents=True)
        (self.tmp / "data").mkdir()
        self.record.parent.mkdir()
        (batch / "run-local.sh").write_text(launcher)
        (batch / "jobs.tsv").write_text("# sample\ttar\tsha256\nprobe\tprobe.tar\t0\n")
        (batch / "probe" / "plan.json").write_text(json.dumps({"entries": [{"role": "executor", **PLAN_EXECUTOR}]}))
        (self.tmp / "bin" / "docker").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$LAUNCHER_TIER_CALLS"\nexit 0\n')
        return batch

    def launcher_writing_a_record(self, sha256: str, exit_code: int = 0) -> str:
        """A run-local.sh body that leaves the record of a succeeded run holding the executor `sha256` and 3 bytes."""
        record = json.dumps({"outcome": "succeeded", "exitCode": 0, "executor": {"sha256": sha256, "size": 3}})
        return f"mkdir -p probe/result\nprintf '%s\\n' '{record}' > probe/result/run-record.json\nexit {exit_code}\n"

    def run_batch(self, batch: Path, record: Path | None = None) -> subprocess.CompletedProcess[str]:
        return self.run_tier(
            "run", "--batch", str(batch), "--data", str(self.tmp / "data"), "--image", "x",
            "--record", str(record or self.record), "--label", "probe",
        )

    def probe_row(self, record: Path | None = None) -> dict:
        return json.loads((record or self.record).read_text())["runs"]["probe"]

    def test_run_records_a_pass_when_the_launcher_and_the_self_check_agree(self) -> None:
        result = self.run_batch(self.write_batch(self.launcher_writing_a_record("aa")))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        row = self.probe_row()
        self.assertTrue(row["passed"])
        self.assertEqual(row["launcherExit"], 0)
        self.assertFalse(row["overSixtyMinutes"])
        sample = row["samples"][0]
        self.assertTrue(sample["selfCheckEqualsPlan"])
        self.assertIsNone(sample["refusal"])

    def test_run_records_no_pass_when_the_self_check_differs(self) -> None:
        result = self.run_batch(self.write_batch(self.launcher_writing_a_record("bb")))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        row = self.probe_row()
        self.assertFalse(row["passed"])
        self.assertEqual(row["launcherExit"], 0)
        self.assertFalse(row["samples"][0]["selfCheckEqualsPlan"])

    def test_run_records_no_pass_when_the_launcher_exits_non_zero_after_a_matching_record(self) -> None:
        result = self.run_batch(self.write_batch(self.launcher_writing_a_record("aa", exit_code=3)))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        row = self.probe_row()
        self.assertFalse(row["passed"])
        self.assertEqual(row["launcherExit"], 3)
        self.assertTrue(row["samples"][0]["selfCheckEqualsPlan"])

    def test_run_records_the_refusal_sentence_of_a_launcher_that_returned_no_record(self) -> None:
        launcher = f"mkdir -p logs\ncat > logs/probe.err <<'END'\nstarted\n  {REFUSAL}  \nEND\nexit 1\n"
        result = self.run_batch(self.write_batch(launcher))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        row = self.probe_row()
        sample = row["samples"][0]
        self.assertEqual(sample["runRecord"], "absent")
        self.assertEqual(sample["refusal"], REFUSAL)
        self.assertEqual(row["launcherExit"], 1)
        self.assertFalse(row["passed"])

    def test_run_refuses_a_sample_that_already_holds_a_result_before_docker(self) -> None:
        # run-local.sh skips a sample whose result/ exists and still exits 0, so a pass would describe an earlier run.
        batch = self.write_batch("touch ran\n")
        (batch / "probe" / "result").mkdir()
        (batch / "probe" / "result" / "run-record.json").write_text(
            json.dumps({"outcome": "succeeded", "exitCode": 0, "executor": PLAN_EXECUTOR})
        )
        result = self.run_batch(batch)
        self.assert_refused_before_docker(result, 2, "The sample probe already holds")
        self.assertFalse((batch / "ran").exists(), "the launcher ran over a finished sample")

    def test_run_writes_its_record_into_a_folder_that_does_not_exist_yet(self) -> None:
        # The run can take an hour, so a record folder that is missing must not cost the run its record.
        record = self.tmp / "new" / "tier" / "record.json"
        result = self.run_batch(self.write_batch(self.launcher_writing_a_record("aa")), record)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe_row(record)["passed"])


if __name__ == "__main__":
    unittest.main()
