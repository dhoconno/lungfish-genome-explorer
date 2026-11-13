#!/usr/bin/env python3
"""Turn an ENA filereport TSV into a stage.py manifest under studies/<id>/raw/.

ENA lists the files of every run in the semicolon separated columns fastq_ftp, fastq_md5 and fastq_bytes (and
submitted_ftp, submitted_md5 and submitted_bytes for the files the submitter uploaded). Each file becomes one
manifest line with ENA's md5 as the expected checksum, so stage.py verifies every read file against ENA.

Get the filereport from the ENA portal, for example
  https://www.ebi.ac.uk/ena/portal/api/filereport?accession=PRJNA123456&result=read_run&format=tsv&download=true&fields=run_accession,fastq_ftp,fastq_md5,fastq_bytes,submitted_ftp,submitted_md5,submitted_bytes
or let this script fetch it with --fetch ACCESSION. Standard library only. Run it with python3 -I.
"""
from __future__ import annotations

import argparse
import csv
import io
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_ROOT = "/Volumes/lge_scratch/lge/rnaseq"
FIELDS = ("run_accession,experiment_accession,sample_accession,library_layout,library_strategy,read_count,"
          "base_count,fastq_ftp,fastq_md5,fastq_bytes,submitted_ftp,submitted_md5,submitted_bytes")
PORTAL = "https://www.ebi.ac.uk/ena/portal/api/filereport"


def to_https(location: str) -> str:
    """ENA lists host/path without a scheme. HTTPS from the same host serves the same files."""
    location = location.strip()
    if location.startswith("ftp://"):
        return "https://" + location[len("ftp://"):]
    if location.startswith(("http://", "https://")):
        return location
    return "https://" + location


def fetch_filereport(accession: str) -> str:
    query = urllib.parse.urlencode({"accession": accession, "result": "read_run", "fields": FIELDS,
                                    "format": "tsv", "download": "true"})
    request = urllib.request.Request(f"{PORTAL}?{query}", headers={"User-Agent": "lge-stage-ena/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read().decode("utf-8")


def manifest_rows(report: str, study: str, kind: str, runs: set[str] | None) -> tuple[list[list[str]], list[str]]:
    """Manifest rows (url, dest_path, type, md5, bytes) and the runs that had no file of this kind."""
    reader = csv.DictReader(io.StringIO(report), delimiter="\t")
    names = reader.fieldnames or []
    needed = [f"{kind}_ftp", f"{kind}_md5", f"{kind}_bytes"]
    missing = [name for name in needed if name not in names]
    if missing:
        raise SystemExit(f"the filereport lacks the column(s) {', '.join(missing)}")
    rows: list[list[str]] = []
    skipped: list[str] = []
    seen: set[str] = set()
    for record in reader:
        run = (record.get("run_accession") or "").strip()
        if runs is not None and run not in runs:
            continue
        urls = [u for u in (record[needed[0]] or "").split(";") if u.strip()]
        md5s = [m for m in (record[needed[1]] or "").split(";") if m.strip()]
        sizes = [b for b in (record[needed[2]] or "").split(";") if b.strip()]
        if not urls:
            skipped.append(run or "(no run accession)")
            continue
        if not (len(urls) == len(md5s) == len(sizes)):
            raise SystemExit(f"run {run}: {len(urls)} files, {len(md5s)} md5 values and {len(sizes)} sizes disagree")
        for url, md5, size in zip(urls, md5s, sizes):
            name = os.path.basename(urllib.parse.urlparse(to_https(url)).path)
            if not name or name in seen:
                raise SystemExit(f"run {run}: file name {name!r} is empty or repeats")
            seen.add(name)
            rows.append([to_https(url), f"studies/{study}/raw/{name}", "md5", md5.strip().lower(), size.strip()])
    return rows, skipped


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Make a stage.py manifest from an ENA filereport TSV.")
    parser.add_argument("filereport", nargs="?", help="filereport TSV, or - for standard input")
    parser.add_argument("--fetch", metavar="ACCESSION", help="download the filereport of a study or project first")
    parser.add_argument("--study", help="study id, the folder name under studies/ (default the --fetch accession)")
    parser.add_argument("--files", choices=("fastq", "submitted"), default="fastq",
                        help="fastq files made by ENA (default) or the files the submitter uploaded")
    parser.add_argument("--runs", help="only these runs, a comma separated list or @file with one run per line")
    parser.add_argument("--max-bytes", type=int, help="refuse when the listed files add up to more than this")
    parser.add_argument("--root", default=DEFAULT_ROOT, help="staging root (default %(default)s)")
    parser.add_argument("--out", help="manifest path (default ROOT/studies/<id>/raw/manifest.tsv), - for standard output")
    parser.add_argument("--save-filereport", help="where to keep the fetched filereport")
    args = parser.parse_args(argv)

    study = args.study or args.fetch
    if not study:
        parser.error("give --study (or --fetch ACCESSION)")
    if args.fetch:
        report = fetch_filereport(args.fetch)
        if args.save_filereport:
            Path(args.save_filereport).write_text(report)
    elif args.filereport == "-":
        report = sys.stdin.read()
    elif args.filereport:
        report = Path(args.filereport).read_text()
    else:
        parser.error("give a filereport file or --fetch ACCESSION")

    runs = None
    if args.runs:
        if args.runs.startswith("@"):
            runs = {line.strip() for line in Path(args.runs[1:]).read_text().splitlines() if line.strip()}
        else:
            runs = {item.strip() for item in args.runs.split(",") if item.strip()}

    rows, skipped = manifest_rows(report, study, args.files, runs)
    if not rows:
        print("no files to stage", file=sys.stderr)
        return 1
    total = sum(int(row[4]) for row in rows)
    if args.max_bytes is not None and total > args.max_bytes:
        print(f"refused, {len(rows)} files add up to {total} bytes, over {args.max_bytes}", file=sys.stderr)
        return 2

    text = "# url\tdest_path\tchecksum_type\tchecksum\tbytes\n" + "".join("\t".join(row) + "\n" for row in rows)
    if args.out == "-":
        sys.stdout.write(text)
    else:
        out = Path(args.out) if args.out else Path(args.root) / "studies" / study / "raw" / "manifest.tsv"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print(f"wrote {out}", file=sys.stderr)
    print(f"{len(rows)} files, {total} bytes ({total / 1e9:.2f} GB), {len(skipped)} runs without {args.files} files",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
