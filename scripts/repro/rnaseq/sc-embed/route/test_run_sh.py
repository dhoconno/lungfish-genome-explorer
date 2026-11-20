#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Self-check of run.sh's wait for a quiet machine (lane CM-REPRO, continuation 1).

run.sh runs under `set -euo pipefail`. Its function `wait_quiet` once ended its loop with
`[ $n -lt 2 ] && sleep 30`. On the check that finds the machine quiet for the second time that
list is false, so the loop and the function return 1, and `set -e` ended the whole chain
without a line in the log. This test takes the function out of run.sh as written, runs it in
/bin/bash with the same options and with `ps` and `sleep` stubbed, and asks for status 0 and
for the next step to run.

Run: /opt/homebrew/bin/python3 scripts/repro/rnaseq/sc-embed/route/test_run_sh.py
"""
import os
import re
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_SH = os.path.join(HERE, "run.sh")

# A `ps` stub that reports one build on its first call and nothing after, and one that reports
# only CM-KIND's X5 measure, which run.sh leaves out of the wait by default.
ONE_BUILD = 'if [ ! -e "$MARK" ]; then : > "$MARK"; echo "  123 /usr/bin/swift-build --build-tests"; fi'
X5_ONLY = (
    'echo "  70113 /usr/bin/swift-test --filter RNASeqCellMapGeneValuesTests/testTheX5CellMapBuildsUnderOneGiB"; '
    'echo "  71369 /usr/bin/xctest -XCTest X /w/agent-a27a57415dd18a53c/.build/LungfishWorkflowTests.xctest"'
)


def run_sh_source():
    with open(RUN_SH, encoding="utf-8") as handle:
        return handle.read()


def function_text(name):
    """The lines of the shell function `name`, as written in run.sh."""
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}\n", run_sh_source(), re.S | re.M)
    assert match, name + " is not in run.sh"
    return match.group(0)


def default_ignore():
    match = re.search(r"^IGNORE=.*$", run_sh_source(), re.M)
    assert match, "IGNORE is not set in run.sh"
    return match.group(0)


def run_in_shell(main, ps_body, functions=("wait_quiet",), extra=""):
    with tempfile.TemporaryDirectory() as folder:
        script = "\n".join(
            [
                "set -euo pipefail",
                "REPO=/no/such/checkout",
                default_ignore(),
                'log() { echo "run.sh: $*"; }',
                "sleep() { :; }",
                "ps() { " + ps_body + "; }",
                extra,
                *[function_text(name) for name in functions],
                main,
            ]
        )
        return subprocess.run(
            ["/bin/bash", "-c", script],
            capture_output=True,
            text=True,
            timeout=60,
            env={"PATH": "/usr/bin:/bin", "MARK": os.path.join(folder, "mark")},
        )


class WaitQuietTests(unittest.TestCase):
    def check_reached(self, result):
        detail = "status %d, stdout %r, stderr %r" % (result.returncode, result.stdout, result.stderr)
        self.assertEqual(result.returncode, 0, "the shell stopped inside or after wait_quiet: " + detail)
        self.assertIn("reached", result.stdout, detail)

    def test_a_quiet_machine_lets_the_wait_end_with_status_0(self):
        result = run_in_shell("wait_quiet; echo reached", ":")
        self.check_reached(result)
        self.assertNotIn("waiting", result.stdout)

    def test_a_build_is_waited_for_and_then_the_wait_ends_with_status_0(self):
        result = run_in_shell("wait_quiet; echo reached", ONE_BUILD)
        self.check_reached(result)
        self.assertEqual(result.stdout.count("waiting, another worktree builds"), 1, result.stdout)

    def test_the_x5_measure_named_by_default_is_not_waited_for(self):
        result = run_in_shell("wait_quiet; echo reached", X5_ONLY)
        self.check_reached(result)
        self.assertNotIn("waiting", result.stdout)

    def test_a_timed_run_goes_on_to_its_embed_after_the_wait(self):
        stubs = 'hostlog() { :; }\nembed() { echo "embed $*"; }'
        result = run_in_shell("timed g1-a 1 0 --x; echo reached", ":", ("wait_quiet", "timed"), stubs)
        self.check_reached(result)
        self.assertIn("embed g1-a 1 0 --x", result.stdout)


if __name__ == "__main__":
    unittest.main()
