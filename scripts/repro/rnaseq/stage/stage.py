#!/usr/bin/env python3
"""Stage public RNA-seq data on the lge_scratch drive.

Reads a TSV manifest with one file per line (url, dest_path, checksum type, checksum, bytes), downloads each file
with aria2c (curl as the fallback), checks the size and the checksum, writes a sha256 sidecar next to the file and
appends one row to the shared ledger MANIFEST.tsv. It refuses to start when the staging folder would pass the cap
(1 TB by default) or when the drive would keep less than the free-space floor (500 GB by default).

Standard library only. Run it as `python3 -I stage.py MANIFEST.tsv` and see README.md for the layout.
Downloaded files are data. This script hashes them and never opens, runs or sources them.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import fcntl
import getpass
import hashlib
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_ROOT = "/Volumes/lge_scratch/lge/rnaseq"
DEFAULT_CAP_BYTES = 1_000_000_000_000
DEFAULT_MIN_FREE_BYTES = 500_000_000_000
LEDGER_NAME = "MANIFEST.tsv"
LEDGER_COLUMNS = ("path", "url", "bytes", "checksum_type", "checksum",
                  "source_checksum_verified", "downloaded_at", "staged_by")
HASHLIB_TYPES = ("md5", "sha1", "sha256", "sha512")
KNOWN_TYPES = HASHLIB_TYPES + ("s3etag", "bsdsum")
URL_SCHEMES = ("http", "https", "ftp", "file")
MIB = 1024 * 1024
PART_SIZES_MIB = (5, 8, 10, 15, 16, 20, 25, 32, 50, 64, 100, 128, 256)
HEX_LENGTHS = {32: "md5", 40: "sha1", 64: "sha256", 128: "sha512"}

PRINT_LOCK = threading.Lock()
CHILDREN: set = set()
CHILDREN_LOCK = threading.Lock()
STOP = threading.Event()


def say(message: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    with PRINT_LOCK:
        print(f"[{stamp}] {message}", flush=True)


class ManifestError(Exception):
    """The manifest cannot be used."""


@dataclass
class Entry:
    url: str
    rel: str
    dest: Path
    ctype: str
    csum: str
    nbytes: int | None
    line: int = 0


@dataclass
class Result:
    entry: Entry
    status: str = "pending"      # staged, adopted, present, failed
    size: int = 0
    sha256: str = ""
    verified: bool = False
    verified_by: str = ""
    seconds: float = 0.0
    error: str = ""
    attempts: int = 0
    tool: str = ""


# ----------------------------------------------------------------------------------------------------------
# Manifest
# ----------------------------------------------------------------------------------------------------------

def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def inside(root: str, candidate: str) -> bool:
    return candidate == root or candidate.startswith(root.rstrip(os.sep) + os.sep)


def parse_manifest(manifest: Path, root: Path) -> list[Entry]:
    entries: list[Entry] = []
    seen: dict[str, int] = {}
    root_real = os.path.realpath(root)
    for number, raw in enumerate(manifest.read_text().splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        cols = raw.split("\t")
        if cols[0].strip().lower() == "url":
            continue
        if len(cols) < 2:
            raise ManifestError(f"line {number}: need at least a url and a dest_path")
        cols = [c.strip() for c in cols[:5]] + [""] * (5 - len(cols[:5]))
        url, dest, ctype, csum, nbytes = cols
        scheme = urllib.parse.urlparse(url).scheme
        if scheme not in URL_SCHEMES:
            raise ManifestError(f"line {number}: url scheme must be one of {', '.join(URL_SCHEMES)}")
        if not dest:
            raise ManifestError(f"line {number}: empty dest_path")
        dest_path = Path(dest) if os.path.isabs(dest) else Path(root) / dest
        dest_path = Path(os.path.normpath(dest_path))
        if not inside(root_real, os.path.join(os.path.realpath(dest_path.parent), dest_path.name)):
            raise ManifestError(f"line {number}: dest_path {dest} is outside the staging root {root}")
        rel = os.path.relpath(os.path.join(os.path.realpath(dest_path.parent), dest_path.name), root_real)
        ctype = ctype.lower()
        if ctype in ("", "none", "-"):
            ctype = ""
        if csum.lower() in ("", "none", "-"):
            csum = ""
        if csum and not ctype:
            ctype = HEX_LENGTHS.get(len(csum), "")
        if ctype and ctype not in KNOWN_TYPES:
            raise ManifestError(f"line {number}: unknown checksum type {ctype!r}")
        if not csum:
            ctype = ""
        if ctype in HASHLIB_TYPES and not re.fullmatch(r"[0-9a-fA-F]+", csum):
            raise ManifestError(f"line {number}: {ctype} value is not hexadecimal")
        if nbytes and not nbytes.isdigit():
            raise ManifestError(f"line {number}: bytes must be a whole number")
        if rel in seen:
            raise ManifestError(f"line {number}: dest_path repeats line {seen[rel]}")
        seen[rel] = number
        entries.append(Entry(url, rel, dest_path, ctype, csum.lower() if ctype != "bsdsum" else csum,
                             int(nbytes) if nbytes else None, number))
    if not entries:
        raise ManifestError("the manifest holds no files")
    return entries


# ----------------------------------------------------------------------------------------------------------
# Sizes, budget
# ----------------------------------------------------------------------------------------------------------

def head_info(url: str, timeout: int = 30) -> tuple[int | None, str | None]:
    """Content-Length and ETag of a url from an HTTP HEAD request. A file url gives the size from the disk."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "file":
        try:
            return os.stat(urllib.request.url2pathname(parsed.path)).st_size, None
        except OSError:
            return None, None
    if parsed.scheme not in ("http", "https"):
        return None, None
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "lge-stage/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            length = response.headers.get("Content-Length")
            etag = response.headers.get("ETag")
    except (urllib.error.URLError, OSError, ValueError):
        return None, None
    return (int(length) if length and length.isdigit() else None), (etag.strip() if etag else None)


