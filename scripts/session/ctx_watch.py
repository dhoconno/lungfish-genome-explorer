#!/usr/bin/env python3
"""ctx_watch.py PROJECT_DIR SID [--over K] [--busy] [--stalled SECONDS] [--review-k K] [--send-k K]

Prints one line for each subagent of a Claude Code session, read from PROJECT_DIR/SID/subagents. A line holds the
agent id, its description, its tool calls so far, the context of its last API turn in K (input plus cache read plus
cache write), the age of its last entry and "final" when that entry is a message with no tool call or only a
SubagentHandback call, which is how a subagent ends, else "busy". A
line at or over --review-k (default 300) ends with REVIEW-STOP and at or over --send-k (default 400) with SEND-STOP.
--over K keeps the agents at or over K. --busy drops the agents whose last entry is final. --stalled SECONDS keeps the
agents whose last entry is older than SECONDS and not final, so a tool call may be pending, and starts each such line
with STALLED. Filters given together must all pass. It prints "none" when no line remains and never prints message text.

Exit codes are 0 after a listing, including "none", and 2 for a bad argument or a session with neither a transcript
nor a folder under PROJECT_DIR.

Serves the rows "Lane size" and "Pending tool call" in the End check and heartbeat table of
docs/contracts/RUNNING-A-PHASE-SESSION.md.
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime


def parse_time(text):
    """Seconds since the epoch for the stamp of a transcript entry, or None when it cannot be read."""
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def last_state(path, handback="SubagentHandback"):
    """(tool calls, context tokens of the last API turn, last stamp, last entry is final) of one transcript.

    A subagent ends with a call of the tool named handback, answered by a tool result. So an assistant entry whose
    only tool calls are that one is final, and the result of that call does not undo it.
    """
    seen, calls, usage_by_id, handbacks = set(), set(), {}, set()
    last_id = last_stamp = None
    final = False
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            uuid = entry.get("uuid")
            if uuid is not None:
                if uuid in seen:
                    continue
                seen.add(uuid)
            if entry.get("timestamp"):
                last_stamp = entry["timestamp"]
            message = entry.get("message")
            message = message if isinstance(message, dict) else {}
            if entry.get("type") == "assistant":
                use = message.get("usage") or {}
                tokens = sum(use.get(key) or 0 for key in (
                    "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                if message.get("id"):
                    usage_by_id[message["id"]] = max(usage_by_id.get(message["id"], 0), tokens)
                    last_id = message["id"]
                content = message.get("content")
                blocks = [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
                tools = [b for b in blocks if b.get("type") == "tool_use"]
                calls.update(block.get("id") for block in tools)
                handbacks.update(block.get("id") for block in tools if block.get("name") == handback)
                final = all(block.get("name") == handback for block in tools)
            elif entry.get("type") == "user":
                content = message.get("content")
                blocks = content if isinstance(content, list) else []
                results = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
                if not (results and all(b.get("tool_use_id") in handbacks for b in results)):
                    final = False
    return len(calls), usage_by_id.get(last_id, 0), last_stamp, final


def describe(sub, name):
    """The first 34 characters of the description in the agent's meta file, or an empty string."""
    meta = os.path.join(sub, name[:-len(".jsonl")] + ".meta.json")
    try:
        with open(meta, encoding="utf-8") as handle:
            return (json.load(handle).get("description") or "")[:34]
    except (OSError, ValueError, AttributeError):
        return ""


def survey(project, sid, now):
    """One dict for each subagent transcript, in file name order. Empty when there is no subagents folder."""
    sub = os.path.join(project, sid, "subagents")
    rows = []
    for name in (sorted(os.listdir(sub)) if os.path.isdir(sub) else []):
        if not name.endswith(".jsonl"):
            continue
        calls, tokens, stamp, final = last_state(os.path.join(sub, name))
        seconds = parse_time(stamp) if stamp else None
        agent = name[len("agent-"):] if name.startswith("agent-") else name
        rows.append({"id": agent[:-len(".jsonl")], "desc": describe(sub, name), "calls": calls,
                     "k": tokens // 1000, "final": final, "age": None if seconds is None else now - seconds})
    return rows


def format_line(row, review_k, send_k, stalled):
    flag = "SEND-STOP" if row["k"] >= send_k else "REVIEW-STOP" if row["k"] >= review_k else ""
    age = "-" if row["age"] is None else "%ds" % row["age"]
    line = "%s %-34s calls %3d ctx %4dK age %6s %s %s" % (
        row["id"][:17], row["desc"], row["calls"], row["k"], age, "final" if row["final"] else "busy ", flag)
    return ("STALLED " if stalled else "") + line.rstrip()


def main(argv=None, now=None, out=None):
    parser = argparse.ArgumentParser(prog="ctx_watch.py", description="One line for each subagent of a session.")
    parser.add_argument("project")
    parser.add_argument("sid")
    parser.add_argument("--over", type=int, default=0, metavar="K")
    parser.add_argument("--busy", action="store_true")
    parser.add_argument("--stalled", type=int, default=None, metavar="SECONDS")
    parser.add_argument("--review-k", type=int, default=300, metavar="K")
    parser.add_argument("--send-k", type=int, default=400, metavar="K")
    args = parser.parse_args(argv)
    out = out or sys.stdout
    root = os.path.join(args.project, args.sid)
    if not os.path.isdir(root) and not os.path.isfile(root + ".jsonl"):
        sys.stderr.write("ctx_watch.py, no transcript or folder for session %s under %s\n" % (args.sid, args.project))
        return 2
    lines = []
    for row in survey(args.project, args.sid, time.time() if now is None else now):
        if row["k"] < args.over or (args.busy and row["final"]):
            continue
        if args.stalled is not None and (row["final"] or row["age"] is None or row["age"] < args.stalled):
            continue
        lines.append(format_line(row, args.review_k, args.send_k, args.stalled is not None))
    out.write("\n".join(lines) + "\n" if lines else "none\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
