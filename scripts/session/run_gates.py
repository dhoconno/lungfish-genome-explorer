#!/usr/bin/env python3
"""run_gates.py LOG [--root DIR] [--list]

Runs the gate scripts of a worktree one after another, read-only, and logs them for a blocking wait. The sequence is
every scripts/ratchets/*.sh (Python scripts despite the suffix, run by their first line), every scripts/checks/*.py
and scripts/testing/preferences-leaks.py with the argument lint, each group sorted by name, with
LUNGFISH_RATCHET_READ_ONLY=1 and no --update. LOG gets a block for each script with its command, a line
status=<n> seconds=<s> and its full output, then a summary table and last a line exit=<code>, which is 0 when every
script passed and 1 when any failed. No earlier line starts with exit=, so a blocking wait on that pattern ends with
the whole run. The table is printed too. --list prints the sequence and runs nothing. --root defaults to the current
folder. Exit codes are the log's exit line and 2 for a bad argument.

Serves the rows "SCR/land/*.py" and "Wait by blocking" in docs/contracts/RUNNING-A-PHASE-SESSION.md, and the gates
that a landing agent runs.
"""
import argparse
import glob
import os
import re
import subprocess
import sys
import time

RULE = "=" * 78


def interpreter(path):
    """bash for a shell script, else the running Python, judged by the first line and then the suffix."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            first = handle.readline()
    except OSError:
        first = ""
    if "python" in first:
        return [sys.executable]
    if "bash" in first or re.search(r"/sh\b", first) or path.endswith(".sh"):
        return ["bash"]
    return [sys.executable]


def sequence(root):
    """(label, argument list) for each gate script of the tree at root, in run order."""
    gates = []
    for pattern in ("scripts/ratchets/*.sh", "scripts/checks/*.py"):
        for path in sorted(glob.glob(os.path.join(root, pattern))):
            rel = os.path.relpath(path, root)
            gates.append((rel, interpreter(path) + [rel]))
    lint = "scripts/testing/preferences-leaks.py"
    gates.append((lint + " lint", interpreter(os.path.join(root, lint)) + [lint, "lint"]))
    return gates


def run_gate(command, root, env):
    started = time.time()
    try:
        done = subprocess.run(command, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors="replace")
        status, output = done.returncode, done.stdout
    except OSError as error:
        status, output = 127, "could not start: %s\n" % error
    return status, output, time.time() - started


def main(argv=None):
    parser = argparse.ArgumentParser(prog="run_gates.py", description="Runs the gate scripts of a worktree.")
    parser.add_argument("log", nargs="?")
    parser.add_argument("--root", default=".")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args(argv)
    if not args.list and not args.log:
        parser.error("LOG is required unless --list is given")
    root = os.path.abspath(args.root)
    gates = sequence(root)
    if args.list:
        for label, _command in gates:
            print(label)
        return 0
    env = dict(os.environ, LUNGFISH_RATCHET_READ_ONLY="1")
    rows = []
    with open(args.log, "w", encoding="utf-8") as handle:
        for label, command in gates:
            status, output, seconds = run_gate(command, root, env)
            handle.write("%s\ncommand: %s\nstatus=%d seconds=%.1f\n" % (RULE, " ".join(command), status, seconds))
            handle.write(output if output.endswith("\n") or not output else output + "\n")
            handle.flush()
            rows.append((label, status, seconds))
        failed = sum(1 for _label, status, _seconds in rows if status != 0)
        code = 1 if failed else 0
        table = "\n".join("%-60s status=%d %.1fs" % row for row in rows)
        handle.write("%s\nSUMMARY\n%s\nfailed=%d of %d\nexit=%d\n" % (RULE, table, failed, len(rows), code))
    print(table)
    print("failed=%d of %d" % (failed, len(rows)))
    return code


if __name__ == "__main__":
    sys.exit(main())
