"""Tests for scripts/index/generate-module-map.py and scripts/checks/module-map-current.py."""
from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS.parent
GENERATOR_PATH = SCRIPTS / "index/generate-module-map.py"
CHECK_PATH = SCRIPTS / "checks/module-map-current.py"


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


gen = load(GENERATOR_PATH, "generate_module_map")
check = load(CHECK_PATH, "module_map_current")

FIXTURE_MANIFEST = textwrap.dedent(
    """\
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Fixture",
        products: [
            .library(name: "Core", targets: ["Core"]),
        ],
        dependencies: [
            // https://example.invalid comment with "quotes" and (parens)
            .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        ],
        targets: [
            .target(
                name: "Support",
                dependencies: ["Core"],
                path: "Tests/Support/Support"
            ),
            /* a block comment .target(name: "Ghost") */
            .target(
                name: "Core",
                dependencies: [
                    .product(name: "Collections", package: "swift-collections"),
                ]
            ),
            .target(
                name: "Feature",
                dependencies: [
                    "Core",
                    .target(name: "Support"),
                ],
                path: "Sources/Feature",
                resources: [.copy("Resources/Data")]
            ),
            .executableTarget(name: "Tool", dependencies: ["Feature"], path: "Sources/Tool"),
            .testTarget(name: "CoreTests", dependencies: ["Core", "Support"], path: "Tests/CoreTests"),
            .testTarget(name: "MixedTests", dependencies: ["Feature"]),
        ]
    )
    """
)


def write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    write(tmp_path, "Package.swift", FIXTURE_MANIFEST)
    write(
        tmp_path,
        "Sources/Core/Model.swift",
        textwrap.dedent(
            """\
            import Foundation

            public struct Model {
                public struct Nested {}
            }

            @MainActor
            public final class Store {}
            @MainActor public protocol Observer {}
            open class Base {}
            nonisolated public enum Mode { case a }
            internal struct Hidden {}
            public extension Model {}
            public func helper() {}
            """
        ),
    )
    write(tmp_path, "Sources/Core/Sub/Deep/Leaf.swift", "public actor Leaf {}\n")
    write(tmp_path, "Sources/Core/Sub/Other.swift", "public typealias Alias = Int")
    write(tmp_path, "Sources/Feature/Feature.swift", "struct Internal {}\n")
    write(tmp_path, "Sources/Tool/main.swift", "print(1)\n")
    write(tmp_path, "Tests/Support/Support/Helpers.swift", "public struct Helper {}\n")
    write(tmp_path, "Tests/CoreTests/ModelTests.swift", "import XCTest\n")
    write(tmp_path, "Tests/MixedTests/MixedTests.swift", "import XCTest\n")
    return tmp_path


def test_parse_package_reads_targets_paths_and_dependencies():
    targets = {t.name: t for t in gen.parse_package(FIXTURE_MANIFEST)}
    assert sorted(targets) == ["Core", "CoreTests", "Feature", "MixedTests", "Support", "Tool"]
    assert "Ghost" not in targets
    assert targets["Core"].path == "Sources/Core"
    assert targets["Core"].external_deps == ["Collections (swift-collections)"]
    assert targets["Feature"].internal_deps == ["Core", "Support"]
    assert targets["Tool"].kind == "executable"
    assert targets["MixedTests"].kind == "test"
    assert targets["MixedTests"].path == "Tests/MixedTests"
    assert targets["Support"].path == "Tests/Support/Support"


def test_public_types_are_top_level_only(repo: Path):
    files = gen.swift_files(repo, "Sources/Core")
    found = {(t.name, t.kind) for t in gen.public_types(repo, files)}
    assert found == {
        ("Alias", "typealias"),
        ("Base", "class"),
        ("Leaf", "actor"),
        ("Mode", "enum"),
        ("Model", "struct"),
        ("Observer", "protocol"),
        ("Store", "class"),
    }


def test_render_reports_subdirectories_public_types_and_test_targets(repo: Path):
    text = gen.render(repo)
    assert "| Core | library | Sources/Core | 7 | none |" in text
    assert "| Sub |" in text
    assert "| Sub/Deep |" in text
    assert "- `Store` class, `Sources/Core/Model.swift`" in text
    assert "- Test target. CoreTests" in text
    assert "- Test target. none named FeatureTests, tested by MixedTests" in text
    assert "- Used by. Feature, Support" in text
    assert "| Support | library | Tests/Support/Support |" in text


def test_the_map_holds_no_file_counts_line_counts_or_line_numbers(repo: Path):
    text = gen.render(repo)
    assert "Swift files" not in text.replace("holds Swift files", "")
    assert "| Lines" not in text
    assert not any(line.startswith("- Swift files") for line in text.splitlines())
    assert not re.search(r"\.swift:\d+", text)
    assert "| Test target | Path | Internal dependencies |" in text


