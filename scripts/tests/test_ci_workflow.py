import unittest
from pathlib import Path


class CIWorkflowTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2]
        self.workflow = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")

    def test_fast_gate_repairs_xcode_lockfile_before_xcodebuild_then_checks_afterward(self):
        repair = "bash scripts/check-package-resolved-consistency.sh --repair"
        xcodebuild = "xcodebuild -project Lungfish.xcodeproj -scheme Lungfish"
        check = "bash scripts/check-package-resolved-consistency.sh"

        self.assertIn(repair, self.workflow)
        self.assertLess(self.workflow.index("run: swift package resolve"), self.workflow.index(repair))
        self.assertLess(self.workflow.index(repair), self.workflow.index(xcodebuild))
        self.assertLess(self.workflow.index(xcodebuild), self.workflow.index(check, self.workflow.index(xcodebuild)))


if __name__ == "__main__":
    unittest.main()
