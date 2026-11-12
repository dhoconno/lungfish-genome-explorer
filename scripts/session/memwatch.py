#!/usr/bin/env python3
"""memwatch.py [--dir DIR] [--interval SECONDS] [--rounds N] [--swap-pct P] [--pressure-level L] [--compressor-gb G]
              [--proc-gb G] [--top-count N] [--ours FILE] [--log-every SECONDS]

Watches swap use, the kernel memory pressure level, the memory compressor and the largest processes (top's MEM
column, which counts compressed memory where ps RSS hides it). It ends nothing and sends no signal. Each round it
rewrites DIR/memwatch.alarm with one line for each limit that is passed and leaves the file empty when none is. A line
starts with SWAP, PRESSURE, COMPRESSOR, RUNAWAY or BIGPROC. A process over --proc-gb is RUNAWAY when its command line
holds a line of the --ours file (one path prefix a line, for the session's worktrees), else BIGPROC. DIR/memwatch.log
gets a line when the alarm changes and a summary every --log-every seconds, DIR/memwatch.pid holds its PID from the
start, and a file DIR/memwatch.stop made after the start ends the loop. Defaults are DIR build/llm, an interval of 60
seconds, no round limit (0), swap over 90 percent, kernel pressure level 2 or worse, a compressor over 100 GiB, a
process over 16 GiB, 12 rows of top and a log summary every 600 seconds.

Prints one line at the start and one at the end. Exit codes are 0 after the loop ends and 2 for a bad argument.
Start it with run_in_background so it keeps running between turns.

Serves the row "Burn, load, memory and quota" in the End check and heartbeat table of
docs/contracts/RUNNING-A-PHASE-SESSION.md. heartbeat.sh prints its alarm file.
"""
import argparse
import os
import re
import subprocess
import sys
import time


def run(args, timeout=60):
    """Text output of one read-only command, or an empty string when it cannot run."""
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (done.stdout + done.stderr).strip()


def parse_swap(text):
    """(total, used, free) in MiB from `sysctl -n vm.swapusage`, zeros when the text is unreadable."""
    found = dict(re.findall(r"(total|used|free) = ([\d.]+)M", text))
    return tuple(float(found.get(key, 0)) for key in ("total", "used", "free"))


def to_mib(text):
    """MiB for a top memory figure such as 512K, 1234M or 2G. A bare number counts bytes."""
    match = re.match(r"([\d.]+)([KMGT]?)", text)
    if not match:
        return 0.0
    scale = {"K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024, "": 1 / (1024 * 1024)}
    return float(match.group(1)) * scale[match.group(2)]


def parse_top(text):
    """[(pid, uid, MiB)] for the rows below the PID header of `top -l 1 -o mem -stats pid,uid,mem`."""
    rows, started = [], False
    for line in text.splitlines():
        if line.startswith("PID"):
            started = True
            continue
        parts = line.split()
        if started and len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), to_mib(parts[2])))
    return rows


def parse_compressor_gib(text):
    """GiB held by the memory compressor, from vm_stat output."""
    pages = re.search(r"Pages stored in compressor:\s+(\d+)", text)
    size = re.search(r"page size of (\d+) bytes", text)
    if not pages:
        return 0.0
    return int(pages.group(1)) * (int(size.group(1)) if size else 16384) / 2**30


def read_ours(path):
    """Path prefixes of the session's own folders, one a line, blank lines and # lines skipped."""
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as handle:
            return [line.strip() for line in handle if line.strip() and not line.startswith("#")]
    except OSError:
        return []


