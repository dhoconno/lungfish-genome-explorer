#!/usr/bin/env python3
"""Shared supported SwiftPM engine and Darwin linker SDK inputs."""
from pathlib import Path
import subprocess


def build_options(sdk_path: str) -> list[str]:
    if not sdk_path or not Path(sdk_path).is_absolute() or any(c in sdk_path for c in '\r\n\0'):
        raise ValueError('SwiftPM requires an absolute SDK path')
    # Swift Build links through swiftc -> clang. On link-only invocations the
    # driver's --sysroot does not supply Darwin SDK version inference; isysroot
    # does. Keep the actual SDK and minimum deployment target separate.
    return ['--build-system', 'swiftbuild',
            '-Xswiftc', '-Xclang-linker', '-Xswiftc', '-isysroot',
            '-Xswiftc', '-Xclang-linker', '-Xswiftc', sdk_path]


def selected_sdk_path() -> str:
    result = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                            check=True, capture_output=True, text=True)
    path = result.stdout.strip()
    build_options(path)
    if not Path(path).is_dir():
        raise ValueError('Selected macOS SDK is not a directory')
    return path


if __name__ == '__main__':
    print('\n'.join(build_options(selected_sdk_path())))
