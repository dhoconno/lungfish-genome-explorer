#!/usr/bin/env python3
"""run_cmd.py [--developer-dir DIR] [--cwd DIR] LOG COMMAND [ARGS...]

Runs one command as a plain argument list and writes everything to LOG, so no subshell with a redirect is needed and
the worktree guard sees one short command. The log holds a line that starts with command, a line that starts with cwd,
the output of the command with its error output merged, a line seconds=<n> and last a line exit=<status>. A blocking
wait on a line that starts with exit= therefore ends only when the command has. A command killed by a signal logs 128
plus the signal number. DEVELOPER_DIR is set to --developer-dir for the command (default
/Applications/Xcode.app/Contents/Developer, and an empty value leaves the variable alone). --cwd sets the working
folder (default the current one). The options come before LOG.

Prints nothing itself. Exit codes are the status of the command as logged, 127 when it cannot start and 2 for a missing
LOG or COMMAND.

Serves the row "Refusals, polling, cache" in the End check and heartbeat table of
docs/contracts/RUNNING-A-PHASE-SESSION.md, and is the fallback that the Commands rule of
.claude/agents/lge-lane.md and lge-lane-opus.md names for a subshell the guard refuses.
"""
import os
import subprocess
import sys
import time

DEFAULT_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
USAGE = "usage: run_cmd.py [--developer-dir DIR] [--cwd DIR] LOG COMMAND [ARGS...]\n"


def parse(argv):
    """(options, log, command), or None when LOG or COMMAND is missing."""
    options = {"--developer-dir": DEFAULT_DEVELOPER_DIR, "--cwd": os.getcwd()}
    rest = list(argv)
    while len(rest) >= 2 and rest[0] in options:
        options[rest[0]] = rest[1]
        del rest[:2]
    if len(rest) < 2:
        return None
    return options, rest[0], rest[1:]


def main(argv=None):
    parsed = parse(sys.argv[1:] if argv is None else argv)
    if parsed is None:
        sys.stderr.write(USAGE)
        return 2
    options, log, command = parsed
    env = dict(os.environ)
    if options["--developer-dir"]:
        env["DEVELOPER_DIR"] = options["--developer-dir"]
    started = time.time()
    with open(log, "w", buffering=1, encoding="utf-8") as handle:
        handle.write("command: " + " ".join(command) + "\n")
        handle.write("cwd: " + options["--cwd"] + "\n")
        handle.flush()
        try:
            status = subprocess.call(command, stdout=handle, stderr=subprocess.STDOUT, env=env, cwd=options["--cwd"])
        except OSError as error:
            handle.write("could not start: %s\n" % error)
            status = 127
        if status < 0:
            status = 128 - status
        handle.write("\nseconds=%.1f\n" % (time.time() - started))
        handle.write("exit=%d\n" % status)
    return status


if __name__ == "__main__":
    sys.exit(main())
