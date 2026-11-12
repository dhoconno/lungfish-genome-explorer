"""Tests of scripts/session/preflight.py. They inject the command runner, so nothing reads the live machine."""
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "session" / "preflight.py"
spec = importlib.util.spec_from_file_location("session_preflight", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

GIB = 1024 * 1024
SCRATCH, HOME, TOP, A, B = "/Volumes/scratch", "/home/t", "/w/wt", "a" * 40, "b" * 40


def df(gib, mount):
    return 0, "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/d1 1948455240 1 %d 6%% %s\n" % (gib * GIB, mount)


def swap(used):
    return 0, "vm.swapusage: total = 2048.00M  used = %.2fM  free = 1.00M  (encrypted)\n" % used


def healthy():
    record = "# T\n\nThese are the technical notes of %s %s, and more.\n"
    return {
        ("df", "-Pk", HOME): df(300, "/System/Volumes/Data"), ("df", "-Pk", SCRATCH): df(1800, SCRATCH),
        ("df", "-Pk", "/"): df(200, "/"), ("sysctl", "vm.swapusage"): swap(100),
        ("tmutil", "listlocalsnapshots", "/"): (0, "Snapshots for disk /:\ncom.apple.TimeMachine.1.local\ncom.apple.TimeMachine.2.local\n"),
        ("ps", "-axo"): (0, "    1 02-19:28:43 /sbin/launchd\n  500 00:10 /usr/bin/python3 other.py\n"),
        ("uptime",): (0, " 3:24  up 2 days, 1 user, load averages: 17.16 8.06 4.88\n"),
        ("git", "worktree", "list", "--porcelain"): (0, "worktree /w/primary\nHEAD x\n\nworktree /w/wt\nHEAD y\n"),
        ("git", "worktree", "list"): (0, "/w/primary  %s [main]\n/w/wt  %s [x]\n" % (A[:9], B[:9])),
        ("git", "rev-parse", "--show-toplevel"): (0, TOP + "\n"),
        ("git", "rev-parse", "--verify", "--quiet", "main^{commit}"): (0, A + "\n"),
        ("git", "rev-parse", "--verify", "--quiet", "origin/main^{commit}"): (0, A + "\n"),
        ("git", "rev-list"): (0, "0\t0\n"),
        ("xcodebuild",): (0, ""),
        ("git", "tag", "--list"): (0, "v2026.11.7\nv2026.11.6\nnot-a-tag\n"),
        ("git", "show", "v2026.11.7:docs/reports/2026.11.7-technical.md"): (0, record % ("Stable", "2026.11.7")),
        ("git", "show", "v2026.11.6:docs/reports/2026.11.6-technical.md"): (0, record % ("Preview", "2026.11.6")),
        ("git", "rev-parse", "--verify", "--quiet", "v2026.11.7^{commit}"): (0, B + "\n"),
        ("git", "rev-parse", "--verify", "--quiet", "v2026.11.6^{commit}"): (0, A + "\n"),
    }


class Fake:
    """Map the first words of a command to (exit code, stdout). The longest match wins, an unknown command gives 127."""
    def __init__(self, table):
        self.table, self.calls = dict(table), []

    def __call__(self, argv, cwd=None, env=None, timeout=60):
        self.calls.append(list(argv))
        keys = [key for key in self.table if tuple(argv[:len(key)]) == key]
        return self.table[max(keys, key=len)] if keys else (127, "")


class PreflightTests(unittest.TestCase):
    def go(self, table, *args, cwd=TOP):
        fake = Fake(table)
        out = io.StringIO()
        with redirect_stdout(out):
            code = module.main(["--scratch", SCRATCH, *args], call=fake, cwd=cwd, home=HOME)
        return code, out.getvalue().splitlines(), fake

    def test_a_healthy_machine_passes_every_check_and_prints_the_facts(self):
        code, lines, _ = self.go(healthy())
        self.assertEqual(code, 0)
        self.assertEqual([l.split()[0] + " " + l.split()[1].rstrip(":") for l in lines[:9]], [
            "PASS disk", "PASS swap", "PASS scratch", "PASS processes", "PASS load", "PASS cwd", "PASS main-sync",
            "PASS xcode", "SKIP transcript"])
        facts = dict(l.split(": ", 1) for l in lines[10:] if l != "worktree: ")
        self.assertEqual(lines[9], "")
        self.assertEqual(facts["local_main"], A)
        self.assertEqual(facts["main_vs_origin"], "ahead 0, behind 0")
        self.assertEqual(facts["newest_stable"], "v2026.11.7 " + B)
        self.assertEqual(facts["newest_preview"], "v2026.11.6 " + A)
        self.assertEqual(facts["free_disk_root"], "200 GiB under /")
        self.assertEqual(facts["free_disk_scratch"], "1800 GiB under " + SCRATCH)
        self.assertEqual((facts["local_snapshots"], facts["worktree_count"]), ("2", "2"))

    def test_each_failing_condition_gives_one_act_line(self):
        cases = [
            ("disk", {("df", "-Pk", HOME): df(50, "/")}, "50 GiB free"),
            ("swap", {("sysctl", "vm.swapusage"): swap(1990)}, "97% used"),
            ("scratch", {("df", "-Pk", SCRATCH): (1, "")}, "is missing"),
            ("scratch", {("df", "-Pk", SCRATCH): df(100, "/")}, "mounted at /"),
            ("processes", {("ps", "-axo"): (0, "  600 01-00:00:00 /x/xctest -run\n")}, "600 (01-00:00:00)"),
            ("load", {("uptime",): (0, "up 1 day, load averages: 55.00 1 1\n")}, "55.0, over 40"),
            ("cwd", {("git", "rev-parse", "--show-toplevel"): (0, "/w/primary\n")}, "primary checkout /w/primary"),
            ("main-sync", {("git", "rev-list"): (0, "2\t0\n")}, "ahead 2 and behind 0"),
            ("main-sync", {("git", "rev-list"): (0, "0\t3\n")}, "ahead 0 and behind 3"),
            ("main-sync", {("git", "rev-list"): (128, "")}, "cannot be compared"),
            ("xcode", {("xcodebuild",): (1, "")}, "exits 1"),
        ]
        for name, change, words in cases:
            with self.subTest(name=name, words=words):
                code, lines, _ = self.go({**healthy(), **change})
                acts = [l for l in lines if l.startswith("ACT ")]
                self.assertEqual(code, 1)
                self.assertEqual(len(acts), 1, acts)
                self.assertTrue(acts[0].startswith("ACT %s: " % name), acts[0])
                self.assertIn(words, acts[0])

    def test_this_process_and_search_tools_are_not_leftovers(self):
        ps = "%d 00:01 /x/xctest\n 7 00:01 rg xctest\n 8 00:01 /usr/bin/grep swift-build\n 9 00:01 ps -axo xctest\n" % os.getpid()
        self.assertEqual(self.go({**healthy(), ("ps", "-axo"): (0, ps)})[0], 0)

    def test_the_program_worktree_option(self):
        self.assertEqual(self.go(healthy(), "--program-worktree", TOP)[0], 0)
        code, lines, _ = self.go(healthy(), "--program-worktree", "/w/other")
        self.assertEqual(code, 1)
        self.assertTrue(any(l.startswith("ACT cwd: ") and "not the program worktree /w/other" in l for l in lines))

    def test_git_fetch_runs_only_when_asked(self):
        fetch = ["git", "fetch", "--quiet", "--tags", "origin"]
        self.assertNotIn(fetch, self.go(healthy())[2].calls)
        code, _, fake = self.go({**healthy(), ("git", "fetch"): (0, "")}, "--fetch")
        self.assertEqual(code, 0)
        self.assertEqual(fake.calls.count(fetch), 1)
        _, lines, _ = self.go({**healthy(), ("git", "fetch"): (1, "")}, "--fetch")
        self.assertTrue(any(l.startswith("ACT main-sync: git fetch failed (exit 1)") for l in lines))

    def test_channel_facts_come_from_the_record_at_each_tag(self):
        table = healthy()
        table[("git", "tag", "--list")] = (0, "v2026.11.9\nv2026.11.8\nv2026.11.7\nv2026.11.6\n")
        table[("git", "show", "v2026.11.8:docs/reports/2026.11.8-technical.md")] = (0, "# T\n\nChannel: Preview\n")
        facts = dict(l.split(": ", 1) for l in self.go(table)[1][10:])
        self.assertEqual(facts["newest_preview"].split()[0], "v2026.11.8")
        self.assertEqual(facts["newest_stable"], "v2026.11.7 " + B)
        facts = dict(l.split(": ", 1) for l in self.go(table, "--max-tags", "1")[1][10:])
        self.assertEqual(facts["newest_stable"], "not found among the newest 1 tags")

    def test_worktree_facts_are_capped(self):
        rows = "".join("/w/t%d  %s [b%d]\n" % (i, A[:9], i) for i in range(30))
        lines = self.go({**healthy(), ("git", "worktree", "list"): (0, rows)})[1]
        self.assertIn("worktree_count: 30", lines)
        self.assertEqual(len([l for l in lines if l.startswith("worktree: ")]), 12)
        self.assertIn("worktree_more: 18 more, see git worktree list", lines)

    def test_doctor_lines_come_only_with_the_option(self):
        doctor = (sys.executable, TOP + "/scripts/release/release.py", "doctor")
        table = {**healthy(), doctor: (0, "noise\nPackage readiness: READY\nPublish readiness: NOT READY (no profile)\n")}
        _, lines, fake = self.go(table)
        self.assertFalse(any(l.startswith("doctor_") for l in lines))
        self.assertNotIn(list(doctor), fake.calls)
        _, lines, _ = self.go(table, "--doctor")
        self.assertIn("doctor_package: Package readiness: READY", lines)
        self.assertIn("doctor_publish: Publish readiness: NOT READY (no profile)", lines)
        self.assertIn("doctor_package: no readiness line (exit 127)", self.go(healthy(), "--doctor")[1])

    def test_the_transcript_check_finds_the_project_folder_to_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(os.path.realpath(tmp))
            (base / "proj-a" / "sid1" / "subagents").mkdir(parents=True)
            (base / "proj-a" / "sid1.jsonl").write_text("{}\n")
            (base / "proj-b" / "x" / "y").mkdir(parents=True)
            (base / "proj-b" / "x" / "y" / "sid2.jsonl").write_text("{}\n")
            args = ["--projects-dir", str(base), "--session-id"]
            _, lines, _ = self.go(healthy(), *args, "sid1", "--expected-project", "proj-a")
            self.assertIn("PASS transcript (under proj-a)", lines)
            self.assertIn("transcript_project_dir: %s" % (base / "proj-a"), lines)
            lines = self.go(healthy(), *args, "sid1", "--expected-project", str(base / "proj-a") + "/")[1]
            self.assertIn("PASS transcript (under proj-a)", lines)
            lines = self.go(healthy(), *args, "sid1", "--expected-project=-dash-name")[1]
            self.assertTrue(any(l.startswith("ACT transcript: the transcript lives under proj-a, not -dash-name") for l in lines))
            code, lines, _ = self.go(healthy(), *args, "sid1", "--expected-project", "proj-z")
            self.assertEqual(code, 1)
            self.assertTrue(any(l.startswith("ACT transcript: the transcript lives under proj-a, not proj-z") for l in lines))
            for sid in ("nothing", "sid2"):
                lines = self.go(healthy(), *args, sid)[1]
                self.assertTrue(any(l.startswith("ACT transcript: no entry named %s*" % sid) for l in lines), sid)

    def test_only_read_commands_are_run(self):
        calls = self.go(healthy(), "--doctor")[2].calls
        for argv in calls:
            self.assertIn(argv[0], {"df", "sysctl", "tmutil", "ps", "uptime", "git", "xcodebuild", sys.executable})
            if argv[0] == "git":
                self.assertIn(argv[1], {"worktree", "rev-parse", "rev-list", "tag", "show"})
            if argv[0] == "tmutil":
                self.assertEqual(argv[1], "listlocalsnapshots")
        for word in ("pkill", "killall", "os.kill", "rm -rf"):
            self.assertNotIn(word, SCRIPT.read_text())

    def test_parsers(self):
        self.assertEqual(module.parse_df("h\n/dev/x 10 1 2048 1% /Volumes/My Disk\n"), (2048, "/Volumes/My Disk"))
        self.assertIsNone(module.parse_df("df: /nope: No such file or directory\n"))
        self.assertAlmostEqual(module.parse_swap("total = 2.00G  used = 512.00M  free = 1.50G"), 25.0)
        self.assertEqual(module.parse_swap("total = 0.00M  used = 0.00M  free = 0.00M"), 0.0)
        self.assertIsNone(module.parse_swap("nonsense"))
        self.assertEqual(module.parse_load("load average: 1.5, 2.0, 3.0"), 1.5)
        self.assertEqual(module.parse_load("load averages: 17.16 8.06 4.88"), 17.16)
        self.assertEqual(module.find_transcripts("/nonexistent/dir", "x"), [])


if __name__ == "__main__":
    unittest.main()
