#!/usr/bin/env python3
"""Measure MEGAHIT crashes at one thread against two (Phase 2.12 lane 12.29 MEGAHIT-PROBE, owner answer O8).

MEGAHIT 1.2.9 (megahit_core_no_hw_accel assemble) ended 2 of 20 repeat runs of
AssemblyConformanceTests.testMegahitProducesFinalContigs with exit -11 or -6 on Apple silicon, at two threads and
without the hardware-accelerated core. The app caps MEGAHIT at two threads there (AssemblyRunRequest.effectiveThreadCount)
and passes --no-hw-accel (ManagedAssemblyPipeline.buildMegahitCommand). This script runs that command at one thread
(arm 1) and at two (arm 2) and records what each run did. It rules nothing. Lane 13.19 reads its numbers.

Harness. Both arms run the `megahit` front end of the managed conda environment directly, with the argument list that
ManagedAssemblyPipeline.buildCommand(for:) returns for the conformance test's request on an arm64 Mac,
-1 R1 -2 R2 -o OUT --num-cpu-threads N --no-hw-accel, from the parent folder of OUT. The environment is the one
ProcessRunner.run builds (the inherited variables, PATH led by the tool's own bin folder) plus the variables of the 2.11
repeat script and LUNGFISH_REQUIRE_TOOLS=1. The arms differ only in the value after --num-cpu-threads. Running the front
end without `swift test` around it takes seconds a run, not minutes.

  run --arm 1|2|both --runs N --out FOLDER   N runs per arm, one record per run in FOLDER. A folder this plan began resumes.
      --order alternating|blocks             with both arms. alternating (the default) runs the pairs 1,2 then 2,1 then
                                             1,2 and so on, so slow drift (heat, background load) falls on both arms.
                                             blocks runs all of arm 1, then all of arm 2.
      --limit SECONDS                        a run past it is a hang and its process group is stopped (default 300)
      --pause SECONDS                        between runs (default 1)
      --allow-busy                           start although swift, xctest or megahit processes run. A dry run only.
      --tool PATH, --fixtures DIR, --conda-root DIR   other inputs. The defaults are the managed environment and
                                             Tests/Fixtures/sarscov2 of this checkout.
  summarize FOLDER                           rewrite summary.json and summary.md from the run records
  report FILE.ips ...                        print the fault of each macOS crash report as JSON
  argv --arm 1|2                             print the command line of an arm

Run folder. probe.json (plan, host, tool, hashes, environment), runs/run-NNN-tT.json (one record a run), logs/ (stdout,
stderr and MEGAHIT's own log), contigs/ (each final.contigs.fa), crash-reports/ (each new megahit_core* report, copied at
once because macOS purges them), summary.json and summary.md.

A run is a pass (exit 0 and a final.contigs.fa), a crash (a non-zero exit with a signal, read from the front end's
"Command: ...; Exit code -11" line, from the front end's own death or from a crash text), a hang (past the limit, its
group stopped) or a fail. The front end exits with 256 minus the signal when its core dies, so 245 is SIGSEGV and 250
is SIGABRT.

The script starts only the child of each run (a session of its own) and a caffeinate that ends with it, and it stops only
that child's process group. Exit status 0 means the plan finished whatever the crash count, 2 a usage error or a folder
that holds another plan, 3 refused because a swift, xctest or megahit process runs, 4 the tool or a fixture is missing
(LUNGFISH_REQUIRE_TOOLS=1 makes a missing tool a hard failure, as ToolAvailability does).
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

REPORTS = os.path.expanduser("~/Library/Logs/DiagnosticReports")
REPO = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURES = REPO / "Tests" / "Fixtures" / "sarscov2"
DEFAULT_LIMIT = 300
REPORT_WAIT = 30
BUSY_EXACT = ("xctest",)
BUSY_PREFIXES = ("swift", "megahit")
INNER_FAILURE = re.compile(r"Command: (.*?); Exit code (-?\d+)")
CRASH_TEXT = re.compile(r"Segmentation fault|Bus error|Abort trap|Illegal instruction")
THREAD_LINE = re.compile(r"threads?\b", re.IGNORECASE)
RECORD_DIRECTORIES = ("runs", "logs", "contigs", "crash-reports", "work")


def probe_variables(conda_root: str) -> dict:
    """The variables of 2.11's R5 and its repeat script plus LUNGFISH_REQUIRE_TOOLS=1 (no CLI runs here)."""
    home = str(Path.home())
    return {
        "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        "LUNGFISH_STORAGE_ROOT": home + "/.lungfish",
        "LUNGFISH_CONDA_ROOT": conda_root,
        "LUNGFISH_LIVE_NEXTFLOW_ROOT": home + "/.lungfish",
        "LUNGFISH_DEMO_ARCHIVE_DIR": "/Users/Shared/lungfish-golden/cache/demo-archives",
        "LUNGFISH_REQUIRE_TOOLS": "1",
    }


