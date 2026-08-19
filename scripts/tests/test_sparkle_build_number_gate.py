import subprocess
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release" / "check-sparkle-build-number.py"


class SparkleBuildNumberGateTests(unittest.TestCase):
    def run_gate(self, planned: str, current: str):
        with tempfile.TemporaryDirectory() as temp_dir:
            appcast = Path(temp_dir) / "appcast.xml"
            appcast.write_text(
                f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item><sparkle:version>{current}</sparkle:version></item></channel>
</rss>\n''',
                encoding="utf-8",
            )
            return subprocess.run(
                ["python3", str(SCRIPT), "--planned", planned, "--appcast", str(appcast)],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_accepts_strictly_greater_build_number(self):
        self.assertEqual(self.run_gate("4025", "4024").returncode, 0)

    def test_rejects_equal_or_lower_build_number(self):
        for planned in ("4024", "4023"):
            result = self.run_gate(planned, "4024")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must exceed live Sparkle build", result.stderr)

    def test_rejects_non_positive_or_non_numeric_build_number(self):
        for planned in ("0", "beta"):
            self.assertNotEqual(self.run_gate(planned, "4024").returncode, 0)


if __name__ == "__main__":
    unittest.main()
