#!/usr/bin/env python3
"""Retain native Release build products without Xcode archive's implicit clean.

This is an internal receipt container, not an Xcode export/signing operation.
Only copied products may be stamped or sealed; compiler-cache products stay intact.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import re
import subprocess

from release_cache_security import validate_ancestor_chain


class ArchiveError(ValueError):
    pass


def checked_directory(path):
    path = Path(os.path.abspath(path))
    validate_ancestor_chain(path, expected_uid=os.geteuid())
    if path.is_symlink() or not path.is_dir():
        raise ArchiveError('archive product directory is unavailable or symlinked')
    return path


def regular(path, *, executable=False):
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise ArchiveError(f'required regular archive product is missing: {path.name}')
    if executable and not os.access(path, os.X_OK):
        raise ArchiveError(f'archive executable is not executable: {path.name}')


def validate_tree(root):
    # Framework version links are valid, but must stay inside the copied product.
    for path in root.rglob('*'):
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(root)
            except (OSError, ValueError) as error:
                raise ArchiveError('archive product contains an escaping or broken symlink') from error
        elif not (path.is_file() or path.is_dir()):
            raise ArchiveError('archive product contains a special filesystem object')


def validate_app(app):
    checked_directory(app)
    validate_tree(app)
    regular(app / 'Contents/MacOS/Lungfish', executable=True)
    regular(app / 'Contents/MacOS/lungfish-cli', executable=True)
    info_path = app / 'Contents/Info.plist'
    regular(info_path)
    if info_path.stat().st_size > 1024 * 1024:
        raise ArchiveError('archive app metadata exceeds bound')
    info = plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleExecutable') != 'Lungfish':
        raise ArchiveError('archive app executable identity differs from native target')
    for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'):
        if not isinstance(info.get(key), str) or not info[key]:
            raise ArchiveError(f'archive app metadata is missing {key}')
    return info


def macho_uuid(path):
    result = subprocess.run(['/usr/bin/dwarfdump', '--uuid', str(path)],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True,
                            check=True, timeout=30)
    lines = result.stdout.splitlines()
    if len(lines) != 1:
        raise ArchiveError('archive symbol identity must contain exactly one arm64 slice')
    match = re.fullmatch(r'UUID: ([0-9A-Fa-f-]{36}) \(arm64\) .+', lines[0])
    if match is None:
        raise ArchiveError('archive product has no valid arm64 UUID')
    return match.group(1).lower()


def validate_symbols(products, app):
    for name, executable in (('Lungfish.app.dSYM', 'Lungfish'), ('lungfish-cli.dSYM', 'lungfish-cli')):
        dsym = checked_directory(products / name)
        validate_tree(dsym)
        dwarf = dsym / 'Contents/Resources/DWARF' / executable
        regular(dwarf)
        if macho_uuid(app / 'Contents/MacOS' / executable) != macho_uuid(dwarf):
            raise ArchiveError(f'archive dSYM UUID differs from {executable}')


def copy_product(source, destination):
    subprocess.run(['/usr/bin/ditto', str(source), str(destination)],
                   stdin=subprocess.DEVNULL, check=True, timeout=180)


def assemble(products, archive):
    products = checked_directory(products)
    archive = Path(os.path.abspath(archive))
    validate_ancestor_chain(archive.parent, expected_uid=os.geteuid())
    if archive.exists() or archive.is_symlink():
        raise ArchiveError('archive destination must be new')
    # Do all source validation before creating the retained output.
    app = products / 'Lungfish.app'
    validate_app(app)
    validate_symbols(products, app)
    if archive == products or products in archive.parents or archive in products.parents:
        raise ArchiveError('archive destination must be separate from compiler products')
    archive.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    checked_directory(archive.parent)
    archive.mkdir(mode=0o700)
    (archive / 'Products/Applications').mkdir(parents=True)
    (archive / 'dSYMs').mkdir()
    copy_product(app, archive / 'Products/Applications/Lungfish.app')
    for name in ('Lungfish.app.dSYM', 'lungfish-cli.dSYM'):
        copy_product(products / name, archive / 'dSYMs' / name)
    finalize(archive)


def finalize(archive):
    archive = checked_directory(archive)
    info = validate_app(archive / 'Products/Applications/Lungfish.app')
    validate_symbols(archive / 'dSYMs', archive / 'Products/Applications/Lungfish.app')
    metadata = {
        'ArchiveVersion': 2,
        'ApplicationProperties': {
            'ApplicationPath': 'Applications/Lungfish.app',
            'Architectures': ['arm64'],
            **{key: info[key] for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')},
            'SigningIdentity': '', 'Team': '',
        },
        'CreationDate': datetime.now(timezone.utc).replace(tzinfo=None),
        'Name': 'Lungfish', 'SchemeName': 'Lungfish',
    }
    path = archive / 'Info.plist'
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ArchiveError('archive metadata destination is unsafe')
    with path.open('wb') as stream:
        plistlib.dump(metadata, stream, sort_keys=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('assemble', 'finalize'))
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--products', type=Path)
    args = parser.parse_args()
    try:
        if args.operation == 'assemble':
            if args.products is None:
                parser.error('assemble requires --products')
            assemble(args.products, args.archive)
        else:
            finalize(args.archive)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FAIL retained release archive: {error}\n')
    print('PASS retained release archive: copied native products verified')


if __name__ == '__main__':
    main()
