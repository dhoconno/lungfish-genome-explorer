#!/usr/bin/env python3
"""Explicit local build maintenance; never invoked by package or publish.

Keep recent candidate payloads and all evidence. Unknown files, unreceipted
candidates, source checkouts, scientific outputs and pending signing are held.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def candidates(root, keep, published_commits=None):
    if keep < 1:
        raise ValueError('keep must be at least one')
    selected, held = [], []
    for channel in ('preview', 'stable'):
        parent = root / 'build/Release' / channel
        entries = []
        if not parent.is_dir() or parent.is_symlink():
            continue
        for path in parent.iterdir():
            if path.is_symlink() or not path.is_dir() or not re.fullmatch('[0-9a-f]{40}', path.name):
                continue
            try:
                receipt = json.loads((path / 'unsigned-candidate-receipt.json').read_text())
                if receipt['source']['commit'] != path.name or receipt['release']['channel'] != channel:
                    raise ValueError('identity mismatch')
                wrapper = receipt['wrapper']['filename']
                if Path(wrapper).name != wrapper or not wrapper.endswith('.app'):
                    raise ValueError('invalid wrapper')
                entries.append((int(receipt['release']['build']), path, wrapper, receipt['release'].get('version')))
            except (OSError, ValueError, KeyError, TypeError):
                held.append(str(path) + ': missing or invalid receipt')
        for _, path, wrapper, version in sorted(entries, reverse=True)[keep:]:
            transaction = path / 'signing-transaction/transaction.json'
            if (path / 'signing-transaction').exists():
                try:
                    if json.loads(transaction.read_text()).get('status') != 'Accepted':
                        raise ValueError('pending')
                except (OSError, ValueError):
                    held.append(str(path) + ': unfinished signing transaction')
                    continue
                if (published_commits or {}).get(('v' + str(version), channel)) != path.name:
                    held.append(str(path) + ': published remote tag/commit not verified')
                    continue
            payloads = [path / wrapper, path / 'Lungfish.xcarchive',
                        path / 'signed' / wrapper, path / 'signing-transaction' / wrapper,
                        path / 'signing-transaction/app.zip', path / 'signing-transaction/input.dmg']
            payloads += sorted(path.glob('Lungfish-*-arm64.dmg'))
            payloads += sorted((path / 'sparkle-appcast').glob('Lungfish-*-arm64.dmg'))
            for item in payloads:
                if item.exists() and not item.is_symlink() and not any(p.is_symlink() for p in item.parents if p.is_relative_to(root)):
                    selected.append(item)
    return selected, held


def published_commits(root):
    """Read-only remote evidence: published release channel plus peeled tag commit."""
    releases = json.loads(subprocess.check_output(
        ['gh', 'release', 'list', '--limit', '1000', '--json', 'tagName,isDraft,isPrerelease'], cwd=root))
    refs = subprocess.check_output(['git', 'ls-remote', '--tags', 'origin'], cwd=root, text=True)
    tags = {}
    for line in refs.splitlines():
        sha, ref = line.split()
        name = ref.removeprefix('refs/tags/').removesuffix('^{}')
        if ref.endswith('^{}') or name not in tags:
            tags[name] = sha
    return {(r['tagName'], 'preview' if r['isPrerelease'] else 'stable'): tags[r['tagName']]
            for r in releases if not r['isDraft'] and r['tagName'] in tags}


def snapshot(path):
    """Metadata tree witness without following symlinks; detects in-use mutations."""
    digest = hashlib.sha256()
    allocated = 0
    def add(item):
        nonlocal allocated
        st = item.lstat()
        digest.update(json.dumps([str(item.relative_to(path)), st.st_dev, st.st_ino,
                                 st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns]).encode())
        allocated += st.st_blocks * 512
    add(path)
    if path.is_dir():
        for directory, dirs, files in os.walk(path, followlinks=False):
            dirs.sort()
            for name in sorted(dirs + files):
                add(Path(directory) / name)
    return {'metadataSha256': digest.hexdigest(), 'allocatedBytes': allocated}


def assert_idle():
    result = subprocess.run(['ps', '-axo', 'pid=,comm='], check=True, capture_output=True, text=True)
    names = {'xcodebuild', 'swift-build', 'swift-test', 'swift-frontend', 'swiftc', 'clang', 'ld'}
    active = [line.strip() for line in result.stdout.splitlines() if Path(line.strip().split(maxsplit=1)[-1]).name in names]
    if active:
        raise RuntimeError('active compiler processes: ' + '; '.join(active))
    commands = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    operators = [line.strip() for line in commands.splitlines() if re.match(
        r'^\s*\d+\s+\S*(?:python[\d.]*|bash|sh)\s+\S*/(?:release\.py|build-app\.sh|build-notarized-dmg\.sh)\b', line)]
    if operators:
        raise RuntimeError('active build/release operators: ' + '; '.join(operators))


def unrelated_time_machine_warning(stderr):
    lines = stderr.strip().splitlines()
    return (len(lines) == 3 and lines[0].startswith("lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/")
            and lines[1].strip() == 'Output information may be incomplete.'
            and re.fullmatch(r'\s+assuming "dev=[0-9a-f]+" from mount table', lines[2]) is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keep', type=int, default=2, help='candidate payloads retained per channel (default: 2)')
    parser.add_argument('--apply', action='store_true', help='delete reviewed reproducible payloads')
    parser.add_argument('--report', type=Path, required=True, help='new audit JSON path outside deleted payloads')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    published = published_commits(root)
    paths, held = candidates(root, args.keep, published)
    args.report = args.report.resolve()
    if args.report.exists():
        parser.error('report already exists; choose a new path')
    if any(args.report.is_relative_to(p) for p in paths):
        parser.error('report cannot be inside a deletion target')
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
    for path in paths:
        if any((root / name).is_relative_to(path) for name in tracked if name):
            raise RuntimeError('tracked content in ' + str(path))
    assert_idle()
    report = {'schemaVersion': 1, 'workflow': 'local-retention', 'version': 1,
              'argv': [sys.executable, *sys.argv], 'root': str(root), 'keep': args.keep,
              'apply': args.apply, 'held': held, 'payloads': [], 'removedAllocatedBytes': 0,
              'publishedCommits': [{'tag': k[0], 'channel': k[1], 'commit': v} for k, v in sorted(published.items())],
              'startedAt': time.time(), 'exitStatus': None}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    def save():
        with tempfile.NamedTemporaryFile(mode='w', dir=args.report.parent, prefix='.retention-', delete=False) as output:
            output.write(json.dumps(report, indent=2) + '\n')
        Path(output.name).replace(args.report)
    try:
        for path in paths:
            report['payloads'].append({'path': str(path), **snapshot(path), 'removed': False})
        save()
        print(f"{len(paths)} payloads; {sum(p['allocatedBytes'] for p in report['payloads']) / 2**30:.2f} GiB allocated; {len(held)} held")
        if args.apply:
            for entry in report['payloads']:
                path = Path(entry['path'])
                assert_idle()
                opened = subprocess.run(['lsof', '-nP', '+D', str(path)] if path.is_dir() else ['lsof', '-nP', str(path)], capture_output=True, text=True)
                if opened.returncode != 1 or opened.stdout.strip() or (opened.stderr.strip() and not unrelated_time_machine_warning(opened.stderr)):
                    raise RuntimeError('open files or incomplete lsof check: ' + str(path))
                if opened.stderr:
                    entry['lsofWarning'] = opened.stderr
                if snapshot(path) != {k: entry[k] for k in ('metadataSha256', 'allocatedBytes')}:
                    raise RuntimeError('payload changed during preflight: ' + str(path))
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                entry['removed'] = True
                report['removedAllocatedBytes'] += entry['allocatedBytes']
                save()
        report['exitStatus'] = 0
    except Exception as error:
        report['exitStatus'] = 1
        report['error'] = str(error)
        raise
    finally:
        report['wallTimeSeconds'] = time.time() - report['startedAt']
        save()


if __name__ == '__main__':
    main()