def probe_environment(tool: Path, conda_root: str) -> dict:
    """ProcessRunner.run's environment (inherited, PATH led by the tool's folder) plus the probe variables."""
    env = dict(os.environ)
    env["PATH"] = str(tool.parent) + ":" + env.get("PATH", "/usr/bin:/bin")
    env.update(probe_variables(conda_root))
    return env


def megahit_argv(r1: Path, r2: Path, out_dir: Path, threads: int) -> list:
    """ManagedAssemblyPipeline.buildMegahitCommand (:296-325) for the conformance request on an arm64 Mac.

    The request names no minimum contig length, preset, memory or extra argument, so the list is the pair, the
    output folder, the thread count and --no-hw-accel (added because AssemblyExecutionHost.capsMegahitThreads holds).
    """
    return ["-1", str(r1), "-2", str(r2), "-o", str(out_dir), "--num-cpu-threads", str(threads), "--no-hw-accel"]


def busy_processes() -> list:
    """pid:name of every swift, xctest or megahit process now running (a name is the file name of the command)."""
    listing = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True).stdout
    found = []
    for line in listing.splitlines():
        pid_text, _, command = line.strip().partition(" ")
        name = os.path.basename(command.strip())
        lowered = name.lower()
        if not pid_text.isdigit() or int(pid_text) == os.getpid():
            continue
        if lowered in BUSY_EXACT or lowered.startswith(BUSY_PREFIXES):
            found.append("%s:%s" % (pid_text, name))
    return found


def list_reports() -> list:
    return sorted(os.path.basename(path) for path in glob.glob(os.path.join(REPORTS, "megahit_core*")))


def now_text() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def write_json(path: Path, data) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(temporary, path)


def parse_report(path: str) -> dict:
    """The fault of one macOS crash report (.ips holds a JSON header line, then a JSON body)."""
    info: dict = {"file": os.path.basename(path)}
    try:
        text = Path(path).read_text(errors="replace")
        header_line, _, rest = text.partition("\n")
        try:
            header = json.loads(header_line)
            info["process"] = header.get("name") or header.get("app_name")
            info["os_version"] = header.get("os_version")
            body = json.loads(rest)
        except ValueError:
            body = json.loads(text)
    except (OSError, ValueError) as error:
        info["error"] = "unreadable: %s" % error
        return info
    exception = body.get("exception") or {}
    termination = body.get("termination") or {}
    info["exception"] = {key: exception[key] for key in ("type", "signal", "subtype") if key in exception}
    info["termination"] = termination.get("indicator") or termination.get("namespace")
    info["capture_time"] = body.get("captureTime")
    info["pid"] = body.get("pid")
    images = body.get("usedImages") or []
    threads = body.get("threads") or []
    info["thread_count"] = len(threads)
    index = body.get("faultingThread")
    if not isinstance(index, int) or not 0 <= index < len(threads):
        index = next((i for i, thread in enumerate(threads) if thread.get("triggered")), None)
    frames = []
    if index is not None:
        for frame in (threads[index].get("frames") or [])[:10]:
            number = frame.get("imageIndex")
            image = images[number] if isinstance(number, int) and 0 <= number < len(images) else {}
            location = frame.get("symbolLocation", frame.get("imageOffset", "?"))
            frames.append("%s %s+%s" % (image.get("name", "?"), frame.get("symbol", "?"), location))
    info["faulting_thread"] = index
    info["faulting_frames"] = frames
    return info


