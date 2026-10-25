"""Tests for scripts/release/linux_executor.py, the build, strip and placement of the app's Linux executor.

Every test runs the script's functions with a fake command runner and a fake toolchain folder, so no test compiles. The
real build is shown in the lane record of C4-14 with the SHA-256 of a mapped and an unmapped build.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release" / "linux_executor.py"
PINS = json.loads((ROOT / "scripts/linux/toolchain.json").read_text(encoding="utf-8"))
COMMIT = "0123456789abcdef0123456789abcdef01234567"
CLEAN_ELF = b"\x7fELF\x02\x01\x01\x00/workspace/Sources/x.swift\x00/swiftpm-build/checkouts/y.cc\x00"


def load_module():
    spec = importlib.util.spec_from_file_location("linux_executor_under_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Fixture:
    """A checkout holding the real pins, a home folder holding a fake pinned toolchain, and a recording runner."""

    def __init__(self, stripped: bytes = CLEAN_ELF, sdk_installed: bool = True):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name).resolve()
        self.root = base / "checkout"
        (self.root / "scripts/linux").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/linux/toolchain.json", self.root / "scripts/linux/toolchain.json")
        self.home = base / "home"
        self.tools = self.home / "Library/Developer/Toolchains" / f"{PINS['toolchain']['name']}.xctoolchain/usr/bin"
        self.tools.mkdir(parents=True)
        for name in ("swift", "llvm-objcopy"):
            (self.tools / name).write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            os.chmod(self.tools / name, 0o755)
        self.products = base / "products"
        self.stripped = stripped
        self.sdk_installed = sdk_installed
        self.commands: list[list[str]] = []

    def run(self, argv, *, cwd, capture, env=None):
        self.commands.append(list(argv))
        if argv[1:3] == ["sdk", "list"]:
            return (PINS["staticSDK"]["id"] + "\n") if self.sdk_installed else "another-sdk\n"
        if argv[0].endswith("llvm-objcopy"):
            Path(argv[-1]).write_bytes(self.stripped)
            return ""
        if argv[-1] == "--show-bin-path":
            return f"warning: one\n{self.products}\n"
        self.products.mkdir(parents=True, exist_ok=True)
        (self.products / "lungfish-executor").write_bytes(self.stripped + b"\x00/Users/someone/debug-map")
        return ""

    def build(self, module, output: Path, **extra):
        return module.build(
            self.root, output, lge_version="2026.10.24", lge_commit=COMMIT, home=self.home, run=self.run, **extra
        )

    def cleanup(self):
        self.temporary.cleanup()


class BuildCommandTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_the_maps_name_the_scratch_then_the_checkout_for_the_c_cxx_and_swift_compilers(self):
        argv = self.module.build_arguments(
            Path("/t/swift"), "sdk-id", "x86_64-swift-linux-musl", Path("/c/build/s"), Path("/c")
        )

        self.assertEqual(argv, [
            "/t/swift", "build", "-c", "release", "--swift-sdk", "sdk-id", "--triple", "x86_64-swift-linux-musl",
            "--product", "lungfish-executor", "--scratch-path", "/c/build/s", "-Xlinker", "--build-id=none",
            "-Xcc", "-ffile-prefix-map=/c/build/s=/swiftpm-build",
            "-Xcxx", "-ffile-prefix-map=/c/build/s=/swiftpm-build",
            "-Xswiftc", "-file-prefix-map", "-Xswiftc", "/c/build/s=/swiftpm-build",
            "-Xcc", "-ffile-prefix-map=/c=/workspace",
            "-Xcxx", "-ffile-prefix-map=/c=/workspace",
            "-Xswiftc", "-file-prefix-map", "-Xswiftc", "/c=/workspace",
        ])

    def test_a_scratch_folder_outside_the_checkout_is_refused_before_any_build_command(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        outside = fixture.root.parent / "elsewhere"

        with self.assertRaisesRegex(self.module.ExecutorBuildError, "inside the checkout"):
            fixture.build(self.module, fixture.root / "build/stage", scratch=outside)

        self.assertFalse(outside.exists())
        self.assertEqual([command[1:3] for command in fixture.commands], [["sdk", "list"]])

    def test_a_missing_sdk_stops_the_build_and_names_the_install_command(self):
        fixture = Fixture(sdk_installed=False)
        self.addCleanup(fixture.cleanup)

        with self.assertRaisesRegex(self.module.ExecutorBuildError, "portable-tier.sh --install"):
            fixture.build(self.module, fixture.root / "build/stage")

        self.assertEqual(len(fixture.commands), 1)

    def test_the_build_strips_with_the_pinned_objcopy_and_writes_the_manifest_beside_the_file(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        stage = fixture.root / "build/stage"

        manifest = fixture.build(self.module, stage)

        build, bin_path, strip = fixture.commands[1:]
        scratch = fixture.root / "build/linux-executor/scratch"
        self.assertEqual(build[0], str(fixture.tools / "swift"))
        self.assertIn(f"{scratch}=/swiftpm-build", build)
        self.assertIn(f"-ffile-prefix-map={fixture.root}=/workspace", build)
        self.assertEqual(bin_path, [*build, "--show-bin-path"])
        self.assertEqual(strip[:2], [str(fixture.tools / "llvm-objcopy"), "--strip-all"])
        stripped = stage / "LinuxExecutor/x86_64/lungfish-executor"
        self.assertEqual(stripped.read_bytes(), CLEAN_ELF)
        self.assertEqual(os.stat(stripped).st_mode & 0o777, 0o755)
        self.assertIn(b"/Users/someone", (stage / "unstripped/lungfish-executor-x86_64-swift-linux-musl").read_bytes())
        self.assertEqual(manifest, {
            "schemaVersion": 1,
            "relativePath": "lungfish-executor",
            "sha256": hashlib.sha256(CLEAN_ELF).hexdigest(),
            "size": len(CLEAN_ELF),
            "lgeVersion": "2026.10.24",
            "lgeCommit": COMMIT,
            "targetTriple": "x86_64-swift-linux-musl",
            "toolchainID": PINS["toolchain"]["name"],
            "toolchainSHA256": PINS["toolchain"]["sha256"],
            "staticLinuxSDKID": PINS["staticSDK"]["id"],
            "staticLinuxSDKSHA256": PINS["staticSDK"]["sha256"],
        })
        written = json.loads((stage / "LinuxExecutor/x86_64/manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(written, manifest)

    def test_the_link_writes_no_build_id_and_the_strip_removes_the_module_hashes(self):
        # Lane C5 REPRO built the base in two checkouts. The stripped files differed only in .note.gnu.build-id, which
        # lld hashes from the whole unstripped file and its path-bound DWARF, and in .swift_modhash, the MD5 of each
        # object's LLVM module, which is named by the object's path in the scratch folder.
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        stage = fixture.root / "build/stage"

        fixture.build(self.module, stage)

        build, bin_path, strip = fixture.commands[1:]
        self.assertIn(["-Xlinker", "--build-id=none"], [build[index:index + 2] for index in range(len(build) - 1)])
        self.assertEqual(bin_path, [*build, "--show-bin-path"])
        self.assertEqual(strip, [
            str(fixture.tools / "llvm-objcopy"), "--strip-all", "--remove-section=.swift_modhash",
            str(fixture.products / "lungfish-executor"), str(stage / "LinuxExecutor/x86_64/lungfish-executor"),
        ])

    def test_a_stage_folder_that_exists_is_refused(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        stage = fixture.root / "build/stage"
        stage.mkdir(parents=True)

        with self.assertRaisesRegex(self.module.ExecutorBuildError, "must be new"):
            fixture.build(self.module, stage)


class PlaceTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def staged(self, stripped: bytes = CLEAN_ELF):
        fixture = Fixture(stripped=stripped)
        self.addCleanup(fixture.cleanup)
        stage = fixture.root / "build/stage"
        fixture.build(self.module, stage)
        app = fixture.root.parent / "Lungfish.xcarchive/Products/Applications/Lungfish.app"
        (app / "Contents/Resources").mkdir(parents=True)
        symbols = fixture.root.parent / "Lungfish.xcarchive/dSYMs"
        symbols.mkdir()
        return stage, app, symbols

    def test_place_puts_the_folder_outside_tools_and_the_unstripped_copy_beside_the_dsyms(self):
        stage, app, symbols = self.staged()

        manifest = self.module.place(stage, app, symbols)

        folder = app / "Contents/Resources/LinuxExecutor/x86_64"
        self.assertEqual(sorted(path.name for path in folder.iterdir()), ["lungfish-executor", "manifest.json"])
        self.assertEqual((folder / "lungfish-executor").read_bytes(), CLEAN_ELF)
        self.assertEqual(os.stat(folder / "manifest.json").st_mode & 0o777, 0o644)
        self.assertNotIn("Tools", folder.relative_to(app).parts)
        self.assertEqual([path.name for path in symbols.iterdir()], ["lungfish-executor-x86_64-swift-linux-musl"])
        self.assertEqual(self.module.app_record(app), {
            "path": "Contents/Resources/LinuxExecutor/x86_64/lungfish-executor", "manifest": manifest,
        })

    def test_place_refuses_a_stripped_file_that_names_a_home_folder(self):
        stage, app, symbols = self.staged(stripped=CLEAN_ELF + b"/Users/someone/checkouts/x.cc\x00")

        with self.assertRaisesRegex(self.module.ExecutorBuildError, "user-home 1"):
            self.module.place(stage, app, symbols)

        self.assertFalse((app / "Contents/Resources/LinuxExecutor").exists())

    def test_a_manifest_that_differs_from_the_file_beside_it_is_refused(self):
        stage, app, symbols = self.staged()
        self.module.place(stage, app, symbols)
        executable = app / "Contents/Resources/LinuxExecutor/x86_64/lungfish-executor"
        executable.write_bytes(CLEAN_ELF + b"\x00")

        with self.assertRaisesRegex(self.module.ExecutorBuildError, "differs from the file beside it"):
            self.module.app_record(app)

    def test_an_app_without_the_folder_has_no_record(self):
        _, app, _ = self.staged()

        self.assertIsNone(self.module.app_record(app))


if __name__ == "__main__":
    unittest.main()
