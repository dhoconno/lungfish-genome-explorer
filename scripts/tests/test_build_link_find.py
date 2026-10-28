"""A linked .build must not hide files from the two scripts that search it.

Stage B of the scratch plan links each lane's .build to a folder on the scratch disk (backlog row BUILD-LINK-FIND).
A find whose start path is that link does not descend into it, so scripts/build-app.sh could not find the Sparkle
framework and scripts/linux/portable-tier.sh could not find the test binaries. find -H follows a link given as the
start path and no other link.

Each test reads the find expression from the script by a fixed pattern, so an edit of the script is what the test
checks, and runs it in bash against a temporary folder whose .build is a link. Nothing here builds, calls swift or
touches a path outside the temporary folder.
"""

import collections
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD_APP = ROOT / "scripts" / "build-app.sh"
PORTABLE_TIER = ROOT / "scripts" / "linux" / "portable-tier.sh"

# Far above the time of one find over a handful of files, far below a hang.
TIMEOUT_SECONDS = 30

Search = collections.namedtuple("Search", "script pattern variable files decoys expected")

# The fallback search for Sparkle in scripts/build-app.sh. The framework sits in a layout that the direct path above
# the search does not name, so only the find can reach it. The ios slice is a decoy the -path test must skip.
SPARKLE_DIRECTORY = "artifacts/other-layout/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

BUILD_APP_SEARCH = Search(
    script=BUILD_APP,
    pattern=re.compile(
        r'^\s*SPARKLE_FRAMEWORK_SOURCE="\$\((?P<expression>/usr/bin/find(?: -[A-Za-z]+)* "\$PROJECT_ROOT/\.build" .*?)\)"\s*$',
        re.MULTILINE,
    ),
    variable="PROJECT_ROOT",
    files=(SPARKLE_DIRECTORY + "/Versions/B/Sparkle",),
    decoys=("artifacts/other-layout/Sparkle.xcframework/ios-arm64/Sparkle.framework/Sparkle",),
    expected=(SPARKLE_DIRECTORY,),
)

# The search for the Linux test binaries in scripts/linux/portable-tier.sh. A folder named like a test bundle is a
# decoy the -type f test must skip.
TEST_BINARIES = (
    "out/Products/LungfishCoreTests-test-runner",
    "out/Products/LungfishCoreTests.so",
    "debug/LungfishPackageTests.xctest",
)

PORTABLE_TIER_SEARCH = Search(
    script=PORTABLE_TIER,
    pattern=re.compile(
        r'^done < <\((?P<expression>find(?: -[A-Za-z]+)* "\$pkg/\.build" .*? \| sort)\)\s*$',
        re.MULTILINE,
    ),
    variable="pkg",
    files=TEST_BINARIES,
    decoys=(
        "out/Products/lungfish-executor",
        "out/Products/LungfishCoreTests.swiftmodule",
        "debug/Bundle.xctest/Contents/Info.plist",
    ),
    expected=TEST_BINARIES,
)

ALL_SEARCHES = (BUILD_APP_SEARCH, PORTABLE_TIER_SEARCH)


def keep(expression):
    return expression


def without_h(expression):
    """The expression as it was before the fix, whatever the script holds now."""
    return re.sub(r"\bfind -H\b", "find", expression, count=1)


def with_h(expression):
    """The expression as the fix writes it, whatever the script holds now."""
    if re.search(r"\bfind -H\b", expression):
        return expression
    return re.sub(r"\bfind\b", "find -H", expression, count=1)


class LinkedBuildFindTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="build-link-find-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)

    def make_project(self, search, linked):
        """A worktree folder whose .build is a link to a folder elsewhere, or a real folder as before stage B."""
        project = self.root / f"{search.variable}-{'linked' if linked else 'plain'}" / "worktree"
        project.mkdir(parents=True)
        real_build = self.root / "scratch" / "builds" / search.variable if linked else project / ".build"
        for relative in search.files + search.decoys:
            path = real_build / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n", encoding="utf-8")
        if linked:
            (project / ".build").symlink_to(real_build, target_is_directory=True)
        return project

    def read_expression(self, search):
        text = search.script.read_text(encoding="utf-8")
        matches = [match.group("expression") for match in search.pattern.finditer(text)]
        self.assertEqual(
            len(matches), 1,
            f"{search.script.name} must hold exactly one line the test can read, found {len(matches)}",
        )
        return matches[0]

    def run_expression(self, expression, search, project):
        result = subprocess.run(
            ["/bin/bash", "-c", expression],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=TIMEOUT_SECONDS,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", search.variable: str(project)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return sorted(result.stdout.splitlines())

    def assert_search(self, search, transform, linked, finds):
        expression = transform(self.read_expression(search))
        project = self.make_project(search, linked)
        found = self.run_expression(expression, search, project)
        expected = sorted(str(project / ".build" / relative) for relative in search.expected) if finds else []
        self.assertEqual(found, expected, f"{search.script.name} ran {expression}")

    def test_find_follows_a_linked_build(self):
        self.assert_search(BUILD_APP_SEARCH, keep, linked=True, finds=True)

    def test_portable_tier_find_follows_a_linked_build(self):
        self.assert_search(PORTABLE_TIER_SEARCH, keep, linked=True, finds=True)

    def test_find_without_h_stops_at_a_linked_build(self):
        for search in ALL_SEARCHES:
            with self.subTest(script=search.script.name):
                self.assert_search(search, without_h, linked=True, finds=False)

    def test_find_with_h_follows_a_linked_build(self):
        for search in ALL_SEARCHES:
            with self.subTest(script=search.script.name):
                self.assert_search(search, with_h, linked=True, finds=True)

    def test_find_still_finds_in_an_unlinked_build(self):
        for search in ALL_SEARCHES:
            with self.subTest(script=search.script.name):
                self.assert_search(search, keep, linked=False, finds=True)


if __name__ == "__main__":
    unittest.main()