COMPLEMENT = str.maketrans("ACGTacgtNn", "TGCAtgcaNn")


def fasta_sequences(data: bytes) -> list:
    sequences: list = []
    current: list = []
    for line in data.decode("utf-8", "replace").splitlines():
        if line.startswith(">"):
            if current:
                sequences.append("".join(current))
            current = []
        elif line.strip():
            current.append(line.strip())
    if current:
        sequences.append("".join(current))
    return sequences


def file_digest(path: Path) -> dict:
    """The byte digest of final.contigs.fa (BIO 1) and two digests of its contigs that ignore their order and names.

    Threads can change the order and the numbering of contigs without changing the contigs, so the byte digest alone
    cannot tell a changed order from a changed assembly. sequence_set_sha256 sorts the sequences as written and
    canonical_set_sha256 also takes the smaller of each sequence and its reverse complement.
    """
    data = path.read_bytes()
    sequences = fasta_sequences(data)
    canonical = [min(sequence, sequence.translate(COMPLEMENT)[::-1]) for sequence in sequences]
    return {
        "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "records": len(sequences),
        "bases": sum(len(sequence) for sequence in sequences),
        "sequence_set_sha256": hashlib.sha256("\n".join(sorted(sequences)).encode()).hexdigest(),
        "canonical_set_sha256": hashlib.sha256("\n".join(sorted(canonical)).encode()).hexdigest(),
    }


def tail_text(path: Path, lines: int = 30, chars: int = 3000) -> str:
    try:
        text = path.read_bytes().decode("utf-8", "replace")
    except OSError:
        return ""
    return "\n".join(text.splitlines()[-lines:])[-chars:]


def signal_name(number: int) -> str:
    try:
        return signal.Signals(number).name
    except ValueError:
        return "signal %d" % number


def option_threads(path: Path) -> dict:
    """The thread and acceleration entries of the options.json MEGAHIT writes beside its output."""
    try:
        options = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(options, dict):
        return {}
    return {key: value for key, value in options.items() if "thread" in key.lower() or "accel" in key.lower()}


def group_alive(pgid: int) -> bool:
    """True when some process still belongs to the group. Only a group this script started is ever asked."""
    try:
        os.killpg(pgid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def sweep_group(pgid: int) -> bool:
    """True when the child's group still held processes after the child was reaped. Stops them (TERM, then KILL)."""
    if not group_alive(pgid):
        return False
    for number in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, number)
        except (ProcessLookupError, PermissionError):
            return True
        deadline = time.monotonic() + 10
        while group_alive(pgid) and time.monotonic() < deadline:
            time.sleep(0.2)
        if not group_alive(pgid):
            return True
    return True


def stop_group(child: subprocess.Popen):
    """Stops the process group of a child this script started (TERM, KILL after 30 s) and returns its status."""
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        child.wait(timeout=30)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        child.wait()
    return child.returncode


def harvest_reports(known: set, folder: Path, tag: str, wait: int) -> list:
    """Copies every megahit_core* report that is not in `known` into the run folder, waiting up to `wait` seconds for one."""
    found: dict = {}
    deadline = time.monotonic() + wait
    while True:
        fresh = [name for name in list_reports() if name not in known and name not in found]
        if fresh:
            time.sleep(2)
        for name in fresh:
            target = folder / "crash-reports" / (tag + "--" + name)
            try:
                shutil.copy2(os.path.join(REPORTS, name), target)
            except OSError as error:
                found[name] = {"file": name, "error": "not copied: %s" % error}
                continue
            entry = parse_report(str(target))
            entry["copied_to"] = str(target.relative_to(folder))
            found[name] = entry
        if found or time.monotonic() >= deadline:
            return list(found.values())
        time.sleep(1)


