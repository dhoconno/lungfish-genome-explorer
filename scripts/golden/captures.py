"""The four Phase 1 golden captures.

Each capture has two steps. `run` executes lungfish-cli in the capture's own
folder under the scratch root and keeps the exit status, stdout and stderr of
every command under logs/. `collect` reads the outputs back and queues the
golden files. `CaptureContext.finish` then registers the digests the identity
masks need, normalizes every queued golden and checks the result. Keeping the
steps apart lets `golden.py --replay` normalize a kept scratch folder again
without rerunning any tool.
"""

from __future__ import annotations

import concurrent.futures
import gzip
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import normalize

# Inputs the genotype capture downloads. Pinned here rather than read from the
# bundled demo manifest so that a newer demo release cannot change the golden.
MHC_DEMO = {
    "id": "mhc-genotyping",
    "version": "2026.9.58",
    "url": "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/"
    "demo-projects/lge-demo-mhc-genotyping-2026.9.58.zip",
    "sha256": "f11b808067437ae3182efe31d50fc0a047857ae0a14cd20f564abd15b673fba0",
    "bytes": 110747,
    "projectFolder": "MHC Genotyping.lungfish",
}

KRAKEN2_DATABASE = "Viral"
KRAKEN2_DATABASE_FILES = ("hash.k2d", "opts.k2d", "taxo.k2d")
ESVIRITU_DATABASE = "EsViritu Viral DB"

# The thread counts are pinned so the argv and provenance do not depend on the
# machine's core count.
THREADS = "2"

# The app spawns the CLI with Finder's bare PATH, and so does the golden run.
BARE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

COMMAND_TIMEOUT_SECONDS = 3600

