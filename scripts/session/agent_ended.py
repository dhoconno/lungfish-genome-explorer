#!/usr/bin/env python3
"""agent_ended.py TRANSCRIPT.jsonl [--min-age 30] [--worktree DIR]

Say whether an agent has ended, so that no review, landing or check starts early.

An agent has ended when the last message entry of its transcript is a final
message (an assistant entry with no tool call, and no user entry after it) and the
last entry of the transcript is at least --min-age seconds old (default 30). With
--worktree DIR it has ended only if no process also has its working folder in DIR
or below it (read from lsof -a -d cwd), since a build or test of the agent can
outlive its final message.

Prints ENDED and exits 0, or prints RUNNING <age> (the age of the last entry, as
"12s"), a note on the processes found in the worktree when there are any, and
exits 1. Exits 2 when the transcript cannot be read. It sends no signal.

Serves docs/contracts/RUNNING-A-PHASE-SESSION.md, section "Rules for the manager",
row "Confirmed end".
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone


def parse_time(text):
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def read_state(path):
    """(final, stamp): is the last message entry a final message, and when was the last entry written."""
    final, stamp = False, None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            when = parse_time(entry.get("timestamp"))
            if when is not None:
                stamp = when
            if entry.get("type") == "assistant":
                content = (entry.get("message") or {}).get("content")
                pending = isinstance(content, list) and any(
                    isinstance(block, dict) and block.get("type") == "tool_use" for block in content)
                final = not pending
            elif entry.get("type") == "user":
                final = False
    return final, stamp


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


def main(argv=None, now=None, lsof=None) -> int:
    parser = argparse.ArgumentParser(prog="agent_ended.py", description="Print ENDED or RUNNING <age> for an agent transcript.")
    parser.add_argument("transcript", help="the agent's transcript, a .jsonl file")
    parser.add_argument("--min-age", type=int, default=30, help="seconds the last entry must be old (default 30)")
    parser.add_argument("--worktree", help="the agent's worktree, to check that no process works in it")
    args = parser.parse_args(argv)
    try:
        final, stamp = read_state(args.transcript)
        if stamp is None:
            stamp = datetime.fromtimestamp(os.path.getmtime(args.transcript), timezone.utc)
    except OSError as error:
        print("agent_ended: cannot read the transcript: %s" % error, file=sys.stderr)
        return 2
    age = max(0, int(((now or datetime.now(timezone.utc)) - stamp).total_seconds()))
    busy, note = [], ""
    if args.worktree:
        text = (lsof or list_cwds)()
        if text is None:
            busy, note = None, " lsof failed, so the worktree is not confirmed idle"
        else:
            busy = busy_in(args.worktree, text, os.getpid())
            if busy:
                note = " busy in the worktree: " + ", ".join("%s %d" % (p["command"], p["pid"]) for p in busy[:5])
    if final and age >= args.min_age and busy == []:
        print("ENDED")
        return 0
    print("RUNNING %ds%s" % (age, note))
    return 1


if __name__ == "__main__":
    sys.exit(main())