def schedule(arm: str, runs: int, order: str) -> list:
    """The thread count of each run, in the order the runs happen."""
    if arm != "both":
        return [int(arm)] * runs
    if order == "blocks":
        return [1] * runs + [2] * runs
    plan: list = []
    for pair in range(runs):
        plan += [1, 2] if pair % 2 == 0 else [2, 1]
    return plan


def run_once(cfg: dict, seq: int, total: int, threads: int, ordinal: int) -> dict:
    """One assembly at `threads` threads. Returns its record. Only this run's own process group is ever stopped."""
    folder: Path = cfg["folder"]
    tag = "run-%03d-t%d" % (seq, threads)
    work = folder / "work" / tag
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    out_dir = work / "out"
    command = [str(cfg["tool"])] + megahit_argv(cfg["r1"], cfg["r2"], out_dir, threads)
    stdout_path = folder / "logs" / (tag + ".stdout.txt")
    stderr_path = folder / "logs" / (tag + ".stderr.txt")
    known = set(list_reports())
    busy_before = busy_processes()
    load_before = list(os.getloadavg())
    started = now_text()
    clock = time.monotonic()
    hung = False
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        child = subprocess.Popen(
            command, cwd=work, env=cfg["env"], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
            start_new_session=True)
        try:
            status = child.wait(timeout=cfg["limit"])
        except subprocess.TimeoutExpired:
            hung = True
            status = stop_group(child)
        except BaseException:
            stop_group(child)
            raise
    wall = time.monotonic() - clock
    leftover = sweep_group(child.pid)
    load_after = list(os.getloadavg())
    busy_after = busy_processes()
    stderr_text = stderr_path.read_text(errors="replace")
    inner = INNER_FAILURE.search(stderr_text)
    inner_code = int(inner.group(2)) if inner else None
    inner_words = inner.group(1).split() if inner else []
    inner_command = " ".join([os.path.basename(inner_words[0])] + inner_words[1:2]) if inner_words else None
    inner_signal = signal_name(-inner_code) if inner_code is not None and inner_code < 0 else None
    wrapper_signal = signal_name(-status) if status is not None and status < 0 else None
    contigs = None
    contigs_file = out_dir / "final.contigs.fa"
    if contigs_file.is_file():
        contigs = file_digest(contigs_file)
        shutil.copy2(contigs_file, folder / "contigs" / (tag + ".final.contigs.fa"))
    thread_lines: list = []
    log_file = out_dir / "log"
    if log_file.is_file():
        shutil.copy2(log_file, folder / "logs" / (tag + ".megahit.log"))
        for line in log_file.read_text(errors="replace").splitlines():
            if THREAD_LINE.search(line) and line.strip() not in thread_lines:
                thread_lines.append(line.strip())
    if hung:
        result = "hang"
    elif status == 0 and contigs and contigs["bytes"] > 0:
        result = "pass"
    elif status != 0 and (inner_signal or wrapper_signal or CRASH_TEXT.search(stderr_text)):
        result = "crash"
    else:
        result = "fail"
    reports = harvest_reports(known, folder, tag, cfg["report_wait"] if result == "crash" else 0)
    options = option_threads(out_dir / "options.json")
    shutil.rmtree(work, ignore_errors=True)
    return {
        "run": seq, "of": total, "tag": tag, "arm": threads, "arm_ordinal": ordinal,
        "started": started, "wall_seconds": round(wall, 3),
        "load_before": load_before, "load_after": load_after,
        "busy_before": busy_before, "busy_after": busy_after,
        "contaminated": bool(busy_before or busy_after),
        "executable": command[0], "argv": command[1:], "threads": threads,
        "thread_lines": thread_lines[:6], "options_threads": options,
        "wrapper_status": status, "wrapper_signal": wrapper_signal,
        "inner_command": inner_command, "inner_exit_code": inner_code, "inner_signal": inner_signal,
        "signal": inner_signal or wrapper_signal,
        "hung": hung, "leftover_processes": leftover,
        "result": result, "contigs": contigs,
        "stderr_tail": tail_text(stderr_path), "stdout_tail": tail_text(stdout_path),
        "crash_reports": reports,
        "elapsed_seconds": round(time.monotonic() - clock, 3),
    }