_UUID_SUFFIX = re.compile(r"-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
_LOG_LABEL = re.compile(r"[^A-Za-z0-9._-]+")


class CaptureError(RuntimeError):
    """A capture could not produce its outputs."""


@dataclass
class Golden:
    """One queued golden file, normalized by CaptureContext.finish."""

    relpath: str
    kind: str  # text, sorted, xlsx, snapshot or request
    raw: bytes
    source: Path | None = None
    header_lines: int = 0


@dataclass
class CaptureContext:
    name: str
    repo_root: Path
    cli: Path | None
    run_root: Path  # the scratch root the tools ran in; its path becomes <RUN_ROOT>
    cache_root: Path
    strict: bool = False
    work_root: Path | None = None  # where <name>/ lives when it is not run_root (replay)
    queue: list[Golden] = field(default_factory=list)
    inputs: set[Path] = field(default_factory=set)  # files the capture itself wrote
    outputs: dict[str, bytes] = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)
    normalizer: normalize.Normalizer | None = None

    @property
    def work(self) -> Path:
        return (self.work_root or self.run_root) / self.name

    # Run step ---------------------------------------------------------------

    def prepare(self) -> None:
        if self.work.exists():
            shutil.rmtree(self.work)
        (self.work / "tmp").mkdir(parents=True)
        (self.work / "logs").mkdir()

    def environment(self) -> dict[str, str]:
        user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
        return {
            "HOME": str(Path.home()),
            "USER": user,
            "LOGNAME": user,
            "PATH": BARE_PATH,
            "TMPDIR": str(self.work / "tmp") + "/",
            "COLUMNS": "80",
            "LINES": "24",
        }

    def log_file(self, label: str, stream: str) -> Path:
        """logs/<label>.<stream>, where stream is argv, exit, stdout or stderr."""
        return self.work / "logs" / f"{_LOG_LABEL.sub('_', label)}.{stream}"

    def run(self, args: list, *, label: str, expect: int | None = 0, cwd: Path | None = None) -> subprocess.CompletedProcess:
        argv = [str(arg) for arg in args]
        completed = subprocess.run(
            argv,
            cwd=str(cwd or self.work),
            env=self.environment(),
            capture_output=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
        self.log_file(label, "argv").write_text("\n".join(argv) + "\n")
        self.log_file(label, "exit").write_text(f"{completed.returncode}\n")
        self.log_file(label, "stdout").write_bytes(completed.stdout)
        self.log_file(label, "stderr").write_bytes(completed.stderr)
        if expect is not None and completed.returncode != expect:
            tail = (completed.stdout[-2000:] + b"\n" + completed.stderr[-4000:]).decode("utf-8", "replace")
            raise CaptureError(
                f"{self.name}: {label} exited {completed.returncode}, expected {expect}\n"
                f"command: {' '.join(argv)}\n{tail}"
            )
        return completed

    def cli_run(self, args: list, *, label: str, expect: int | None = 0, cwd: Path | None = None) -> subprocess.CompletedProcess:
        if self.cli is None:
            raise CaptureError(f"{self.name}: no lungfish-cli to run {label}")
        return self.run([self.cli, *args], label=label, expect=expect, cwd=cwd)

    def tool(self, args: list) -> bytes:
        """Run a read-only helper (samtools) during collect and return stdout."""
        completed = subprocess.run([str(arg) for arg in args], env=self.environment(), capture_output=True,
                                   timeout=COMMAND_TIMEOUT_SECONDS)
        if completed.returncode != 0:
            raise CaptureError(f"{self.name}: {' '.join(map(str, args))} exited {completed.returncode}\n"
                               + completed.stderr.decode("utf-8", "replace")[-2000:])
        return completed.stdout

    def wrote_input(self, path: Path) -> Path:
        """Record a file the capture wrote itself (an input). The volatility
        check skips it, and its timestamps and UUIDs count as stable values.
        The list is kept in logs/inputs.txt so a replay sees it too."""
        with (self.work / "logs" / "inputs.txt").open("a") as handle:
            handle.write(path.relative_to(self.work).as_posix() + "\n")
        return path

    def load_inputs(self) -> None:
        listing = self.work / "logs" / "inputs.txt"
        if listing.exists():
            self.inputs = {(self.work / line).resolve() for line in listing.read_text().splitlines() if line}

    # Collect step -----------------------------------------------------------

    def logged(self, label: str) -> tuple[int, bytes, bytes]:
        try:
            return (int(self.log_file(label, "exit").read_text()), self.log_file(label, "stdout").read_bytes(),
                    self.log_file(label, "stderr").read_bytes())
        except FileNotFoundError as error:
            raise CaptureError(f"{self.name}: no log for {label} ({error.filename})") from error

    def stdout(self, label: str) -> str:
        return self.logged(label)[1].decode("utf-8")

    def queue_golden(self, golden: Golden) -> None:
        if any(item.relpath == golden.relpath for item in self.queue):
            raise CaptureError(f"{self.name}: duplicate golden path {golden.relpath}")
        self.queue.append(golden)

    def put_text(self, relpath: str, text: str) -> None:
        self.queue_golden(Golden(relpath, "text", text.encode("utf-8")))

    def put_file(self, relpath: str, path: Path) -> None:
        self.queue_golden(Golden(relpath, "text", read_bytes(path), path))

    def put_json(self, relpath: str, value) -> None:
        self.put_text(relpath, json.dumps(value, indent=2, sort_keys=True) + "\n")

    def put_sorted_table(self, relpath: str, path: Path, header_lines: int = 1) -> None:
        self.queue_golden(Golden(relpath, "sorted", read_bytes(path), path, header_lines))

    def put_xlsx(self, relpath: str, path: Path) -> None:
        self.queue_golden(Golden(relpath, "xlsx", path.read_bytes(), path))

    def put_snapshot(self, relpath: str, path: Path) -> None:
        self.queue_golden(Golden(relpath, "snapshot", path.read_bytes(), path))

    def put_request(self, relpath: str, path: Path) -> None:
        self.queue_golden(Golden(relpath, "request", path.read_bytes(), path))

    def put_inventory(self, relpath: str, root: Path) -> None:
        self.put_text(relpath, inventory(root))

    def put_command(self, relpath: str, label: str) -> None:
        """Exit status, stdout and stderr of one command whose terminal output
        is part of the contract."""
        exit_status, stdout, stderr = self.logged(label)
        self.put_text(relpath, f"exit: {exit_status}\n--- stdout\n{stdout.decode('utf-8', 'replace')}"
                               f"--- stderr\n{stderr.decode('utf-8', 'replace')}")

    def register_file(self, path: Path, rule: str, label: str, *, mask_size: bool = False, pending: bool = False) -> None:
        """Mask every occurrence of this file's SHA-256 (identity mask)."""
        self.normalizer.register(normalize.VolatileDigest(sha256_file(path), rule, label, mask_size, pending))

    # Finish -------------------------------------------------------------------

    def finish(self) -> None:
        """Register identity digests, normalize every queued golden, check."""
        n = self.normalizer
        self.load_inputs()
        for path in sorted(self.inputs):
            try:
                n.add_stable_values(read_bytes(path).decode("utf-8"))
            except (UnicodeDecodeError, OSError, EOFError, gzip.BadGzipFile):
                continue
        # A file or payload can hold the digest of another one, so registration
        # repeats until no new digest is masked. Volatility is cached per item
        # for each size of the digest set.
        volatile: dict[tuple[str, int], bool] = {}
        changed = True
        while changed:
            changed = False
            for golden in self.queue:
                if golden.kind in ("snapshot", "request"):
                    changed |= bool(n.register_payloads(golden.raw.decode("utf-8"), golden.relpath))
            for golden in self.queue:
                # R10: a captured file that holds a masked field changes its own
                # SHA-256 and size from run to run, and its content is compared
                # here, so its digest and size are masked wherever recorded.
                if golden.source is None:
                    continue
                key = (golden.relpath, len(n.digests))
                if key not in volatile:
                    volatile[key] = self.holds_run_dependent_field(golden)
                if volatile[key]:
                    entry = normalize.VolatileDigest(sha256_file(golden.source), "R10", golden.relpath, mask_size=True)
                    changed |= n.register(entry)
        for golden in self.queue:
            for relpath, data in self.normalized(golden).items():
                if relpath in self.outputs:
                    raise CaptureError(f"{self.name}: duplicate golden path {relpath}")
                self.outputs[relpath] = data
        self.check_recorded_digests()
        self.check_unmasked_volatile_references()
        self.outputs["normalization.tsv"] = self.normalization_table()

    def holds_run_dependent_field(self, golden: Golden) -> bool:
        """True when the golden's source file holds a masked field whose value
        changes from run to run, so the file's own SHA-256 and size change."""
        n = self.normalizer
        if golden.kind == "xlsx":
            # docProps/core.xml records the time of the export.
            return n.xlsx_parts(golden.raw) != n.xlsx_parts(golden.raw, relocate_only=True)
        try:
            text = golden.raw.decode("utf-8")
        except UnicodeDecodeError:
            return False
        if n.holds_run_dependent_field(text):
            return True
        if golden.kind == "snapshot":
            return n.payloads_hold_run_dependent_field(text, "capturedScientificInputs")
        if golden.kind == "request":
            return n.payloads_hold_run_dependent_field(text, "inputs")
        return False

    def normalized(self, golden: Golden) -> dict[str, bytes]:
        n = self.normalizer
        if golden.kind == "xlsx":
            return {f"{golden.relpath}.parts/{part}": data for part, data in n.xlsx_parts(golden.raw).items()}
        text = golden.raw.decode("utf-8")
        if golden.kind == "sorted":
            return {golden.relpath: sorted_table(n.text(text), golden.header_lines).encode("utf-8")}
        if golden.kind == "snapshot":
            snapshot, payloads = n.snapshot(text)
            folder = golden.relpath.rsplit("/", 1)[0]
            out = {golden.relpath: snapshot.encode("utf-8")}
            for name, payload in payloads.items():
                out[f"{folder}/captured-inputs/{name}"] = payload
            return out
        if golden.kind == "request":
            return {golden.relpath: n.request(text).encode("utf-8")}
        return {golden.relpath: n.text(text).encode("utf-8")}

    def resolve_record_path(self, recorded: str, golden: Golden) -> Path | None:
        """The file a provenance record names, when its path form can be resolved."""
        run_root = str(self.run_root)
        if recorded.startswith(run_root + "/"):
            return self.work.parent / recorded[len(run_root) + 1:]
        if recorded.startswith("@/") and golden.source is not None:
            for parent in golden.source.parents:
                if parent.suffix == ".lungfish":
                    return parent / recorded[2:]
            return None
        if not recorded.startswith(("/", "<", "@", "file:")) and golden.source is not None:
            return golden.source.parent / recorded
        return None

    def check_recorded_digests(self) -> None:
        """R10 asks that a masked record's hash match the file on disk at capture
        time. A record of a registered file with any other digest is a problem."""
        n = self.normalizer
        for golden in self.queue:
            if golden.kind not in ("text", "request", "snapshot") or golden.source is None:
                continue
            root = normalize.parse_json(golden.raw.decode("utf-8", "replace"))
            if root is None:
                continue
            for record in normalize.file_records(root):
                path = self.resolve_record_path(str(record.get("path").value), golden)
                if path is None or not path.is_file():
                    continue
                on_disk = sha256_file(path)
                if on_disk not in n.digests:
                    continue
                for key in normalize.HASH_KEYS:
                    node = record.get(key)
                    if node is not None and node.value != on_disk:
                        self.problems.append(
                            f"{golden.relpath} records {key} {node.value} for {path.name}, "
                            f"but the file on disk has {on_disk}"
                        )

    def check_unmasked_volatile_references(self) -> None:
        """A golden that still records the digest of a file holding a masked field
        would change from run to run. Every such reference is a problem."""
        by_digest: dict[str, Path] = {}
        for path in sorted(self.work.rglob("*")):
            if path.is_file() and not path.is_symlink() and path.resolve() not in self.inputs:
                by_digest.setdefault(sha256_file(path), path)
        reported = set()
        for relpath, data in self.outputs.items():
            for digest in set(normalize.SHA256_HEX.findall(data.decode("utf-8", "replace"))):
                path = by_digest.get(digest)
                if path is None or digest in reported:
                    continue
                try:
                    text = path.read_bytes().decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if self.normalizer.holds_run_dependent_field(text):
                    reported.add(digest)
                    self.problems.append(
                        f"{relpath} records the digest of {path.relative_to(self.work)}, which holds a masked "
                        "field but is not captured as a golden"
                    )

    def normalization_table(self) -> bytes:
        """Every path rule and every file or payload whose digest is masked, so
        the set of masks is itself compared. An identity item is listed whether
        or not a golden records its digest, because that does not change from
        run to run while digest coincidences can."""
        n = self.normalizer
        rows = ["rule\tfile, payload or record path\tsize masked\tstatus"]
        for rule in n.path_rules:
            for suffix in rule.suffixes:
                rows.append(f"{rule.rule}\trecords whose path ends in {suffix}\t"
                            f"{'yes' if rule.mask_size else 'no'}\t{'pending' if rule.pending else 'ruled'}")
        for entry in sorted(n.items, key=lambda e: (e.rule, e.label)):
            rows.append(f"{entry.rule}\t{entry.label}\t{'yes' if entry.mask_size else 'no'}\t"
                        f"{'pending' if entry.pending else 'ruled'}")
        return ("\n".join(rows) + "\n").encode("utf-8")


def read_bytes(path: Path) -> bytes:
    data = path.read_bytes()
    return gzip.decompress(data) if path.suffix == ".gz" else data


def sorted_table(text: str, header_lines: int = 1) -> str:
    """Header lines first, then the remaining non-empty rows in sorted order."""
    lines = text.splitlines()
    header, rows = lines[:header_lines], [line for line in lines[header_lines:] if line]
    return "\n".join(header + sorted(rows)) + "\n"


def golden_name(relative: str) -> str:
    """A golden path for a file path: a leading dot is dropped from each part so
    nothing is hidden, and a trailing -UUID is dropped from each part so the
    path is the same in every run."""
    parts = []
    for part in relative.split("/"):
        part = _UUID_SUFFIX.sub("", part)
        parts.append(part[1:] if part.startswith(".") and len(part) > 1 else part)
    return "/".join(parts)


def inventory(root: Path) -> str:
    """Every file under root, relative and sorted. Sizes are left out because
    files that hold a duration change length from run to run."""
    names = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() or path.is_symlink())
    return "".join(name + "\n" for name in names)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fastq_records(path: Path) -> list[list[str]]:
    lines = read_bytes(path).decode("utf-8").splitlines()
    if len(lines) % 4:
        raise CaptureError(f"{path} is not a four-line FASTQ")
    return [lines[index:index + 4] for index in range(0, len(lines), 4)]


