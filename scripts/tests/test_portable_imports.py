"""Tests for scripts/ratchets/portable-imports.sh (CHTC program C3, lane K1, ARCH-K1 rows K1-08 to K1-12)."""
from __future__ import annotations

import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS.parent
SCRIPT = SCRIPTS / "ratchets/portable-imports.sh"

MANIFEST = textwrap.dedent(
    """\
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Fixture",
        products: [
            .library(name: "LungfishPortable", targets: ["LungfishPortable"]),
            .executable(name: "lungfish-executor", targets: ["LungfishExecutor"]),
        ],
        targets: [
            .target(name: "LungfishPortable", path: "Sources/LungfishPortable"),
            .executableTarget(
                name: "LungfishExecutor",
                dependencies: ["CLungfishExecutor", "LungfishPortable"],
                path: "Sources/LungfishExecutor"
            ),
            .target(name: "CLungfishExecutor", path: "Sources/CLungfishExecutor"),
            .testTarget(name: "LungfishExecutorTests", dependencies: ["LungfishExecutor"], path: "Tests/LungfishExecutorTests"),
            .target(name: "LungfishWorkflow", dependencies: ["LungfishPortable"], path: "Sources/LungfishWorkflow"),
        ]
    )
    """
)

HEADER = textwrap.dedent(
    """\
    // CLungfishExecutor.h
    #pragma once

    // Returns 0 or the errno value.
    int lungfish_set_child_subreaper(void);
    int lungfish_get_child_subreaper(int *out);
    """
)

C_FILE = textwrap.dedent(
    """\
    // ChildSubreaper.c, a comment may name LUNGFISH_ and _CONDOR_
    #include "CLungfishExecutor.h"
    #include <errno.h>

    int lungfish_set_child_subreaper(void) { return ENOSYS; }
    int lungfish_get_child_subreaper(int *out) { (void)out; return ENOSYS; }
    """
)

FILES = {
    "Sources/LungfishPortable/Digest.swift": (
        "import Foundation\n#if canImport(CryptoKit)\nimport CryptoKit\n#endif\n"
        "/// Reads no LUNGFISH_ variable.\npublic enum Digest {}\n"
    ),
    "Sources/LungfishExecutor/main.swift": "import Foundation\nimport LungfishPortable\nprint(1)\n",
    "Sources/CLungfishExecutor/include/CLungfishExecutor.h": HEADER,
    "Sources/CLungfishExecutor/ChildSubreaper.c": C_FILE,
    "Tests/LungfishExecutorTests/ExecutorTests.swift": "import XCTest\n@testable import LungfishExecutor\n",
    "Sources/LungfishWorkflow/Workflow.swift": "import Foundation\nimport LungfishPortable\n",
}


def write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def edit(root: Path, rel: str, old: str, new: str) -> None:
    path = root / rel
    text = path.read_text(encoding="utf-8")
    assert old in text, f"{old!r} not in {rel}"
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def append(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.write_text(path.read_text(encoding="utf-8") + text, encoding="utf-8")


@pytest.fixture
def tree(tmp_path: Path) -> Path:
    write(tmp_path, "Package.swift", MANIFEST)
    for rel, text in FILES.items():
        write(tmp_path, rel, text)
    return tmp_path


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)


def test_repository_tree_is_at_its_baseline():
    result = run()
    assert result.returncode == 0, result.stderr
    assert "1 c_targets" in result.stdout
    assert "0 executor_dependents" in result.stdout


def test_fixture_where_only_executor_tests_list_the_executor_passes(tree: Path):
    result = run("--root", str(tree))
    assert result.returncode == 0, result.stderr
    assert "0 forbidden_tokens" in result.stdout


def test_manifest_option_reads_another_manifest(tree: Path, tmp_path: Path):
    other = tmp_path / "Other.swift"
    other.write_text(MANIFEST.replace('dependencies: ["LungfishPortable"], path: "Sources/LungfishWorkflow"',
                                      'dependencies: ["LungfishExecutor"], path: "Sources/LungfishWorkflow"'))
    assert run("--root", str(tree)).returncode == 0
    assert run("--root", str(tree), "--manifest", str(other)).returncode == 1