def folder_usage(root: Path) -> int:
    """Bytes of every regular file under root. Symbolic links are not followed and not counted."""
    total = 0
    stack = [str(root)]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as scan:
                for item in scan:
                    try:
                        if item.is_symlink():
                            continue
                        if item.is_dir(follow_symlinks=False):
                            stack.append(item.path)
                        elif item.is_file(follow_symlinks=False):
                            total += item.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return total


def free_bytes(root: Path) -> int:
    probe = root
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return shutil.disk_usage(probe).free


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1000
    return f"{n:.2f} TB"


def budget_problems(used: int, new: int, free: int, cap: int, floor: int) -> list[str]:
    problems = []
    if used + new > cap:
        problems.append(f"the folder holds {human(used)} and {human(new)} more would pass the cap of {human(cap)}")
    if free - new < floor:
        problems.append(f"the drive has {human(free)} free and {human(new)} more would leave it under the floor of "
                        f"{human(floor)}")
    return problems


# ----------------------------------------------------------------------------------------------------------
# Hashing and verification
# ----------------------------------------------------------------------------------------------------------

class EtagTracker:
    """Reproduces an S3 ETag. A plain ETag is the MD5 of the object. A multipart ETag is the MD5 of the part MD5s
    followed by a dash and the part count. The part size is unknown, so every common size that gives the stated
    part count is tried."""

    def __init__(self, etag: str, size: int):
        self.expected = etag.strip().strip('"').lower()
        found = re.fullmatch(r"([0-9a-f]{32})(?:-([0-9]+))?", self.expected)
        self.parts = int(found.group(2)) if found and found.group(2) else 0
        self.candidates: list[dict] = []
        if not found:
            return
        if self.parts == 0:
            self.candidates.append({"size": max(size, 1), "md5": hashlib.md5(), "digests": [], "filled": 0})
            return
        for mib in PART_SIZES_MIB:
            if math.ceil(size / (mib * MIB)) == self.parts:
                self.candidates.append({"size": mib * MIB, "md5": hashlib.md5(), "digests": [], "filled": 0})

    def update(self, chunk: bytes) -> None:
        for cand in self.candidates:
            view = memoryview(chunk)
            while len(view):
                take = min(len(view), cand["size"] - cand["filled"])
                cand["md5"].update(view[:take])
                cand["filled"] += take
                view = view[take:]
                if cand["filled"] == cand["size"]:
                    cand["digests"].append(cand["md5"].digest())
                    cand["md5"] = hashlib.md5()
                    cand["filled"] = 0

    def verdict(self) -> str:
        """match, mismatch or unverifiable."""
        if not self.candidates:
            return "unverifiable"
        for cand in self.candidates:
            if cand["filled"]:
                cand["digests"].append(cand["md5"].digest())
                cand["filled"] = 0
            if self.parts == 0:
                value = cand["digests"][0].hex() if cand["digests"] else hashlib.md5(b"").hexdigest()
            else:
                value = hashlib.md5(b"".join(cand["digests"])).hexdigest() + f"-{len(cand['digests'])}"
            if value == self.expected:
                return "match"
        return "mismatch"