def run_storage_info(ctx: CaptureContext) -> None:
    ctx.cli_run(["storage", "info", "--format", "json"], label="storage-info")


def storage_info(ctx: CaptureContext) -> dict:
    return json.loads(ctx.stdout("storage-info"))


def managed_samtools(ctx: CaptureContext) -> Path:
    samtools = Path(storage_info(ctx)["condaRoot"]) / "envs" / "samtools" / "bin" / "samtools"
    if not samtools.exists():
        raise CaptureError(f"managed samtools not found at {samtools}")
    return samtools


def put_alignment(ctx: CaptureContext, prefix: str, bam: Path, *, header_filter: Callable[[str], str] | None = None) -> dict:
    """Header without samtools' own @PG line, and a SHA-256 of the records in a
    canonical text form, in BAM order."""
    samtools = managed_samtools(ctx)
    header = ctx.tool([samtools, "view", "-H", "--no-PG", bam]).decode("utf-8")
    ctx.put_text(f"{prefix}header.sam", header_filter(header) if header_filter else header)
    records = ctx.tool([samtools, "view", "--no-PG", bam])
    count = records.count(b"\n")
    ctx.put_text(f"{prefix}records.sha256",
                 f"{hashlib.sha256(records).hexdigest()}  samtools view --no-PG ({count} records)\n")
    return {"records": count}