def one_line(record: dict) -> str:
    digest = ((record.get("contigs") or {}).get("sha256") or "-")[:12]
    return "run %03d/%03d threads=%d %s wall=%.1fs status=%s signal=%s load=%.2f contigs=%s%s" % (
        record["run"], record["of"], record["threads"], record["result"], record["wall_seconds"],
        record["wrapper_status"], record["signal"], record["load_before"][0], digest,
        " BUSY" if record["contaminated"] else "")


def load_records(folder: Path) -> list:
    records = []
    for path in sorted((folder / "runs").glob("run-*.json")):
        try:
            records.append(json.loads(path.read_text()))
        except (OSError, ValueError):
            continue
    return records


def stats(values: list) -> dict:
    if not values:
        return {}
    return {"min": round(min(values), 2), "median": round(statistics.median(values), 2),
            "mean": round(statistics.fmean(values), 2), "max": round(max(values), 2)}


def late_reports(folder: Path, records: list) -> list:
    """Copies the megahit_core* reports that appeared after the plan began and that no run record holds."""
    try:
        start = set(json.loads((folder / "probe.json").read_text()).get("reports_at_start", []))
    except (OSError, ValueError):
        return []
    held = {report.get("file") for record in records for report in record.get("crash_reports") or []}
    late = []
    for name in list_reports():
        if name in start or name in held:
            continue
        target = folder / "crash-reports" / ("late--" + name)
        try:
            shutil.copy2(os.path.join(REPORTS, name), target)
        except OSError:
            continue
        entry = parse_report(str(target))
        entry["copied_to"] = str(target.relative_to(folder))
        late.append(entry)
    return late