def bsd_sum(path: Path) -> int | None:
    """The 16 bit BSD checksum that Ensembl lists in CHECKSUMS files. The system sum tool computes it."""
    try:
        done = subprocess.run(["sum", str(path)], capture_output=True, text=True, timeout=7200,
                              stdin=subprocess.DEVNULL)
        return int(done.stdout.split()[0])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


def hash_and_check(path: Path, entry: Entry) -> tuple[str, int, bool, str]:
    """Stream the file once. Returns the sha256, the size, whether the source checksum matched and a problem text
    that is empty when the file is acceptable."""
    size = path.stat().st_size
    if entry.nbytes is not None and size != entry.nbytes:
        return "", size, False, f"size {size} does not match the expected {entry.nbytes}"
    sha = hashlib.sha256()
    other = hashlib.new(entry.ctype) if entry.ctype in HASHLIB_TYPES and entry.ctype != "sha256" else None
    etag = EtagTracker(entry.csum, size) if entry.ctype == "s3etag" else None
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(MIB)
            if not chunk:
                break
            sha.update(chunk)
            if other is not None:
                other.update(chunk)
            if etag is not None:
                etag.update(chunk)
    digest = sha.hexdigest()
    if entry.ctype == "":
        return digest, size, False, ""
    if entry.ctype == "sha256":
        ok = digest == entry.csum
    elif other is not None:
        ok = other.hexdigest() == entry.csum
    elif etag is not None:
        verdict = etag.verdict()
        if verdict == "unverifiable":
            return digest, size, False, ""
        ok = verdict == "match"
    else:  # bsdsum
        value = bsd_sum(path)
        if value is None:
            return digest, size, False, ""
        ok = value == int(entry.csum.split()[0])
    if not ok:
        return digest, size, False, f"{entry.ctype} does not match the source value"
    return digest, size, True, ""


# ----------------------------------------------------------------------------------------------------------
# Downloading
# ----------------------------------------------------------------------------------------------------------

def run_child(command: list[str]) -> tuple[int, str]:
    if STOP.is_set():
        return 143, "interrupted"
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    with CHILDREN_LOCK:
        CHILDREN.add(process)
    try:
        output, _ = process.communicate()
    finally:
        with CHILDREN_LOCK:
            CHILDREN.discard(process)
    return process.returncode, (output or "")[-600:]


def download(entry: Entry, part: Path, use_aria2: bool) -> tuple[bool, str, str]:
    """Fetch the url into the .part file. Returns success, the tool that did it and the last output."""
    scheme = urllib.parse.urlparse(entry.url).scheme
    note = ""
    if use_aria2 and scheme in ("http", "https", "ftp") and shutil.which("aria2c"):
        command = ["aria2c", "-x", "8", "-s", "8", "--continue=true", "--auto-file-renaming=false",
                   "--allow-overwrite=true", "--file-allocation=none", "--max-tries=5", "--retry-wait=5",
                   "--show-console-readout=false", "--summary-interval=0", "--console-log-level=warn",
                   "--download-result=hide", "-d", str(part.parent), "-o", part.name, entry.url]
        code, note = run_child(command)
        if code == 0:
            return True, "aria2c", note
    if STOP.is_set():
        return False, "none", "interrupted"
    if shutil.which("curl") is None:
        return False, "none", note or "neither aria2c nor curl is available"
    command = ["curl", "-sS", "-f", "-L", "--retry", "3", "--connect-timeout", "30", "-C", "-",
               "-o", str(part), entry.url]
    code, note2 = run_child(command)
    return code == 0, "curl", note2 or note