def test_an_edit_that_changes_no_target_folder_or_public_type_leaves_the_map_identical(repo: Path):
    before = gen.render(repo)
    model = repo / "Sources/Core/Model.swift"
    model.write_text("// a line above\n// and another\n" + model.read_text() + "\nlet unrelated = 1\n")
    write(repo, "Sources/Core/Sub/Third.swift", "struct Plain {}\n\n\n\n")
    write(repo, "Tests/CoreTests/MoreTests.swift", "import XCTest\n")
    assert gen.render(repo) == before


def test_a_target_a_folder_or_a_public_type_changes_the_map(repo: Path):
    def add_target():
        write(repo, "Sources/Extra/Extra.swift", "struct Extra {}\n")
        manifest = FIXTURE_MANIFEST.replace(
            '.executableTarget(name: "Tool"',
            '.target(name: "Extra", path: "Sources/Extra"),\n        .executableTarget(name: "Tool"',
        )
        write(repo, "Package.swift", manifest)

    steps = [
        ("a public type", lambda: write(repo, "Sources/Core/Another.swift", "public struct Another {}\n")),
        ("a renamed public type", lambda: write(repo, "Sources/Core/Another.swift", "public struct Renamed {}\n")),
        ("a folder", lambda: write(repo, "Sources/Core/Fresh/File.swift", "struct Plain {}\n")),
        ("a target", add_target),
    ]
    previous = gen.render(repo)
    for label, change in steps:
        change()
        current = gen.render(repo)
        assert current != previous, label
        previous = current


C_TARGET_MANIFEST = textwrap.dedent(
    """\
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Fixture",
        targets: [
            .executableTarget(name: "Tool", dependencies: ["CTool"], path: "Sources/Tool"),
            .target(name: "CTool", path: "Sources/CTool"),
        ]
    )
    """
)


def test_render_lists_c_files_in_the_target_section_only(tmp_path: Path, repo: Path):
    ctree = tmp_path / "ctree"  # The repo fixture owns tmp_path itself.
    write(ctree, "Package.swift", C_TARGET_MANIFEST)
    write(ctree, "Sources/Tool/main.swift", "print(1)\n")
    write(ctree, "Sources/CTool/include/CTool.h", "#pragma once\nint tool_call(void);\n")
    write(ctree, "Sources/CTool/tool.c", '#include "CTool.h"\nint tool_call(void) {\n    return 0;\n}\n')
    text = gen.render(ctree)
    assert "| CTool | library | Sources/CTool | 0 | none |" in text
    section = text.split("## CTool\n", 1)[1].split("\n## ", 1)[0]
    assert "- C files. Sources/CTool/include/CTool.h, Sources/CTool/tool.c\n" in section
    assert "- C files." not in text.split("## Tool\n", 1)[1]
    assert "- C files." not in gen.render(repo)


def test_generation_is_idempotent(repo: Path):
    assert gen.main(["--root", str(repo)]) == 0
    output = repo / "docs/architecture/MODULES.md"
    first = output.read_bytes()
    assert gen.main(["--root", str(repo)]) == 0
    assert output.read_bytes() == first


def test_check_passes_when_current_and_fails_on_drift(repo: Path, capsys):
    assert check.main(["--root", str(repo)]) == 1  # missing
    gen.main(["--root", str(repo)])
    assert check.main(["--root", str(repo)]) == 0

    output = repo / "docs/architecture/MODULES.md"
    output.write_text(output.read_text() + "hand edit\n")
    assert check.main(["--root", str(repo)]) == 1
    assert "stale" in capsys.readouterr().out

    gen.main(["--root", str(repo)])
    write(repo, "Sources/Feature/New.swift", "public struct Added {}\n")
    assert check.main(["--root", str(repo)]) == 1


def test_check_stays_green_through_an_edit_that_only_moves_lines(repo: Path):
    gen.main(["--root", str(repo)])
    model = repo / "Sources/Core/Model.swift"
    model.write_text("// moved\n" * 5 + model.read_text())
    write(repo, "Sources/Feature/Internal2.swift", "struct Internal2 {}\n")
    assert check.main(["--root", str(repo)]) == 0


def test_check_runs_as_a_script_against_the_fixture(repo: Path):
    gen.main(["--root", str(repo)])
    result = subprocess.run(
        [sys.executable, str(CHECK_PATH), "--root", str(repo)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_committed_module_map_is_current():
    result = subprocess.run(
        [sys.executable, str(CHECK_PATH)], capture_output=True, text=True
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_every_sources_directory_is_a_package_target():
    targets = gen.parse_package((REPO_ROOT / "Package.swift").read_text())
    paths = {t.path for t in targets}
    for child in sorted((REPO_ROOT / "Sources").iterdir()):
        if child.is_dir():
            assert f"Sources/{child.name}" in paths, child.name
