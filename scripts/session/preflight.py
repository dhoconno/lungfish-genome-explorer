#!/usr/bin/env python3
"""preflight.py [--fetch] [--doctor] [--session-id ID] [--program-worktree DIR] [options]
preflight.py --start TEMPLATE --plan PLAN --scope LANE-IDS [--owner IDS] --out FILE [options]

Run the session-start checks of the phase-session contract and print the facts that
a START prompt carries. It reads only: it changes no file, ends no process, and
uses the network only for git fetch when given --fetch. With --start it also writes
the one file named by --out and nothing else.

Prints one line a check, then a blank line and a block of "KEY: value" facts:
  PASS <check> (<evidence>)
  ACT <check>: <what to do>
  SKIP <check>: <why it did not run>
The checks are disk, swap, scratch, processes, load, cwd, main-sync, agents, xcode,
transcript and effort. The get_usage check is a tool call of the manager and stays with it.
The effort check reads the manager's own effort from the main transcript of --session-id,
the way session_ledger.py does (the most common value of the top-level `effort` field),
and gives ACT when it is not --manager-effort (default max), PASS when it is and SKIP when
no transcript or no effort record can be read. Its fact is manager_effort, each value
with its count.
The agents check reads the primary checkout, where sessions load typed agents from. It
gives ACT when the primary's .claude/agents/ lacks a type that main has or holds
another copy of one. The facts are local_main and origin_main, the primary_head,
newest_preview and newest_stable (tag and commit), the worktrees, the free disk of ~,
/ and the scratch disk, the count of local snapshots, and with --doctor the two
readiness lines of release.py doctor. The channel of a tag comes from the first lines
of docs/reports/<version>-technical.md at that tag. Every path, name and threshold is
an option with a default.

--start fills TEMPLATE (scripts/session/start-template.md) with the fields {{taken}},
{{facts}}, {{plan}}, {{scope}}, {{owner}}, {{budget}} and {{records}}. Each lane id of
--scope must head a row of a table of --plan, and each id of --owner a row of
docs/contracts/OWNER-DIRECTIONS.md. The facts list the worktrees that are not agent
worktrees. It writes --out, prints the size and refuses an output over
--max-start-bytes (4,096), with exit 2 and no file.

Exit codes: 0 no ACT line, 1 at least one ACT line, 2 a usage error or a refused fill.

Serves docs/contracts/RUNNING-A-PHASE-SESSION.md, section "Session start", the table
of checks before the first launch and the START prompt.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter

GIB = 1048576.0
TAG = re.compile(r"^v\d{4}\.\d+\.\d+$")
CHANNEL = re.compile(r"technical notes of (Preview|Stable)\b|^Channel: (Preview|Stable)\b", re.M)
AGENTS_DIR = ".claude/agents"
AGENT_WORKTREE = "/.claude/worktrees/agent-"
BLOB_ROW = re.compile(r"^\d+ blob ([0-9a-f]{40,64})\t(.+)$")
FIELD = re.compile(r"\{\{(\w+)\}\}")
START_LIMIT = 4096


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


def parse_worktrees(text):
    """[(path, head, branch)] from git worktree list --porcelain. The branch reads detached when none is named."""
    rows = []
    for line in text.splitlines():
        if line.startswith("worktree "):
            rows.append([line[9:], "", "detached"])
        elif rows and line.startswith("HEAD "):
            rows[-1][1] = line[5:]
        elif rows and line.startswith("branch "):
            rows[-1][2] = line[7:].replace("refs/heads/", "", 1)
    return [tuple(row) for row in rows]


def blob_id(data):
    """The git blob id of the bytes of a file, so a file compares with a tree entry without a git call."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def some(names, limit=4):
    return ", ".join(names[:limit]) + (" and %d more" % (len(names) - limit) if len(names) > limit else "")


