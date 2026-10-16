from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release" / "check-sparkle-build-number.py"


class AppcastHTTPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/missing.xml":
            self.send_error(404)
            return
        if self.path == "/server-error.xml":
            self.send_error(500)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.end_headers()
        if self.path == "/current.xml":
            self.wfile.write(
                b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                b"<channel><item><sparkle:version>4025</sparkle:version></item></channel>"
                b"</rss>"
            )
        else:
            self.wfile.write(b"not XML")

    def log_message(self, format, *args):
        pass


class SparkleBuildNumberGateTests(unittest.TestCase):
    def run_gate(self, planned: str, current: str, *extra_args: str):
        with tempfile.TemporaryDirectory() as temp_dir:
            appcast = Path(temp_dir) / "appcast.xml"
            appcast.write_text(
                f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item><sparkle:version>{current}</sparkle:version></item></channel>
</rss>\n''',
                encoding="utf-8",
            )
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--planned", planned, "--appcast", str(appcast), *extra_args],
                text=True,
                capture_output=True,
                check=False,
            )

    def run_url_gate(self, path: str, *extra_args: str):
        server = ThreadingHTTPServer(("127.0.0.1", 0), AppcastHTTPHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}{path}"
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--planned",
                    "4025",
                    "--appcast-url",
                    url,
                    *extra_args,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_accepts_strictly_greater_build_number(self):
        self.assertEqual(self.run_gate("4025", "4024").returncode, 0)

    def test_rejects_equal_or_lower_build_number(self):
        for planned in ("4024", "4023"):
            result = self.run_gate(planned, "4024")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must exceed live Sparkle build", result.stderr)

    def test_rejects_non_positive_or_non_numeric_build_number(self):
        for planned in ("0", "beta"):
            self.assertNotEqual(self.run_gate(planned, "4024").returncode, 0)

    def test_yank_marker_keeps_the_floor_at_the_withdrawn_build(self):
        # A yank removes the bad item and restores an older one, but
        # leaves an lge:yanked marker so the floor never drops below the
        # withdrawn build.
        with tempfile.TemporaryDirectory() as temp_dir:
            appcast = Path(temp_dir) / "appcast.xml"
            appcast.write_text(
                '<?xml version="1.0"?>'
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
                'xmlns:lge="urn:lungfish-genome-explorer:release"><channel>'
                "<item><sparkle:version>4024</sparkle:version></item>"
                '<lge:yanked build="4025" version="2026.9.38" date="2026-09-24"/>'
                "</channel></rss>\n",
                encoding="utf-8",
            )
            for planned, expected in (("4025", False), ("4024", False), ("4026", True)):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--planned", planned, "--appcast", str(appcast)],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(result.returncode == 0, expected, (planned, result.stderr))

    def test_equal_build_number_is_rejected(self):
        result = self.run_gate("4024", "4024")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exceed live Sparkle build", result.stderr)

    def test_there_is_no_yank_equality_escape_hatch(self):
        result = self.run_gate("4024", "4024", "--yank")
        self.assertNotEqual(result.returncode, 0)

    def test_http_not_found_is_rejected_by_default(self):
        result = self.run_url_gate("/missing.xml")

        self.assertEqual(result.returncode, 64)
        self.assertIn("HTTP Error 404", result.stderr)

    def test_explicit_flag_tolerates_http_not_found(self):
        result = self.run_url_gate("/missing.xml", "--allow-http-not-found")

        self.assertEqual(result.returncode, 0)
        self.assertIn("no existing appcast", result.stdout)

    def test_explicit_flag_does_not_tolerate_other_http_errors(self):
        result = self.run_url_gate("/server-error.xml", "--allow-http-not-found")

        self.assertEqual(result.returncode, 64)
        self.assertIn("HTTP Error 500", result.stderr)

    def test_explicit_flag_does_not_tolerate_malformed_appcast(self):
        result = self.run_url_gate("/malformed.xml", "--allow-http-not-found")

        self.assertEqual(result.returncode, 64)
        self.assertIn("Sparkle build-number gate failed", result.stderr)

    def test_explicit_flag_still_enforces_existing_appcast_build_number(self):
        result = self.run_url_gate("/current.xml", "--allow-http-not-found")

        self.assertEqual(result.returncode, 64)
        self.assertIn("must exceed live Sparkle build 4025", result.stderr)


CANDIDATE_VERSION = "2026.10.19"
CANDIDATE_ENCLOSURE = (
    "https://github.com/example/lungfish/releases/download/"
    "v2026.10.19/Lungfish-2026.10.19-arm64.dmg"
)
RECOVERY_VERSION_ENV = "LUNGFISH_SPARKLE_RECOVERY_VERSION"
RECOVERY_ENCLOSURE_ENV = "LUNGFISH_SPARKLE_RECOVERY_ENCLOSURE_URL"
RECOVERY_CONTEXT = {
    RECOVERY_VERSION_ENV: CANDIDATE_VERSION,
    RECOVERY_ENCLOSURE_ENV: CANDIDATE_ENCLOSURE,
}


def appcast_item(build, version=CANDIDATE_VERSION, enclosure=CANDIDATE_ENCLOSURE):
    return (
        f"<item><title>{version}</title>"
        f"<sparkle:version>{build}</sparkle:version>"
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
        f'<enclosure url="{enclosure}" length="175105926" '
        'type="application/octet-stream"/></item>'
    )


class SparkleBuildNumberRecoveryTests(unittest.TestCase):
    """Q2: in recovery the floor accepts the candidate's own live item.

    The coordinator names the candidate through two environment variables, so
    the floors inside the builder, which release.py cannot give arguments,
    see the same context. Without both variables the floor is the strict one.
    """

    def run_recovery_gate(self, planned, body, context=RECOVERY_CONTEXT):
        with tempfile.TemporaryDirectory() as temp_dir:
            appcast = Path(temp_dir) / "appcast.xml"
            appcast.write_text(
                '<?xml version="1.0"?>'
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
                'xmlns:lge="urn:lungfish-genome-explorer:release">'
                f"<channel>{body}</channel></rss>\n",
                encoding="utf-8",
            )
            environment = {
                key: value
                for key, value in os.environ.items()
                if key not in RECOVERY_CONTEXT
            }
            environment.update(context or {})
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--planned", planned, "--appcast", str(appcast)],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )

    def test_recovery_accepts_the_live_item_that_is_the_candidates_own(self):
        body = appcast_item(9046) + appcast_item(9035, "2026.10.18", "https://example.test/old.dmg")

        result = self.run_recovery_gate("9046", body)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("passed in recovery", result.stdout)
        self.assertIn("build 9046", result.stdout)

    def test_the_candidates_own_item_is_refused_outside_recovery(self):
        result = self.run_recovery_gate("9046", appcast_item(9046), context={})

        self.assertEqual(result.returncode, 64)
        self.assertIn("must exceed live Sparkle build 9046", result.stderr)

    def test_recovery_refuses_a_different_build_of_the_same_number(self):
        # Another version, another enclosure, or two items where only one is ours.
        cases = {
            "another version": appcast_item(9046, "2026.10.18"),
            "another enclosure": appcast_item(
                9046, enclosure="https://example.test/Lungfish-2026.10.19-arm64.dmg"
            ),
            "no enclosure": (
                "<item><sparkle:version>9046</sparkle:version>"
                f"<sparkle:shortVersionString>{CANDIDATE_VERSION}</sparkle:shortVersionString></item>"
            ),
            "a second item at the same build": appcast_item(9046)
            + appcast_item(9046, "2026.10.18", "https://example.test/other.dmg"),
            "a yank marker at the planned build": (
                '<lge:yanked build="9046" version="2026.10.19" date="2026-10-16"/>'
                + appcast_item(9035, "2026.10.18", "https://example.test/old.dmg")
            ),
        }
        for label, body in cases.items():
            with self.subTest(label):
                result = self.run_recovery_gate("9046", body)

                self.assertEqual(result.returncode, 64, result.stdout)
                self.assertIn("must exceed live Sparkle build 9046", result.stderr)
                self.assertIn("not this candidate", result.stderr)

    def test_recovery_never_lowers_the_floor_below_a_higher_live_build(self):
        body = appcast_item(9046) + appcast_item(9047, "2026.10.20", "https://example.test/next.dmg")

        result = self.run_recovery_gate("9046", body)

        self.assertEqual(result.returncode, 64)
        self.assertIn("must exceed live Sparkle build 9047", result.stderr)

    def test_recovery_leaves_a_higher_planned_build_as_it_was(self):
        result = self.run_recovery_gate("9046", appcast_item(9035, "2026.10.18", "https://example.test/old.dmg"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("passed: 9046 > 9035", result.stdout)

    def test_half_a_recovery_context_is_refused_even_for_a_higher_planned_build(self):
        for name in RECOVERY_CONTEXT:
            with self.subTest(name):
                result = self.run_recovery_gate(
                    "9046",
                    appcast_item(9035, "2026.10.18", "https://example.test/old.dmg"),
                    context={name: RECOVERY_CONTEXT[name]},
                )

                self.assertEqual(result.returncode, 64)
                self.assertIn("recovery needs both", result.stderr)


if __name__ == "__main__":
    unittest.main()