# ---------------------------------------------------------------------------
# cli-help


def run_cli_help(ctx: CaptureContext) -> None:
    completed = ctx.cli_run(["--experimental-dump-help"], label="dump-help")
    paths = command_paths(completed.stdout)

    def help_text(path: list[str]) -> None:
        ctx.cli_run([*path[1:], "--help"], label="help " + " ".join(path), expect=None)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(help_text, [path for path, _ in paths]))


def command_paths(dump: bytes) -> list[tuple[list[str], bool]]:
    tree = json.loads(dump)["command"]
    paths: list[tuple[list[str], bool]] = []

    def walk(command: dict, prefix: list[str]) -> None:
        path = prefix + [command["commandName"]]
        paths.append((path, bool(command.get("shouldDisplay", True))))
        for sub in command.get("subcommands") or []:
            walk(sub, path)

    walk(tree, [])
    return paths


def collect_cli_help(ctx: CaptureContext) -> None:
    index = ["command\tvisibility\texit\tfile"]
    for path, shown in command_paths(ctx.logged("dump-help")[1]):
        exit_status, stdout, stderr = ctx.logged("help " + " ".join(path))
        filename = ".".join(path) + ".txt"
        index.append(f"{' '.join(path)}\t{'shown' if shown else 'hidden'}\t{exit_status}\t{filename}")
        text = stdout.decode("utf-8", "replace")
        if stderr:
            text += "--- stderr\n" + stderr.decode("utf-8", "replace")
        ctx.put_text(filename, text)
    ctx.put_text("index.tsv", "\n".join(index) + "\n")


# ---------------------------------------------------------------------------
# mapping


def run_mapping(ctx: CaptureContext) -> None:
    fixtures = ctx.repo_root / "Tests" / "Fixtures" / "sarscov2"
    inputs = ctx.work / "inputs"
    inputs.mkdir()
    for name in ("genome.fasta", "test_1.fastq.gz", "test_2.fastq.gz"):
        shutil.copyfile(fixtures / name, ctx.wrote_input(inputs / name))
    run_storage_info(ctx)
    ctx.cli_run(
        [
            "map", inputs / "test_1.fastq.gz", inputs / "test_2.fastq.gz", "--paired",
            "--reference", inputs / "genome.fasta",
            "--mapper", "minimap2", "--preset", "sr",
            "--sample-name", "sarscov2-test",
            "--threads", THREADS, "--format", "json",
            "--output-dir", ctx.work / "out",
        ],
        label="map",
    )


