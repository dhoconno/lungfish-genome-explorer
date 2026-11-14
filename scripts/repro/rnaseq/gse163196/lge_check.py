"""RS-INSTRUMENT gate: the import records the same read pairs that pairhash.py finds in the source files.

Usage: python3 -I lge_check.py <lungfish-cli> <samples.tsv> <work_dir> <studies_dir>

Imports the 24 runs of samples.tsv whose column 9 is not NA, with `lungfish-cli import fastq` and no recipe,
into <work_dir>/lge/RS-INSTRUMENT/Project.lungfish, PAR (default 2) at a time. Wave 1 is the twelve 2020 runs
and wave 2 the twelve 2024 runs (SRR28...), so a wave 2 run finds its twin already in the project. Each run's
stored pair count and pair hash are compared with <work_dir>/pairhash.tsv (run, pairs, sum, from pairhash.py).
Pass: 24 of 24 equal, one "one library twice" notice in each wave 2 log naming that run's twin, and none in a
wave 1 log. Writes compare.tsv, prints the sha256 of pairhash.tsv and removes the project only on a pass.
Exit 0 on a pass and 1 otherwise.
"""
import concurrent.futures
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

NOTICE = re.compile(r"holds the same (\d+) read pairs as bundle (.+?), in any order")


def read_runs(samples):
    rows = [line.rstrip("\n").split("\t") for line in open(samples)]
    head = rows[0]
    run_i, study_i, twin_i = head.index("run"), head.index("study"), head.index("same_counts_as")
    return [(r[run_i], r[study_i], r[twin_i]) for r in rows[1:] if r[twin_i] != "NA"]


def import_run(cli, project, fastq, logs, run):
    cmd = [cli, "import", "fastq", f"{fastq}/{run}_1.fastq.gz", f"{fastq}/{run}_2.fastq.gz",
           "--project", project, "--name", run, "-t", "8", "--clumpify-heap-gb", "12"]
    t0 = time.monotonic()
    with open(f"{logs}/{run}.log", "w") as log:
        rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
    secs = time.monotonic() - t0
    print(f"{run} rc {rc} {secs:.0f} s", flush=True)
    return rc, secs


def stored_facts(project, run):
    """The stored pair count, pair hash and instrument of one imported run (None when no sidecar holds them)."""
    for path in sorted(glob.glob(f"{project}/Imports/{run}.lungfishfastq/*.lungfish-meta.json")):
        meta = json.load(open(path))
        rec = meta.get("recordedReadCount")
        if rec:
            return rec.get("paired_r1"), str(rec.get("pair_hash")).lower(), meta.get("sequencerInstrument")
    return None, None, None


def notices(log_path):
    """The bundle names of every "one library twice" notice in one import log, one list a notice."""
    found = []
    for line in open(log_path, errors="replace").read().splitlines():
        if "one library twice" in line:
            m = NOTICE.search(line)
            names = re.split(r",\s*|\s+and\s+", m.group(2)) if m else []
            found.append([n.strip().removesuffix(".lungfishfastq") for n in names])
    return found


def main():
    cli, samples, work, studies = sys.argv[1:5]
    runs = read_runs(samples)
    base = f"{work}/lge/RS-INSTRUMENT"
    project, logs = f"{base}/Project.lungfish", f"{base}/logs"
    shutil.rmtree(project, ignore_errors=True)
    os.makedirs(project)
    os.makedirs(logs, exist_ok=True)
    expect = {}
    for line in open(f"{work}/pairhash.tsv"):
        run, pairs, total = line.rstrip("\n").split("\t")
        expect[run] = (int(pairs), total)
    twin = {run: t for run, _, t in runs}
    study = {run: s for run, s, _ in runs}
    waves = [[r for r, _, _ in runs if not r.startswith("SRR28")], [r for r, _, _ in runs if r.startswith("SRR28")]]
    done = {}
    for wave in waves:
        with concurrent.futures.ThreadPoolExecutor(int(os.environ.get("PAR", "2"))) as pool:
            jobs = {run: pool.submit(import_run, cli, project, f"{studies}/{study[run]}/fastq", logs, run) for run in wave}
            done.update({run: job.result() for run, job in jobs.items()})
    head = "run twin wave rc seconds pairs_lge pairs_ref hash_lge hash_ref equal notices notice_twins notice_right instrument"
    rows = [head.replace(" ", "\t")]
    equal_n = right_n = 0
    for n, wave in enumerate(waves, 1):
        for run in wave:
            rc, secs = done[run]
            pairs, digest, instrument = stored_facts(project, run)
            want_pairs, want_digest = expect[run]
            equal = rc == 0 and pairs == want_pairs and digest == want_digest
            found = notices(f"{logs}/{run}.log")
            names = [name for one in found for name in one]
            right = (len(found) == 1 and names == [twin[run]]) if n == 2 else not found
            equal_n += equal
            right_n += right
            cells = (run, twin[run], n, rc, f"{secs:.0f}", pairs, want_pairs, digest, want_digest, "yes" if equal else "NO",
                     len(found), ",".join(names), "yes" if right else "NO", json.dumps(instrument, sort_keys=True))
            rows.append("\t".join(str(c) for c in cells))
    open(f"{base}/compare.tsv", "w").write("\n".join(rows) + "\n")
    print("sha256 of pairhash.tsv", hashlib.sha256(open(f"{work}/pairhash.tsv", "rb").read()).hexdigest())
    passed = equal_n == len(runs) and right_n == len(runs)
    print(f"{equal_n} of {len(runs)} counts and hashes equal, {right_n} of {len(runs)} runs with the right notices, "
          f"{'PASS' if passed else 'FAIL'}, table {base}/compare.tsv", flush=True)
    if passed:
        shutil.rmtree(project)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
