"""Tests for scripts/release/sparkle_yank.py and `release.py yank` (REL-04, D17).

Every GitHub or network call goes through a fake YankRunner. Nothing here
contacts GitHub.
"""

from __future__ import annotations

import contextlib
import importlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPTS_DIR = ROOT / "scripts" / "release"
if str(RELEASE_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(RELEASE_SCRIPTS_DIR))

import sparkle_yank  # noqa: E402

BAD = "2026.9.38"
GOOD = "2026.9.37"
BAD_BUILD = 4025
GOOD_BUILD = 4024
DMG_LENGTH = 1000


def item_xml(build: int, version: str, length: int = DMG_LENGTH) -> str:
    return f"""
    <item>
      <title>Version {version}</title>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <enclosure url="https://github.com/example/lge/releases/download/v{version}/Lungfish-{version}.dmg" sparkle:edSignature="abc=" length="{length}" type="application/octet-stream"/>
    </item>"""


def make_appcast(*items: str) -> bytes:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Lungfish Preview Changelog</title>{''.join(items)}
  </channel>
</rss>""".encode()


def release(version: str, *, prerelease: bool = True, name: str | None = None, size: int = DMG_LENGTH) -> dict:
    return {
        "tagName": f"v{version}",
        "name": name or f"Lungfish Genome Explorer Preview {version}",
        "body": f"Notes for {version}.",
        "isPrerelease": prerelease,
        "assets": [{"name": f"Lungfish-{version}.dmg", "size": size}],
    }


class FakeRunner:
    """In-memory GitHub: feeds, releases and a call log."""

    def __init__(self, feeds, releases, latest_full=None, apply_uploads=True):
        self.feeds = dict(feeds)
        self.releases = dict(releases)
        self.latest_full = latest_full
        self.apply_uploads = apply_uploads
        self.uploads = []
        self.edits = []

    def fetch_appcast(self, release_name, filename):
        return self.feeds.get((release_name, filename))

    def release_info(self, tag):
        info = self.releases.get(tag)
        return dict(info) if info is not None else None

    def latest_full_release_tag(self):
        return self.latest_full

    def upload_appcast(self, release_name, filename, content):
        self.uploads.append((release_name, filename, content))
        if self.apply_uploads:
            self.feeds[(release_name, filename)] = content

    def mark_release_yanked(self, tag, title, body):
        self.edits.append((tag, title, body))
        info = self.releases[tag]
        info.update(name=title, body=body, isPrerelease=True)


def preview_runner(**overrides):
    feeds = {
        ("sparkle-beta", "appcast-beta.xml"): make_appcast(item_xml(BAD_BUILD, BAD)),
        ("sparkle-alpha", "appcast-alpha.xml"): make_appcast(item_xml(BAD_BUILD, BAD)),
    }
    releases = {f"v{BAD}": release(BAD), f"v{GOOD}": release(GOOD)}
    kwargs = {"feeds": feeds, "releases": releases, "latest_full": "v2026.9.28"}
    kwargs.update(overrides)
    return FakeRunner(**kwargs)


class ReleaseYankCommandTests(unittest.TestCase):
    def setUp(self):
        self.release = importlib.import_module("release")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "config").mkdir()
        shutil.copy(ROOT / "config/release-contract.json", self.root / "config/release-contract.json")
        self.restore_path = self.root / "restore-appcast-beta.xml"
        self.restore_path.write_bytes(make_appcast(item_xml(GOOD_BUILD, GOOD)))

    def yank(self, runner, *, version=BAD, channel="preview", typed=None, **kwargs):
        prompts = []

        def prompt(text):
            prompts.append(text)
            if typed is None:
                raise EOFError
            return typed

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            result = self.release.run_yank(
                self.root, channel, version, runner=runner, prompt=prompt, **kwargs
            )
        return result, buffer.getvalue(), prompts

    def feed(self, runner, release_name="sparkle-beta", filename="appcast-beta.xml"):
        return runner.feeds[(release_name, filename)]

    # -- dry run ---------------------------------------------------------

    def test_dry_run_prints_plan_and_changes_nothing(self):
        runner = preview_runner()
        result, output, prompts = self.yank(runner, restore_appcast_path=self.restore_path)

        self.assertEqual(result, 0)
        self.assertEqual(prompts, [])
        self.assertEqual(runner.uploads, [])
        self.assertEqual(runner.edits, [])
        self.assertIn("Dry run: nothing was changed", output)
        self.assertIn(f"remove v{BAD} item (build {BAD_BUILD})", output)
        self.assertIn(f"restore v{GOOD}", output)
        self.assertIn("Follow-up: Sparkle cannot downgrade", output)
        self.assertIn(f"must exceed {BAD_BUILD}", output)
        self.assertFalse((self.root / "build").exists())

    # -- confirmation ----------------------------------------------------

    def test_confirmation_mismatch_changes_nothing(self):
        for typed in ("2026.9.37", "v2026.9.38", "", None):
            with self.subTest(typed=typed):
                runner = preview_runner()
                with self.assertRaises(self.release.ReleaseError) as ctx:
                    self.yank(runner, restore_appcast_path=self.restore_path, execute=True, typed=typed)
                self.assertIn("nothing was changed", str(ctx.exception))
                self.assertEqual(runner.uploads, [])
                self.assertEqual(runner.edits, [])
                self.assertFalse((self.root / "build").exists())

    # -- execution -------------------------------------------------------

    def test_execute_removes_item_restores_good_item_and_marks_release(self):
        runner = preview_runner()
        result, output, prompts = self.yank(
            runner, restore_appcast_path=self.restore_path, execute=True, typed=BAD, reason="crashes on launch."
        )

        self.assertEqual(result, 0)
        self.assertEqual(len(prompts), 1)
        self.assertIn(BAD, prompts[0])
        for release_name, filename in (("sparkle-beta", "appcast-beta.xml"), ("sparkle-alpha", "appcast-alpha.xml")):
            after = self.feed(runner, release_name, filename)
            items = sparkle_yank.parse_appcast_items(after)
            self.assertEqual([item.short_version for item in items], [GOOD], filename)
            self.assertEqual(sparkle_yank.yank_markers(after), [(BAD_BUILD, BAD)])
            self.assertEqual(sparkle_yank.appcast_build_floor(after), BAD_BUILD)
        self.assertEqual({upload[1] for upload in runner.uploads}, {"appcast-beta.xml", "appcast-alpha.xml"})

        self.assertEqual(len(runner.edits), 1)
        tag, title, body = runner.edits[0]
        self.assertEqual(tag, f"v{BAD}")
        self.assertTrue(title.startswith("Yanked: "))
        self.assertIn("crashes on launch.", body)
        self.assertIn(f"Notes for {BAD}.", body)
        self.assertTrue(runner.releases[f"v{BAD}"]["isPrerelease"])

        evidence = list((self.root / "build/Release/preview" / f"yank-{BAD}").iterdir())
        self.assertEqual(len(evidence), 1)
        names = {path.name for path in evidence[0].iterdir()}
        self.assertIn("sparkle-beta-appcast-beta.xml.before.xml", names)
        self.assertIn("sparkle-beta-appcast-beta.xml.after.xml", names)
        self.assertIn("release.before.json", names)
        self.assertIn("plan.txt", names)
        self.assertIn("Follow-up", output)

    def test_yanked_feed_still_blocks_republishing_the_yanked_build(self):
        runner = preview_runner()
        self.yank(runner, restore_appcast_path=self.restore_path, execute=True, typed=BAD)
        appcast = self.root / "after.xml"
        appcast.write_bytes(self.feed(runner))
        gate = RELEASE_SCRIPTS_DIR / "check-sparkle-build-number.py"
        for planned, passes in ((GOOD_BUILD + 0, False), (BAD_BUILD, False), (BAD_BUILD + 1, True)):
            result = subprocess.run(
                [sys.executable, str(gate), "--planned", str(planned), "--appcast", str(appcast)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode == 0, passes, (planned, result.stderr))

    def test_rerun_after_success_is_a_no_op(self):
        runner = preview_runner()
        self.yank(runner, restore_appcast_path=self.restore_path, execute=True, typed=BAD)
        uploads, edits = len(runner.uploads), len(runner.edits)

        result, output, _ = self.yank(runner, execute=True, typed=BAD)

        self.assertEqual(result, 0)
        self.assertEqual(len(runner.uploads), uploads)
        self.assertEqual(len(runner.edits), edits)
        self.assertIn("already yanked, no change", output)
        self.assertIn("already marked yanked", output)

    def test_rerun_finishes_release_edit_after_interrupted_run(self):
        runner = preview_runner()
        self.yank(runner, restore_appcast_path=self.restore_path, execute=True, typed=BAD)
        runner.releases[f"v{BAD}"] = release(BAD)  # simulate the edit never landing
        runner.edits.clear()

        self.yank(runner, execute=True, typed=BAD)

        self.assertEqual(len(runner.edits), 1)

    def test_execute_fails_loudly_when_live_feed_still_offers_the_build(self):
        runner = preview_runner(apply_uploads=False)
        with self.assertRaises(self.release.ReleaseError) as ctx:
            self.yank(runner, restore_appcast_path=self.restore_path, execute=True, typed=BAD)
        self.assertIn("Re-run the same yank command", str(ctx.exception))
        self.assertEqual(runner.edits, [])

    # -- refusals --------------------------------------------------------

    def test_refuses_to_yank_the_only_item_without_restore_or_force(self):
        runner = preview_runner()
        with self.assertRaises(self.release.ReleaseError) as ctx:
            self.yank(runner)
        self.assertIn("no <item>", str(ctx.exception))

    def test_force_allows_an_empty_feed_that_keeps_the_floor(self):
        runner = preview_runner()
        result, output, _ = self.yank(runner, execute=True, typed=BAD, force=True)
        self.assertEqual(result, 0)
        after = self.feed(runner)
        self.assertEqual(sparkle_yank.parse_appcast_items(after), [])
        self.assertEqual(sparkle_yank.appcast_build_floor(after), BAD_BUILD)
        self.assertIn("will offer no update at all", output)

    def test_removing_one_of_several_items_needs_no_restore(self):
        feeds = {
            ("sparkle-stable", "appcast-stable.xml"): make_appcast(
                item_xml(BAD_BUILD, BAD), item_xml(GOOD_BUILD, GOOD)
            ),
        }
        runner = FakeRunner(feeds, {f"v{BAD}": release(BAD, prerelease=False)}, latest_full="v2026.9.28")
        result, _, _ = self.yank(runner, channel="stable", execute=True, typed=BAD)
        self.assertEqual(result, 0)
        items = sparkle_yank.parse_appcast_items(self.feed(runner, "sparkle-stable", "appcast-stable.xml"))
        self.assertEqual([item.sparkle_version for item in items], [GOOD_BUILD])
        self.assertEqual([upload[0] for upload in runner.uploads], ["sparkle-stable"])

    def test_refuses_the_current_stable_baseline_without_force(self):
        feeds = {("sparkle-stable", "appcast-stable.xml"): make_appcast(item_xml(BAD_BUILD, BAD))}
        releases = {f"v{BAD}": release(BAD, prerelease=False), f"v{GOOD}": release(GOOD, prerelease=False)}
        runner = FakeRunner(feeds, releases, latest_full=f"v{BAD}")
        with self.assertRaises(self.release.ReleaseError) as ctx:
            self.yank(runner, channel="stable", restore_appcast_path=self.restore_path)
        self.assertIn("current Stable baseline", str(ctx.exception))

        result, output, _ = self.yank(
            runner, channel="stable", restore_appcast_path=self.restore_path, force=True
        )
        self.assertEqual(result, 0)
        self.assertIn("previous full release becomes the baseline", output)

    def test_refuses_a_version_the_feed_does_not_offer(self):
        runner = preview_runner()
        runner.releases[f"v{GOOD}"] = release(GOOD)
        with self.assertRaises(self.release.ReleaseError) as ctx:
            self.yank(runner, version=GOOD, force=True)
        self.assertIn("nothing for Sparkle to stop offering", str(ctx.exception))

    def test_refuses_a_missing_github_release(self):
        runner = preview_runner(releases={})
        with self.assertRaises(self.release.ReleaseError):
            self.yank(runner, force=True)

    def test_refuses_restore_item_that_is_not_older(self):
        self.restore_path.write_bytes(make_appcast(item_xml(BAD_BUILD + 1, "2026.9.39")))
        runner = preview_runner()
        runner.releases["v2026.9.39"] = release("2026.9.39")
        with self.assertRaises(self.release.ReleaseError) as ctx:
            self.yank(runner, restore_appcast_path=self.restore_path)
        self.assertIn("not older", str(ctx.exception))

    def test_refuses_restore_item_whose_dmg_is_missing_or_changed(self):
        cases = {
            "missing release": {},
            "missing asset": {f"v{GOOD}": dict(release(GOOD), assets=[])},
            "size mismatch": {f"v{GOOD}": release(GOOD, size=DMG_LENGTH + 1)},
            "restore target yanked": {f"v{GOOD}": release(GOOD, name=f"Yanked: {GOOD}")},
        }
        for label, restore_releases in cases.items():
            with self.subTest(label):
                runner = preview_runner(releases={f"v{BAD}": release(BAD), **restore_releases})
                with self.assertRaises(self.release.ReleaseError):
                    self.yank(runner, restore_appcast_path=self.restore_path)

    def test_rejects_malformed_version(self):
        with self.assertRaises(self.release.ReleaseError):
            self.yank(preview_runner(), version=f"v{BAD}")


class AppcastHelperTests(unittest.TestCase):
    def test_parses_item_fields(self):
        items = sparkle_yank.parse_appcast_items(make_appcast(item_xml(BAD_BUILD, BAD)))
        self.assertEqual(items[0].sparkle_version, BAD_BUILD)
        self.assertEqual(items[0].short_version, BAD)
        self.assertEqual(items[0].enclosure_length, DMG_LENGTH)

    def test_rejects_item_missing_sparkle_version(self):
        with self.assertRaises(sparkle_yank.YankError):
            sparkle_yank.parse_appcast_items(make_appcast("<item><title>no version</title></item>"))

    def test_floor_counts_markers(self):
        appcast = make_appcast(item_xml(GOOD_BUILD, GOOD)).replace(
            b"</channel>",
            b'<lge:yanked xmlns:lge="urn:lungfish-genome-explorer:release" build="4030" version="x"/></channel>',
        )
        self.assertEqual(sparkle_yank.appcast_build_floor(appcast), 4030)


if __name__ == "__main__":
    unittest.main()
