"""Tests for scripts/release/generate-notices.py (REL-03).

Covers: license resolution from overrides vs. .build/checkouts, the hard
failure when a dependency has neither, the check-mode staleness gate, and
that the real repo's manifests round-trip into a notices file mentioning the
bundled GPL-2.0 kernel and the micromamba bootstrap.
"""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "scripts" / "release" / "generate-notices.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("generate_notices", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GenerateNoticesRealRepoTests(unittest.TestCase):
    """Exercises the script against the actual repo manifests."""

    def test_generates_notices_mentioning_bundled_gpl_kernel_and_micromamba(self):
        module = _load_module()
        overrides = module.load_json(module.OVERRIDES_PATH)
        overrides = {k: v for k, v in overrides.items() if not k.startswith("_")}
        tool_lock = module.load_json(module.TOOL_LOCK_PATH)
        bundled_payloads = module.load_json(module.BUNDLED_PAYLOADS_PATH)
        shipped, excluded = module.resolve_swiftpm_dependencies(overrides)

        rendered = module.render_notices(tool_lock, bundled_payloads, shipped, excluded)

        self.assertIn("GPL-2.0", rendered)
        self.assertIn("vmlinux", "".join(p["path"] for p in bundled_payloads["containerizationPayloads"]))
        self.assertIn("micromamba", rendered)
        self.assertIn("source offer", rendered.lower())
        self.assertIn("<!-- managed-tools:begin -->", rendered)
        self.assertIn("<!-- managed-tools:end -->", rendered)
        # Every non-test-only SwiftPM pin should appear by identity.
        for entry in shipped:
            self.assertIn(entry["identity"], rendered)
        # Test-only dependencies (e.g. viewinspector) are called out, not silently dropped.
        excluded_ids = {entry["identity"] for entry in excluded}
        if excluded_ids:
            self.assertIn("Test-only Swift package dependencies", rendered)
            for identity in excluded_ids:
                self.assertIn(identity, rendered)

    def test_all_overrides_correspond_to_a_real_package_resolved_pin(self):
        # Guards against the overrides file accumulating stale entries for
        # dependencies that have since been removed from Package.resolved.
        module = _load_module()
        overrides = module.load_json(module.OVERRIDES_PATH)
        overrides = {k: v for k, v in overrides.items() if not k.startswith("_")}
        resolved = module.load_json(module.PACKAGE_RESOLVED_PATH)
        pinned_identities = {pin["identity"] for pin in resolved["pins"]}
        stale = set(overrides) - pinned_identities
        self.assertEqual(stale, set(), f"stale override entries no longer in Package.resolved: {stale}")

    def test_check_mode_passes_against_freshly_generated_file(self):
        module = _load_module()
        with tempfile.TemporaryDirectory() as temp_dir:
            out_path = Path(temp_dir) / "THIRD-PARTY-NOTICES"
            result = self._run_main(module, ["--out", str(out_path)])
            self.assertEqual(result, 0)

            check_result = self._run_main(module, ["--out", str(out_path), "--check"])
            self.assertEqual(check_result, 0)

    def test_check_mode_fails_when_out_of_date(self):
        module = _load_module()
        with tempfile.TemporaryDirectory() as temp_dir:
            out_path = Path(temp_dir) / "THIRD-PARTY-NOTICES"
            out_path.write_text("stale content\n", encoding="utf-8")
            result = self._run_main(module, ["--out", str(out_path), "--check"])
            self.assertEqual(result, 1)

    def _run_main(self, module, argv):
        old_argv = sys.argv
        sys.argv = ["generate-notices.py"] + argv
        try:
            return module.main()
        finally:
            sys.argv = old_argv


class GenerateNoticesFailureModeTests(unittest.TestCase):
    """Exercises the hard-failure path with a synthetic repo layout."""

    def setUp(self):
        self.module = _load_module()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.fake_root = Path(self.temp_dir.name)

        self.module.PACKAGE_RESOLVED_PATH = self.fake_root / "Package.resolved"
        self.module.CHECKOUTS_DIR = self.fake_root / ".build" / "checkouts"
        self.module.OVERRIDES_PATH = self.fake_root / "notices-overrides.json"
        self.module.TOOL_LOCK_PATH = self.fake_root / "third-party-tools-lock.json"
        self.module.BUNDLED_PAYLOADS_PATH = self.fake_root / "bundled-payloads.json"

        self.module.TOOL_LOCK_PATH.write_text(
            json.dumps({"tools": [], "packTools": []}), encoding="utf-8"
        )
        self.module.BUNDLED_PAYLOADS_PATH.write_text(
            json.dumps({"bootstrapBinaries": [], "containerizationPayloads": []}),
            encoding="utf-8",
        )

    def _write_resolved(self, identities):
        pins = [
            {
                "identity": identity,
                "kind": "remoteSourceControl",
                "location": f"https://example.invalid/{identity}.git",
                "state": {"revision": "abc123", "version": "1.0.0"},
            }
            for identity in identities
        ]
        self.module.PACKAGE_RESOLVED_PATH.write_text(
            json.dumps({"pins": pins}), encoding="utf-8"
        )

    def test_fails_clearly_when_a_dependency_has_no_license_source(self):
        self._write_resolved(["mystery-package"])
        self.module.OVERRIDES_PATH.write_text(json.dumps({}), encoding="utf-8")

        with self.assertRaises(self.module.NoticesGenerationError) as ctx:
            self.module.resolve_swiftpm_dependencies({})

        self.assertIn("mystery-package", str(ctx.exception))

    def test_resolves_from_checkout_license_file_when_present(self):
        self._write_resolved(["local-lib"])
        checkout_dir = self.module.CHECKOUTS_DIR / "local-lib"
        checkout_dir.mkdir(parents=True)
        (checkout_dir / "LICENSE").write_text("MIT License text here.\n", encoding="utf-8")

        shipped, excluded = self.module.resolve_swiftpm_dependencies({})

        self.assertEqual(excluded, [])
        self.assertEqual(len(shipped), 1)
        self.assertIn("MIT License text here.", shipped[0]["licenseText"])

    def test_resolves_from_overrides_when_checkout_missing(self):
        self._write_resolved(["override-only"])
        overrides = {
            "override-only": {
                "license": "Apache-2.0",
                "licenseUrl": "https://example.invalid/LICENSE",
                "copyright": "Copyright Example",
            }
        }

        shipped, excluded = self.module.resolve_swiftpm_dependencies(overrides)

        self.assertEqual(excluded, [])
        self.assertEqual(shipped[0]["license"], "Apache-2.0")
        self.assertIsNone(shipped[0]["licenseText"])

    def test_test_only_dependency_is_excluded_not_silently_dropped(self):
        self._write_resolved(["test-only-lib", "shipped-lib"])
        overrides = {
            "test-only-lib": {"shipped": False, "reason": "test target only"},
            "shipped-lib": {"license": "MIT", "licenseUrl": "https://example.invalid/LICENSE", "copyright": "Copyright X"},
        }

        shipped, excluded = self.module.resolve_swiftpm_dependencies(overrides)

        self.assertEqual([e["identity"] for e in shipped], ["shipped-lib"])
        self.assertEqual([e["identity"] for e in excluded], ["test-only-lib"])
        self.assertEqual(excluded[0]["reason"], "test target only")


if __name__ == "__main__":
    unittest.main()
