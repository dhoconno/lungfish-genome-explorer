"""Tests for scripts/release/upload-timeout.sh (REL-05).

github_cli_asset_upload_timeout_seconds computes the timeout for a `gh
release upload`/`create` call whose last argument is a local file, since the
old flat 180s bound (shared with fast metadata calls) times out well before
a ~167 MB DMG can finish uploading at the upload rates this project has
recorded in practice.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release" / "upload-timeout.sh"


def compute_timeout(size_bytes, env_override=None, extra_env=None):
    with tempfile.NamedTemporaryFile(delete=False) as handle:
        if size_bytes:
            handle.truncate(size_bytes)
        path = handle.name
    try:
        environment = dict(os.environ)
        if extra_env:
            environment.update(extra_env)
        if env_override is not None:
            environment["LUNGFISH_RELEASE_UPLOAD_TIMEOUT_SECONDS"] = env_override
        else:
            environment.pop("LUNGFISH_RELEASE_UPLOAD_TIMEOUT_SECONDS", None)
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                f'source "{SCRIPT}" && github_cli_asset_upload_timeout_seconds "$1"',
                "upload-timeout-test",
                path,
            ],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=15,
        )
        return int(result.stdout.strip())
    finally:
        os.unlink(path)


class UploadTimeoutTests(unittest.TestCase):
    def test_small_asset_gets_the_ten_minute_floor(self):
        self.assertEqual(compute_timeout(1024), 600)

    def test_zero_byte_asset_gets_the_floor_not_zero(self):
        self.assertEqual(compute_timeout(0), 600)

    def test_dmg_sized_asset_scales_above_the_floor(self):
        # 166,935,984 bytes was the actual 2026.9.38 DMG size cited in the
        # audit (REL-05). At 50,000 bytes/s that is ~3339s (~55 minutes),
        # comfortably above the old flat 180s bound and above the roughly
        # 28-minute real-world upload time the audit measured.
        dmg_size = 166_935_984
        timeout = compute_timeout(dmg_size)
        self.assertGreater(timeout, 180)
        self.assertGreater(timeout, 28 * 60)
        self.assertEqual(timeout, dmg_size // 50_000)

    def test_explicit_override_wins_regardless_of_size(self):
        self.assertEqual(compute_timeout(200_000_000, env_override="42"), 42)
        self.assertEqual(compute_timeout(10, env_override="9999"), 9999)

    def test_timeout_is_monotonic_in_size(self):
        small = compute_timeout(10_000_000)
        large = compute_timeout(500_000_000)
        self.assertLess(small, large)


if __name__ == "__main__":
    unittest.main()
