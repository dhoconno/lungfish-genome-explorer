"""A patch release: package stable and publish stable on a branch cut from the newest Stable tag.

docs/contracts/VERIFICATION-ORDER.md (row A stable release) runs a patch release on a branch cut from the last Stable
tag. These tests build a small repository with real git, a bare origin beside it and three Sparkle feeds that a fake
floor checker reads, then drive LocalReleaseOperations as package stable and publish stable do. The pins at the end
hold a Preview package and publish, and a stable release from main, to the commands, words and floors of today.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from scripts.tests.test_release_frontdoor import load_module


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
GIT_ENVIRONMENT = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Patch Test",
    "GIT_AUTHOR_EMAIL": "patch-test@example.invalid",
    "GIT_COMMITTER_NAME": "Patch Test",
    "GIT_COMMITTER_EMAIL": "patch-test@example.invalid",
    "GIT_TERMINAL_PROMPT": "0",
}
PATCH_LINES = (
    "Previous versioned release: v2026.11.7",
    "Stable baseline: v2026.11.7",
    "Includes no Preview. It patches v2026.11.7.",
)


def notes_text(version, channel, previous, baseline, included=None):
    text = (
        f"# Lungfish {version}\n\nChannel: {channel}\n\nPrevious versioned release: {previous}\n\n"
        f"Stable baseline: {baseline}\n\nDependency set: 2026.2\n\nWhat changed.\n\n"
    )
    if included is not None:
        text += f"## Included preview releases\n\n{included}\n\n"
    return text + "## Dependency versions\n\nMAFFT: 7.526\n"


PATCH_NOTES = notes_text("2026.11.9", "Stable", "v2026.11.7", "v2026.11.7", "Includes no Preview. It patches v2026.11.7.")


class PatchRepository:
    """main: v2026.11.6 (Preview, count 1), v2026.11.7 (Stable, count 2), v2026.11.8 (Preview, count 3) and two record
    commits, so origin main counts 5. stable-patch: one commit on v2026.11.7 with the fix and the 2026.11.9 notes."""

    def __init__(self, base: Path):
        self.base = base
        self.work = base / "work"
        self.origin = base / "origin.git"
        self.work.mkdir()
        self.git("init", "-q", "-b", "main")
        self.write(MANIFEST, json.dumps({"dependencySet": "2026.2"}))
        self.release("2026.11.6", "Preview", "v2026.11.5", "v2026.10.29")
        self.release("2026.11.7", "Stable", "v2026.11.6", "v2026.10.29", "Includes Previews 2026.11.1 to 2026.11.6.")
        self.release("2026.11.8", "Preview", "v2026.11.7", "v2026.11.7")
        self.commit("records", {"docs/records.md": "one\n"})
        self.commit("records two", {"docs/records.md": "two\n"})
        self.git("switch", "-q", "-c", "stable-patch", "v2026.11.7")
        self.commit("patch", {"fix.txt": "fixed\n", "docs/release-notes/2026.11.9.md": PATCH_NOTES})
        self.git("clone", "-q", "--bare", str(self.work), str(self.origin), cwd=base)
        self.git("remote", "add", "origin", str(self.origin))
        self.git("fetch", "-q", "origin")

    def git(self, *arguments, cwd=None):
        result = subprocess.run(["git", *arguments], cwd=cwd or self.work, env={**os.environ, **GIT_ENVIRONMENT},
                                text=True, capture_output=True, check=False)
        if result.returncode != 0:
            raise AssertionError(f"git {' '.join(arguments)} failed: {result.stderr}")
        return result.stdout.strip()

    def write(self, relative, text):
        path = self.work / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, message, files):
        for relative, text in files.items():
            self.write(relative, text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def release(self, version, channel, previous, baseline, included=None):
        self.commit(version, {f"docs/release-notes/{version}.md": notes_text(version, channel, previous, baseline, included)})
        self.git("tag", "-a", f"v{version}", "-m", f"Lungfish v{version}")

    def head(self):
        return self.git("rev-parse", "HEAD")


class FeedRunner:
    """The release runner on the fixture: git runs for real, the Sparkle floor checker reads the feeds below, gh finds
    no release, and every command is recorded."""

    def __init__(self, release, root, feeds, environment=None):
        self.inner = release.SubprocessRunner(root, {**GIT_ENVIRONMENT, **(environment or {})})
        self.environment = self.inner.environment
        self.release = release
        self.feeds = feeds
        self.commands = []

    def run(self, command, *, capture=False, env=None, check=True, timeout=None):
        self.commands.append(list(command))
        if len(command) > 1 and command[1].endswith("check-sparkle-build-number.py"):
            planned = int(command[command.index("--planned") + 1])
            floor = self.feeds[command[command.index("--appcast-url") + 1].rsplit("/", 1)[1]]
            status = 0 if planned > floor else 64
            if check and status:
                raise self.release.ReleaseError(f"command failed with exit {status}: {command[0]}")
            return subprocess.CompletedProcess(command, status, "", "")
        if command[0] == "gh":
            return subprocess.CompletedProcess(command, 1, "", "release not found")
        return self.inner.run(command, capture=capture, env=env, check=check, timeout=timeout)

    def text(self, command):
        return self.run(command, capture=True).stdout or ""


REAL_POPEN = subprocess.Popen


class FakeBuilder:
    """Stands in for the builder process alone, and lets git run."""

    started = []

    def __new__(cls, command, *arguments, **kwargs):
        if list(command[:1]) != ["/bin/echo"]:
            return REAL_POPEN(command, *arguments, **kwargs)
        FakeBuilder.started.append((list(command), kwargs))
        return super().__new__(cls)

    def __init__(self, command, *arguments, **kwargs):
        self.pid = 4242
        self.returncode = None

    def poll(self):
        return None


class PatchFixture(unittest.TestCase):
    def setUp(self):
        self.release = load_module()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.repository = PatchRepository(self.base)
        self.feeds = {"appcast-alpha.xml": 1, "appcast-beta.xml": 3, "appcast-stable.xml": 2}
        self.receipt = self.base / "receipt.json"
        self.receipt.write_text(json.dumps({"release": {"build": "4"}}), encoding="utf-8")

    def operations(self, environment=None):
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root = self.repository.work
        operations.contract = self.release.load_contract(ROOT / "config/release-contract.json")
        operations.runner = FeedRunner(self.release, self.repository.work, self.feeds, environment)
        return operations

    def request(self, channel="stable", mode="package"):
        return self.release.ReleaseRequest(
            root=self.repository.work, channel=channel, mode=mode, receipt=self.receipt, remote="origin",
            main_branch="main", signing_identity="", team_id="", notary_profile="",
            sparkle_generate_appcast=Path("/unresolved/generate_appcast"), sparkle_ed_key_file=None,
            dependency_receipt=self.base / "dependency.json", release_dir=self.base / "release" / "candidate",
            prune_prereleases=False, prune_prereleases_keep=10, github_repository="example/lungfish",
        )

    def identity(self):
        return self.release.CandidateIdentity(receipt=self.receipt, tag="v2026.11.9", commit=self.repository.head(),
                                              version="2026.11.9", scratch_path=self.base / "scratch")

    def start_build(self, operations, request):
        FakeBuilder.started = []
        operations._package_command = lambda _request, gate_arguments: ["/bin/echo", *gate_arguments]
        source = {"clean": True, "commit": self.repository.head()}
        with mock.patch.object(self.release, "source_identity", return_value=source), \
                mock.patch.object(self.release, "prepare_identity_plist", return_value=self.base / "cli.plist"), \
                mock.patch.object(self.release.subprocess, "Popen", FakeBuilder):
            build = operations.start_package_build(request)
        operations._close_handoff(build)
        self.assertEqual(len(FakeBuilder.started), 1)
        return FakeBuilder.started[0]

    def floor_commands(self, operations):
        return [command for command in operations.runner.commands
                if len(command) > 1 and command[1].endswith("check-sparkle-build-number.py")]


class PatchModeTests(PatchFixture):
    # Package.

    def test_package_stamps_origin_main_count_less_one_after_checking_both_feeds(self):
        operations = self.operations()
        request = self.request()
        operations.verify_package_source(request)
        _command, arguments = self.start_build(operations, request)
        self.assertEqual(arguments["env"]["LUNGFISH_BUILD_NUMBER"], "4")
        floors = self.floor_commands(operations)
        self.assertEqual([command[command.index("--appcast-url") + 1].rsplit("/", 2)[1:] for command in floors],
                         [["sparkle-alpha", "appcast-alpha.xml"], ["sparkle-beta", "appcast-beta.xml"],
                          ["sparkle-stable", "appcast-stable.xml"]])
        self.assertTrue(all(command[command.index("--planned") + 1] == "4" for command in floors))

    def test_package_refuses_a_build_no_feed_floor_leaves_room_for(self):
        self.feeds["appcast-beta.xml"] = 4
        operations = self.operations()
        request = self.request()
        operations.verify_package_source(request)
        with self.assertRaisesRegex(self.release.ReleaseError, r"patch build 4 .*origin main.*5.*feed"):
            self.start_build(operations, request)
        self.assertEqual(FakeBuilder.started, [])

    def test_package_refuses_a_build_number_set_in_the_shell(self):
        operations = self.operations({"LUNGFISH_BUILD_NUMBER": "99999"})
        with self.assertRaisesRegex(self.release.ReleaseError, "LUNGFISH_BUILD_NUMBER"):
            operations.verify_package_source(self.request())

    def test_package_refuses_a_patch_version_that_is_not_newer_than_every_release_tag(self):
        self.repository.git("mv", "docs/release-notes/2026.11.9.md", "docs/release-notes/2026.11.8.md")
        self.repository.write("docs/release-notes/2026.11.8.md", PATCH_NOTES.replace("2026.11.9", "2026.11.8"))
        self.repository.commit("taken version", {})
        with self.assertRaisesRegex(self.release.ReleaseError, r"patch version 2026\.11\.8 .*v2026\.11\.8"):
            self.operations().verify_package_source(self.request())

    def test_package_refuses_patch_notes_without_each_patch_line(self):
        for line in PATCH_LINES:
            with self.subTest(line=line):
                self.repository.write("docs/release-notes/2026.11.9.md",
                                      PATCH_NOTES.replace(line + "\n", line.replace("v2026.11.7", "v2026.11.8") + "\n"))
                with self.assertRaisesRegex(self.release.ReleaseError, "patch release notes .*" + line.split(":")[0]):
                    self.operations().verify_package_source(self.request())

    def test_package_refuses_when_origin_holds_a_release_tag_this_checkout_lacks(self):
        main = self.repository.git("rev-parse", "main")
        self.repository.git("tag", "v2026.11.10", main, cwd=self.repository.origin)
        with self.assertRaisesRegex(self.release.ReleaseError, r"v2026\.11\.10.*git fetch --tags origin"):
            self.operations().verify_package_source(self.request())

    def test_package_checks_that_the_receipt_holds_the_stamped_build(self):
        operations = self.operations()
        request = self.request()
        operations.verify_package_source(request)
        self.start_build(operations, request)
        operations._verify_patch_receipt(self.receipt)
        self.receipt.write_text(json.dumps({"release": {"build": "3"}}), encoding="utf-8")
        with self.assertRaisesRegex(self.release.ReleaseError, "receipt build 3 .* 4"):
            operations._verify_patch_receipt(self.receipt)

    # Publish.

    def test_publish_takes_the_patch_branch_and_checks_the_receipt_build_against_origin_main(self):
        operations = self.operations()
        operations.verify_source_history(self.request(mode="publish"))
        self.receipt.write_text(json.dumps({"release": {"build": "5"}}), encoding="utf-8")
        with self.assertRaisesRegex(self.release.ReleaseError, r"patch build 5 is not below origin main's count 5"):
            operations.verify_source_history(self.request(mode="publish"))

    def test_publish_refuses_when_origin_holds_a_release_tag_this_checkout_lacks(self):
        main = self.repository.git("rev-parse", "main")
        self.repository.git("tag", "v2026.11.10", main, cwd=self.repository.origin)
        with self.assertRaisesRegex(self.release.ReleaseError, r"v2026\.11\.10.*git fetch --tags origin"):
            self.operations().verify_source_history(self.request(mode="publish"))

    def test_publish_floors_read_the_receipt_build_on_every_stable_feed(self):
        operations = self.operations()
        operations.validate_sparkle_build_number(self.request(mode="publish"), self.identity())
        floors = self.floor_commands(operations)
        self.assertEqual(len(floors), 3)
        self.assertTrue(all(command[command.index("--planned") + 1] == "4" for command in floors))
        self.feeds["appcast-beta.xml"] = 4
        with self.assertRaisesRegex(self.release.ReleaseError, "command failed with exit 64"):
            self.operations().validate_sparkle_build_number(self.request(mode="publish"), self.identity())

    def test_publish_tags_the_patch_commit_and_pushes_the_patch_branch_with_the_tag(self):
        operations = self.operations()
        operations.ensure_annotated_tag(self.request(mode="publish"), self.identity())
        pushes = [command for command in operations.runner.commands if command[:2] == ["git", "push"]]
        self.assertEqual(pushes, [["git", "push", "--atomic", "origin", "stable-patch", "v2026.11.9"]])
        self.assertEqual(self.repository.git("rev-parse", "refs/tags/v2026.11.9^{commit}", cwd=self.repository.origin),
                         self.repository.head())
        self.assertEqual(self.repository.git("rev-parse", "refs/heads/main", cwd=self.repository.origin),
                         self.repository.git("rev-parse", "main"))
        # A rerun finds its own tag on HEAD, which is not a later release tag, and pushes nothing.
        rerun = self.operations()
        rerun.verify_source_history(self.request(mode="publish"))
        rerun.ensure_annotated_tag(self.request(mode="publish"), self.identity())
        self.assertFalse([command for command in rerun.runner.commands if command[:2] == ["git", "push"]])

    # Sources that are not a patch keep today's words.

    def test_a_branch_that_holds_a_later_release_tag_keeps_the_main_refusal(self):
        self.repository.git("switch", "-q", "-c", "from-preview", "v2026.11.8")
        self.repository.commit("patch on a preview", {"docs/release-notes/2026.11.9.md": PATCH_NOTES})
        with self.assertRaisesRegex(self.release.ReleaseError, "^release source must be on main, not from-preview$"):
            self.operations().verify_source_history(self.request(mode="publish"))
        with self.assertRaisesRegex(self.release.ReleaseError, "^release source must be on main, not from-preview$"):
            self.operations().ensure_annotated_tag(self.request(mode="publish"), self.identity())

    def test_a_branch_from_an_older_stable_tag_keeps_the_main_refusal(self):
        self.repository.git("switch", "-q", "-c", "from-old", "v2026.11.6")
        self.repository.commit("patch on an old release", {"docs/release-notes/2026.11.9.md": PATCH_NOTES})
        with self.assertRaisesRegex(self.release.ReleaseError, "^release source must be on main, not from-old$"):
            self.operations().verify_source_history(self.request(mode="publish"))

    def test_a_preview_on_the_patch_branch_keeps_the_main_refusal_and_stamps_nothing(self):
        operations = self.operations()
        with self.assertRaisesRegex(self.release.ReleaseError, "^release source must be on main, not stable-patch$"):
            operations.verify_source_history(self.request(channel="preview", mode="publish"))
        self.repository.write("docs/release-notes/2026.11.9.md", PATCH_NOTES.replace("Channel: Stable", "Channel: Preview"))
        operations = self.operations()
        request = self.request(channel="preview")
        operations.verify_package_source(request)
        self.assertEqual(operations.runner.commands, [["git", "rev-parse", "--is-shallow-repository"],
                                                      ["git", "branch", "--show-current"]])
        _command, arguments = self.start_build(operations, request)
        self.assertNotIn("LUNGFISH_BUILD_NUMBER", arguments["env"])


class TodayPinTests(PatchFixture):
    """A Preview package and publish, and a stable release from main, run the commands of today, word for word."""

    def on_main(self, version=None, channel="Preview"):
        self.repository.git("switch", "-q", "main")
        if version is not None:
            included = "Includes Previews 2026.11.8 to 2026.11.9." if channel == "Stable" else None
            self.repository.commit(version, {f"docs/release-notes/{version}.md":
                                             notes_text(version, channel, "v2026.11.8", "v2026.11.7", included)})
        return self.repository.head()

    def floor(self, release, filename, planned, *extra):
        return [sys.executable, str(self.release.SCRIPT_DIR / "check-sparkle-build-number.py"), "--planned", planned,
                "--appcast-url", f"https://github.com/example/lungfish/releases/download/{release}/{filename}", *extra]

    def test_package_source_on_main_runs_two_commands(self):
        for channel, version in (("preview", None), ("stable", "2026.11.10")):
            with self.subTest(channel=channel):
                self.on_main(version, "Stable")
                operations = self.operations()
                operations.verify_package_source(self.request(channel=channel))
                self.assertEqual(operations.runner.commands, [["git", "rev-parse", "--is-shallow-repository"],
                                                              ["git", "branch", "--show-current"]])

    def test_source_history_on_main_runs_todays_commands(self):
        head = self.on_main()
        main = self.repository.git("rev-parse", "origin/main")
        for channel in ("preview", "stable"):
            with self.subTest(channel=channel):
                operations = self.operations()
                operations.verify_source_history(self.request(channel=channel, mode="publish"))
                self.assertEqual(operations.runner.commands, [
                    ["git", "rev-parse", "--is-shallow-repository"],
                    ["git", "branch", "--show-current"],
                    ["git", "rev-parse", "HEAD"],
                    ["git", "ls-remote", "--heads", "origin", "refs/heads/main"],
                    ["git", "merge-base", "--is-ancestor", main, head],
                ])

    def test_a_branch_publish_keeps_todays_words(self):
        self.repository.git("switch", "-q", "-c", "feature", "main")
        for channel in ("preview", "stable"):
            with self.subTest(channel=channel):
                with self.assertRaisesRegex(self.release.ReleaseError, "^release source must be on main, not feature$"):
                    self.operations().verify_source_history(self.request(channel=channel, mode="publish"))

    def test_floors_run_todays_argv_from_the_receipt_build(self):
        self.on_main()
        self.receipt.write_text(json.dumps({"release": {"build": "6"}}), encoding="utf-8")
        identity = self.release.CandidateIdentity(receipt=self.receipt, tag="v2026.11.10", commit="a" * 40,
                                                  version="2026.11.10", scratch_path=self.base / "scratch")
        draft = ["gh", "release", "view", "v2026.11.10", "--json", "isDraft"]
        cases = (
            ("preview", [draft, self.floor("sparkle-alpha", "appcast-alpha.xml", "6"),
                         self.floor("sparkle-beta", "appcast-beta.xml", "6")]),
            ("stable", [draft, self.floor("sparkle-alpha", "appcast-alpha.xml", "6"),
                        self.floor("sparkle-beta", "appcast-beta.xml", "6"),
                        self.floor("sparkle-stable", "appcast-stable.xml", "6", "--allow-http-not-found")]),
        )
        for channel, expected in cases:
            with self.subTest(channel=channel):
                operations = self.operations({"LUNGFISH_BUILD_NUMBER": "99999"})
                operations.validate_sparkle_build_number(self.request(channel=channel, mode="publish"), identity)
                self.assertEqual(operations.runner.commands, expected)

    def test_package_floor_without_a_receipt_reads_the_shell_or_the_count(self):
        self.on_main()
        operations = self.operations()
        operations.validate_sparkle_build_number(self.request(channel="preview"))
        self.assertEqual(operations.runner.commands, [["git", "rev-list", "--count", "HEAD"],
                                                      self.floor("sparkle-alpha", "appcast-alpha.xml", "5"),
                                                      self.floor("sparkle-beta", "appcast-beta.xml", "5")])
        operations = self.operations({"LUNGFISH_BUILD_NUMBER": "77"})
        operations.validate_sparkle_build_number(self.request(channel="preview"))
        self.assertEqual(operations.runner.commands, [self.floor("sparkle-alpha", "appcast-alpha.xml", "77"),
                                                      self.floor("sparkle-beta", "appcast-beta.xml", "77")])

    def test_tag_and_push_of_a_preview_run_todays_commands(self):
        head = self.on_main("2026.11.10")
        identity = self.release.CandidateIdentity(receipt=self.receipt, tag="v2026.11.10", commit=head,
                                                  version="2026.11.10", scratch_path=self.base / "scratch")
        operations = self.operations()
        operations.ensure_annotated_tag(self.request(channel="preview", mode="publish"), identity)
        remote_tag = ["git", "ls-remote", "--tags", "origin", "refs/tags/v2026.11.10", "refs/tags/v2026.11.10^{}"]
        self.assertEqual(operations.runner.commands, [
            ["git", "branch", "--show-current"],
            remote_tag,
            ["gh", "release", "view", "v2026.11.10"],
            ["git", "cat-file", "-t", "v2026.11.10"],
            ["git", "tag", "-a", "v2026.11.10", head, "-m", "Lungfish v2026.11.10"],
            ["git", "push", "--atomic", "origin", "main", "v2026.11.10"],
            remote_tag,
        ])
        self.assertEqual(self.repository.git("rev-parse", "refs/heads/main", cwd=self.repository.origin), head)

    def test_package_build_of_a_preview_gets_todays_argv_and_environment(self):
        self.on_main()
        for environment in ({}, {"LUNGFISH_BUILD_NUMBER": "77"}):
            with self.subTest(environment=environment):
                operations = self.operations(environment)
                request = self.request(channel="preview")
                operations.verify_package_source(request)
                operations.runner.commands.clear()
                command, arguments = self.start_build(operations, request)
                self.assertEqual(command[:2], ["/bin/echo", "--gate-handoff-fd"])
                self.assertEqual(arguments["env"], {**operations.runner.environment,
                                                    "LUNGFISH_CLI_INFOPLIST_FILE": str(self.base / "cli.plist")})
                self.assertEqual(operations.runner.commands, [])

    def test_package_command_argv_is_todays(self):
        operations = self.operations()
        cache = SimpleNamespace(swiftpm=Path("/cache/swiftpm"), derived_data=Path("/cache/derived"))
        operations._cache_paths = lambda _request: cache
        request = self.request(channel="preview")
        self.assertEqual(operations._package_command(request, ["--gate-handoff-fd", "9"]), [
            "/bin/bash", str(self.release.SCRIPT_DIR / "build-notarized-dmg.sh"), "--package-only",
            "--gate-handoff-fd", "9", "--channel", "preview", "--release-dir", str(request.release_dir.resolve()),
            "--archive-path", str(request.release_dir.resolve() / "Lungfish.xcarchive"),
            "--derived-data-path", "/cache/derived", "--scratch-path", "/cache/swiftpm",
            "--sparkle-public-ed-key", request.sparkle_public_ed_key, "--remote", "origin",
            "--github-repository", "example/lungfish",
        ])

    def test_notes_checks_of_a_preview_and_of_a_stable_release_from_main_are_todays(self):
        self.on_main("2026.11.10", "Stable")
        self.operations().verify_package_source(self.request(channel="stable"))
        self.repository.write("docs/release-notes/2026.11.10.md",
                              notes_text("2026.11.10", "Stable", "v2026.11.8", "v2026.11.7"))
        with self.assertRaisesRegex(self.release.ReleaseError,
                                    "^release notes are missing required audit field: ## Included preview releases"):
            self.operations().verify_package_source(self.request(channel="stable"))
        self.repository.write("docs/release-notes/2026.11.10.md",
                              notes_text("2026.11.10", "Preview", "v2026.11.8", "v2026.11.7"))
        self.operations().verify_package_source(self.request(channel="preview"))


if __name__ == "__main__":
    unittest.main()
