import unittest
from pathlib import Path


class NightlyPrereleaseNamingTests(unittest.TestCase):
    def test_release_entrypoints_use_prerelease_names(self):
        root = Path(__file__).resolve().parents[2]

        self.assertTrue((root / "scripts" / "release" / "nightly_prerelease_release.py").is_file())
        self.assertTrue((root / "scripts" / "release" / "run-nightly-prerelease.sh").is_file())
        self.assertFalse((root / "scripts" / "release" / "nightly_alpha_release.py").exists())
        self.assertFalse((root / "scripts" / "release" / "run-nightly-alpha-release.sh").exists())


if __name__ == "__main__":
    unittest.main()
