"""Tests for scripts/checks/features-yaml-sources.py."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "checks" / "features-yaml-sources.py"
spec = importlib.util.spec_from_file_location("features_yaml_sources", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

FEATURES = """\
# header comment
version: 0
features:
  demo.one:
    title: Demo one
    entry_points:
      - "Tools > Demo"
    sources:
      - Sources/LungfishCore/A.swift
      - Sources/LungfishCLI/B.swift
    module: [LungfishCore, LungfishCLI]
    cli:
      - lungfish-cli demo
    tests:
      - Tests/LungfishCoreTests/ATests.swift
    notes: >-
      free text
  demo.two:
    title: Demo two
    sources:
      - Sources/LungfishCore/A.swift
    module: LungfishCore
"""


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    for rel in ("Sources/LungfishCore/A.swift", "Sources/LungfishCLI/B.swift",
                "Tests/LungfishCoreTests/ATests.swift"):
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// stub\n")
    return tmp_path


def run(repo: Path, text: str, capsys) -> tuple[int, str]:
    features = repo / "features.yaml"
    features.write_text(text)
    code = checker.main(["--features", str(features), "--root", str(repo)])
    return code, capsys.readouterr().out


def test_passes_on_valid_registry(repo, capsys):
    code, out = run(repo, FEATURES, capsys)
    assert code == 0
    assert "all resolve" in out


def test_missing_source_fails(repo, capsys):
    text = FEATURES.replace("Sources/LungfishCLI/B.swift", "Sources/LungfishCLI/Gone.swift")
    code, out = run(repo, text, capsys)
    assert code == 1
    assert "demo.one: sources path does not exist: Sources/LungfishCLI/Gone.swift" in out


def test_missing_test_fails(repo, capsys):
    text = FEATURES.replace("ATests.swift", "MissingTests.swift")
    code, out = run(repo, text, capsys)
    assert code == 1
    assert "demo.one: tests path does not exist" in out


def test_module_not_a_sources_directory_fails(repo, capsys):
    text = FEATURES.replace("module: LungfishCore", "module: LungfishNope")
    code, out = run(repo, text, capsys)
    assert code == 1
    assert "demo.two: module is not a directory under Sources/: LungfishNope" in out


def test_module_list_member_is_checked(repo, capsys):
    text = FEATURES.replace("[LungfishCore, LungfishCLI]", "[LungfishCore, LungfishNope]")
    code, out = run(repo, text, capsys)
    assert code == 1
    assert "LungfishNope" in out


def test_module_must_be_a_directory_not_a_file(repo, capsys):
    (repo / "Sources" / "NotADir").write_text("file\n")
    text = FEATURES.replace("module: LungfishCore", "module: NotADir")
    code, out = run(repo, text, capsys)
    assert code == 1
    assert "NotADir" in out


def test_source_may_name_a_directory(repo, capsys):
    text = FEATURES.replace("Sources/LungfishCLI/B.swift", "Sources/LungfishCLI")
    code, out = run(repo, text, capsys)
    assert code == 0


def test_all_failures_are_reported_together(repo, capsys):
    text = (FEATURES.replace("B.swift", "Gone.swift")
            .replace("ATests.swift", "MissingTests.swift")
            .replace("module: LungfishCore", "module: LungfishNope"))
    code, out = run(repo, text, capsys)
    assert code == 1
    assert "3 problem(s)" in out


def test_missing_features_file_fails(repo, capsys):
    code = checker.main(["--features", str(repo / "absent.yaml"), "--root", str(repo)])
    assert code == 1


def test_real_registry_parses_to_many_entries():
    text = (checker.DEFAULT_FEATURES).read_text()
    features = checker.parse_features(text)
    assert len(features) > 50
    assert all("module" in f for f in features.values())
