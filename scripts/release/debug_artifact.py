#!/usr/bin/env python3
"""Cheap local Debug identity/resource checks; no publication authority or UI."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile

try:
    from release_contract import load_contract
    from release_identity import apply_app_identity, identity_plist, prepare_identity_plist
except ModuleNotFoundError:
    from scripts.release.release_contract import load_contract
    from scripts.release.release_identity import apply_app_identity, identity_plist, prepare_identity_plist


class DebugArtifactError(ValueError):
    pass


# ProcessInfoPlistFile enriches the native target's compact identity before linking.
# These build/toolchain fields are not runtime identity or updater configuration.
XCODE_EXECUTABLE_METADATA = frozenset({
    'BuildMachineOSBuild', 'CFBundleExecutable', 'CFBundleInfoDictionaryVersion',
    'CFBundlePackageType', 'CFBundleShortVersionString', 'CFBundleVersion',
    'CFBundleSupportedPlatforms', 'LSMinimumSystemVersion', 'MinimumOSVersion',
    'DTCompiler', 'DTPlatformBuild', 'DTPlatformName', 'DTPlatformVersion',
    'DTSDKBuild', 'DTSDKName', 'DTXcode', 'DTXcodeBuild',
})


def embedded_identity_matches(actual: dict, expected: dict) -> bool:
    return (all(actual.get(key) == value and type(actual.get(key)) is type(value)
                for key, value in expected.items())
            and set(actual) - set(expected) <= XCODE_EXECUTABLE_METADATA)


def embedded_identity(path: Path) -> dict:
    """Read the arm64 main executable's bounded Mach-O identity section."""
    with path.open('rb') as handle:
        header = handle.read(32)
        if len(header) != 32:
            raise DebugArtifactError('CLI has no complete Mach-O header')
        magic, cpu, _, _, commands, command_bytes, _, _ = struct.unpack('<8I', header)
        if magic != 0xFEEDFACF or cpu != 0x0100000C or command_bytes > 1024 * 1024:
            raise DebugArtifactError('CLI must be an arm64 Mach-O executable')
        table = handle.read(command_bytes)
        cursor = 0
        found = None
        for _ in range(commands):
            if cursor + 8 > len(table):
                raise DebugArtifactError('CLI Mach-O commands are truncated')
            command, size = struct.unpack_from('<II', table, cursor)
            if size < 8 or cursor + size > len(table):
                raise DebugArtifactError('CLI Mach-O command size is invalid')
            if command == 0x19:  # LC_SEGMENT_64
                if size < 72:
                    raise DebugArtifactError('CLI Mach-O segment is truncated')
                sections = struct.unpack_from('<I', table, cursor + 64)[0]
                if 72 + sections * 80 > size:
                    raise DebugArtifactError('CLI Mach-O section table is truncated')
                for index in range(sections):
                    section = cursor + 72 + index * 80
                    name, segment, _, length, offset = struct.unpack_from('<16s16sQQI', table, section)
                    if name.rstrip(b'\0') == b'__info_plist' and segment.rstrip(b'\0') == b'__TEXT':
                        if found is not None or not 0 < length <= 65_536:
                            raise DebugArtifactError('CLI identity section is ambiguous or unbounded')
                        found = (offset, length)
            cursor += size
        if cursor != len(table) or found is None:
            raise DebugArtifactError('CLI embedded identity is missing or malformed; rebuild without --skip-build')
        handle.seek(found[0])
        data = handle.read(found[1])
        if len(data) != found[1]:
            raise DebugArtifactError('CLI identity section is truncated')
    try:
        value = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise DebugArtifactError('CLI identity is not a valid plist') from error
    if not isinstance(value, dict):
        raise DebugArtifactError('CLI identity must be a dictionary')
    return value


def check_metadata(app: Path, contract) -> tuple[Path, str]:
    selected = contract.profile('debug')
    if app.name != selected.appBundleFilename or app.is_symlink() or not app.is_dir():
        raise DebugArtifactError('Debug wrapper differs from the contract')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = identity_plist(contract, 'debug')
    if any(info.get(key) != value for key, value in expected.items()):
        raise DebugArtifactError('Debug app identity differs from the contract')
    if any(key in info for key in ('SUFeedURL', 'SUPublicEDKey', 'SUVerifyUpdateBeforeExtraction')):
        raise DebugArtifactError('Debug app contains updater configuration')
    if not expected.get('LungfishRuntimeNamespace') and any(key in info for key in ('LungfishRuntimeNamespace', 'LungfishIdentitySchemaVersion')):
        raise DebugArtifactError('Upstream Debug app contains unexpected fork identity')
    executables = app / 'Contents/MacOS'
    for name in ('Lungfish', 'lungfish-cli'):
        executable = executables / name
        if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
            raise DebugArtifactError('Debug app lacks a regular executable: ' + name)
    cli = executables / 'lungfish-cli'
    if not embedded_identity_matches(embedded_identity(cli), expected):
        raise DebugArtifactError('Debug CLI embedded identity differs from the app contract; rebuild without --skip-build')
    resources = app / 'Contents/Resources'
    for name in ('LungfishGenomeBrowser_LungfishWorkflow.bundle', 'LungfishGenomeBrowser_LungfishApp.bundle'):
        resource = resources / name
        if not resource.is_dir() or resource.is_symlink():
            raise DebugArtifactError('Debug runtime resource bundle is missing: ' + name)
    if contract.identity.runtimeNamespace is not None:
        name = selected.displayName + ' Help'
        if info.get('CFBundleHelpBookName') != name:
            raise DebugArtifactError('Fork Help registration differs from app identity')
        help_info = plistlib.loads((resources / 'Lungfish.help/Contents/Info.plist').read_bytes())
        if help_info.get('HPDBookTitle') != name:
            raise DebugArtifactError('Fork Help title differs from app identity')
    version = info.get('CFBundleShortVersionString')
    if not isinstance(version, str) or not version:
        raise DebugArtifactError('Debug app version is missing')
    return cli, version


def check_app(app: Path, contract, runner=subprocess.run):
    cli, version = check_metadata(app, contract)
    with tempfile.TemporaryDirectory(prefix='lungfish-debug-check-') as directory:
        root = Path(directory)
        for name in ('home', 'tmp', 'storage'):
            (root / name).mkdir()
        environment = {**os.environ, 'HOME': str(root / 'home'), 'CFFIXED_USER_HOME': str(root / 'home'),
                       'TMPDIR': str(root / 'tmp'), 'LUNGFISH_STORAGE_ROOT': str(root / 'storage')}
        for arguments, expected in [(['--version'], version), (['debug', 'resource-smoke'], 'debug-resource-smoke-ok')]:
            result = runner([str(cli), *arguments], cwd=root, env=environment, capture_output=True,
                            text=True, timeout=45, check=False)
            if result.returncode != 0 or expected not in result.stdout.splitlines():
                raise DebugArtifactError('Debug CLI check failed: ' + ' '.join(arguments))
    print('Debug identity/CLI/resource checks passed: ' + str(app))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare-identity', 'apply-identity', 'check'))
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--app', type=Path)
    args = parser.parse_args(argv)
    try:
        contract = load_contract(args.root / 'config/release-contract.json')
        if args.operation == 'prepare-identity':
            print(prepare_identity_plist(args.root, contract, 'debug'))
        else:
            if args.app is None:
                raise DebugArtifactError('--app is required')
            app = args.app.absolute()
            if args.operation == 'apply-identity':
                apply_app_identity(app, contract, 'debug')
            else:
                check_app(app, contract)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, 'Debug artifact: ' + str(error) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