def check_agents(call, cwd, facts):
    """Sessions load typed agents from the primary checkout, so its .claude/agents/ must hold those of main."""
    code, listing = call(["git", "worktree", "list", "--porcelain"], cwd=cwd)
    rows = parse_worktrees(listing) if code == 0 else []
    if not rows:
        return "SKIP", "agents", "git worktree list named no primary checkout"
    path, head, branch = rows[0]
    facts.append(("primary_head", "%s %s (%s)" % (head or "unknown", branch, path)))
    code, tree = call(["git", "ls-tree", "main", AGENTS_DIR + "/"], cwd=cwd)
    wanted = {}
    for row in tree.splitlines() if code == 0 else []:
        found = BLOB_ROW.match(row)
        if found:
            wanted[os.path.basename(found.group(2))] = found.group(1)
    if not wanted:
        return "SKIP", "agents", "main holds no %s/ to compare with" % AGENTS_DIR
    lacks, differs = [], []
    for name, blob in sorted(wanted.items()):
        try:
            with open(os.path.join(path, AGENTS_DIR, name), "rb") as handle:
                same = blob_id(handle.read()) == blob
        except OSError:
            lacks.append(name)
            continue
        if not same:
            differs.append(name)
    if lacks or differs:
        said = ["lacks %d agent type(s) of main (%s)" % (len(lacks), some(lacks))] if lacks else []
        said += ["holds another copy of %d (%s)" % (len(differs), some(differs))] if differs else []
        return ("ACT", "agents", "the primary checkout %s is at %s and %s. Sessions load typed agents from its %s/, so they "
                "need it at main. Check main out there detached while nothing runs in it, or tell the owner."
                % (path, head[:9], " and ".join(said), AGENTS_DIR))
    return "PASS", "agents", "the primary checkout holds the %d agent types of main" % len(wanted)


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


def manager_effort(paths):
    """The count of each value of the top-level `effort` field in the main transcripts of one session. It reads as
    session_ledger.py reads the manager's effort (commit 3bf5c2230). An entry counts once by its uuid, so a transcript copied
    into two project folders counts once. An entry that names an agent or is a sidechain belongs to a subagent and does not
    count, and a line that is not JSON, such as the half line a live session leaves at the end of its file, is skipped."""
    counts, seen = Counter(), set()
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(entry, dict) or entry.get("agentId") or entry.get("isSidechain"):
                        continue
                    uid = entry.get("uuid")
                    if uid:
                        if uid in seen:
                            continue
                        seen.add(uid)
                    if isinstance(entry.get("effort"), str) and entry["effort"]:
                        counts[entry["effort"]] += 1
        except OSError:
            continue
    return counts


def check_effort(projects, session_id, wanted, facts):
    """ACT when the manager's own effort, the most common value in its main transcript, is not the wanted one."""
    if not session_id:
        return "SKIP", "effort", "no --session-id given"
    base = os.path.abspath(projects)
    paths = sorted(glob.glob(os.path.join(glob.escape(base), "*", glob.escape(session_id) + ".jsonl")))
    if not paths:
        return "SKIP", "effort", "no %s.jsonl under %s/*/ to read the effort from" % (session_id, base)
    counts = manager_effort(paths)
    if not counts:
        return "SKIP", "effort", "the transcript of %s records no effort" % session_id
    effort, entries = counts.most_common(1)[0][0], sum(counts.values())
    facts.append(("manager_effort", ", ".join("%s %d" % item for item in counts.most_common())))
    if effort.strip().lower() != wanted.strip().lower():
        return ("ACT", "effort", "the manager session runs at effort %s (%d of %d entries), not %s. The owner set %s for managers on "
                "2026-11-11. Write the effort it runs at into line 1 of the event log and go on." % (effort, counts[effort], entries, wanted, wanted))
    return "PASS", "effort", "%s, %d of %d entries" % (effort, counts[effort], entries)


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


def machine_facts(call, cwd, max_worktrees, facts, hide_agents=False):
    code, out = call(["git", "worktree", "list"], cwd=cwd)
    rows = out.splitlines() if code == 0 else []
    facts.append(("worktree_count", str(len(rows))))
    hidden = [row for row in rows if hide_agents and AGENT_WORKTREE in row]
    shown = [row for row in rows if row not in hidden][:max_worktrees]
    facts += [("worktree", row) for row in shown]
    if len(rows) > len(shown):
        note = ", %d of them agent worktrees" % len(hidden) if hidden else ""
        facts.append(("worktree_more", "%d more%s, see git worktree list" % (len(rows) - len(shown), note)))
    code, out = call(["df", "-Pk", "/"])
    row = parse_df(out) if code == 0 else None
    facts.append(("free_disk_root", "%.0f GiB under /" % (row[0] / GIB) if row else "unreadable"))
    code, out = call(["tmutil", "listlocalsnapshots", "/"])
    count = sum(1 for line in out.splitlines() if line.startswith("com.apple."))
    facts.append(("local_snapshots", str(count) if code == 0 else "unreadable"))


