#!/usr/bin/env python3
"""reap_build.py WORKTREE [--done-ids FILE] [--execute]

Remove the build folder of a finished lane's worktree.

WORKTREE is <repo>/.claude/worktrees/<name>, and the folder removed is its .build.
Without --execute the script prints what it would remove and the bytes that frees,
and removes nothing. With --execute it removes the folder only when every check
holds, and otherwise prints one "REFUSED <reason>" line a failed check:
  - WORKTREE is <repo>/.claude/worktrees/<name> of a git repository, is the root of
    a linked worktree, and its .build is a real folder inside it, not a link,
  - its branch is worktree-agent-<id>, and <id> is a line of the done-ids file
    (the ids of agents that have ended, SCR/llm/done_ids.txt),
  - no process has its working folder in WORKTREE or below it (lsof -a -d cwd).
--done-ids defaults to llm/done_ids.txt under the folder that the environment
variable LGE_SCR names. With neither, the script refuses.

Prints "would remove <path> (<n> bytes)" or "removed <path> freed <n> bytes", where
n is the sum of the file sizes, or "nothing to remove: <path> does not exist". It
starts and ends no process and acts on that one literal path.
Exit codes: 0 done or dry run, 2 refused, 1 the removal failed.

Serves docs/contracts/RUNNING-A-PHASE-SESSION.md, section "Rules for the manager",
rows "Fresh worktrees" and "Disk and snapshots" (delete a lane's build folder as
soon as its last agent ends).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import subprocess
import sys

BRANCH = re.compile(r"^worktree-agent-([A-Za-z0-9]+)$")


def git_out(args, cwd):
    try:
        done = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def read_ids(path):
    ids = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#"):
                ids.add(line.split()[0])
    return ids


def parse_lsof(text):
    """The processes of lsof -Fpcn output as dicts with pid, command and cwd."""
    procs, current = [], None
    for line in text.splitlines():
        tag, value = line[:1], line[1:]
        if tag == "p":
            current = {"pid": int(value) if value.isdigit() else 0, "command": "", "cwd": None}
            procs.append(current)
        elif current is not None and tag == "c":
            current["command"] = value
        elif current is not None and tag == "n":
            current["cwd"] = value
    return procs


def busy_in(worktree, lsof_text, own_pid):
    """The processes, this one excluded, whose working folder is the worktree or below it."""
    root = os.path.realpath(worktree)
    found = []
    for proc in parse_lsof(lsof_text):
        if proc["pid"] == own_pid or not proc["cwd"]:
            continue
        here = os.path.realpath(proc["cwd"])
        if here == root or here.startswith(root + os.sep):
            found.append(proc)
    return found


def list_cwds(timeout=60):
    """The text of lsof -a -d cwd, or None when lsof cannot run. Its exit code is ignored, since it is 1 for other users' processes."""
    try:
        done = subprocess.run(["lsof", "-nP", "-a", "-d", "cwd", "-Fpcn"], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout


def tree_bytes(path):
    """The sum of the sizes of the files below path, each inode once, links not followed."""
    total, seen = 0, set()
    for folder, dirs, files in os.walk(path):
        for name in dirs + files:
            try:
                info = os.lstat(os.path.join(folder, name))
            except OSError:
                continue
            if stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) in seen:
                continue
            seen.add((info.st_dev, info.st_ino))
            total += info.st_size
    return total


def shape_reasons(worktree):
    """Why the path is not the root of a linked worktree under <repo>/.claude/worktrees, empty when it is."""
    parent = os.path.dirname(worktree)
    repo = os.path.dirname(os.path.dirname(parent))
    if not (os.path.basename(parent) == "worktrees" and os.path.basename(os.path.dirname(parent)) == ".claude"
            and os.path.isdir(os.path.join(repo, ".git"))):
        return ["the path is not <repo>/.claude/worktrees/<name> of a git repository: %s" % worktree]
    top = git_out(["rev-parse", "--show-toplevel"], worktree) if os.path.isdir(worktree) else None
    if not os.path.isfile(os.path.join(worktree, ".git")) or top is None or os.path.realpath(top) != os.path.realpath(worktree):
        return ["%s is not the root of a linked git worktree" % worktree]
    build = os.path.join(worktree, ".build")
    if os.path.lexists(build) and (os.path.islink(build) or os.path.realpath(build) != os.path.join(os.path.realpath(worktree), ".build")):
        return ["%s is a link or lies behind one" % build]
    return []


def state_reasons(worktree, done_ids, lsof):
    """Why an agent may still use the worktree: its id is not done, or a process works in it."""
    reasons = []
    match = BRANCH.match(git_out(["branch", "--show-current"], worktree) or "")
    if not match:
        reasons.append("the branch of the worktree is not worktree-agent-<id>")
    elif done_ids is None or match.group(1) not in done_ids:
        reasons.append("the id %s is not in the done-ids file, so an agent may still work in it" % match.group(1))
    text = lsof()
    if text is None:
        reasons.append("lsof could not list the working folders of the processes")
    else:
        for proc in busy_in(worktree, text, os.getpid()):
            reasons.append("process %d (%s) has its working folder in the worktree" % (proc["pid"], proc["command"]))
    return reasons


def make_removable(root):
    stack = [root]
    while stack:
        folder = stack.pop()
        try:
            os.chmod(folder, os.stat(folder).st_mode | 0o700)
            stack.extend(entry.path for entry in os.scandir(folder) if entry.is_dir(follow_symlinks=False))
        except OSError:
            pass


def remove_tree(path):
    """None when the folder is gone, else the error text. One retry after making the folders writable."""
    try:
        shutil.rmtree(path)
        return None
    except OSError:
        make_removable(path)
    try:
        shutil.rmtree(path)
    except OSError as error:
        return str(error)
    return None


def main(argv=None, lsof=None) -> int:
    parser = argparse.ArgumentParser(prog="reap_build.py", description="Remove the .build folder of a finished lane's worktree.")
    parser.add_argument("worktree", help="<repo>/.claude/worktrees/<name>")
    parser.add_argument("--done-ids", help="file of ended agent ids, one a line (default $LGE_SCR/llm/done_ids.txt)")
    parser.add_argument("--execute", action="store_true", help="remove the folder (without it nothing is removed)")
    args = parser.parse_args(argv)
    worktree = os.path.abspath(args.worktree)
    build = os.path.join(worktree, ".build")
    reasons = shape_reasons(worktree)
    if not reasons and not os.path.lexists(build):
        print("nothing to remove: %s does not exist" % build)
        return 0
    if not reasons:
        ids_path = args.done_ids or (os.path.join(os.environ["LGE_SCR"], "llm", "done_ids.txt") if os.environ.get("LGE_SCR") else None)
        done_ids = None
        if ids_path is None:
            reasons.append("no done-ids file: pass --done-ids or set LGE_SCR")
        else:
            try:
                done_ids = read_ids(ids_path)
            except OSError as error:
                reasons.append("cannot read the done-ids file: %s" % error)
        reasons += state_reasons(worktree, done_ids, lsof or list_cwds)
    if reasons:
        for reason in reasons:
            print("REFUSED %s" % reason)
        return 2
    size = tree_bytes(build)
    if not args.execute:
        print("would remove %s (%d bytes)" % (build, size))
        return 0
    error = remove_tree(build)
    if error:
        print("REMOVAL FAILED %s: %s" % (build, error))
        return 1
    print("removed %s freed %d bytes" % (build, size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