def collect(runner, top_count=12):
    """One reading of the machine. runner(argument list) returns the text of a read-only command."""
    level = runner(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    top = runner(["top", "-l", "1", "-o", "mem", "-stats", "pid,uid,mem", "-n", str(top_count)])
    procs = []
    for pid, uid, mib in parse_top(top):
        name = os.path.basename(runner(["ps", "-o", "comm=", "-p", str(pid)]).strip())
        procs.append({"pid": pid, "uid": uid, "mib": mib, "name": name})
    return {"swap": parse_swap(runner(["sysctl", "-n", "vm.swapusage"])),
            "level": int(level) if level.isdigit() else 0,
            "compressor": parse_compressor_gib(runner(["vm_stat"])), "procs": procs}


def evaluate(reading, args, ours, command_of):
    """Alarm lines, without a time stamp, for the limits that a reading passes."""
    total, used, _free = reading["swap"]
    lines = []
    if total and used / total * 100 > args.swap_pct:
        lines.append("SWAP %.0f%% used (%.1f of %.1f GiB)" % (used / total * 100, used / 1024, total / 1024))
    if reading["level"] >= args.pressure_level:
        lines.append("PRESSURE kernel level %d" % reading["level"])
    for proc in reading["procs"]:
        if proc["mib"] / 1024 > args.proc_gb:
            command = command_of(proc["pid"])
            kind = "RUNAWAY" if any(prefix in command for prefix in ours) else "BIGPROC"
            lines.append("%s %s pid %d uid %d at %.1f GiB | %s" % (
                kind, proc["name"], proc["pid"], proc["uid"], proc["mib"] / 1024, command[:200]))
    if reading["compressor"] > args.compressor_gb:
        top = reading["procs"][0]["name"] if reading["procs"] else "?"
        lines.append("COMPRESSOR holds %.0f GiB | top: %s" % (reading["compressor"], top))
    return lines


def summary(reading):
    total, used, _free = reading["swap"]
    top = ", ".join("%s %.1fG" % (p["name"], p["mib"] / 1024) for p in reading["procs"][:5])
    return "level %d | swap %.1f of %.1f GiB | compressor %.0f GiB | top: %s" % (
        reading["level"], used / 1024, total / 1024, reading["compressor"], top)


def write_alarm(path, stamp, lines):
    """Rewrite the alarm file with the current lines. It is left empty, never removed, when none is passed."""
    with open(path, "w", encoding="utf-8") as handle:
        for line in lines:
            handle.write("%s | %s\n" % (stamp, line))


def append_log(path, stamp, text):
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("%s | %s\n" % (stamp, text))


def stop_requested(path, started):
    """True when the stop file exists and was made after the watch started, so an old one is ignored."""
    try:
        return os.path.getmtime(path) >= started
    except OSError:
        return False


def build_parser():
    parser = argparse.ArgumentParser(prog="memwatch.py", description="Watches memory and writes an alarm file.")
    add = parser.add_argument
    add("--dir", default="build/llm")
    add("--interval", type=float, default=60)
    add("--rounds", type=int, default=0, help="0 runs until the stop file")
    add("--swap-pct", type=float, default=90)
    add("--pressure-level", type=int, default=2)
    add("--compressor-gb", type=float, default=100)
    add("--proc-gb", type=float, default=16)
    add("--top-count", type=int, default=12)
    add("--ours", default=None)
    add("--log-every", type=float, default=600)
    return parser


def main(argv=None, runner=run, sleep=time.sleep, clock=time.time):
    args = build_parser().parse_args(argv)
    os.makedirs(args.dir, exist_ok=True)
    paths = {name: os.path.join(args.dir, "memwatch." + name) for name in ("alarm", "log", "pid", "stop")}
    started = clock()
    with open(paths["pid"], "w", encoding="utf-8") as handle:
        handle.write("%d\n" % os.getpid())
    print("memwatch started pid %d dir %s" % (os.getpid(), args.dir), flush=True)
    ours = read_ours(args.ours)
    previous, last_log, rounds = None, None, 0
    while not stop_requested(paths["stop"], started):
        now = clock()
        reading = collect(runner, args.top_count)
        lines = evaluate(reading, args, ours, lambda pid: runner(["ps", "-o", "command=", "-p", str(pid)]))
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
        write_alarm(paths["alarm"], stamp, lines)
        if lines != previous or last_log is None or now - last_log >= args.log_every:
            state = "ALARM " + " || ".join(lines) if lines else "ok"
            append_log(paths["log"], stamp, state + " | " + summary(reading))
            previous, last_log = lines, now
        rounds += 1
        if args.rounds and rounds >= args.rounds:
            break
        sleep(args.interval)
    print("memwatch stopped after %d rounds" % rounds, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