def read_text(path, cwd):
    """(text, None) of a file, or (None, the reason it cannot be read). A relative path starts at cwd."""
    try:
        with open(os.path.join(cwd, path), encoding="utf-8") as handle:
            return handle.read(), None
    except (OSError, UnicodeDecodeError) as error:
        return None, "cannot read %s (%s)" % (path, error)


def table_rows(text):
    """The stripped cells of every markdown table row of a text."""
    return [[cell.strip() for cell in row.strip().strip("|").split("|")] for row in text.splitlines() if row.startswith("|")]


def split_ids(text):
    return [item.strip() for item in (text or "").split(",") if item.strip()]


def load_start(args, cwd):
    """(the values a START template is filled with, None), or (None, the reason an input does not hold up)."""
    template, error = read_text(args.start, cwd)
    plan, plan_error = read_text(args.plan, cwd)
    if error or plan_error:
        return None, error or plan_error
    lanes = split_ids(args.scope)
    known = {part.strip("` ") for row in table_rows(plan) for part in row[0].split(",")}
    missing = [item for item in lanes if item not in known]
    if not lanes or missing:
        return None, "lane id(s) %s not at the head of a table row of %s" % (", ".join(missing) or "(none given)", args.plan)
    rows, owners = [], split_ids(args.owner)
    if owners:
        text, error = read_text(args.owner_file, cwd)
        if error:
            return None, error
        by_id = {row[0]: row for row in table_rows(text) if len(row) >= 4}
        missing = [item for item in owners if item not in by_id]
        if missing:
            return None, "owner id(s) %s not found in %s" % (", ".join(missing), args.owner_file)
        rows = ["- %s (%s) %s" % (item, by_id[item][1], by_id[item][-1]) for item in owners]
    records = args.records or os.path.dirname(os.path.abspath(os.path.join(cwd, args.out)))
    return {"template": template, "plan": args.plan, "scope": ", ".join(lanes), "owner": "\n".join(rows) or "none since the plan",
            "budget": args.budget or "as the Budget line of the plan sets", "records": records}, None


def doctor_facts(call, cwd, timeout, facts):
    code, top = call(["git", "rev-parse", "--show-toplevel"], cwd=cwd)
    root = top.strip() if code == 0 and top.strip() else cwd
    code, out = call([sys.executable, os.path.join(root, "scripts", "release", "release.py"), "doctor"], cwd=root, timeout=timeout)
    for key, word in (("doctor_package", "Package"), ("doctor_publish", "Publish")):
        row = next((line.strip() for line in out.splitlines() if line.startswith(word + " readiness:")), None)
        facts.append((key, row or "no readiness line (exit %d)" % code))


def facts_text(results, facts):
    """The facts block of a START prompt. The ACT lines come in full and the other checks are counted."""
    def names(state):
        return [name for current, name, _ in results if current == state]
    counts = ["%d %s%s" % (len(names(state)), state, " (%s)" % ", ".join(names(state)) if state != "PASS" else "")
              for state in ("PASS", "SKIP", "ACT") if names(state)]
    acts = ["ACT %s: %s" % (name, text) for state, name, text in results if state == "ACT"]
    return "\n".join(["checks: " + ", ".join(counts)] + acts + ["%s: %s" % item for item in facts])


def fill_start(start, results, facts, taken):
    """(the filled text, the fields of the template that this script does not know)."""
    values = {key: start[key] for key in ("plan", "scope", "owner", "budget", "records")}
    values.update(facts=facts_text(results, facts), taken=taken)
    unknown = []

    def put(found):
        if found.group(1) not in values:
            unknown.append(found.group(1))
            return found.group(0)
        return values[found.group(1)]
    return FIELD.sub(put, start["template"]), unknown


def write_start(args, cwd, start, results, facts):
    """Fill the template, refuse an output over the limit, write --out and give the exit code of the checks."""
    text, unknown = fill_start(start, results, facts, time.strftime("%Y-%m-%d %H:%M %Z"))
    data = text.encode("utf-8")
    if unknown or len(data) > args.max_start_bytes:
        why = ("the template names the unknown field(s) %s" % ", ".join("{{%s}}" % item for item in unknown) if unknown else
               "the filled START prompt is %d bytes, over the limit of %d. Name fewer lanes or owner ids, or lower --max-worktrees"
               % (len(data), args.max_start_bytes))
        print("preflight.py: error: " + why, file=sys.stderr)
        return 2
    try:
        with open(os.path.join(cwd, args.out), "wb") as handle:
            handle.write(data)
    except OSError as error:
        print("preflight.py: error: cannot write %s (%s)" % (args.out, error), file=sys.stderr)
        return 2
    print("START prompt written to %s (%d of %d bytes)" % (args.out, len(data), args.max_start_bytes))
    return 1 if any(state == "ACT" for state, _, _ in results) else 0


