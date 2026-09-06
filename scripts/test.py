#!/usr/bin/env python3
"""List, audit and execute canonical test profiles with retained gate evidence.

No run of this diagnostic frontend independently authorizes a release. The
coordinator binds its fixed source profile and actual artifact checks to a candidate.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from testing.catalog import audit, audit_source_targets, load_catalog, profile_options, python_modules


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['list', 'audit', 'run', 'gate'])
    parser.add_argument('--profile', default='quick')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--describe-selection', action='store_true')
    parser.add_argument('--inventory', type=Path, help='JSON array of exact IDs from both harness discoveries')
    parser.add_argument('--evidence-dir', type=Path)
    parser.add_argument('--require-tools', action='store_true')
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args(argv)
    try:
        data = load_catalog(ROOT)
        options = profile_options(data, args.profile, args.require_tools)
        if args.describe_selection:
            print(json.dumps(options))
            return 0
        targets = audit_source_targets(data, ROOT)
        if args.command == 'audit':
            report = {'sourceTargets': targets, 'discoveryAudited': False}
            if args.inventory:
                report.update(collections=audit(data, json.loads(args.inventory.read_text())), discoveryAudited=True)
            print(json.dumps(report, indent=2))
            return 0
        modules = python_modules(data, args.profile, ROOT)
        if args.command == 'list':
            print(json.dumps({'profile': args.profile, 'options': options, 'collections': [c for c in data['collections'] if c['id'] in data['profiles'][args.profile]['collections']], 'pythonModules': modules,
                              'nativeXCUITestCommand': data['profiles'][args.profile].get('nativeXCUITestCommand'), 'releaseAuthority': False}, indent=2))
            return 0
        gate = ROOT / 'scripts/release/gate_evidence.py'
        if args.evidence_dir:
            directory = args.evidence_dir.resolve()
        else:
            logs = ROOT / '.build/gate-logs'
            logs.mkdir(parents=True, exist_ok=True)
            directory = Path(tempfile.mkdtemp(prefix=args.profile + '-', dir=logs))
            directory.rmdir()  # evidence helper creates its immutable directory
        # gate compatibility emits exactly one Swift result for release.py.
        swift_output = directory if args.command == 'gate' else directory / 'swift'
        if args.command != 'gate':
            directory.mkdir(parents=True, exist_ok=False)
        command = [sys.executable, str(gate), 'swift', '--root', str(ROOT), '--output', str(swift_output), '--tier', args.profile,
                   '--profile', args.profile, '--filter', options['filter'], '--skip', options['skip'], '--workers', str(options['workers'])]
        if options['parallel']:
            command.append('--parallel')
        if options['requireTools']:
            command.append('--require-tools')
        command += ['--', str(Path(__file__).resolve()), *(argv if argv is not None else sys.argv[1:])]
        result = subprocess.run(command, stdout=subprocess.DEVNULL if args.quiet else None, check=False,
                                env={**os.environ, "LUNGFISH_REQUIRE_TOOLS": "1" if options["requireTools"] else "0"})
        if result.returncode or args.command == 'gate':
            return result.returncode
        if modules:
            result = subprocess.run([sys.executable, str(gate), 'python', '--root', str(ROOT), '--output', str(directory / 'python'), *modules], check=False)
        print('Evidence: ' + str(directory))
        return result.returncode
    except (ValueError, OSError, KeyError) as error:
        print('Test profile failed: ' + str(error), file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