def summarize(folder: Path) -> dict:
    records = load_records(folder)
    summary: dict = {"folder": str(folder), "runs": len(records), "arms": {}, "crashes": []}
    every: Counter = Counter()
    means = {}
    for arm in (1, 2):
        rows = [record for record in records if record.get("arm") == arm]
        crashes = [record for record in rows if record["result"] == "crash"]
        digests = Counter(record["contigs"]["sha256"] for record in rows if record.get("contigs"))
        every.update(digests)
        if rows:
            means[arm] = statistics.fmean(record["elapsed_seconds"] for record in rows)
        summary["arms"][str(arm)] = {
            "runs": len(rows),
            "pass": sum(record["result"] == "pass" for record in rows),
            "crash": len(crashes),
            "hang": sum(record["result"] == "hang" for record in rows),
            "fail": sum(record["result"] == "fail" for record in rows),
            "crashes_by_status": dict(Counter(
                "%s, front end exit %s, core exit code %s" % (
                    record.get("signal"), record.get("wrapper_status"), record.get("inner_exit_code"))
                for record in crashes)),
            "distinct_contig_digests": len(digests),
            "contig_digests": dict(digests),
            "wall_seconds": stats([record["wall_seconds"] for record in rows]),
            "load_before_1min": stats([record["load_before"][0] for record in rows]),
            "contaminated_runs": sum(bool(record.get("contaminated")) for record in rows),
            "leftover_runs": sum(bool(record.get("leftover_processes")) for record in rows),
            "reports_on_a_pass": sum(
                1 for record in rows if record["result"] == "pass" and record.get("crash_reports")),
        }
        for record in crashes:
            summary["crashes"].append({
                "run": record["run"], "threads": arm, "signal": record.get("signal"),
                "front_end_exit": record.get("wrapper_status"), "core_exit_code": record.get("inner_exit_code"),
                "core_command": record.get("inner_command"),
                "reports": [{"file": report.get("file"), "exception": report.get("exception"),
                             "fault": (report.get("faulting_frames") or ["-"])[0]}
                            for report in record.get("crash_reports") or []],
            })
    for arm in (1, 2):
        held = [record["contigs"] for record in records if record.get("arm") == arm and record.get("contigs")]
        summary["arms"][str(arm)]["distinct_sequence_sets"] = len({item.get("sequence_set_sha256") for item in held})
        summary["arms"][str(arm)]["distinct_canonical_sets"] = len({item.get("canonical_set_sha256") for item in held})
    both = [record["contigs"] for record in records if record.get("contigs")]
    summary["distinct_sequence_sets_across_arms"] = len({item.get("sequence_set_sha256") for item in both})
    summary["distinct_canonical_sets_across_arms"] = len({item.get("canonical_set_sha256") for item in both})
    summary["crashes"].sort(key=lambda crash: crash["run"])
    summary["distinct_contig_digests_across_arms"] = len(every)
    try:
        late = json.loads((folder / "late-reports.json").read_text())
    except (OSError, ValueError):
        late = []
    summary["late_reports"] = [{"file": report.get("file"), "fault": (report.get("faulting_frames") or ["-"])[0]}
                               for report in late]
    pause = 1.0
    try:
        pause = float(json.loads((folder / "probe.json").read_text())["args"]["pause"])
    except (OSError, ValueError, KeyError):
        pass
    if len(means) == 2:
        summary["estimate_40_plus_40_hours"] = round(40 * (means[1] + means[2] + 2 * pause) / 3600, 2)
    return summary


def render(summary: dict) -> str:
    lines = [
        "# MEGAHIT probe summary", "", "Folder: %s" % summary["folder"], "",
        "| threads | runs | pass | crash | hang | fail | distinct contig digests | median wall s | min wall s "
        "| max wall s | runs beside another process |",
        "|---|---|---|---|---|---|---|---|---|---|---|"]
    for arm, row in summary["arms"].items():
        wall = row["wall_seconds"] or {}
        lines.append("| %s | %d | %d | %d | %d | %d | %d | %s | %s | %s | %d |" % (
            arm, row["runs"], row["pass"], row["crash"], row["hang"], row["fail"], row["distinct_contig_digests"],
            wall.get("median", "-"), wall.get("min", "-"), wall.get("max", "-"), row["contaminated_runs"]))
    lines += ["", "Distinct final.contigs.fa digests across both arms: %d" % summary["distinct_contig_digests_across_arms"],
              "Distinct sets of contig sequences (order and names ignored) within arm 1, arm 2 and across both: %d, %d, %d"
              % (summary["arms"]["1"]["distinct_sequence_sets"], summary["arms"]["2"]["distinct_sequence_sets"],
                 summary["distinct_sequence_sets_across_arms"]),
              "Distinct sets after reverse-complement canonicalization within arm 1, arm 2 and across both: %d, %d, %d"
              % (summary["arms"]["1"]["distinct_canonical_sets"], summary["arms"]["2"]["distinct_canonical_sets"],
                 summary["distinct_canonical_sets_across_arms"]), ""]
    for arm, row in summary["arms"].items():
        for label, count in row["crashes_by_status"].items():
            lines.append("- %s thread(s), %d crash(es): %s" % (arm, count, label))
    for crash in summary["crashes"]:
        reports = ", ".join("%s (%s)" % (report["file"], report["fault"]) for report in crash["reports"]) or "no report"
        lines.append("- run %d, %d thread(s), %s, front end exit %s, core exit code %s, %s: %s" % (
            crash["run"], crash["threads"], crash["signal"], crash["front_end_exit"], crash["core_exit_code"],
            crash["core_command"], reports))
    for report in summary["late_reports"]:
        lines.append("- late report with no run: %s (%s)" % (report["file"], report["fault"]))
    if "estimate_40_plus_40_hours" in summary:
        lines += ["", "Estimate for 40 runs at each thread count at this pace and load: %s hours."
                  % summary["estimate_40_plus_40_hours"]]
    return "\n".join(lines) + "\n"