def main(argv=None, call=run, cwd=None, home=None) -> int:
    parser = argparse.ArgumentParser(prog="preflight.py", description="Run the session-start checks and print the START facts.")
    parser.add_argument("--fetch", action="store_true", help="run git fetch first (the only network use)")
    parser.add_argument("--doctor", action="store_true", help="add the two readiness lines of release.py doctor")
    parser.add_argument("--session-id", help="the session id, to find its transcript")
    parser.add_argument("--projects-dir", default="~/.claude/projects", help="folder of the project folders (default %(default)s)")
    parser.add_argument("--expected-project", help="the project folder (its path or its name) that the briefs and helpers name; "
                        "a name that starts with a dash needs the form --expected-project=NAME")
    parser.add_argument("--program-worktree", help="the folder the manager must work in (default: any linked worktree)")
    parser.add_argument("--manager-effort", default="max", help="the effort the manager session must run at, which the effort "
                        "check reads from its transcript (default %(default)s)")
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
    parser.add_argument("--start", metavar="TEMPLATE", help="fill this START template from the facts and write it to --out")
    parser.add_argument("--plan", help="with --start, the plan whose lanes the session takes")
    parser.add_argument("--scope", help="with --start, the lane ids of the plan that the session takes, separated by commas")
    parser.add_argument("--owner", help="with --start, the ids of the owner directions given since the plan, separated by commas")
    parser.add_argument("--owner-file", default="docs/contracts/OWNER-DIRECTIONS.md", help="with --start, the file of owner directions "
                        "(default %(default)s)")
    parser.add_argument("--budget", help="with --start, the budget as a phrase (default: the Budget line of the plan)")
    parser.add_argument("--records", help="with --start, the records folder (default: the folder of --out)")
    parser.add_argument("--out", help="with --start, the file to write")
    parser.add_argument("--max-start-bytes", type=int, default=START_LIMIT, help="with --start, the most bytes to write "
                        "(default %(default)s)")
    args = parser.parse_args(argv)
    cwd = cwd or os.getcwd()
    home = home or os.path.expanduser("~")
    start = None
    if args.start:
        absent = [flag for flag, value in (("--plan", args.plan), ("--scope", args.scope), ("--out", args.out)) if not value]
        if absent:
            parser.error("--start also needs " + ", ".join(absent))
        start, reason = load_start(args, cwd)
        if reason:
            parser.error(reason)
    elif any((args.plan, args.scope, args.owner, args.budget, args.records, args.out)):
        parser.error("--plan, --scope, --owner, --budget, --records and --out belong to --start")
    facts = []
    results = [
        check_disk(call, home, args.min_free_gib, facts),
        check_swap(call, args.max_swap_percent, facts),
        check_scratch(call, args.scratch, facts),
        check_processes(call, args.process_pattern, facts),
        check_load(call, args.max_load, facts),
        check_cwd(call, cwd, args.program_worktree, facts),
        check_sync(call, cwd, args.fetch, facts),
        check_agents(call, cwd, facts),
        ("SKIP", "xcode", "--skip-xcode given") if args.skip_xcode else check_xcode(call, args.developer_dir),
        check_transcript(os.path.expanduser(args.projects_dir), args.session_id, args.expected_project, facts),
        check_effort(os.path.expanduser(args.projects_dir), args.session_id, args.manager_effort, facts),
    ]
    release_facts(call, cwd, args.max_tags, facts)
    machine_facts(call, cwd, args.max_worktrees, facts, hide_agents=bool(start))
    if args.doctor:
        doctor_facts(call, cwd, args.doctor_timeout, facts)
    for state, name, text in results:
        print("PASS %s (%s)" % (name, text) if state == "PASS" else "%s %s: %s" % (state, name, text))
    if start:
        return write_start(args, cwd, start, results, facts)
    print()
    for key, value in facts:
        print("%s: %s" % (key, value))
    return 1 if any(state == "ACT" for state, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
