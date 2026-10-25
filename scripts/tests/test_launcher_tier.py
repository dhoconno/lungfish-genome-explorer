#!/usr/bin/env python3
"""Argument handling of scripts/linux/launcher-tier.sh (C5 lane LAUNCH M3).

The Docker run itself is a tier record, not a test. These tests run the script with a stand-in `docker` on PATH that
writes down each call and fails, and read the exit code, the messages, what the script printed and whether it called
Docker or wrote a record.
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


if __name__ == "__main__":
    unittest.main()