def collect_mapping(ctx: CaptureContext) -> None:
    # R8: minimap2 records the per-run reference staging folder in the @PG CL
    # line, so the bytes of every SAM, BAM and BAI change from run to run. The
    # header and records goldens below cover their content.
    ctx.normalizer.add_path_rule(normalize.ALIGNMENT_RECORDS)
    out = ctx.work / "out"
    ctx.put_text("cli-report.json", ctx.stdout("map"))
    bam = out / "sarscov2-test.sorted.bam"
    put_alignment(ctx, "", bam)
    samtools = managed_samtools(ctx)
    flagstat = json.loads(ctx.tool([samtools, "flagstat", "-O", "json", bam]))
    passed = flagstat["QC-passed reads"]
    idxstats = []
    for line in ctx.tool([samtools, "idxstats", bam]).decode("utf-8").splitlines():
        contig, length, mapped, unmapped = line.split("\t")
        idxstats.append({"contig": contig, "length": int(length), "mapped": int(mapped), "unmapped": int(unmapped)})
    ctx.put_json(
        "counts.json",
        {
            "total": passed["total"],
            "primary": passed["primary"],
            "mapped": passed["mapped"],
            "unmapped": passed["total"] - passed["mapped"],
            "primaryMapped": passed["primary mapped"],
            "secondary": passed["secondary"],
            "supplementary": passed["supplementary"],
            "perContig": idxstats,
            "flagstat": flagstat,
        },
    )
    ctx.put_file("mapping-result.json", out / "mapping-result.json")
    ctx.put_file("mapping-provenance.json", out / "mapping-provenance.json")
    ctx.put_file("lungfish-provenance.json", out / ".lungfish-provenance.json")
    ctx.put_inventory("files.txt", out)


# ---------------------------------------------------------------------------
# classifiers (EsViritu and Kraken2 on a virtual FASTQ bundle)

PREVIEW_READS = 10
MIN_LENGTH = 150
SAMPLE = "sarscov2-R1-len150"
PROJECT = "Golden.lungfish"
ROOT_BUNDLE = "Imports/sarscov2-R1.lungfishfastq"
DERIVED_BUNDLE = f"{ROOT_BUNDLE}/derivatives/len-{MIN_LENGTH}-any-00000000.lungfishfastq"


