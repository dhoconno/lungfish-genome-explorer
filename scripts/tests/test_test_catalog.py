"""Behavioral checks for test partition and release-safe profile selections."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class CatalogTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('catalog', ROOT / 'scripts/testing/catalog.py')
        self.assertIsNotNone(spec)
        self.assertTrue(Path(spec.origin).exists(), 'canonical catalog implementation is missing')
        self.catalog = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.catalog)
        self.data = self.catalog.load_catalog(ROOT)

    def test_headless_and_release_exclude_gui_tools_and_stress(self):
        safe = 'LungfishWorkflowTests.MappingProvenanceTests/testPayload'
        unsafe = ['LungfishAppTests.ViewerBundleRoutingTests/testOpen',
                  'LungfishKitTests.BatchTableViewTests/testLayout',
                  'LungfishWorkflowTests.NativeToolRunnerTests/testRun',
                  'LungfishCoreTests.ProjectStorageScannerLargeTreeTests/testScan']
        for profile in ('quick', 'headless', 'release'):
            options = self.catalog.profile_options(self.data, profile)
            self.assertTrue(self.catalog.matches(safe, options))
            for test in unsafe:
                self.assertFalse(self.catalog.matches(test, options), (profile, test))

    def test_primary_partition_rejects_unknown_duplicate_and_empty(self):
        tiny = {'collections': [dict(id='one', harness='swift', include='^One\\.', exclude='', resources=[])]}
        self.assertEqual(self.catalog.audit(tiny, ['One.Suite/test']), {'one': 1})
        for ids in ([], ['Unknown.Suite/test'], ['One.Suite/test', 'One.Suite/test']):
            with self.assertRaises(ValueError):
                self.catalog.audit(tiny, ids)
        ambiguous = copy.deepcopy(tiny)
        ambiguous['collections'].append({**tiny['collections'][0], 'id': 'two'})
        with self.assertRaises(ValueError):
            self.catalog.audit(ambiguous, ['One.Suite/test'])

    def test_legacy_tiers_have_exact_previous_options(self):
        fixtures = json.loads((ROOT / 'scripts/tests/fixtures/legacy-tier-options.json').read_text())
        for tier, expected in fixtures.items():
            self.assertEqual(self.catalog.legacy_options(self.data, tier), expected)

    def test_all_source_test_targets_are_explicitly_assigned(self):
        counts = self.catalog.audit_source_targets(self.data, ROOT)
        self.assertGreater(len(counts), 15)

    def test_extended_retains_every_python_test_module(self):
        retained = set(self.catalog.python_modules(self.data, 'extended', ROOT))
        expected = {'scripts.tests.' + p.stem for p in (ROOT / 'scripts/tests').glob('test_*.py')}
        self.assertEqual(retained, expected)

    def test_profiles_select_all_members_of_their_collections(self):
        cases = ['LungfishWorkflowTests.NativeToolRunnerTests/testTool',
                 'LungfishWorkflowTests.FullLengthONTMHCGenotypingPipelineTests/testMatrix',
                 'LungfishIntegrationTests.ExampleTests/testExample']
        for profile, policy in self.data['profiles'].items():
            if policy.get('filter'):
                continue
            for test in cases:
                expected = any(c['id'] in policy['collections'] and self.catalog.collection_matches(test, c)
                               for c in self.data['collections'])
                self.assertEqual(self.catalog.matches(test, self.catalog.profile_options(self.data, profile)), expected, (profile, test))

    def test_profiles_refuse_resource_overrides_and_unknown_names(self):
        with self.assertRaises(ValueError):
            self.catalog.profile_options(self.data, 'made-up')
        with self.assertRaises(ValueError):
            self.catalog.profile_options(self.data, 'headless', require_tools=True)

if __name__ == '__main__':
    unittest.main()