def write_text_atomic(path: Path, text: str) -> None:
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(text)
    os.replace(temp, path)


def sidecar_for(dest: Path) -> Path:
    return dest.with_name(dest.name + ".sha256")


def read_sidecar(dest: Path) -> str:
    try:
        return sidecar_for(dest).read_text().split()[0].lower()
    except (OSError, IndexError):
        return ""


# ----------------------------------------------------------------------------------------------------------
# Ledger
# ----------------------------------------------------------------------------------------------------------

def read_ledger(ledger: Path) -> dict[str, list[str]]:
    rows: dict[str, list[str]] = {}
    if not ledger.exists():
        return rows
    for line in ledger.read_text().splitlines():
        cols = line.split("\t")
        if len(cols) >= 5 and cols[0] != "path":
            rows[cols[0]] = cols
    return rows


def append_ledger(ledger: Path, row: list[str]) -> bool:
    """Append one row under an exclusive lock. A row with the same path and checksum is not written twice."""
    ledger.parent.mkdir(parents=True, exist_ok=True)
    with open(ledger, "a+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            handle.seek(0)
            content = handle.read()
            for line in content.splitlines():
                cols = line.split("\t")
                if len(cols) >= 5 and cols[0] == row[0] and cols[4] == row[4]:
                    return False
            if not content:
                handle.write("\t".join(LEDGER_COLUMNS) + "\n")
            elif not content.endswith("\n"):
                handle.write("\n")
            handle.write("\t".join(row) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    return True


def prune_ledger(ledger: Path, root: Path) -> int:
    """Drop the rows whose file no longer exists. The rewrite happens in place under the same lock as appends."""
    if not ledger.exists():
        return 0
    removed = 0
    with open(ledger, "r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            kept = []
            for index, line in enumerate(handle.read().splitlines()):
                cols = line.split("\t")
                if index == 0 and cols[0] == "path":
                    kept.append(line)
                elif cols and (root / cols[0]).exists():
                    kept.append(line)
                else:
                    removed += 1
            handle.seek(0)
            handle.write("\n".join(kept) + ("\n" if kept else ""))
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    return removed


# ----------------------------------------------------------------------------------------------------------
# One file
# ----------------------------------------------------------------------------------------------------------

@dataclass
class Context:
    root: Path
    ledger: Path
    staged_by: str
    retries: int
    use_aria2: bool
    force: bool
    cap: int
    floor: int
    used_at_start: int
    free_at_start: int
    reserved: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)


def record(entry: Entry, result: Result, ctx: Context, when: str) -> None:
    row = [str(entry.dest), entry.url, str(result.size), "sha256", result.sha256,
           "yes" if result.verified else "no", when, ctx.staged_by]
    if append_ledger(ctx.ledger, row):
        say(f"ledger row added for {entry.rel}")


def stage_locked(entry: Entry, ctx: Context) -> Result:
    result = Result(entry)
    dest = entry.dest
    part = dest.with_name(dest.name + ".part")
    started = time.monotonic()
    try:
        if STOP.is_set():
            result.status, result.error = "failed", "interrupted"
            return result
        if dest.exists() and not ctx.force:
            size = dest.stat().st_size
            if entry.nbytes is not None and size != entry.nbytes:
                result.status, result.error = "failed", f"{entry.rel} exists with {size} bytes, expected {entry.nbytes} (use --force)"
                return result
            known = read_sidecar(dest)
            if known and sidecar_for(dest).stat().st_mtime + 2 >= dest.stat().st_mtime:
                ledger_row = read_ledger(ctx.ledger).get(str(dest))
                result.status, result.size, result.sha256 = "present", size, known
                result.verified = bool(ledger_row and ledger_row[5] == "yes")
                if not ledger_row:
                    record(entry, result, ctx, dt.datetime.fromtimestamp(dest.stat().st_mtime, dt.timezone.utc)
                           .strftime("%Y-%m-%dT%H:%M:%SZ"))
                say(f"present {entry.rel} ({human(size)})")
                return result
            digest, size, ok, problem = hash_and_check(dest, entry)
            if problem:
                result.status, result.error = "failed", f"{entry.rel} exists but {problem} (use --force)"
                return result
            write_text_atomic(sidecar_for(dest), f"{digest}  {dest.name}\n")
            result.status, result.size, result.sha256, result.verified = "adopted", size, digest, ok
            record(entry, result, ctx, dt.datetime.fromtimestamp(dest.stat().st_mtime, dt.timezone.utc)
                   .strftime("%Y-%m-%dT%H:%M:%SZ"))
            say(f"adopted {entry.rel} ({human(size)}) verified={'yes' if ok else 'no'}")
            return result
        if dest.exists() and ctx.force:
            dest.unlink()
        dest.parent.mkdir(parents=True, exist_ok=True)
        wanted = entry.nbytes or 0
        with ctx.lock:
            problems = budget_problems(ctx.used_at_start + ctx.reserved, wanted,
                                       min(free_bytes(ctx.root), ctx.free_at_start - ctx.reserved),
                                       ctx.cap, ctx.floor)
            if not problems:
                ctx.reserved += wanted
        if problems:
            result.status, result.error = "failed", "budget: " + "; ".join(problems)
            return result
        attempts = ctx.retries + 1
        for attempt in range(1, attempts + 1):
            if STOP.is_set():
                result.error = "interrupted"
                break
            result.attempts = attempt
            say(f"download {entry.rel} attempt {attempt} of {attempts}"
                + (f" ({human(entry.nbytes)})" if entry.nbytes else ""))
            began = time.monotonic()
            ok, tool, note = download(entry, part, ctx.use_aria2)
            result.tool = tool
            if not ok or not part.exists():
                result.error = f"download failed with {tool}: {note.strip()[-300:]}"
                say(f"{entry.rel} {result.error}")
                continue
            fetched = time.monotonic() - began
            digest, size, good, problem = hash_and_check(part, entry)
            if problem:
                result.error = problem
                say(f"{entry.rel} {problem}, discarding the partial file")
                for stale in (part, part.with_name(part.name + ".aria2")):
                    if stale.exists():
                        stale.unlink()
                continue
            os.replace(part, dest)
            write_text_atomic(sidecar_for(dest), f"{digest}  {dest.name}\n")
            result.status, result.size, result.sha256, result.verified = "staged", size, digest, good
            result.verified_by = entry.ctype if good else ""
            result.seconds = fetched
            record(entry, result, ctx, utc_now())
            rate = size / fetched / 1e6 if fetched > 0 else 0.0
            say(f"staged {entry.rel} {human(size)} in {fetched:.1f} s ({rate:.1f} MB/s) with {tool}, "
                f"source checksum {'verified by ' + entry.ctype if good else 'not verified'}")
            return result
        result.status = "failed"
        result.seconds = time.monotonic() - started
        return result
    except Exception as error:  # a worker never takes the whole run down
        result.status, result.error = "failed", f"{type(error).__name__}: {error}"
        return result


def stage_one(entry: Entry, ctx: Context) -> Result:
    """Stage one file while holding a lock on its .lock file, so that two runs never write the same .part file.
    A file that another run is staging is skipped, and that run finishes it."""
    entry.dest.parent.mkdir(parents=True, exist_ok=True)
    lock_path = entry.dest.with_name(entry.dest.name + ".lock")
    handle = open(lock_path, "w")
    locked = False
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
        except BlockingIOError:
            say(f"busy {entry.rel} is being staged by another process, skipped")
            return Result(entry, status="busy")
        return stage_locked(entry, ctx)
    finally:
        if locked:
            try:
                os.unlink(lock_path)
            except OSError:
                pass
            fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()


# ----------------------------------------------------------------------------------------------------------
# Duplicates
# ----------------------------------------------------------------------------------------------------------

def link_duplicates(scopes: list[Path], root: Path, min_size: int = MIB) -> list[tuple[str, str]]:
    """Find regular files of at least min_size bytes with the same sha256 and size under the scopes, keep the
    oldest and turn the others into relative symbolic links. Returns the pairs (link, kept)."""
    groups: dict[tuple[str, int], list[Path]] = {}
    for scope in scopes:
        for sidecar in scope.rglob("*.sha256"):
            target = sidecar.with_name(sidecar.name[: -len(".sha256")])
            if target.is_symlink() or not target.is_file():
                continue
            digest = read_sidecar(target)
            size = target.stat().st_size
            if digest and size >= min_size:
                groups.setdefault((digest, size), []).append(target)
    pairs = []
    for files in groups.values():
        if len(files) < 2:
            continue
        files.sort(key=lambda p: (p.stat().st_mtime, str(p)))
        keeper = files[0]
        for dup in files[1:]:
            dup.unlink()
            os.symlink(os.path.relpath(keeper, dup.parent), dup)
            pairs.append((os.path.relpath(dup, root), os.path.relpath(keeper, root)))
            say(f"linked {pairs[-1][0]} to {pairs[-1][1]}")
    return pairs


# ----------------------------------------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------------------------------------

def classify(entry: Entry, ledger_rows: dict[str, list[str]], force: bool) -> str:
    if entry.dest.exists() and not force:
        return "present" if read_sidecar(entry.dest) else "adopt"
    return "todo"


def plan_bytes(entry: Entry, status: str, use_head: bool) -> tuple[int, bool]:
    """Bytes still to fetch for an entry and whether the size is known."""
    if status != "todo":
        return 0, True
    size = entry.nbytes
    if size is None and use_head:
        size, _ = head_info(entry.url)
    if size is None:
        return 0, False
    part = entry.dest.with_name(entry.dest.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    return max(size - have, 0), True


def fill_from_head(entries: list[Entry], use_etag: bool) -> None:
    """Fill a blank size and, with --etag, a blank checksum from an HTTP HEAD request."""
    for entry in entries:
        scheme = urllib.parse.urlparse(entry.url).scheme
        if scheme not in ("http", "https", "file"):
            continue
        need_size = entry.nbytes is None
        need_etag = use_etag and not entry.csum and scheme in ("http", "https")
        if not (need_size or need_etag):
            continue
        length, etag = head_info(entry.url)
        if need_size and length is not None:
            entry.nbytes = length
        if need_etag and etag and re.fullmatch(r'"?[0-9a-fA-F]{32}(-[0-9]+)?"?', etag):
            entry.ctype, entry.csum = "s3etag", etag.strip('"').lower()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Stage public RNA-seq data and keep the MANIFEST.tsv ledger.")
    parser.add_argument("manifest", nargs="?", help="TSV file with url, dest_path, checksum type, checksum, bytes")
    parser.add_argument("--root", default=DEFAULT_ROOT, help="staging root (default %(default)s)")
    parser.add_argument("--ledger", help="ledger path (default ROOT/MANIFEST.tsv)")
    parser.add_argument("--jobs", type=int, default=3, help="files downloaded at the same time (default 3)")
    parser.add_argument("--retries", type=int, default=2, help="extra tries for a failed file (default 2)")
    parser.add_argument("--dry-run", action="store_true", help="show the plan and the budget check, change nothing")
    parser.add_argument("--cap-bytes", type=int, default=DEFAULT_CAP_BYTES, help="folder cap (default 1 TB)")
    parser.add_argument("--min-free-bytes", type=int, default=DEFAULT_MIN_FREE_BYTES,
                        help="free space the drive must keep (default 500 GB)")
    parser.add_argument("--staged-by", default=os.environ.get("STAGED_BY") or getpass.getuser(),
                        help="value of the staged_by ledger column")
    parser.add_argument("--etag", action="store_true",
                        help="when the checksum is blank, check against the S3 ETag the server sends")
    parser.add_argument("--force", action="store_true", help="download again when the file already exists")
    parser.add_argument("--no-aria2", action="store_true", help="use curl only")
    parser.add_argument("--link-duplicates", action="store_true",
                        help="after staging, turn byte-identical files (same sha256) into symbolic links")
    parser.add_argument("--link-scope", action="append", default=[],
                        help="folder under the root to scan for duplicates (default the folders of the manifest)")
    parser.add_argument("--prune-ledger", action="store_true", help="drop ledger rows of files that are gone")
    return parser


def terminate_children(*_args) -> None:
    STOP.set()
    with CHILDREN_LOCK:
        for process in list(CHILDREN):
            try:
                process.terminate()
            except OSError:
                pass


def on_term(*_args) -> None:
    terminate_children()
    raise KeyboardInterrupt


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = Path(os.path.abspath(args.root))
    ledger = Path(args.ledger) if args.ledger else root / LEDGER_NAME
    if args.prune_ledger:
        say(f"pruned {prune_ledger(ledger, root)} ledger rows")
        if not args.manifest:
            return 0
    if not args.manifest:
        print("a manifest is required", file=sys.stderr)
        return 2
    if args.jobs < 1 or args.retries < 0:
        print("--jobs must be at least 1 and --retries at least 0", file=sys.stderr)
        return 2
    if not root.is_dir():
        print(f"staging root {root} does not exist, is the drive mounted?", file=sys.stderr)
        return 2
    try:
        entries = parse_manifest(Path(args.manifest), root)
    except (ManifestError, OSError) as error:
        print(f"manifest refused: {error}", file=sys.stderr)
        return 2

    fill_from_head(entries, args.etag)
    ledger_rows = read_ledger(ledger)
    statuses = {e.rel: classify(e, ledger_rows, args.force) for e in entries}
    new_bytes, unknown = 0, 0
    for entry in entries:
        size, known = plan_bytes(entry, statuses[entry.rel], use_head=False)
        new_bytes += size
        unknown += 0 if known else 1
    used = folder_usage(root) if root.exists() else 0
    free = free_bytes(root)
    problems = budget_problems(used, new_bytes, free, args.cap_bytes, args.min_free_bytes)

    say(f"stage.py pid {os.getpid()} root {root}")
    say(f"folder holds {human(used)} of a cap of {human(args.cap_bytes)}, drive has {human(free)} free "
        f"with a floor of {human(args.min_free_bytes)}")
    todo = [e for e in entries if statuses[e.rel] == "todo"]
    say(f"{len(entries)} files in the manifest, {len(todo)} to download ({human(new_bytes)}), "
        f"{len(entries) - len(todo)} already present or adoptable"
        + (f", {unknown} with an unknown size" if unknown else ""))
    if args.dry_run:
        for entry in entries:
            size = human(entry.nbytes) if entry.nbytes is not None else "size unknown"
            say(f"  {statuses[entry.rel]:7} {entry.rel} ({size}, checksum {entry.ctype or 'none'})")
    if problems:
        for problem in problems:
            say("REFUSED " + problem)
        return 2
    if args.dry_run:
        say("dry run, nothing was downloaded and no ledger row was written")
        return 0

    signal.signal(signal.SIGTERM, on_term)
    ctx = Context(root=root, ledger=ledger, staged_by=args.staged_by, retries=args.retries,
                  use_aria2=not args.no_aria2, force=args.force, cap=args.cap_bytes, floor=args.min_free_bytes,
                  used_at_start=used, free_at_start=free)
    wall = time.monotonic()
    results: list[Result] = []
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            results = list(pool.map(lambda e: stage_one(e, ctx), entries))
    except KeyboardInterrupt:
        terminate_children()
        say("interrupted, partial files stay in place for a resume")
        return 130
    wall = time.monotonic() - wall

    if args.link_duplicates:
        scopes = [root / s for s in args.link_scope] or [Path(os.path.commonpath([str(e.dest.parent) for e in entries]))]
        link_duplicates(scopes, root)

    failed = [r for r in results if r.status == "failed"]
    busy = [r for r in results if r.status == "busy"]
    fetched = [r for r in results if r.status == "staged"]
    total = sum(r.size for r in fetched)
    say("summary")
    for r in results:
        rate = f"{r.size / r.seconds / 1e6:.1f} MB/s" if r.status == "staged" and r.seconds > 0 else "-"
        say(f"  {r.status:7} {r.entry.rel} {human(r.size)} {rate} verified={'yes' if r.verified else 'no'}"
            + (f" ERROR {r.error}" if r.error and r.status == "failed" else ""))
    say(f"{len(fetched)} staged ({human(total)}), {len(results) - len(fetched) - len(failed) - len(busy)} already present, "
        f"{len(busy)} left to another process, {len(failed)} failed, wall time {wall:.0f} s"
        + (f", aggregate {total / wall / 1e6:.1f} MB/s" if fetched and wall > 0 else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
