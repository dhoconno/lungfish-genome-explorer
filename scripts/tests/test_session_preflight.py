"""Tests of scripts/session/preflight.py. They inject the command runner, so nothing reads the live machine."""
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "session" / "preflight.py"
LEDGER = Path(__file__).resolve().parents[1] / "llm" / "session_ledger.py"
spec = importlib.util.spec_from_file_location("session_preflight", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

GIB = 1024 * 1024
SCRATCH, HOME, TOP, A, B = "/Volumes/scratch", "/home/t", "/w/wt", "a" * 40, "b" * 40
AGENT_FILES = {"lge-fix.md": b"fix\n", "lge-lane.md": b"lane\n"}
PRIMARY, _tmp = "", None


def setUpModule():
    """A throwaway folder stands for the primary checkout and holds the agent types of main."""
    global PRIMARY, _tmp
    _tmp = tempfile.TemporaryDirectory()
    PRIMARY = os.path.realpath(_tmp.name)
    agents = Path(PRIMARY) / ".claude" / "agents"
    agents.mkdir(parents=True)
    for name, data in AGENT_FILES.items():
        (agents / name).write_bytes(data)


def tearDownModule():
    _tmp.cleanup()


def tree(files):
    """The git ls-tree rows of main for a map of agent file names to their bytes."""
    return "".join("100644 blob %s\t.claude/agents/%s\n" % (module.blob_id(data), name) for name, data in files.items())


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
        ("git", "worktree", "list", "--porcelain"): (0, "worktree %s\nHEAD %s\nbranch refs/heads/claude/x\n\nworktree /w/wt\nHEAD %s\n"
                                                      % (PRIMARY, B, A)),
        ("git", "ls-tree", "main", ".claude/agents/"): (0, tree(AGENT_FILES)),
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
        self.assertEqual([l.split()[0] + " " + l.split()[1].rstrip(":") for l in lines[:11]], [
            "PASS disk", "PASS swap", "PASS scratch", "PASS processes", "PASS load", "PASS cwd", "PASS main-sync",
            "PASS agents", "PASS xcode", "SKIP transcript", "SKIP effort"])
        facts = dict(l.split(": ", 1) for l in lines[12:] if l != "worktree: ")
        self.assertEqual(lines[11], "")
        self.assertEqual(facts["primary_head"], "%s claude/x (%s)" % (B, PRIMARY))
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
            ("cwd", {("git", "rev-parse", "--show-toplevel"): (0, PRIMARY + "\n")}, "primary checkout " + PRIMARY),
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
        facts = dict(l.split(": ", 1) for l in self.go(table)[1][12:])
        self.assertEqual(facts["newest_preview"].split()[0], "v2026.11.8")
        self.assertEqual(facts["newest_stable"], "v2026.11.7 " + B)
        facts = dict(l.split(": ", 1) for l in self.go(table, "--max-tags", "1")[1][12:])
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
                self.assertIn(argv[1], {"worktree", "rev-parse", "rev-list", "tag", "show", "ls-tree"})
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


PLAN = ("# Plan\n\n| Lane | What it does | Proof |\n|---|---|---|\n| SWEEP-1, SWEEP-2 | sweeps | table |\n"
        "| PROBES | probes | rows |\n")
OWNERS = ("# Owner directions\n\n| Id | Date | The owner's words | Binds |\n|---|---|---|---|\n"
          "| O171 | 2026-11-11 | \"Have experts decide.\" | Experts decide in the owner's absence |\n"
          "| 2.9 O5 | 2026-10-12 | \"Use live tests.\" | Real tool runs first |\n")
TEMPLATE = "# START {{taken}}\n{{facts}}\nThe plan is {{plan}}, lanes {{scope}}.\n{{owner}}\nBudget {{budget}}, records {{records}}.\n"


class StartPromptTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(os.path.realpath(tmp.name))
        for name, text in (("plan.md", PLAN), ("owners.md", OWNERS), ("t.md", TEMPLATE), ("bad.md", TEMPLATE + "{{what}}\n")):
            (self.dir / name).write_text(text)

    def fill(self, *args, table=None, template="t.md"):
        """(exit code, stdout, stderr, the file written or None) of a fill in the throwaway folder."""
        out, err = io.StringIO(), io.StringIO()
        base = ["--scratch", SCRATCH, "--start", template, "--plan", "plan.md", "--owner-file", "owners.md", "--out", "out.md"]
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = module.main(base + list(args), call=Fake(table or healthy()), cwd=str(self.dir), home=HOME)
            except SystemExit as stop:
                code = stop.code
        written = self.dir / "out.md"
        return code, out.getvalue(), err.getvalue(), written.read_text() if written.exists() else None

    def test_the_template_is_filled_from_the_facts_and_the_ids(self):
        code, out, _, text = self.fill("--scope", "SWEEP-1,PROBES", "--owner", "O171,2.9 O5")
        self.assertEqual(code, 0)
        self.assertIn("START prompt written to out.md (%d of 4096 bytes)" % len(text.encode()), out)
        for part in ("checks: 9 PASS, 2 SKIP (transcript, effort)", "local_main: " + A, "The plan is plan.md, lanes SWEEP-1, PROBES.",
                     "- O171 (2026-11-11) Experts decide in the owner's absence", "- 2.9 O5 (2026-10-12) Real tool runs first",
                     "Budget as the Budget line of the plan sets, records " + str(self.dir)):
            self.assertIn(part, text)
        self.assertNotIn("{{", text)
        self.assertIn("none since the plan", self.fill("--scope", "PROBES")[3])

    def test_an_act_line_is_written_in_full_and_sets_the_exit_code(self):
        code, _, _, text = self.fill("--scope", "PROBES", table={**healthy(), ("df", "-Pk", HOME): df(50, "/")})
        self.assertEqual(code, 1)
        self.assertIn("checks: 8 PASS, 2 SKIP (transcript, effort), 1 ACT (disk)", text)
        self.assertIn("ACT disk: 50 GiB free", text)

    def test_agent_worktrees_are_counted_and_left_out_of_the_facts(self):
        rows = "/w/primary  %s [main]\n/w/wt  %s [x]\n" % (A[:9], B[:9]) + "".join(
            "/w/p/.claude/worktrees/agent-%d  %s [b%d]\n" % (i, A[:9], i) for i in range(3))
        text = self.fill("--scope", "PROBES", table={**healthy(), ("git", "worktree", "list"): (0, rows)})[3]
        self.assertIn("worktree_count: 5", text)
        self.assertNotIn("agent-0", text)
        self.assertIn("worktree_more: 3 more, 3 of them agent worktrees, see git worktree list", text)

    def test_a_fill_over_the_limit_or_with_a_bad_input_writes_nothing(self):
        cases = [
            (("--scope", "PROBES", "--budget", "x" * 5000), "t.md", "over the limit of 4096"),
            (("--scope", "PROBES", "--max-start-bytes", "300"), "t.md", "over the limit of 300"),
            (("--scope", "NOPE"), "t.md", "NOPE not at the head of a table row of plan.md"),
            (("--scope", "PROBES", "--owner", "O999"), "t.md", "O999 not found in owners.md"),
            (("--scope", "PROBES"), "bad.md", "unknown field(s) {{what}}"),
            ((), "t.md", "--start also needs --scope"),
        ]
        for args, template, words in cases:
            with self.subTest(words=words):
                code, _, err, text = self.fill(*args, template=template)
                self.assertEqual(code, 2)
                self.assertIn(words, err)
                self.assertIsNone(text)
        with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            module.main(["--scope", "PROBES"], call=Fake(healthy()), cwd=str(self.dir), home=HOME)
        self.assertIn("belong to --start", err.getvalue())

    def test_the_real_template_fits_the_limit_on_a_busy_machine(self):
        lanes = ["LANE-%d" % i for i in range(8)]
        (self.dir / "plan.md").write_text("| Lane | x |\n|---|---|\n" + "".join("| %s | does a thing |\n" % item for item in lanes))
        binds = "A direction that binds the session, long enough to stand for a real one of about one hundred characters"
        (self.dir / "owners.md").write_text("| Id | Date | Words | Binds |\n|---|---|---|---|\n" + "".join(
            "| O%d | 2026-11-11 | \"w\" | %s |\n" % (i, binds) for i in range(3)))
        rows = "".join("/w/folder-%d/with/a/long/path  %s [a-long-branch-name]\n" % (i, A[:9]) for i in range(20))
        names = {"lge-t%d.md" % i: b"t" for i in range(9)}
        doctor = (sys.executable, TOP + "/scripts/release/release.py", "doctor")
        table = {**healthy(), ("git", "worktree", "list"): (0, rows), ("git", "ls-tree", "main", ".claude/agents/"): (0, tree({**AGENT_FILES, **names})),
                 doctor: (0, "Package readiness: READY\nPublish readiness: NOT READY (no profile)\n")}
        code, _, err, text = self.fill("--doctor", "--scope", ",".join(lanes), "--owner", "O0,O1,O2", "--budget", "about $660 and 34 points of the week",
                                       "--records", "/Users/someone/lungfish-phase-records/a-session-folder", table=table,
                                       template=str(SCRIPT.parent / "start-template.md"))
        self.assertEqual((code, err), (1, ""))
        self.assertIn("ACT agents: ", text)
        self.assertNotIn("{{", text)
        self.assertLessEqual(len(text.encode()), 4096)


class AgentsCheckTests(unittest.TestCase):
    def lines(self, change):
        out = io.StringIO()
        with redirect_stdout(out):
            module.main(["--scratch", SCRATCH], call=Fake({**healthy(), **change}), cwd=TOP, home=HOME)
        return out.getvalue().splitlines()

    def test_each_way_the_primary_differs_from_main_gives_one_act_line(self):
        old = "worktree /w/old\nHEAD %s\nbranch refs/heads/old\n\nworktree /w/wt\n" % A
        listing = ("git", "ls-tree", "main", ".claude/agents/")
        cases = [
            ({listing: (0, tree({**AGENT_FILES, "lge-new.md": b"n\n"}))}, "lacks 1 agent type(s) of main (lge-new.md)"),
            ({listing: (0, tree({**AGENT_FILES, "lge-lane.md": b"changed\n"}))}, "holds another copy of 1 (lge-lane.md)"),
            ({("git", "worktree", "list", "--porcelain"): (0, old)}, "lacks 2 agent type(s) of main (lge-fix.md, lge-lane.md)"),
        ]
        for change, words in cases:
            with self.subTest(words=words):
                acts = [l for l in self.lines(change) if l.startswith("ACT ")]
                self.assertEqual(len(acts), 1, acts)
                self.assertTrue(acts[0].startswith("ACT agents: the primary checkout "), acts[0])
                self.assertIn(words, acts[0])
                self.assertIn("so they need it at main", acts[0])

    def test_a_missing_comparison_skips_and_an_extra_type_is_no_fault(self):
        lines = self.lines({("git", "ls-tree", "main", ".claude/agents/"): (0, "")})
        self.assertIn("SKIP agents: main holds no .claude/agents/ to compare with", lines)
        lines = self.lines({("git", "worktree", "list", "--porcelain"): (128, "")})
        self.assertIn("SKIP agents: git worktree list named no primary checkout", lines)
        extra = Path(PRIMARY) / ".claude" / "agents" / "old.md"
        extra.write_bytes(b"x")
        self.addCleanup(extra.unlink)
        self.assertTrue(any(l.startswith("PASS agents") for l in self.lines({})))

    def test_the_worktree_listing_and_the_blob_id(self):
        text = "worktree /p\nHEAD abc\nbranch refs/heads/x/y\n\nworktree /q\nHEAD def\nlocked why\ndetached\n"
        self.assertEqual(module.parse_worktrees(text), [("/p", "abc", "x/y"), ("/q", "def", "detached")])
        self.assertEqual(module.blob_id(b"hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a")


class EffortCheckTests(unittest.TestCase):
    """The effort check reads the manager's own effort from its main transcript as session_ledger.py does (commit
    3bf5c2230), and gives ACT when it is not max (O177 Q4)."""
    SID = "11111111-2222-3333-4444-555555555555"
    STAMP = "2026-11-14T12:00:00.000Z"

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(os.path.realpath(tmp.name))

    def entry(self, uuid, effort=None, **fields):
        row = {"type": "user", "uuid": uuid, "timestamp": self.STAMP, "message": {"role": "user", "content": "x"}}
        row.update(fields)
        if effort:
            row["effort"] = effort
        return row

    def transcript(self, efforts, folder="proj-a", extra=(), first=0):
        """Write the main transcript of the session, one entry for each of `efforts` (None leaves the field out) with
        uuids that count up from `first`, then the `extra` entries."""
        rows = [self.entry("u%d" % (first + i), effort) for i, effort in enumerate(efforts)] + list(extra)
        path = self.base / folder / (self.SID + ".jsonl")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        return path

    def check(self, *args, sid=None):
        """(exit code, the lines of the effort check, all lines) of a run that reads the temporary projects folder."""
        out = io.StringIO()
        argv = ["--scratch", SCRATCH, "--projects-dir", str(self.base), "--session-id", sid or self.SID, *args]
        with redirect_stdout(out):
            code = module.main(argv, call=Fake(healthy()), cwd=TOP, home=HOME)
        lines = out.getvalue().splitlines()
        return code, [l for l in lines if re.match(r"(PASS|ACT|SKIP) effort\b", l)], lines

    def test_a_manager_at_max_passes(self):
        self.transcript(["max", "max", "max"])
        code, found, _ = self.check()
        self.assertEqual((code, len(found)), (0, 1))
        self.assertTrue(found[0].startswith("PASS effort ("), found)
        self.assertIn("max", found[0])

    def test_a_manager_below_max_gets_one_act_line_that_names_its_effort(self):
        self.transcript(["xhigh", "xhigh", "high"])
        code, found, lines = self.check()
        self.assertEqual((code, len(found)), (1, 1))
        self.assertTrue(found[0].startswith("ACT effort: "), found)
        self.assertIn("xhigh", found[0])
        self.assertIn("not max", found[0])
        self.assertIn("manager_effort: xhigh 2, high 1", lines)

    def test_no_effort_record_or_no_transcript_skips(self):
        self.transcript([None, None])
        code, found, _ = self.check()
        self.assertEqual((code, len(found)), (0, 1))
        self.assertTrue(found[0].startswith("SKIP effort: "), found)
        code, found, lines = self.check(sid="no-such-session")
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].startswith("SKIP effort: "), found)
        self.assertEqual([l.split(":")[0] for l in lines if l.startswith("ACT ")], ["ACT transcript"])

    def test_the_wanted_effort_is_an_option(self):
        self.transcript(["xhigh", "xhigh"])
        code, found, _ = self.check("--manager-effort", "xhigh")
        self.assertEqual(code, 0)
        self.assertTrue(found[0].startswith("PASS effort"), found)

    def test_the_reading_equals_the_ledgers_for_copies_sidechains_and_nested_fields(self):
        spec = importlib.util.spec_from_file_location("session_ledger", LEDGER)
        ledger = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ledger)
        noise = ([self.entry("s%d" % i, "low", isSidechain=True) for i in range(6)] +
                 [self.entry("a%d" % i, "low", agentId="ab12") for i in range(6)] +
                 [{"type": "system", "uuid": "n%d" % i, "timestamp": self.STAMP, "output_config": {"effort": "low"}}
                  for i in range(6)])
        full = self.transcript(["max", "max", "max", "xhigh", "xhigh"], extra=noise)
        with open(full, "a") as handle:
            handle.write('{"effort": "low", "uuid": "cut\n')  # the half line a live session leaves at the end
        self.transcript(["xhigh", "xhigh"], folder="proj-b", first=3)  # an earlier copy that repeats the two xhigh uuids
        code, found, lines = self.check()
        self.assertEqual(code, 0)
        self.assertTrue(found[0].startswith("PASS effort ("), found)
        self.assertIn("manager_effort: max 3, xhigh 2", lines)
        main = next(a for a in ledger.load_session(self.SID, str(self.base), None, 12)["agents"] if a["key"] == "main")
        self.assertEqual(main["transcript_effort"], "max")


if __name__ == "__main__":
    unittest.main()
