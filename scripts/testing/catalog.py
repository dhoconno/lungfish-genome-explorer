"""Canonical logical collection policy; selection is independent of execution."""
from __future__ import annotations
import fnmatch
import json
from pathlib import Path
import re


def load_catalog(root):
    data = json.loads((Path(root) / 'config/test-catalog.json').read_text())
    if data.get('schemaVersion') != 1:
        raise ValueError('unsupported test catalog schema')
    ids = [c['id'] for c in data['collections']]
    if len(ids) != len(set(ids)):
        raise ValueError('duplicate primary collection')
    for collection in data['collections']:
        if not collection['include']:
            raise ValueError('empty collection selector')
        re.compile(collection['include'])
        re.compile(collection.get('exclude', ''))
    for profile in data['profiles'].values():
        if not profile['collections'] or set(profile['collections']) - set(ids):
            raise ValueError('profile has empty or unknown collection membership')
    return data


def matches(test, options):
    return bool((not options.get('filter') or re.search(options['filter'], test)) and
                (not options.get('skip') or not re.search(options['skip'], test)))


def collection_matches(test, collection):
    return matches(test, {'filter': collection['include'], 'skip': collection.get('exclude', '')})


def audit(data, discovered):
    """Fail closed on the complete discovered inventory, before selecting a profile."""
    tests = list(discovered)
    if not tests or len(tests) != len(set(tests)):
        raise ValueError('empty or duplicate discovered test inventory')
    collections = [c for c in data['collections'] if c['harness'] == 'swift']
    counts = {c['id']: 0 for c in collections}
    for test in tests:
        owners = [c['id'] for c in collections if collection_matches(test, c)]
        if len(owners) != 1:
            raise ValueError(f'unassigned or ambiguous test: {test}: {owners}')
        counts[owners[0]] += 1
    if any(not count for count in counts.values()):
        raise ValueError('empty required collections: ' + ', '.join(k for k, v in counts.items() if not v))
    return counts


def audit_source_targets(data, root):
    targets = re.findall(r'\.testTarget\(\s*name: "([^"]+)"', (Path(root) / 'Package.swift').read_text())
    if set(targets) != set(data['targets']):
        raise ValueError('SwiftPM target inventory differs from catalog: ' + str(set(targets) ^ set(data['targets'])))
    counts = {t: len(list((Path(root) / 'Tests' / t).rglob('*.swift'))) for t in targets}
    if not all(counts.values()):
        raise ValueError('empty required test target')
    return counts


def profile_options(data, profile, require_tools=False):
    if profile not in data['profiles']:
        raise ValueError('unknown test profile: ' + profile)
    policy = data['profiles'][profile]
    if require_tools and not policy['requireTools']:
        raise ValueError('profile resource policy cannot be overridden by --require-tools')
    selected = [c for c in data['collections'] if c['id'] in policy['collections']]
    selectors = ['(?=.*(?:' + c['include'] + '))' + ('(?!.*(?:' + c['exclude'] + '))' if c.get('exclude') else '') + '.*' for c in selected]
    include = '^(?:' + '|'.join(selectors) + ')'
    if policy.get('filter'):
        include = '(?=' + include + ')' + policy['filter']
    return dict(tier=profile, filter=include, skip='', parallel=policy['parallel'],
                requireTools=policy['requireTools'], profile=profile, workers=policy['workers'])


def legacy_options(data, tier, require_tools=False):
    if tier not in data['legacyTiers']:
        raise ValueError('unknown tier: ' + tier + ' (smoke|unit|integration|conformance|full)')
    return {**data['legacyTiers'][tier], 'requireTools': bool(require_tools)}


def python_modules(data, profile, root):
    available = sorted('scripts.tests.' + p.stem for p in (Path(root) / 'scripts/tests').glob('test_*.py'))
    patterns = data['profiles'][profile]['pythonModules']
    for pattern in patterns:
        if not any(fnmatch.fnmatchcase(name, pattern) for name in available):
            raise ValueError('empty Python selector: ' + pattern)
    return [name for name in available if any(fnmatch.fnmatchcase(name, p) for p in patterns)]