def sysctl(name: str) -> str:
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def sha256_of(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return ""


def tool_location(args) -> tuple:
    """The conda root and the megahit front end (the path ToolAvailability.require would resolve)."""
    conda_root = args.conda_root or os.environ.get("LUNGFISH_CONDA_ROOT") or str(Path.home() / ".lungfish" / "conda")
    tool = Path(args.tool) if args.tool else Path(conda_root) / "envs" / "megahit" / "bin" / "megahit"
    return conda_root, tool


def probe_header(cfg: dict, args, plan: list, busy: list) -> dict:
    tool: Path = cfg["tool"]
    try:
        done = subprocess.run([str(tool), "--version"], capture_output=True, text=True, env=cfg["env"], timeout=60)
        version = (done.stdout + done.stderr).strip()
    except (OSError, subprocess.SubprocessError) as error:
        version = "unavailable: %s" % error
    core = tool.parent / "megahit_core_no_hw_accel"
    template = megahit_argv(cfg["r1"], cfg["r2"], Path("<OUT>"), 0)
    template[template.index("--num-cpu-threads") + 1] = "<N>"
    script = Path(__file__).resolve()
    return {
        "created": now_text(), "script": str(script), "script_sha256": sha256_of(script),
        "args": {"arm": args.arm, "runs": args.runs, "order": args.order, "limit": args.limit, "pause": args.pause,
                 "report_wait": args.report_wait, "allow_busy": args.allow_busy},
        "plan": plan,
        "host": {"platform": platform.platform(), "machine": platform.machine(), "macos": platform.mac_ver()[0],
                 "cpu": sysctl("machdep.cpu.brand_string"), "cpus": os.cpu_count(),
                 "memory_bytes": sysctl("hw.memsize"), "load_at_start": list(os.getloadavg()),
                 "python": platform.python_version()},
        "tool": str(tool), "tool_version": version, "core": str(core), "core_sha256": sha256_of(core),
        "conda_packages": sorted(path.name for path in (tool.parent.parent / "conda-meta").glob("megahit-*.json")),
        "fixtures": {"r1": str(cfg["r1"]), "r1_sha256": sha256_of(cfg["r1"]),
                     "r2": str(cfg["r2"]), "r2_sha256": sha256_of(cfg["r2"])},
        "environment": {key: cfg["env"].get(key) for key in sorted(probe_variables("")) + ["PATH"]},
        "argv_template": template, "cwd": "the parent folder of <OUT>",
        "busy_at_start": busy, "reports_readable": os.access(REPORTS, os.R_OK), "reports_at_start": list_reports(),
    }


def start_caffeinate():
    """A caffeinate that holds off idle sleep and exits when this process does (it waits on our pid)."""
    try:
        return subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


def command_run(args) -> int:
    conda_root, tool = tool_location(args)
    r1, r2 = Path(args.fixtures) / "test_1.fastq.gz", Path(args.fixtures) / "test_2.fastq.gz"
    missing = [str(path) for path in (tool, r1, r2) if not path.is_file()]
    if not missing and not os.access(tool, os.X_OK):
        missing = [str(tool) + " (not executable)"]
    if missing:
        sys.stderr.write("LUNGFISH_REQUIRE_TOOLS=1 and missing: %s\n" % ", ".join(missing))
        return 4
    busy = busy_processes()
    if busy and not args.allow_busy:
        sys.stderr.write("refused, these processes run: %s\nWait for them, or pass --allow-busy for a dry run.\n"
                         % ", ".join(busy))
        return 3
    plan = schedule(args.arm, args.runs, args.order)
    folder = Path(args.out).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    for name in RECORD_DIRECTORIES:
        (folder / name).mkdir(exist_ok=True)
    cfg = {"folder": folder, "tool": tool, "r1": r1, "r2": r2, "limit": args.limit,
           "report_wait": args.report_wait, "env": probe_environment(tool, conda_root)}
    header_path = folder / "probe.json"
    if header_path.exists():
        try:
            previous = json.loads(header_path.read_text()).get("plan")
        except (OSError, ValueError):
            previous = None
        if previous != plan:
            sys.stderr.write("%s holds another plan. Use a new folder.\n" % folder)
            return 2
    else:
        write_json(header_path, probe_header(cfg, args, plan, busy))
    signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(128 + number))
    print("plan %s in %s with %s, other processes at start: %s" % (plan, folder, tool, busy or "none"), flush=True)
    keep_awake = start_caffeinate()
    seen: Counter = Counter()
    try:
        for seq, threads in enumerate(plan, 1):
            seen[threads] += 1
            record_path = folder / "runs" / ("run-%03d-t%d.json" % (seq, threads))
            if record_path.exists():
                print("run %03d at %d thread(s) is recorded, skipped" % (seq, threads), flush=True)
                continue
            record = run_once(cfg, seq, len(plan), threads, seen[threads])
            write_json(record_path, record)
            print(one_line(record), flush=True)
            if seq < len(plan):
                time.sleep(args.pause)
    finally:
        if keep_awake is not None:
            keep_awake.terminate()
    write_json(folder / "late-reports.json", late_reports(folder, load_records(folder)))
    return command_summarize(argparse.Namespace(folder=str(folder)))


