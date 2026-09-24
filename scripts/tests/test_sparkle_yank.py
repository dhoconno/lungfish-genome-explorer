"""Tests for scripts/release/sparkle_yank.py and `release.py yank` (REL-04).

There is no supported way today to pull a bad Sparkle release back once
published: each publish overwrites the mutable per-channel appcast asset with
a fresh single-item appcast, and the build-number floor gate refuses to
republish anything at or below the live build (rejecting the obvious
"republish the previous commit" fix). This module is a pure plan computation
against two appcast XML documents; it never calls `gh` or touches network
state other than the read-only fetch in `release.py yank` itself, which
these tests avoid by exercising `plan_yank` directly and by stubbing the
network fetch for the CLI test.
"""

from __future__ import annotations

import importlib
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPTS_DIR = ROOT / "scripts" / "release"
if str(RELEASE_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(RELEASE_SCRIPTS_DIR))

import sparkle_yank  # noqa: E402


def make_appcast(version: int, short_version: str = "2026.9.1") -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Lungfish Preview Changelog</title>
    <item>
      <title>Version {short_version}</title>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
      <enclosure url="https://example.invalid/Lungfish.dmg" sparkle:edSignature="abc=" length="1000" type="application/octet-stream"/>
    </item>
  </channel>
</rss>'''


class ParseAppcastItemsTests(unittest.TestCase):
    def test_parses_single_item_fields(self):
        items = sparkle_yank.parse_appcast_items(make_appcast(4025, "2026.9.38"))
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].sparkle_version, 4025)
        self.assertEqual(items[0].short_version, "2026.9.38")

    def test_rejects_appcast_with_no_items(self):
        empty = '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel></channel></rss>'
        with self.assertRaises(sparkle_yank.YankError):
            sparkle_yank.parse_appcast_items(empty)

    def test_rejects_item_missing_sparkle_version(self):
        malformed = (
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            "<channel><item><title>no version</title></item></channel></rss>"
        )
        with self.assertRaises(sparkle_yank.YankError):
            sparkle_yank.parse_appcast_items(malformed)


class PlanYankTests(unittest.TestCase):
    def test_plan_restores_older_build_and_reports_both_versions(self):
        plan = sparkle_yank.plan_yank(
            channel="preview",
            sparkle_release="sparkle-beta",
            appcast_filename="appcast-beta.xml",
            live_appcast_xml=make_appcast(4025, "2026.9.38"),
            restore_appcast_xml=make_appcast(4024, "2026.9.37"),
        )

        self.assertEqual(plan.bad_item.sparkle_version, 4025)
        self.assertEqual(plan.restored_item.sparkle_version, 4024)
        self.assertEqual(plan.channel, "preview")
        self.assertEqual(plan.sparkle_release, "sparkle-beta")
        self.assertTrue(len(plan.steps) >= 5)

        rendered = plan.render()
        self.assertIn("4025", rendered)
        self.assertIn("4024", rendered)
        self.assertIn("2026.9.38", rendered)
        self.assertIn("2026.9.37", rendered)
        self.assertIn("Withdrawn", rendered)

    def test_refuses_to_yank_forward(self):
        # If the "restore" appcast is not actually older than the live one,
        # this is not a yank -- it would publish forward, which is what the
        # ordinary publish path already does under the floor gate.
        with self.assertRaises(sparkle_yank.YankError):
            sparkle_yank.plan_yank(
                channel="preview",
                sparkle_release="sparkle-beta",
                appcast_filename="appcast-beta.xml",
                live_appcast_xml=make_appcast(4024),
                restore_appcast_xml=make_appcast(4025),
            )

    def test_refuses_equal_versions(self):
        with self.assertRaises(sparkle_yank.YankError):
            sparkle_yank.plan_yank(
                channel="preview",
                sparkle_release="sparkle-beta",
                appcast_filename="appcast-beta.xml",
                live_appcast_xml=make_appcast(4025),
                restore_appcast_xml=make_appcast(4025),
            )

    def test_refuses_multi_item_live_appcast(self):
        two_items = make_appcast(4025).replace(
            "</channel>",
            "<item><sparkle:version>4024</sparkle:version></item></channel>",
        )
        with self.assertRaises(sparkle_yank.YankError):
            sparkle_yank.plan_yank(
                channel="preview",
                sparkle_release="sparkle-beta",
                appcast_filename="appcast-beta.xml",
                live_appcast_xml=two_items,
                restore_appcast_xml=make_appcast(4023),
            )


class ExecuteYankTests(unittest.TestCase):
    def test_execute_is_not_implemented_and_never_mutates_anything(self):
        plan = sparkle_yank.plan_yank(
            channel="preview",
            sparkle_release="sparkle-beta",
            appcast_filename="appcast-beta.xml",
            live_appcast_xml=make_appcast(4025),
            restore_appcast_xml=make_appcast(4024),
        )
        with self.assertRaises(NotImplementedError):
            sparkle_yank.execute_yank(plan)


class ReleasePyYankCommandTests(unittest.TestCase):
    """Exercises `release.py yank` end to end with the network fetch stubbed."""

    def setUp(self):
        self.release = importlib.import_module("release")

    def test_dry_run_prints_plan_and_does_not_execute(self):
        import tempfile
        import io
        import contextlib
        import urllib.request

        live_xml = make_appcast(4025, "2026.9.38").encode()
        restore_xml = make_appcast(4024, "2026.9.37")

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return live_xml

        def fake_urlopen(request, timeout=30):
            return FakeResponse()

        with tempfile.TemporaryDirectory() as temp_dir:
            restore_path = Path(temp_dir) / "appcast-beta.xml"
            restore_path.write_text(restore_xml, encoding="utf-8")

            original_urlopen = urllib.request.urlopen
            urllib.request.urlopen = fake_urlopen
            try:
                buffer = io.StringIO()
                with contextlib.redirect_stdout(buffer):
                    result = self.release.run_yank(ROOT, "preview", restore_path, execute=False)
            finally:
                urllib.request.urlopen = original_urlopen

        self.assertEqual(result, 0)
        output = buffer.getvalue()
        self.assertIn("4025", output)
        self.assertIn("4024", output)
        self.assertIn("dry run", output)


if __name__ == "__main__":
    unittest.main()
