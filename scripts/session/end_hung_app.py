#!/usr/bin/env python3
"""end_hung_app.py --list | PID [--execute] [--wait SECONDS] [--bundle NAME ...]

Ends one hung Lungfish app by its PID. --list prints each process whose executable lies inside a Lungfish app bundle
as "pid <n> rss <MiB> MiB uid <n> app|helper <executable>", or "none". An app is the main program in
NAME/Contents/MacOS/ and a helper is any other file of the bundle. The bundle names default to Lungfish.app,
Lungfish Preview.app and Lungfish Debug.app, the three names in config/release-contract.json, and --bundle replaces
them. With a PID the script refuses unless that process is an app (exit 4) owned by the user who runs it (exit 4), and
prints what it would do. Only --execute acts. It sends SIGTERM, checks once a second for --wait seconds (default 20)
and, if the same program still runs, sends SIGKILL, since the last check showed that the PID still names the app. It
signals only the PID given and never finds a process by name.

Prints ENDED, DRY RUN, REFUSED, NOT FOUND or STILL RUNNING and the PID. Exit codes are 0 for ENDED, a dry run or a
listing, 2 for a bad argument, 3 when no process has the PID, 4 for a refusal and 5 when the app still runs.

Serves the rows "Leftover processes, with the command below" and "Own processes only" in
docs/contracts/RUNNING-A-PHASE-SESSION.md.
"""
import argparse
import os
import signal
import subprocess
import sys
import time

BUNDLES = ("Lungfish.app", "Lungfish Preview.app", "Lungfish Debug.app")


def parse_ps(text):
    """[(pid, uid, rss_kib, executable)] from `ps -axo pid=,uid=,rss=,comm=`."""
    rows = []
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and all(part.isdigit() for part in parts[:3]):
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3].strip()))
    return rows


def kind_of(executable, bundles):
    """app for the main program of a bundle, helper for any other file inside one, else None."""
    if any("/%s/Contents/MacOS/" % name in executable for name in bundles):
        return "app"
    return "helper" if any("/%s/Contents/" % name in executable for name in bundles) else None


class Machine:
    """The real machine. Tests pass a stand-in that records the signals and sends none."""

    def processes(self):
        try:
            done = subprocess.run(["ps", "-axo", "pid=,uid=,rss=,comm="], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return []
        return parse_ps(done.stdout)

    def uid(self):
        return os.getuid()

    def send(self, pid, number):
        os.kill(pid, number)

    def sleep(self, seconds):
        time.sleep(seconds)


def find(machine, pid):
    return next((row for row in machine.processes() if row[0] == pid), None)


def list_apps(machine, bundles, out):
    rows = [row for row in machine.processes() if kind_of(row[3], bundles)]
    for pid, uid, rss, exe in rows:
        out("pid %d rss %d MiB uid %d %s %s" % (pid, rss // 1024, uid, kind_of(exe, bundles), exe))
    if not rows:
        out("none")
    return 0


def end_app(machine, pid, execute, wait, bundles, out):
    row = find(machine, pid)
    if row is None:
        out("NOT FOUND pid %d" % pid)
        return 3
    _pid, uid, rss, exe = row
    if kind_of(exe, bundles) != "app":
        out("REFUSED pid %d runs %s, which is not the main program of a Lungfish app bundle" % (pid, exe))
        return 4
    if uid != machine.uid():
        out("REFUSED pid %d belongs to uid %d, not to this user" % (pid, uid))
        return 4
    if not execute:
        out("DRY RUN would send SIGTERM to pid %d (%s, %d MiB), wait up to %d seconds, then send SIGKILL if it still "
            "runs. Add --execute to do it" % (pid, exe, rss // 1024, wait))
        return 0

    def running():
        now = find(machine, pid)
        return now is not None and now[3] == exe

    machine.send(pid, signal.SIGTERM)
    for _ in range(max(wait, 1)):
        machine.sleep(1)
        if not running():
            out("ENDED pid %d with SIGTERM" % pid)
            return 0
    machine.send(pid, signal.SIGKILL)
    for _ in range(5):
        machine.sleep(1)
        if not running():
            out("ENDED pid %d with SIGKILL after SIGTERM" % pid)
            return 0
    out("STILL RUNNING pid %d after SIGKILL" % pid)
    return 5


def main(argv=None, machine=None, out=print):
    parser = argparse.ArgumentParser(prog="end_hung_app.py", description="Ends one hung Lungfish app by PID.")
    parser.add_argument("pid", nargs="?", type=int)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--wait", type=int, default=20, metavar="SECONDS")
    parser.add_argument("--bundle", action="append", metavar="NAME")
    args = parser.parse_args(argv)
    if args.list == (args.pid is not None):
        parser.error("give either --list or a PID")
    if args.pid is not None and args.pid <= 0:
        parser.error("PID must be a positive number")
    machine = machine or Machine()
    bundles = tuple(args.bundle) if args.bundle else BUNDLES
    if args.list:
        return list_apps(machine, bundles, out)
    return end_app(machine, args.pid, args.execute, args.wait, bundles, out)


if __name__ == "__main__":
    sys.exit(main())