def library_target_lists_executor(root: Path) -> None:
    edit(root, "Package.swift", 'dependencies: ["LungfishPortable"], path: "Sources/LungfishWorkflow"',
         'dependencies: ["LungfishExecutor"], path: "Sources/LungfishWorkflow"')


def second_executable_target_lists_executor(root: Path) -> None:
    edit(root, "Package.swift", "    targets: [\n",
         '        targets: [\n        .executableTarget(name: "Other", dependencies: ["LungfishExecutor"], path: "Sources/Other"),\n')


def library_product_lists_executor(root: Path) -> None:
    edit(root, "Package.swift", "    products: [\n",
         '        products: [\n        .library(name: "Exec", targets: ["LungfishExecutor"]),\n')


def workflow_file_imports_executor(root: Path) -> None:
    append(root, "Sources/LungfishWorkflow/Workflow.swift", "import LungfishExecutor\n")


def portable_lists_c_target(root: Path) -> None:
    edit(root, "Package.swift", '.target(name: "LungfishPortable", path:',
         '.target(name: "LungfishPortable", dependencies: ["CLungfishExecutor"], path:')


def executor_test_imports_c_target(root: Path) -> None:
    append(root, "Tests/LungfishExecutorTests/ExecutorTests.swift", "import CLungfishExecutor\n")


def third_file_in_c_folder(root: Path) -> None:
    write(root, "Sources/CLungfishExecutor/Extra.c", "int lungfish_extra(void) { return 0; }\n")


def header_declares_third_function(root: Path) -> None:
    append(root, "Sources/CLungfishExecutor/include/CLungfishExecutor.h", "int lungfish_third(void);\n")


def c_target_call_holds_c_settings(root: Path) -> None:
    edit(root, "Package.swift", '.target(name: "CLungfishExecutor", path: "Sources/CLungfishExecutor")',
         '.target(name: "CLungfishExecutor", path: "Sources/CLungfishExecutor", cSettings: [.define("X")])')


def second_c_target(root: Path) -> None:
    edit(root, "Package.swift", "    targets: [\n",
         '        targets: [\n        .target(name: "CLungfishOther", path: "Sources/CLungfishOther"),\n')
    write(root, "Sources/CLungfishOther/other.c", "int other(void) { return 0; }\n")


def portable_file_reads_condor_scratch(root: Path) -> None:
    append(root, "Sources/LungfishPortable/Digest.swift",
           'let scratch = ProcessInfo.processInfo.environment["_CONDOR_SCRATCH_DIR"]\n')


def c_file_holds_lungfish_token(root: Path) -> None:
    append(root, "Sources/CLungfishExecutor/ChildSubreaper.c", "#define LUNGFISH_GUARD 1\n")


def portable_file_imports_os_log_outside_if(root: Path) -> None:
    edit(root, "Sources/LungfishPortable/Digest.swift", "import Foundation\n", "import Foundation\nimport os.log\n")


@pytest.mark.parametrize(
    "mutate",
    [
        library_target_lists_executor,
        second_executable_target_lists_executor,
        library_product_lists_executor,
        workflow_file_imports_executor,
        portable_lists_c_target,
        executor_test_imports_c_target,
        third_file_in_c_folder,
        header_declares_third_function,
        c_target_call_holds_c_settings,
        second_c_target,
        portable_file_reads_condor_scratch,
        c_file_holds_lungfish_token,
        portable_file_imports_os_log_outside_if,
    ],
)
def test_fixture_fails(tree: Path, mutate):
    mutate(tree)
    result = run("--root", str(tree))
    assert result.returncode == 1, result.stdout
    assert "portable-imports:" in result.stderr


def test_planted_condor_line_fails_and_its_removal_passes(tree: Path):
    portable_file_reads_condor_scratch(tree)
    assert run("--root", str(tree)).returncode == 1
    write(tree, "Sources/LungfishPortable/Digest.swift", FILES["Sources/LungfishPortable/Digest.swift"])
    assert run("--root", str(tree)).returncode == 0


def test_import_inside_if_passes(tree: Path):
    append(tree, "Sources/LungfishPortable/Digest.swift", "#if canImport(Darwin)\nimport Darwin\n#endif\n")
    assert run("--root", str(tree)).returncode == 0
