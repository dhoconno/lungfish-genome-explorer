#!/usr/bin/env python3
"""preflight.py [--fetch] [--doctor] [--session-id ID] [--program-worktree DIR] [options]

Run the session-start checks of the phase-session contract and print the facts that
a START prompt carries. It reads only: it changes no file, ends no process, and
uses the network only for git fetch when given --fetch.

Prints one line a check, then a blank line and a block of "KEY: value" facts:
  PASS <check> (<evidence>)
  ACT <check>: <what to do>
  SKIP <check>: <why it did not run>
The checks are disk, swap, scratch, processes, load, cwd, main-sync, xcode and
transcript. The get_usage check is a tool call of the manager and stays with it.
The facts are local_main and origin_main, newest_preview and newest_stable (tag and
commit), the worktrees, the free disk of ~, / and the scratch disk, the count of
local snapshots, and with --doctor the two readiness lines of release.py doctor.
The channel of a tag comes from the first lines of docs/reports/<version>-technical.md
at that tag. Every path, name and threshold is an option with a default.

Exit codes: 0 no ACT line, 1 at least one ACT line, 2 a usage error.

Serves docs/contracts/RUNNING-A-PHASE-SESSION.md, section "Session start", the table
of checks before the first launch.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

GIB = 1048576.0
TAG = re.compile(r"^v\d{4}\.\d+\.\d+$")
CHANNEL = re.compile(r"technical notes of (Preview|Stable)\b|^Channel: (Preview|Stable)\b", re.M)


def run(argv, cwd=None, env=None, timeout=60):
    """Run one command and return (exit code, stdout). A command that cannot start gives 127."""
    try:
        done = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        return 127, str(error)
    return done.returncode, done.stdout


def parse_df(text):
    """(available KiB, mount point) from the last row of df -Pk output, or None."""
    rows = [row for row in text.splitlines() if row.strip()]
    fields = rows[-1].split() if len(rows) > 1 else []
    if len(fields) < 6 or not fields[3].isdigit():
        return None
    return int(fields[3]), " ".join(fields[5:])


def parse_swap(text):
    """Percent of swap used from sysctl vm.swapusage output, or None. No swap at all counts as 0."""
    found = re.search(r"total = ([\d.]+)([MG]).*?used = ([\d.]+)([MG])", text)
    if not found:
        return None
    scale = {"M": 1.0, "G": 1024.0}
    total = float(found.group(1)) * scale[found.group(2)]
    return 0.0 if total <= 0 else 100.0 * float(found.group(3)) * scale[found.group(4)] / total


def parse_load(text):
    found = re.search(r"load averages?:\s*([\d.]+)", text)
    return float(found.group(1)) if found else None


def leftover(text, pattern, own_pid):
    """(pid, elapsed, command) of the processes in a ps -axo pid=,etime=,command= listing that match pattern."""
    found = []
    for row in text.splitlines():
        parts = row.split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or int(parts[0]) == own_pid:
            continue
        if os.path.basename(parts[2].split()[0]) in ("rg", "grep", "ps") or not re.search(pattern, parts[2]):
            continue
        found.append((int(parts[0]), parts[1], parts[2][:80]))
    return found


def check_disk(call, home, minimum, facts):
    code, out = call(["df", "-Pk", home])
    row = parse_df(out) if code == 0 else None
    if row is None:
        return "ACT", "disk", "df of %s gave nothing readable. Read the free space by hand before the first launch." % home
    free = row[0] / GIB
    facts.append(("free_disk_home", "%.0f GiB under %s" % (free, home)))
    if free < minimum:
        return ("ACT", "disk", "%.0f GiB free under %s, under the line of %d GiB. Delete the build folders of old worktrees "
                "(scripts/session/reap_build.py), then thin local snapshots under the owner's standing grant "
                "(tmutil thinlocalsnapshots / 400000000000 4), or ask the owner for that grant." % (free, home, minimum))
    return "PASS", "disk", "%.0f GiB free under %s" % (free, home)


def check_swap(call, maximum, facts):
    code, out = call(["sysctl", "vm.swapusage"])
    used = parse_swap(out) if code == 0 else None
    if used is None:
        return "ACT", "swap", "sysctl vm.swapusage gave nothing readable. Read the swap use by hand."
    facts.append(("swap_used_percent", "%.0f" % used))
    if used > maximum:
        return "ACT", "swap", "swap is %.0f%% used, over %d%%. Start the memory watch before the first launch." % (used, maximum)
    return "PASS", "swap", "%.0f%% used" % used


def check_scratch(call, scratch, facts):
    code, out = call(["df", "-Pk", scratch])
    row = parse_df(out) if code == 0 else None
    if row is None or row[1] != scratch:
        where = "missing" if row is None else "mounted at %s" % row[1]
        facts.append(("free_disk_scratch", "%s is %s" % (scratch, where)))
        return "ACT", "scratch", "%s is %s. Tell the owner, and move no archive until it is back." % (scratch, where)
    facts.append(("free_disk_scratch", "%.0f GiB under %s" % (row[0] / GIB, scratch)))
    return "PASS", "scratch", "%s is mounted, %.0f GiB free" % (scratch, row[0] / GIB)


def check_processes(call, pattern, facts):
    code, out = call(["ps", "-axo", "pid=,etime=,command="])
    if code != 0:
        return "ACT", "processes", "ps gave nothing readable. List the test runners and builds by hand."
    found = leftover(out, pattern, os.getpid())
    if found:
        listing = "; ".join("%d (%s) %s" % item for item in found[:5])
        return ("ACT", "processes", "%d process(es) of an earlier day still run: %s. Stop each one by its PID "
                "before the first build." % (len(found), listing))
    return "PASS", "processes", "none matches %s" % pattern


def check_load(call, maximum, facts):
    code, out = call(["uptime"])
    load = parse_load(out) if code == 0 else None
    if load is None:
        return "ACT", "load", "uptime gave nothing readable. Read the load average by hand."
    facts.append(("load_average", "%.2f" % load))
    if load > maximum:
        return "ACT", "load", "the load average is %.1f, over %d. Find the cause before launching." % (load, maximum)
    return "PASS", "load", "%.1f" % load


def check_cwd(call, cwd, program, facts):
    here = os.path.realpath(cwd)
    facts.append(("cwd", here))
    if program:
        root = os.path.realpath(program)
        if here == root or here.startswith(root + os.sep):
            return "PASS", "cwd", "inside the program worktree"
        return ("ACT", "cwd", "the working folder is %s, not the program worktree %s. cd into it before a spawn, "
                "since a spawn without isolation inherits the cwd." % (here, root))
    code, listing = call(["git", "worktree", "list", "--porcelain"], cwd=cwd)
    top_code, top = call(["git", "rev-parse", "--show-toplevel"], cwd=cwd)
    primary = next((row[9:] for row in listing.splitlines() if row.startswith("worktree ")), None) if code == 0 else None
    if top_code != 0 or primary is None:
        return "ACT", "cwd", "the working folder %s is not inside a git checkout." % here
    if os.path.realpath(top.strip()) == os.path.realpath(primary):
        return ("ACT", "cwd", "the working folder is the primary checkout %s. Work in the program worktree "
                "and pass it as --program-worktree." % primary)
    return "PASS", "cwd", "a linked worktree, not the primary checkout"


def check_sync(call, cwd, fetch, facts):
    if fetch:
        code, _ = call(["git", "fetch", "--quiet", "--tags", "origin"], cwd=cwd, timeout=180)
        if code != 0:
            return "ACT", "main-sync", "git fetch failed (exit %d). Find the cause, since local main cannot be compared." % code
    for key, ref in (("local_main", "main"), ("origin_main", "origin/main")):
        code, out = call(["git", "rev-parse", "--verify", "--quiet", ref + "^{commit}"], cwd=cwd)
        facts.append((key, out.strip() if code == 0 and out.strip() else "missing"))
    code, out = call(["git", "rev-list", "--left-right", "--count", "main...origin/main"], cwd=cwd)
    counts = out.split()
    if code != 0 or len(counts) != 2 or not all(item.isdigit() for item in counts):
        return "ACT", "main-sync", "main and origin/main cannot be compared. Run git fetch, or pass --fetch."
    ahead, behind = int(counts[0]), int(counts[1])
    facts.append(("main_vs_origin", "ahead %d, behind %d" % (ahead, behind)))
    if ahead or behind:
        return ("ACT", "main-sync", "local main is ahead %d and behind %d of origin/main. Find the cause before launching, "
                "base the program branch on origin/main, and tell the owner of commits only local main holds." % (ahead, behind))
    return "PASS", "main-sync", "local main equals origin/main"


def check_xcode(call, developer_dir):
    env = dict(os.environ, DEVELOPER_DIR=developer_dir)
    code, _ = call(["xcodebuild", "-checkFirstLaunchStatus"], env=env, timeout=120)
    if code != 0:
        return ("ACT", "xcode", "xcodebuild -checkFirstLaunchStatus exits %d. Ask the owner to open Xcode and finish its "
                "setup while present, since the release doctor stops on it." % code)
    return "PASS", "xcode", "first launch status 0"


def find_transcripts(projects, session_id, depth=3):
    """Paths named <session id>* up to depth levels below the projects folder, as find -maxdepth does."""
    base = os.path.abspath(projects)
    found = []
    for folder, dirs, files in os.walk(base):
        level = 0 if folder == base else folder[len(base):].count(os.sep)
        found += [os.path.join(folder, name) for name in dirs + files if name.startswith(session_id)]
        if level >= depth - 1:
            dirs[:] = []
    return sorted(found)


def check_transcript(projects, session_id, expected, facts):
    if not session_id:
        return "SKIP", "transcript", "no --session-id given"
    base = os.path.abspath(projects)
    found = find_transcripts(projects, session_id)
    if not found:
        return "ACT", "transcript", "no entry named %s* under %s. Find the session's project folder by hand." % (session_id, base)
    folders = sorted({os.path.relpath(path, base).split(os.sep)[0] for path in found})
    facts.append(("transcript_project_dir", os.path.join(base, folders[0])))
    want = os.path.basename(expected.rstrip(os.sep)) if expected else None
    if want and want not in folders:
        return ("ACT", "transcript", "the transcript lives under %s, not %s. Write the found folder into the STATE block, "
                "the helpers and every brief, and never type it." % (folders[0], want))
    return "PASS", "transcript", "under %s" % folders[0]


def channel_of(call, cwd, tag):
    """preview, stable or unknown, from the technical record at the tag."""
    code, out = call(["git", "show", "%s:docs/reports/%s-technical.md" % (tag, tag[1:])], cwd=cwd)
    found = CHANNEL.search("\n".join(out.splitlines()[:20])) if code == 0 else None
    return (found.group(1) or found.group(2)).lower() if found else "unknown"


def release_facts(call, cwd, max_tags, facts):
    code, out = call(["git", "tag", "--list", "v*", "--sort=-version:refname"], cwd=cwd)
    tags = [tag for tag in out.split() if TAG.match(tag)][:max_tags] if code == 0 else []
    seen = {}
    for tag in tags:
        channel = channel_of(call, cwd, tag)
        if channel in ("preview", "stable") and channel not in seen:
            _, commit = call(["git", "rev-parse", "--verify", "--quiet", tag + "^{commit}"], cwd=cwd)
            seen[channel] = "%s %s" % (tag, commit.strip())
        if len(seen) == 2:
            break
    for channel in ("preview", "stable"):
        facts.append(("newest_" + channel, seen.get(channel, "not found among the newest %d tags" % max_tags)))


def machine_facts(call, cwd, max_worktrees, facts):
    code, out = call(["git", "worktree", "list"], cwd=cwd)
    rows = out.splitlines() if code == 0 else []
    facts.append(("worktree_count", str(len(rows))))
    facts += [("worktree", row) for row in rows[:max_worktrees]]
    if len(rows) > max_worktrees:
        facts.append(("worktree_more", "%d more, see git worktree list" % (len(rows) - max_worktrees)))
    code, out = call(["df", "-Pk", "/"])
    row = parse_df(out) if code == 0 else None
    facts.append(("free_disk_root", "%.0f GiB under /" % (row[0] / GIB) if row else "unreadable"))
    code, out = call(["tmutil", "listlocalsnapshots", "/"])
    count = sum(1 for line in out.splitlines() if line.startswith("com.apple."))
    facts.append(("local_snapshots", str(count) if code == 0 else "unreadable"))


def doctor_facts(call, cwd, timeout, facts):
    code, top = call(["git", "rev-parse", "--show-toplevel"], cwd=cwd)
    root = top.strip() if code == 0 and top.strip() else cwd
    code, out = call([sys.executable, os.path.join(root, "scripts", "release", "release.py"), "doctor"], cwd=root, timeout=timeout)
    for key, word in (("doctor_package", "Package"), ("doctor_publish", "Publish")):
        row = next((line.strip() for line in out.splitlines() if line.startswith(word + " readiness:")), None)
        facts.append((key, row or "no readiness line (exit %d)" % code))


def main(argv=None, call=run, cwd=None, home=None) -> int:
    parser = argparse.ArgumentParser(prog="preflight.py", description="Run the session-start checks and print the START facts.")
    parser.add_argument("--fetch", action="store_true", help="run git fetch first (the only network use)")
    parser.add_argument("--doctor", action="store_true", help="add the two readiness lines of release.py doctor")
    parser.add_argument("--session-id", help="the session id, to find its transcript")
    parser.add_argument("--projects-dir", default="~/.claude/projects", help="folder of the project folders (default %(default)s)")
    parser.add_argument("--expected-project", help="the project folder (its path or its name) that the briefs and helpers name; "
                        "a name that starts with a dash needs the form --expected-project=NAME")
    parser.add_argument("--program-worktree", help="the folder the manager must work in (default: any linked worktree)")
    parser.add_argument("--scratch", default="/Volumes/lge_scratch", help="mount point of the scratch disk (default %(default)s)")
    parser.add_argument("--process-pattern", default="xctest|swift-build|swift-test|lungfish-cli", help="regex of leftover processes")
    parser.add_argument("--min-free-gib", type=int, default=100, help="free GiB under ~ below which to act (default %(default)s)")
    parser.add_argument("--max-swap-percent", type=int, default=90, help="swap use above which to act (default %(default)s)")
    parser.add_argument("--max-load", type=int, default=40, help="load average above which to act (default %(default)s)")
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer", help="DEVELOPER_DIR for xcodebuild")
    parser.add_argument("--skip-xcode", action="store_true", help="do not run xcodebuild")
    parser.add_argument("--max-tags", type=int, default=12, help="newest tags to read for the channel facts (default %(default)s)")
    parser.add_argument("--max-worktrees", type=int, default=12, help="worktree facts to print (default %(default)s)")
    parser.add_argument("--doctor-timeout", type=int, default=300, help="seconds for release.py doctor (default %(default)s)")
    args = parser.parse_args(argv)
    cwd = cwd or os.getcwd()
    home = home or os.path.expanduser("~")
    facts = []
    results = [
        check_disk(call, home, args.min_free_gib, facts),
        check_swap(call, args.max_swap_percent, facts),
        check_scratch(call, args.scratch, facts),
        check_processes(call, args.process_pattern, facts),
        check_load(call, args.max_load, facts),
        check_cwd(call, cwd, args.program_worktree, facts),
        check_sync(call, cwd, args.fetch, facts),
        ("SKIP", "xcode", "--skip-xcode given") if args.skip_xcode else check_xcode(call, args.developer_dir),
        check_transcript(os.path.expanduser(args.projects_dir), args.session_id, args.expected_project, facts),
    ]
    release_facts(call, cwd, args.max_tags, facts)
    machine_facts(call, cwd, args.max_worktrees, facts)
    if args.doctor:
        doctor_facts(call, cwd, args.doctor_timeout, facts)
    for state, name, text in results:
        print("PASS %s (%s)" % (name, text) if state == "PASS" else "%s %s: %s" % (state, name, text))
    print()
    for key, value in facts:
        print("%s: %s" % (key, value))
    return 1 if any(state == "ACT" for state, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