def command_summarize(args) -> int:
    folder = Path(args.folder).resolve()
    summary = summarize(folder)
    write_json(folder / "summary.json", summary)
    (folder / "summary.md").write_text(render(summary))
    print(render(summary), flush=True)
    return 0


def command_report(args) -> int:
    print(json.dumps([parse_report(path) for path in args.files], indent=2))
    return 0


def command_argv(args) -> int:
    _, tool = tool_location(args)
    fixtures = Path(args.fixtures)
    print(shlex.join([str(tool)] + megahit_argv(
        fixtures / "test_1.fastq.gz", fixtures / "test_2.fastq.gz", Path("<OUT>"), int(args.arm))))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="MEGAHIT crashes at one thread against two (lane 12.29).")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run the plan and write the run folder")
    run.add_argument("--arm", choices=("1", "2", "both"), required=True)
    run.add_argument("--runs", type=int, required=True, help="runs per arm")
    run.add_argument("--out", required=True)
    run.add_argument("--order", choices=("alternating", "blocks"), default="alternating")
    run.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    run.add_argument("--pause", type=float, default=1.0)
    run.add_argument("--report-wait", type=int, default=REPORT_WAIT)
    run.add_argument("--allow-busy", action="store_true")
    run.add_argument("--tool")
    run.add_argument("--fixtures", default=str(DEFAULT_FIXTURES))
    run.add_argument("--conda-root")
    again = commands.add_parser("summarize", help="rewrite summary.json and summary.md")
    again.add_argument("folder")
    report = commands.add_parser("report", help="print the fault of each crash report")
    report.add_argument("files", nargs="+")
    show = commands.add_parser("argv", help="print the command line of an arm")
    show.add_argument("--arm", choices=("1", "2"), required=True)
    show.add_argument("--tool")
    show.add_argument("--fixtures", default=str(DEFAULT_FIXTURES))
    show.add_argument("--conda-root")
    args = parser.parse_args(argv)
    if args.command == "run" and args.runs < 1:
        parser.error("--runs must be at least 1")
    handlers = {"run": command_run, "summarize": command_summarize, "report": command_report, "argv": command_argv}
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
