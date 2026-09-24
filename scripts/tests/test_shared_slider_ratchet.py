"""Tests for scripts/ratchets/shared-slider-control.sh (owner decision D10)."""
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ratchets" / "shared-slider-control.sh"
ALLOWLISTED = "Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift"


def make_repo(tmp_path, files):
    (tmp_path / "scripts" / "ratchets").mkdir(parents=True)
    shutil.copy(SCRIPT, tmp_path / "scripts" / "ratchets" / SCRIPT.name)
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def run(repo):
    return subprocess.run(
        [sys.executable, str(repo / "scripts" / "ratchets" / SCRIPT.name)],
        capture_output=True, text=True,
    )


BASE = {
    "Sources/LungfishKit/NumericSliderField.swift": "Slider(value: $v, in: 0...1)\n",
    ALLOWLISTED: "Slider(value: $v, in: 0...1)\n",
    "Sources/LungfishApp/Other.swift": "NumericSliderField(\"x\", value: $v, in: 0...1)\nif view is NSSlider {}\n// Slider( in a comment\n",
}


def test_clean_tree_passes(tmp_path):
    assert run(make_repo(tmp_path, BASE)).returncode == 0


def test_raw_slider_outside_shared_control_fails(tmp_path):
    files = dict(BASE, **{"Sources/LungfishApp/New.swift": "Slider(value: $v, in: 0...10)\n"})
    result = run(make_repo(tmp_path, files))
    assert result.returncode == 1
    assert "Sources/LungfishApp/New.swift:1" in result.stderr


def test_nsslider_construction_fails(tmp_path):
    files = dict(BASE, **{"Sources/LungfishKit/X.swift": "let s = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)\n"})
    assert run(make_repo(tmp_path, files)).returncode == 1


def test_stale_allowlist_entry_fails(tmp_path):
    files = dict(BASE, **{ALLOWLISTED: "NumericSliderField(\"x\", value: $v, in: 0...1)\n"})
    result = run(make_repo(tmp_path, files))
    assert result.returncode == 1
    assert "remove it from ALLOWLIST" in result.stderr
