"""Tests for scripts/session/build_slot.sh, the cold-build slots of RUN's Concurrency row (E-RUN-50).

Each test uses its own slot folder in a temporary folder, and a holder is a build that runs `cat` until
its stdin closes, so no test sleeps.
"""
import os
import re
import select
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "session" / "build_slot.sh"
TYPES = ROOT / ".claude" / "agents"
TIMEOUT = 30
FIRST_BUILD = "bash scripts/session/build_slot.sh SCR/build-slots swift build"


def slot_count():
    """The one constant SLOTS of the script, so the tests hold if a measurement lowers it."""
    found = re.search(r"^SLOTS=(\d+)", SCRIPT.read_text(), re.M) if SCRIPT.is_file() else None
    return int(found.group(1)) if found else 2


class BuildSlotTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.slots = os.path.join(temp.name, "build-slots")
        self.env = dict(os.environ, BUILD_SLOT_POLL="0.1")
        self.started = []
        self.addCleanup(self.end_all)

    def end_all(self):
        for proc in self.started:
            if proc.poll() is None:
                proc.kill()
            proc.communicate(timeout=TIMEOUT)

    def line_of(self, proc, stream):
        """One line of a child's stream, or a failure once TIMEOUT seconds pass with none."""
        ready, _, _ = select.select([stream], [], [], TIMEOUT)
        if not ready:
            self.fail(f"pid {proc.pid} wrote no line in {TIMEOUT} s")
        return stream.readline()

    def start(self, *command, stdin=None):
        proc = subprocess.Popen(["bash", str(SCRIPT), *command], stdin=stdin, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=self.env)
        self.started.append(proc)
        return proc

    def hold(self):
        """Start a build that holds a slot until its stdin closes, and return once it holds one."""
        proc = self.start(self.slots, "/bin/sh", "-c", "echo held; exec cat", stdin=subprocess.PIPE)
        self.assertEqual(self.line_of(proc, proc.stdout), "held\n")
        return proc

    def build(self, *command):
        return subprocess.run(["bash", str(SCRIPT), self.slots, *command], capture_output=True, text=True,
                              timeout=TIMEOUT, env=self.env)

    def status(self):
        result = subprocess.run(["bash", str(SCRIPT), "--status", self.slots], capture_output=True, text=True,
                                timeout=TIMEOUT)
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        return result.stdout.splitlines()

    def test_a_build_with_a_free_slot_runs_and_returns_its_exit_code(self):
        result = self.build("/bin/sh", "-c", "echo built; exit 3")
        self.assertEqual((result.returncode, result.stdout), (3, "built\n"))
        self.assertIn(f"holding slot-1 of {slot_count()}", result.stderr)
        self.assertEqual(self.status(), [f"slot-{n} free" for n in range(1, slot_count() + 1)])

    def test_a_held_slot_names_its_holder_and_frees_when_the_build_ends(self):
        holder = self.hold()
        self.assertTrue(self.status()[0].startswith(f"slot-1 held by {holder.pid} "), self.status())
        self.assertIn("/bin/sh -c echo held; exec cat", self.status()[0])
        holder.stdin.close()
        self.assertEqual(holder.wait(timeout=TIMEOUT), 0)
        self.assertEqual(self.status()[0], "slot-1 free")

    def test_a_build_waits_while_every_slot_is_held_and_runs_when_one_frees(self):
        holders = [self.hold() for _ in range(slot_count())]
        waiter = self.start(self.slots, "/bin/sh", "-c", "echo built")
        self.assertIn(f"all {slot_count()} slots", self.line_of(waiter, waiter.stderr))
        self.assertIsNone(waiter.poll())
        holders[0].stdin.close()
        out, err = waiter.communicate(timeout=TIMEOUT)
        self.assertEqual((waiter.returncode, out), (0, "built\n"))
        self.assertIn(f"holding slot-1 of {slot_count()}", err)

    def test_a_holder_stopped_by_sigkill_frees_its_slot_with_no_trap(self):
        holders = [self.hold() for _ in range(slot_count())]
        os.kill(holders[-1].pid, signal.SIGKILL)
        self.assertEqual(holders[-1].wait(timeout=TIMEOUT), -signal.SIGKILL)
        result = self.build("/bin/sh", "-c", "echo built")
        self.assertEqual((result.returncode, result.stdout), (0, "built\n"))
        self.assertIn(f"holding slot-{slot_count()} of {slot_count()}", result.stderr)
        self.assertNotIn("waiting", result.stderr)

    def test_a_command_line_with_no_command_or_no_folder_exits_2(self):
        for arguments in ([], [self.slots], ["--status"]):
            with self.subTest(arguments):
                result = subprocess.run(["bash", str(SCRIPT), *arguments], capture_output=True, text=True,
                                        timeout=TIMEOUT)
                self.assertEqual(result.returncode, 2)
                self.assertIn("usage", result.stderr)

    def test_the_building_types_take_a_slot_for_their_first_build(self):
        for name in ("lge-lane.md", "lge-lane-opus.md", "lge-fix.md"):
            with self.subTest(name):
                self.assertIn(FIRST_BUILD, (TYPES / name).read_text())


if __name__ == "__main__":
    unittest.main()