def build_virtual_bundle(ctx: CaptureContext) -> None:
    """A project with a physical root bundle and a virtual length-filter subset.

    The subset bundle holds only read-ids.txt, preview.fastq and
    derived.manifest.json and points at its root, the layout the app's
    derivative service writes. The app's preview holds the first 1,000 reads.
    Here it holds the first 10, so that a tool reading the preview (10 reads)
    is told apart from one reading the materialized subset (55 reads) and from
    one reading the whole root (100 reads).
    """
    project = ctx.work / PROJECT
    root_fastq = project / ROOT_BUNDLE / "sarscov2-R1.fastq.gz"
    root_fastq.parent.mkdir(parents=True)
    shutil.copyfile(ctx.repo_root / "Tests" / "Fixtures" / "sarscov2" / "test_1.fastq.gz", ctx.wrote_input(root_fastq))

    subset = [record for record in fastq_records(root_fastq) if len(record[1]) >= MIN_LENGTH]
    derived = project / DERIVED_BUNDLE
    derived.mkdir(parents=True)
    # seqkit seq --name --only-id writes the first word of each header.
    ctx.wrote_input(derived / "read-ids.txt").write_text("".join(record[0][1:].split()[0] + "\n" for record in subset))
    ctx.wrote_input(derived / "preview.fastq").write_text(
        "".join("\n".join(record) + "\n" for record in subset[:PREVIEW_READS]))
    base_count = sum(len(record[1]) for record in subset)
    operation = {"createdAt": "2026-10-02T00:00:00Z", "kind": "lengthFilter", "minLength": MIN_LENGTH}
    manifest = {
        # FASTQDatasetStatistics.placeholder(readCount:baseCount:)
        "cachedStatistics": {
            "baseCount": base_count,
            "gcContent": 0,
            "maxReadLength": 0,
            "meanQuality": 0,
            "meanReadLength": base_count / len(subset),
            "medianReadLength": 0,
            "minReadLength": 0,
            "n50ReadLength": 0,
            "perPositionQuality": [],
            "q20Percentage": 0,
            "q30Percentage": 0,
            "qualityScoreHistogram": [],
            "readCount": len(subset),
            "readLengthHistogram": {},
        },
        "createdAt": "2026-10-02T00:00:00Z",
        "id": "00000000-0000-4000-8000-000000000001",
        "lineage": [operation],
        "name": derived.name.removesuffix(".lungfishfastq"),
        "operation": operation,
        "pairingMode": "single_end",
        "parentBundleRelativePath": f"@/{ROOT_BUNDLE}",
        "payload": {"subset": {"readIDListFilename": "read-ids.txt"}},
        "rootBundleRelativePath": f"@/{ROOT_BUNDLE}",
        "rootFASTQFilename": root_fastq.name,
        "schemaVersion": 2,
        "sequenceFormat": "fastq",
    }
    ctx.wrote_input(derived / "derived.manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def run_classifiers(ctx: CaptureContext) -> None:
    build_virtual_bundle(ctx)
    run_storage_info(ctx)
    project = ctx.work / PROJECT
    derived = project / DERIVED_BUNDLE
    analyses = project / "Analyses"
    analyses.mkdir()
    # Kraken2 reads the virtual bundle directly and materializes it itself.
    ctx.cli_run(["conda", "classify", derived, "--db", KRAKEN2_DATABASE, "--threads", THREADS,
                 "--output-dir", analyses / "kraken2-golden"], label="conda-classify")
    # EsViritu refuses a bundle (it takes FASTQ files only), while the app
    # materializes first and then runs EsViritu in process. The probe records
    # the refusal. The run below materializes through the CLI first.
    ctx.cli_run(["esviritu", "detect", "--input", derived, "--sample", SAMPLE, "--threads", THREADS,
                 "--output", ctx.work / "esviritu-bundle-probe"], label="esviritu-bundle-probe", expect=None)
    (ctx.work / "work").mkdir()
    materialized = ctx.work / "work" / f"{SAMPLE}.fastq"
    ctx.cli_run(["fastq", "materialize", derived, "-o", materialized], label="fastq-materialize")
    ctx.cli_run(["esviritu", "detect", "--input", materialized, "--sample", SAMPLE, "--threads", THREADS,
                 "--output", analyses / "esviritu-golden"], label="esviritu-detect")


def database_fingerprint(database_root: Path, entry: dict, files: list[Path]) -> dict:
    location = Path(entry["path"].removeprefix("file://"))
    return {
        "name": entry["name"],
        "tool": entry["tool"],
        "version": entry.get("version"),
        "status": entry.get("status"),
        "path": os.path.relpath(location, database_root),
        "files": {
            os.path.relpath(path, location): {"bytes": path.stat().st_size, "sha256": sha256_file(path)}
            for path in sorted(files)
        },
    }


def sqlite_dump(path: Path) -> str:
    """Schema and rows of a SQLite file in storage order, read without writing."""
    connection = sqlite3.connect(f"file:{path}?immutable=1", uri=True)
    try:
        lines = []
        objects = connection.execute(
            "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name").fetchall()
        for kind, name, sql in objects:
            lines.append(f"-- {kind} {name}\n{sql}")
            if kind != "table":
                continue
            cursor = connection.execute(f'SELECT * FROM "{name}" ORDER BY rowid')
            lines.append("\t".join(column[0] for column in cursor.description))
            for row in cursor:
                lines.append("\t".join("NULL" if value is None else value.hex() if isinstance(value, bytes)
                                       else str(value) for value in row))
        return "\n".join(lines) + "\n"
    finally:
        connection.close()


def collect_classifiers(ctx: CaptureContext) -> None:
    project = ctx.work / PROJECT
    derived = project / DERIVED_BUNDLE
    ctx.put_json("inputs.json", {
        "rootReads": len(fastq_records(project / ROOT_BUNDLE / "sarscov2-R1.fastq.gz")),
        "subsetReads": len((derived / "read-ids.txt").read_text().splitlines()),
        "previewReads": len(fastq_records(derived / "preview.fastq")),
        "subsetRule": f"read length >= {MIN_LENGTH}",
    })

    database_root = Path(storage_info(ctx)["databaseRoot"])
    registry = json.loads((database_root / "metagenomics-db-registry.json").read_text())
    entries = {entry["name"]: entry for entry in registry["databases"]}
    for name in (KRAKEN2_DATABASE, ESVIRITU_DATABASE):
        if entries.get(name, {}).get("status") != "ready":
            raise CaptureError(f"classifiers: the {name} database is not installed in {database_root}")
    kraken_path = Path(entries[KRAKEN2_DATABASE]["path"].removeprefix("file://"))
    esviritu_path = Path(entries[ESVIRITU_DATABASE]["path"].removeprefix("file://"))
    ctx.put_json("environment.json", {
        "kraken2Database": database_fingerprint(
            database_root, entries[KRAKEN2_DATABASE], [kraken_path / name for name in KRAKEN2_DATABASE_FILES]),
        "esvirituDatabase": database_fingerprint(
            database_root, entries[ESVIRITU_DATABASE], [path for path in esviritu_path.rglob("*") if path.is_file()]),
    })

    kraken = project / "Analyses" / "kraken2-golden"
    # R11: gzip stores the wall-clock MTIME in header bytes 4 to 7. The sorted
    # per-read golden below compares the decompressed content.
    ctx.register_file(kraken / "classification.kraken.gz", "R11", "classification.kraken.gz")
    # R12: the read index stores its creation time. Its dump is a golden.
    ctx.register_file(kraken / "classification.kraken.gz.idx.sqlite", "R12", "classification.kraken.gz.idx.sqlite")
    materialized_inputs = sorted((kraken / ".lungfish-classify-inputs").glob("*.fastq"))
    kreport = [line.split("\t") for line in (kraken / "classification.kreport").read_text().splitlines() if line]
    # LGE's kreport has eight columns. The rank code is the third from the end.
    unclassified = sum(int(row[1]) for row in kreport if row[-3] == "U")
    root_clade = sum(int(row[1]) for row in kreport if row[-3] == "R")
    ctx.put_json("kraken2/counts.json", {
        "materializedInputFiles": len(materialized_inputs),
        "materializedInputReads": sum(len(fastq_records(path)) for path in materialized_inputs),
        "kreportClassified": root_clade,
        "kreportUnclassified": unclassified,
        "kreportTotal": root_clade + unclassified,
    })
    ctx.put_text("kraken2/cli-stdout.txt", ctx.stdout("conda-classify"))
    ctx.put_sorted_table("kraken2/classification.kreport.sorted", kraken / "classification.kreport", header_lines=0)
    ctx.put_sorted_table("kraken2/classification.kraken.sorted", kraken / "classification.kraken.gz", header_lines=0)
    ctx.put_text("kraken2/classification.kraken.gz.idx.sqlite.dump",
                 sqlite_dump(kraken / "classification.kraken.gz.idx.sqlite"))
    ctx.put_file("kraken2/classification-result.json", kraken / "classification-result.json")
    ctx.put_file("kraken2/lungfish-provenance.json", kraken / ".lungfish-provenance.json")
    ctx.put_inventory("kraken2/files.txt", kraken)

    ctx.put_command("esviritu/bundle-input-probe.txt", "esviritu-bundle-probe")
    ctx.put_command("esviritu/materialize.txt", "fastq-materialize")
    work = ctx.work / "work"
    materialized = work / f"{SAMPLE}.fastq"
    ctx.put_file("esviritu/materialize-provenance.json", work / f"{SAMPLE}.fastq.lungfish-provenance.json")
    ctx.put_file("esviritu/materialize-folder-provenance.json", work / ".lungfish-provenance.json")
    esviritu = project / "Analyses" / "esviritu-golden"
    ctx.put_json("esviritu/counts.json", {"materializedInputReads": len(fastq_records(materialized))})
    ctx.put_file(f"esviritu/{SAMPLE}_esviritu.readstats.yaml", esviritu / f"{SAMPLE}_esviritu.readstats.yaml")
    for table in (
        f"{SAMPLE}.detected_virus.info.tsv",
        f"{SAMPLE}.detected_virus.assembly_summary.tsv",
        f"{SAMPLE}.tax_profile.tsv",
        f"{SAMPLE}.virus_coverage_windows.tsv",
    ):
        ctx.put_sorted_table(f"esviritu/{table}.sorted", esviritu / table)
    ctx.put_file("esviritu/esviritu-result.json", esviritu / "esviritu-result.json")
    ctx.put_file("esviritu/lungfish-provenance.json", esviritu / ".lungfish-provenance.json")
    ctx.put_inventory("esviritu/files.txt", esviritu)


# ---------------------------------------------------------------------------
# genotype (mhc-genotyping demo project)

GENOTYPE_NAME = "SIMULATED-MHC-haplotypes"

# Files of an export capture folder that are not goldens: input-N.bin files are
# byte copies of bundle files whose digests are masked or compared through those
# files, and renderer.py is the workbook renderer the app ships.
_EXPORT_FOLDER_SKIP = re.compile(r"(^|/)[^/]*\.xlsx\.export-[^/]*/(input-[0-9]+\.bin|renderer\.py)$")


def demo_archive(ctx: CaptureContext) -> Path:
    archive = ctx.cache_root / Path(MHC_DEMO["url"]).name
    if not archive.exists() or sha256_file(archive) != MHC_DEMO["sha256"]:
        partial = archive.with_suffix(".zip.partial")
        with urllib.request.urlopen(MHC_DEMO["url"], timeout=120) as response, partial.open("wb") as handle:
            shutil.copyfileobj(response, handle)
        partial.replace(archive)
    size, digest = archive.stat().st_size, sha256_file(archive)
    if size != MHC_DEMO["bytes"] or digest != MHC_DEMO["sha256"]:
        raise CaptureError(f"genotype: {archive} is {size} bytes with SHA-256 {digest}, not the pinned archive")
    return archive


def extract(archive: Path, destination: Path) -> list[Path]:
    with zipfile.ZipFile(archive) as zf:
        for member in zf.namelist():
            target = (destination / member).resolve()
            if not str(target).startswith(str(destination.resolve()) + os.sep):
                raise CaptureError(f"genotype: unsafe member {member} in {archive}")
        zf.extractall(destination)
        return [destination / member for member in zf.namelist()]


def run_genotype(ctx: CaptureContext) -> None:
    for path in extract(demo_archive(ctx), ctx.work):
        if path.is_file():
            ctx.wrote_input(path)
    run_storage_info(ctx)
    project = ctx.work / MHC_DEMO["projectFolder"]
    bundles = sorted((project / "Imports").glob("SIMULATED-MHC-*-pairs.lungfishfastq"))
    if len(bundles) != 2:
        raise CaptureError(f"genotype: expected two sample bundles in {project / 'Imports'}, found {len(bundles)}")
    reference = project / "Reference allele databases" / "SIMULATED-MHC-MCM-teaching.lungfishmhcref"
    result = ctx.work / "out" / f"{GENOTYPE_NAME}.lungfishgenotype"
    result.parent.mkdir()
    ctx.cli_run(
        ["fastq", "genotype-cohort", *bundles, "--reference", reference,
         "--mode", "illumina-paired", "--read-type", "illumina",
         "--output-dir", result, "--output-name", GENOTYPE_NAME,
         "--threads", THREADS, "--sort-threads", THREADS, "--min-support", "1"],
        label="genotype-cohort",
    )
    exports = ctx.work / "exports"
    exports.mkdir()
    ctx.cli_run(["genotype", "export-xlsx", "--bundle", result, "--output", exports / "workbook.xlsx"],
                label="export-xlsx")
    ctx.cli_run(["genotype", "export-pivot-xlsx", "--bundle", result, "--output", exports / "pivot.xlsx"],
                label="export-pivot-xlsx")
    for fmt in ("tsv", "csv"):
        ctx.cli_run(["genotype", "export", "--bundle", result, "--export-format", fmt,
                     "--output", exports / f"matrix.{fmt}"], label=f"export-{fmt}")


def put_tree(ctx: CaptureContext, prefix: str, root: Path, skip: re.Pattern[str]) -> None:
    """Every file under root as a golden, by kind. Binary files other than
    workbooks appear only in the inventory."""
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(root).as_posix()
        if skip.search(relative):
            continue
        name = f"{prefix}{golden_name(relative)}"
        if path.suffix == ".xlsx":
            ctx.put_xlsx(name, path)
        elif path.name == "snapshot.json" and ".xlsx.export-" in relative:
            ctx.put_snapshot(name, path)
        elif path.name == "request.json" and ".xlsx.export-" in relative:
            ctx.put_request(name, path)
        else:
            try:
                path.read_bytes().decode("utf-8")
            except UnicodeDecodeError:
                continue
            ctx.put_file(name, path)
    ctx.put_inventory(f"{prefix}files.txt", root)


def collect_genotype(ctx: CaptureContext) -> None:
    ctx.put_json("inputs.json", {key: MHC_DEMO[key] for key in ("id", "version", "url", "sha256", "bytes")})
    result = ctx.work / "out" / f"{GENOTYPE_NAME}.lungfishgenotype"
    exports = ctx.work / "exports"

    # N2 (pending): samtools merge gives colliding @PG IDs a random suffix, so
    # the merged BAM, the genotyping-evidence BAM filtered from it and their
    # indexes change bytes from run to run. The header (suffix masked) and
    # records goldens cover the evidence BAM's content. The merged BAM is
    # deleted at the end of the run, so its records are matched by path.
    bam = result / f"{GENOTYPE_NAME}.retained.demuxed.bam"
    ctx.register_file(bam, "N2", bam.name, mask_size=True, pending=True)
    ctx.register_file(bam.with_suffix(".bam.bai"), "N2", bam.name + ".bai", mask_size=True, pending=True)
    ctx.normalizer.add_path_rule(normalize.PathRule(
        "N2", (f"/{GENOTYPE_NAME}.md.sorted.bam", f"/{GENOTYPE_NAME}.md.sorted.bam.bai"), pending=True))
    # N3 (pending): the sample manifest records the per-run bbmerge staging
    # folder (the demo project's path holds a space) and is deleted at the end
    # of the run.
    ctx.normalizer.add_path_rule(normalize.PathRule(
        "N3", ("/.amplicon-genotyping/inputs/illumina-sample-manifest.json",), mask_size=False, pending=True))
    put_alignment(ctx, "bundle-bam/", bam,
                  header_filter=None if ctx.strict else normalize.mask_merge_pg_suffixes)

    ctx.put_text("run/cli-report.json", ctx.stdout("genotype-cohort"))
    put_tree(ctx, "bundle/", result, _EXPORT_FOLDER_SKIP)
    for label in ("export-xlsx", "export-pivot-xlsx", "export-tsv", "export-csv"):
        ctx.put_text(f"exports-stdout/{label}.json", ctx.stdout(label))
    put_tree(ctx, "exports/", exports, _EXPORT_FOLDER_SKIP)


@dataclass(frozen=True)
class Capture:
    run: Callable[[CaptureContext], None]
    collect: Callable[[CaptureContext], None]


CAPTURES = {
    "cli-help": Capture(run_cli_help, collect_cli_help),
    "mapping": Capture(run_mapping, collect_mapping),
    "classifiers": Capture(run_classifiers, collect_classifiers),
    "genotype": Capture(run_genotype, collect_genotype),
}
