"""Evidence integrity checks independent of Swift compilation or credential tools."""
import importlib.util
import json
from pathlib import Path
import tempfile
import copy
import unittest
from unittest.mock import patch
import subprocess
import sys
import time
from types import SimpleNamespace
from scripts.tests.gate_fixtures import make_gate_fixture

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('profile_evidence', ROOT / 'scripts/release/gate_evidence.py')
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

class ProfileEvidenceTests(unittest.TestCase):
    def test_duplicate_xctest_terminals_cannot_authorize(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            terminal = "Test Case '-[ExampleTests testA]' passed (0.1 seconds).\n"
            (root / 'runner.log').write_text(terminal * 2 + "Test Suite 'Selected tests' passed at now\nExecuted 1 test, with 0 failures\n")
            record = {'exitStatus': 0, 'files': [gate.file_record(root / 'runner.log', root)]}
            result = gate.analyze_attempt(root, record, {'xctest': ['ExampleTests/testA'], 'swift-testing': []}, False, False)
            self.assertFalse(result['passed'])

    def test_release_is_compact_sentinel_profile_with_bounded_workers(self):
        quick = gate.canonical_profile_options('quick')
        release = gate.canonical_profile_options('release')
        self.assertEqual(quick['filter'], release['filter'])
        self.assertEqual(release['workers'], 4)
        self.assertFalse(release['requireTools'])
        self.assertNotEqual(release['filter'], gate.canonical_profile_options('headless')['filter'])

    def test_shell_profile_adapter_preserves_canonical_selection(self):
        import subprocess
        actual = json.loads(subprocess.check_output(['bash', str(ROOT / 'scripts/full-suite-gate.sh'), '--profile', 'release', '--describe-selection']))
        self.assertEqual(actual, gate.canonical_profile_options('release'))

class CompletionAccountingTests(unittest.TestCase):
    def analyze_swift(self, kinds):
        identifier = 'ExampleTests.Suite/testFunction()/Tests.swift:1:1'
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'runner.log').write_text('')
            records = [dict(version=0, kind='test', payload=dict(id=identifier, kind='function')),
                       dict(version=0, kind='test', payload=dict(id='ExampleTests.Suite', kind='suite'))]
            for kind in kinds:
                if kind == 'runEnded':
                    records.append(dict(version=0, kind='event', payload=dict(kind='testEnded', testID='ExampleTests.Suite')))
                records.append(dict(version=0, kind='event', payload=dict(kind=kind, **({'testID': identifier} if kind.startswith('test') else {}))))
                if kind == 'runStarted':
                    records.append(dict(version=0, kind='event', payload=dict(kind='testStarted', testID='ExampleTests.Suite')))
            (root / 'swift-testing.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in records))
            command = dict(exitStatus=0, files=[gate.file_record(root / 'runner.log', root)])
            return gate.analyze_attempt(root, command, {'xctest': [], 'swift-testing': [identifier]}, False, False)

    def test_swift_ended_without_started_and_duplicate_function_events_fail(self):
        cases = [('runStarted', 'testEnded', 'runEnded'),
                 ('runStarted', 'testStarted', 'testStarted', 'testEnded', 'runEnded'),
                 ('runStarted', 'testStarted', 'testEnded', 'testEnded', 'runEnded'),
                 ('runStarted', 'testEnded', 'testStarted', 'runEnded')]
        for kinds in cases:
            with self.subTest(events=kinds):
                self.assertFalse(self.analyze_swift(kinds)['passed'])
        self.assertTrue(self.analyze_swift(('runStarted', 'testStarted', 'testEnded', 'runEnded'))['passed'])
        self.assertTrue(self.analyze_swift(('runStarted', 'testSkipped', 'runEnded'))['passed'])

    def test_watchdog_trap_zero_cannot_authorize_even_with_complete_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            ready = root / 'ready'
            script = """import signal,sys,time,pathlib
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
print("Test Case '-[ExampleTests testA]' passed (0.1 seconds).", flush=True)
print("Test Suite 'Selected tests' passed at now", flush=True)
print("Executed 1 test, with 0 failures", flush=True)
pathlib.Path(sys.argv[1]).write_text('ready')
while True: time.sleep(.01)
"""
            def watchdog(argv, **kwargs):
                if argv[0] == 'pgrep':
                    deadline = time.monotonic() + 2
                    while not ready.exists() and time.monotonic() < deadline: time.sleep(.005)
                    self.assertTrue(ready.exists())
                    return SimpleNamespace(stdout='12345')
                return SimpleNamespace(stdout='Z xctest')
            with patch.object(gate.subprocess, 'run', side_effect=watchdog):
                command = gate.command_record([sys.executable, '-c', script, str(ready)], root, root, 'runner')
            self.assertEqual(command['exitStatus'], 0)
            self.assertIsNotNone(command['intervention'])
            result = gate.analyze_attempt(root, command, {'xctest': ['ExampleTests/testA'], 'swift-testing': []}, False, False)
            self.assertFalse(result['passed'])

    def test_replayed_authoritative_and_discovery_interventions_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            source = dict(clean=True, commit='fixture')
            path = make_gate_fixture(Path(temp) / 'gates', source, legacy=True)
            manifest = json.loads(path.read_text())
            baseline = json.loads((path.parent / manifest['results'][1]['path']).read_text())
            for location in ('authoritative', 'discovery', 'identity'):
                value = copy.deepcopy(baseline)
                command = dict(intervention='terminated-unreaped-xctest-parent', exitStatus=0)
                if location == 'authoritative': value['attempts'][0].update(command)
                elif location == 'discovery': value['discovery'] = [command]
                else: value['identityCommand'] = command
                with self.subTest(location=location), self.assertRaises(gate.EvidenceError):
                    gate.validate_result(value, source)


class DependencyEvidenceTests(unittest.TestCase):
    def contract(self, policy, source_root=ROOT):
        steps = [SimpleNamespace(tier='full', requireTools=False), SimpleNamespace(tier='conformance', requireTools=True)]
        return SimpleNamespace(sourceRoot=source_root, gates=SimpleNamespace(dependencyPolicy=policy, focusedReleaseTests=[], for_channel=lambda _: steps))

    def test_legacy_installed_receipt_cannot_satisfy_manifest_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            source = dict(clean=True, commit='fixture')
            path = make_gate_fixture(Path(temp) / 'gates', source, legacy=True)
            digest = gate.file_record(path, path.parent)['sha256']
            gate.verify_manifest(path, digest, source, 'stable', self.contract('installed'))
            with self.assertRaises(gate.EvidenceError):
                gate.verify_manifest(path, digest, source, 'stable', self.contract('manifest'))

    def test_creation_rejects_receipt_relabel_or_same_bytes_wrong_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            wrong = root / 'installed-receipt.json'
            actual = ROOT / 'Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json'
            for index, raw in enumerate((b'{"fixture":true}', actual.read_bytes())):
                wrong.write_bytes(raw)
                output = root / str(index); output.mkdir()
                with self.assertRaisesRegex(gate.EvidenceError, 'canonical'):
                    gate.create_manifest(output, dict(clean=True, commit='fixture'), 'stable', [], wrong, self.contract('manifest'))

    def test_verification_rejects_relabelled_receipt_even_with_rehashed_records(self):
        with tempfile.TemporaryDirectory() as temp:
            source = dict(clean=True, commit='fixture')
            path = make_gate_fixture(Path(temp) / 'gates', source, legacy=True)
            value = json.loads(path.read_text())
            value.update(schemaVersion=2, dependencyEvidence={'kind': 'lock-manifest', 'file': value.pop('dependencyReceipt')},
                         dependencySourcePath=str((ROOT / 'Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json').resolve()))
            path.write_text(json.dumps(value))
            with self.assertRaises(gate.EvidenceError):
                gate.verify_manifest(path, gate.file_record(path, path.parent)['sha256'], source, 'stable', self.contract('manifest'))

    def test_canonical_file_must_have_real_pins_and_is_revalidated(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            dependency = root / 'Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json'
            dependency.parent.mkdir(parents=True)
            source = dict(clean=True, commit='fixture')
            path = make_gate_fixture(root / 'gates', source, legacy=True)
            old = json.loads(path.read_text()); path.unlink()
            results = [path.parent / r['path'] for r in old['results']]
            dependency.write_text('{"fixture":true}')
            with self.assertRaises(gate.EvidenceError):
                gate.create_manifest(path.parent, source, 'stable', results, dependency, self.contract('manifest', root))
            dependency.write_bytes((ROOT / dependency.relative_to(root)).read_bytes())
            path, digest = gate.create_manifest(path.parent, source, 'stable', results, dependency, self.contract('manifest', root))
            value = json.loads(path.read_text())
            value['dependencySourcePath'] = str(root / 'unrelated.json')
            path.write_text(json.dumps(value))
            with self.assertRaises(gate.EvidenceError):
                gate.verify_manifest(path, gate.file_record(path, path.parent)['sha256'], source, 'stable', self.contract('manifest', root))
            value['dependencySourcePath'] = str(dependency)
            path.write_text(json.dumps(value)); digest = gate.file_record(path, path.parent)['sha256']
            changed = json.loads(dependency.read_text()); changed['version'] = 'changed'
            dependency.write_text(json.dumps(changed))
            with self.assertRaises(gate.EvidenceError):
                gate.verify_manifest(path, digest, source, 'stable', self.contract('manifest', root))

    def test_typed_manifest_creation_and_policy_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = dict(clean=True, commit='fixture')
            path = make_gate_fixture(root / 'gates', source, legacy=True)
            old = json.loads(path.read_text())
            path.unlink()
            dependency = ROOT / 'Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json'
            (path.parent / 'dependency-receipt.json').unlink()
            results = [path.parent / r['path'] for r in old['results']]
            path, digest = gate.create_manifest(path.parent, source, 'stable', results, dependency, self.contract('manifest'))
            manifest = json.loads(path.read_text())
            self.assertEqual(manifest['schemaVersion'], 2)
            self.assertEqual(manifest['dependencyEvidence']['kind'], 'lock-manifest')
            self.assertEqual(manifest['dependencyEvidence']['file']['path'], 'dependency-manifest.json')
            self.assertNotIn('dependencyReceipt', manifest)
            self.assertEqual(manifest['dependencySourcePath'], str(dependency.resolve()))
            with self.assertRaises(gate.EvidenceError):
                gate.verify_manifest(path, digest, source, 'stable', self.contract('installed'))
            (path.parent / 'dependency-manifest.json').write_text('changed')
            with self.assertRaises(gate.EvidenceError):
                gate.verify_manifest(path, digest, source, 'stable', self.contract('manifest'))

if __name__ == '__main__':
    unittest.main()
