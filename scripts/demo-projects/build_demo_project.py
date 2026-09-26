#!/usr/bin/env python3
"""Build, package, and verify the downloadable LGE demo projects.

Each demo project is a `.lungfish` project that already holds the inputs a
reader needs for a group of user-manual chapters, in the state the reader
would reach after each chapter's "Before you start" section: reads imported,
reference bundles built, original files the procedures import copied into
`Practice Data/`, and no analysis results.

Everything inside a project is made by `lungfish-cli` (the same commands the
app runs), except two files the CLI cannot write:

* `.project.db`, the project store, created from `project-store-schema.sql`
  (a copy of `ProjectStore.createTables()`, schema version 1).
* `metadata.json`, the project metadata `ProjectFile` reads.

Usage:
    build_demo_project.py <id>[,<id>...]|all --out-dir DIR [options]

Options:
    --cli PATH          lungfish-cli to drive (default $LUNGFISH_CLI or the
                        installed Lungfish Preview CLI)
    --cache-dir DIR     directory holding already-downloaded SRA FASTQs
                        (<run>_1.fastq[.gz] and <run>_2.fastq[.gz]); may be
                        repeated. Runs not found are fetched with
                        `lungfish-cli fetch sra download` into the first
                        cache dir (or <work-dir>/sra-cache).
    --work-dir DIR      scratch root for staging, building and verifying
                        (default /tmp/lge-demo-build). Provenance written by
                        the CLI records paths under this root, so a neutral
                        root keeps user-specific paths out of the projects.
    --version VER       demo project version (default 2026.9.44)
    --no-verify         skip the unzip-and-inspect verification
    --no-manifest       do not update demo-projects.manifest.json

The large hg002 fixtures come from the pinned media repo. Run
`bash docs/user-manual/build/scripts/fetch-media.sh` first.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
FIXTURES = REPO / "docs/user-manual/fixtures"
TEST_FIXTURES = REPO / "Tests/Fixtures"
CHAPTERS = REPO / "docs/user-manual/chapters"
SCHEMA_SQL = HERE / "project-store-schema.sql"
MANIFEST = HERE / "demo-projects.manifest.json"

DEFAULT_CLI = "/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli"
DEFAULT_VERSION = "2026.9.44"
DEFAULT_WORK = pathlib.Path("/tmp/lge-demo-build")
RELEASE_URL = "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/demo-projects"
DOCS_URL = "https://lungfish-genome-explorer.readthedocs.io/en/latest/chapters"

# Fixed timestamps so metadata.json and the zip entries do not depend on the
# build date.
FIXED_ISO = "2026-09-25T00:00:00Z"
ZIP_DATE = (2026, 9, 25, 0, 0, 0)

# Payloads that are already compressed are stored, not deflated again.
STORED_SUFFIXES = (".gz", ".bgz", ".bgzf", ".zst", ".bz2", ".xz", ".bam", ".cram", ".zip")

# Machine-specific state that never ships.
STRIP_NAMES = {
    ".tmp", ".lungfish", ".lungfish-cache", ".DS_Store", "__MACOSX",
    ".universal-search.db", ".universal-search.db-shm", ".universal-search.db-wal",
    ".universal-search.db.lungfish-provenance.json",
    ".project.db-shm", ".project.db-wal", ".project.db-journal",
    ".lungfish-operation-history",
}
STRIP_SUFFIXES = (".lock",)

# ---------------------------------------------------------------------------
# Recipes. Source paths are "fx:<path>" under docs/user-manual/fixtures or
# "tests:<path>" under Tests/Fixtures.
#
#   ("reads", [sources], platform, pairing)   lungfish-cli import fastq
#   ("sra", accession, platform)              SRA route: fetch sra download, then import fastq
#   ("reference", source)                     lungfish-cli import fasta
#   ("practice", source, dest)                copy into Practice Data/<dest>
# ---------------------------------------------------------------------------

PROJECTS: dict[str, dict] = {
    "genes-and-sequences": {
        "title": "Genes and Sequences",
        "folder": "Genes and Sequences.lungfish",
        "summary": "The human beta-globin region record and five primate mitochondrial genomes, imported as reference bundles for the sequence chapters.",
        "chapters": [
            "01-foundations/01-what-is-a-genome",
            "02-sequences/01-importing-and-viewing",
            "02-sequences/02-downloading-from-ncbi",
            "02-sequences/03-extracting-and-comparing",
            "02-sequences/04-aligning-sequences",
            "02-sequences/05-building-trees",
        ],
        "steps": [
            ("reference", "fx:hbb-gene/NG_000007.3.gb"),
            ("reference", "fx:primate-mito/primate-mito.fasta"),
            ("practice", "fx:hbb-gene/NG_000007.3.gb", "hbb-gene/NG_000007.3.gb"),
            ("practice", "fx:primate-mito/primate-mito.fasta", "primate-mito/primate-mito.fasta"),
            ("practice", "fx:human-mito/NC_012920.1.fasta", "human-mito/NC_012920.1.fasta"),
        ],
    },
    "human-reads": {
        "title": "Human Reads",
        "folder": "Human Reads.lungfish",
        "summary": "HG002 Illumina reads from a half-megabase slice of human chromosome 20, imported and ready for quality control, trimming, decontamination, subsetting, and read processing.",
        "chapters": [
            "01-foundations/02-sequencing-reads",
            "03-reads/01-importing-fastq",
            "03-reads/03-quality-control",
            "03-reads/04-trimming-and-filtering",
            "03-reads/05-decontamination",
            "03-reads/06-subsetting-and-extraction",
            "03-reads/08-read-processing",
        ],
        "steps": [
            ("reads", ["fx:hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz",
                       "fx:hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz"], "illumina", "paired"),
            ("reads", ["fx:hg002-long-reads/HG002.chrM.ont.fastq.gz"], "ont", "single"),
            ("sra", "SRR36291587", "illumina"),
            ("reference", "fx:human-mito/NC_012920.1.fasta"),
            ("practice", "fx:hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz", "hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz"),
            ("practice", "fx:hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz", "hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz"),
        ],
    },
    "human-mapping-and-variants": {
        "title": "Human Mapping and Variants",
        "folder": "Human Mapping and Variants.lungfish",
        "summary": "HG002 reads and the matching 500 kb GRCh38 chromosome 20 reference bundle, with the GIAB benchmark VCF, ready for mapping, variant calling, and the GATK chapters.",
        "chapters": [
            "01-foundations/04-alignment-files",
            "01-foundations/05-variants-and-vcf",
            "04-alignments/01-mapping-reads-to-a-reference",
            "04-alignments/02-reading-an-alignment",
            "04-alignments/04-alignment-quality",
            "05-variants/01-calling-variants-from-amplicons",
            "05-variants/02-reading-the-variant-browser",
            "05-variants/05-consensus-and-lineage",
            "05-variants/06-importing-existing-vcfs",
            "06-human-germline-variants/01-haplotype-caller",
            "06-human-germline-variants/02-joint-genotyping",
            "06-human-germline-variants/03-filtering-selecting-and-metrics",
            "06-human-germline-variants/04-reference-packs",
        ],
        "steps": [
            ("reads", ["fx:hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz",
                       "fx:hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz"], "illumina", "paired"),
            ("reference", "fx:hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta"),
            ("practice", "fx:hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta", "hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta"),
            ("practice", "fx:hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta.fai", "hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta.fai"),
            ("practice", "fx:hg002-chr20/HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz", "hg002-chr20/HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz"),
            ("practice", "fx:hg002-chr20/HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz.tbi", "hg002-chr20/HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz.tbi"),
        ],
    },
    "long-reads-and-assembly": {
        "title": "Long Reads and Assembly",
        "folder": "Long Reads and Assembly.lungfish",
        "summary": "HG002 mitochondrial reads from Oxford Nanopore, PacBio HiFi, and Illumina instruments with the rCRS reference, ready for long-read variant calling and genome assembly.",
        "chapters": [
            "03-reads/07-ont-runs",
            "05-variants/04-nanopore-variant-calling",
            "07-assembly/01-when-to-assemble",
            "07-assembly/02-running-spades",
            "07-assembly/03-running-flye-or-hifiasm",
            "07-assembly/04-extracting-contigs",
        ],
        "steps": [
            ("reads", ["fx:human-mito/HG002.chrM_R1.fastq.gz",
                       "fx:human-mito/HG002.chrM_R2.fastq.gz"], "illumina", "paired"),
            ("reads", ["fx:hg002-long-reads/HG002.chrM.ont.fastq.gz"], "ont", "single"),
            ("reads", ["fx:hg002-long-reads/HG002.chrM.hifi.fastq.gz"], "pacbio", "single"),
            ("reference", "fx:human-mito/NC_012920.1.fasta"),
            ("practice", "fx:hg002-long-reads/ont-run/fastq_pass/barcode01/HG002_chrM_pass_barcode01_0.fastq.gz",
             "hg002-long-reads/ont-run/fastq_pass/barcode01/HG002_chrM_pass_barcode01_0.fastq.gz"),
        ],
    },
    "sarscov2-amplicons": {
        "title": "SARS-CoV-2 Amplicons",
        "folder": "SARS-CoV-2 Amplicons.lungfish",
        "summary": "A QIAseq Direct SARS-CoV-2 amplicon run, SRR36291587, with the MN908947.3 reference bundle, ready for mapping, primer trimming, Viral Recon, EsViritu, and Freyja.",
        "chapters": [
            "03-reads/05-decontamination",
            "04-alignments/03-primer-trimming",
            "04-alignments/05-viral-recon-wizard",
            "06-classification/03-running-esviritu",
            "06-classification/07-running-freyja",
        ],
        "steps": [
            ("sra", "SRR36291587", "illumina"),
            ("reference", "tests:sarscov2-srr36291587/MN908947.3.fasta"),
        ],
    },
    "pathogen-detection": {
        "title": "Pathogen Detection",
        "folder": "Pathogen Detection.lungfish",
        "summary": "Two public corneal tissue metagenomes, SRR12486983 and SRR12486989, plus NVD, NAO-MGS, and CZ ID result files, for the classification and pathogen detection chapters.",
        "chapters": [
            "06-classification/01-what-is-classification",
            "06-classification/02-running-kraken2",
            "06-classification/04-running-taxtriage",
            "06-classification/05-running-nao-mgs",
            "06-classification/06-blast-verification",
            "06-classification/08-importing-cz-id-results",
            "06-classification/09-novel-virus-detection",
        ],
        "steps": [
            ("sra", "SRR12486983", "illumina"),
            ("sra", "SRR12486989", "illumina"),
            ("practice", "fx:nvd-demo/results/05_labkey_bundling/demo_blast_concatenated.csv",
             "nvd-demo/results/05_labkey_bundling/demo_blast_concatenated.csv"),
            ("practice", "tests:naomgs/virus_hits_final.tsv.gz", "naomgs/virus_hits_final.tsv.gz"),
            ("practice", "tests:czid/minimal_taxon_report.tsv", "czid/minimal_taxon_report.tsv"),
        ],
    },
    "mhc-genotyping": {
        "title": "MHC Genotyping",
        "folder": "MHC Genotyping.lungfish",
        "summary": "Two simulated macaque MHC amplicon samples and a three-allele annotated reference, ready for amplicon genotyping and export.",
        "chapters": [
            "09-genotyping/01-what-is-mhc-genotyping",
            "09-genotyping/02-running-genotyping",
            "09-genotyping/03-reading-the-genotype-comparison",
            "09-genotyping/04-haplotype-definitions-and-export",
        ],
        "steps": [
            ("reads", ["fx:mhc-simulated/SIMULATED-MHC-A-pairs.fastq"], "illumina", "interleaved"),
            ("reads", ["fx:mhc-simulated/SIMULATED-MHC-B-pairs.fastq"], "illumina", "interleaved"),
            ("reference", "fx:mhc-simulated/SIMULATED-MHC-annotated-reference.gb"),
        ],
    },
    "twelve-s-metabarcoding": {
        "title": "12S Metabarcoding",
        "folder": "12S Metabarcoding.lungfish",
        "summary": "Oriented human 12S amplicon reads and a five-species primate 12S reference, ready for 12S amplicon matching.",
        "chapters": [
            "06-classification/10-twelve-s-metabarcoding",
        ],
        "steps": [
            ("reads", ["fx:primate-12s/HG002-12S-oriented.fastq"], "illumina", "single"),
            ("practice", "fx:primate-12s/primate-12s-dedup.fasta", "primate-12s/primate-12s-dedup.fasta"),
            ("practice", "fx:primate-12s/primate-12s-midori.tsv", "primate-12s/primate-12s-midori.tsv"),
        ],
    },
}

PROJECT_ORDER = list(PROJECTS)

# ---------------------------------------------------------------------------


class BuildError(RuntimeError):
    pass


def log(msg: str) -> None:
    print(msg, flush=True)


def resolve_source(spec: str) -> pathlib.Path:
    root, _, rel = spec.partition(":")
    base = {"fx": FIXTURES, "tests": TEST_FIXTURES}[root]
    path = base / rel
    if not path.is_file():
        hint = ""
        if "hg002-" in rel:
            hint = " Run `bash docs/user-manual/build/scripts/fetch-media.sh` first."
        raise BuildError(f"missing fixture file {path}.{hint}")
    return path


def fixture_name(spec: str) -> str:
    return spec.partition(":")[2].split("/", 1)[0]


def link_or_copy(src: pathlib.Path, dst: pathlib.Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst.unlink()
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


class Runner:
    def __init__(self, cli: str, log_dir: pathlib.Path, tmp_dir: pathlib.Path):
        self.cli = cli
        self.log_dir = log_dir
        self.count = 0
        log_dir.mkdir(parents=True, exist_ok=True)
        # Tools launched by the CLI record their temporary paths in
        # provenance. A TMPDIR under the work root keeps the per-user
        # /var/folders path out of the shipped projects.
        tmp_dir.mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ, TMPDIR=str(tmp_dir) + "/")

    def run(self, args: list, label: str, cwd: pathlib.Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
        self.count += 1
        argv = [self.cli, *[str(a) for a in args]]
        log(f"   $ lungfish-cli {' '.join(str(a) for a in args)}")
        result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, env=self.env)
        slug = re.sub(r"[^A-Za-z0-9._-]+", "-", label)[:60]
        (self.log_dir / f"{self.count:02d}-{slug}.log").write_text(
            "argv: " + json.dumps(argv) + "\n\n--- stdout\n" + result.stdout + "\n--- stderr\n" + result.stderr
            + f"\n--- exit {result.returncode}\n")
        if check and result.returncode != 0:
            tail = (result.stdout + result.stderr)[-2000:]
            raise BuildError(f"{label} failed (exit {result.returncode}):\n{tail}")
        return result


# ---------------------------------------------------------------------------
# Project creation


def app_json(obj) -> str:
    """JSON shaped like Foundation's JSONEncoder with prettyPrinted + sortedKeys."""
    return json.dumps(obj, indent=2, sort_keys=True, separators=(",", " : "), ensure_ascii=False) + "\n"


def create_project(project_dir: pathlib.Path, pid: str, spec: dict, readme_text: str, version: str) -> None:
    if project_dir.exists():
        shutil.rmtree(project_dir)
    project_dir.mkdir(parents=True)
    db = project_dir / ".project.db"
    subprocess.run(["sqlite3", str(db), f".read {SCHEMA_SQL}"], check=True, capture_output=True, text=True)
    for suffix in ("-wal", "-shm"):
        side = pathlib.Path(str(db) + suffix)
        if side.exists():
            side.unlink()
    metadata = {
        "createdAt": FIXED_ISO,
        "customMetadata": {
            "demoProjectID": pid,
            "demoProjectVersion": version,
        },
        "description": readme_text,
        "formatVersion": "1.0",
        "modifiedAt": FIXED_ISO,
        "name": spec["title"],
        "version": "1.0",
    }
    (project_dir / "metadata.json").write_text(app_json(metadata))


def find_sra_fastqs(accession: str, cache_dirs: list[pathlib.Path]) -> list[pathlib.Path] | None:
    for cache in cache_dirs:
        for base in (cache, cache / accession):
            for ext in (".fastq.gz", ".fastq"):
                r1 = base / f"{accession}_1{ext}"
                r2 = base / f"{accession}_2{ext}"
                if r1.is_file() and r2.is_file():
                    return [r1, r2]
    return None


def import_reads(runner: Runner, project: pathlib.Path, files: list[pathlib.Path], platform: str, pairing: str, label: str) -> None:
    # Same argv shape as the app's CLIImportRunner.buildCLIArguments with the
    # import sheet's defaults (no quality binning, balanced compression, no
    # recipe, platform-default storage optimisation).
    runner.run(["import", "fastq", *files, "--project", project, "--platform", platform,
                "--pairing", pairing, "--quality-binning", "none", "--compression", "balanced",
                "--recipe", "none", "--no-progress"], label)


def build_project(pid: str, args, runner: Runner, project_dir: pathlib.Path, staging: pathlib.Path) -> None:
    spec = PROJECTS[pid]
    for step in spec["steps"]:
        kind = step[0]
        if kind == "reads":
            _, sources, platform, pairing = step
            staged = []
            for source in sources:
                src = resolve_source(source)
                dst = staging / fixture_name(source) / src.name
                link_or_copy(src, dst)
                staged.append(dst)
            log(f"== reads {', '.join(p.name for p in staged)} ({platform}, {pairing})")
            import_reads(runner, project_dir, staged, platform, pairing, f"reads-{staged[0].name}")
        elif kind == "sra":
            _, accession, platform = step
            log(f"== SRA run {accession}")
            found = find_sra_fastqs(accession, args.cache_dir)
            if found is None:
                download_root = args.cache_dir[0] if args.cache_dir else args.work_dir / "sra-cache"
                target = download_root / accession
                target.mkdir(parents=True, exist_ok=True)
                runner.run(["fetch", "sra", "download", accession, "--output-dir", target, "--no-progress"],
                           f"fetch-{accession}")
                found = find_sra_fastqs(accession, [target])
                if found is None:
                    raise BuildError(f"fetch sra download {accession} did not leave _1/_2 FASTQ files in {target}")
            else:
                log(f"   using cached {found[0].parent}")
            staged = []
            for src in found:
                dst = staging / "sra" / accession / src.name
                link_or_copy(src, dst)
                staged.append(dst)
            import_reads(runner, project_dir, staged, platform, "paired", f"sra-{accession}")
        elif kind == "reference":
            _, source = step
            src = resolve_source(source)
            dst = staging / fixture_name(source) / src.name
            link_or_copy(src, dst)
            log(f"== reference {src.name}")
            runner.run(["import", "fasta", dst, "--output-dir", project_dir, "--no-progress"], f"reference-{src.name}")
        elif kind == "practice":
            _, source, dest = step
            src = resolve_source(source)
            out = project_dir / "Practice Data" / dest
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, out)
            log(f"== practice file {dest}")
        else:
            raise BuildError(f"unknown step kind {kind}")


def strip_machine_state(project_dir: pathlib.Path) -> list[str]:
    removed = []
    for path in sorted(project_dir.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if not path.exists() and not path.is_symlink():
            continue
        name = path.name
        if name in STRIP_NAMES or name.endswith(STRIP_SUFFIXES) or name.startswith("._"):
            removed.append(str(path.relative_to(project_dir)))
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
    # Empty folders inside bundles (variants/, tracks/ and so on) are part of
    # the layout the CLI writes, so they are kept. The zip carries directory
    # entries for them.
    symlinks = [p for p in project_dir.rglob("*") if p.is_symlink()]
    if symlinks:
        raise BuildError(f"project contains symbolic links: {symlinks}")
    return removed


# ---------------------------------------------------------------------------
# README


def chapter_title(stem: str) -> str:
    text = (CHAPTERS / f"{stem}.md").read_text()
    front = text.split("---", 2)[1]
    match = re.search(r"^title:\s*(.+?)\s*$", front, re.M)
    if not match:
        raise BuildError(f"no title in front matter of {stem}")
    return match.group(1).strip().strip('"')


def chapter_table(stems: list[str]) -> str:
    rows = ["| Chapter | Online manual |", "| --- | --- |"]
    for stem in stems:
        rows.append(f"| {chapter_title(stem)} | {DOCS_URL}/{stem}/ |")
    return "\n".join(rows)


def render_readme(pid: str, version: str) -> str:
    template = (HERE / "projects" / pid / "README.md").read_text()
    text = template.replace("{{CHAPTERS}}", chapter_table(PROJECTS[pid]["chapters"]))
    text = text.replace("{{VERSION}}", version)
    if "{{" in text:
        raise BuildError(f"unfilled placeholder in README for {pid}")
    return text


# ---------------------------------------------------------------------------
# Zip


def zip_project(project_dir: pathlib.Path, archive: pathlib.Path) -> None:
    root_name = project_dir.name
    entries = []
    for path in project_dir.rglob("*"):
        rel = path.relative_to(project_dir.parent).as_posix()
        entries.append((rel + "/" if path.is_dir() else rel, path))
    entries.append((root_name + "/", project_dir))
    entries.sort(key=lambda item: item[0])
    archive.parent.mkdir(parents=True, exist_ok=True)
    tmp = archive.with_suffix(".zip.partial")
    with zipfile.ZipFile(tmp, "w", allowZip64=True) as zf:
        for name, path in entries:
            info = zipfile.ZipInfo(name, date_time=ZIP_DATE)
            info.create_system = 3
            if name.endswith("/"):
                info.external_attr = (0o40755 << 16) | 0x10
                info.compress_type = zipfile.ZIP_STORED
                zf.writestr(info, b"")
            else:
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_STORED if name.lower().endswith(STORED_SUFFIXES) else zipfile.ZIP_DEFLATED
                with open(path, "rb") as src, zf.open(info, "w", force_zip64=True) as dst:
                    shutil.copyfileobj(src, dst, 1024 * 1024)
    tmp.replace(archive)


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_bytes(path: pathlib.Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


# ---------------------------------------------------------------------------
# Verification


def verify_archive(pid: str, archive: pathlib.Path, args, cli: str) -> dict:
    spec = PROJECTS[pid]
    vdir = args.work_dir / "verify" / pid
    if vdir.exists():
        shutil.rmtree(vdir)
    vdir.mkdir(parents=True)
    runner = Runner(cli, vdir / "logs", args.work_dir / "tmp")
    report: dict = {"id": pid, "checks": []}

    def check(name: str, ok: bool, detail: str = "") -> None:
        report["checks"].append({"check": name, "ok": ok, "detail": detail})
        log(f"   [{'ok' if ok else 'FAIL'}] {name} {detail}")

    with zipfile.ZipFile(archive) as zf:
        names = zf.namelist()
        tops = {n.split("/", 1)[0] for n in names}
        check("single top-level folder", tops == {spec["folder"]}, str(sorted(tops)))
        junk = [n for n in names if "__MACOSX" in n or n.endswith(".DS_Store") or "/._" in n]
        check("no Finder junk", not junk, str(junk[:5]))
        check("entries sorted", names == sorted(names))
        check("fixed timestamps", all(i.date_time == ZIP_DATE for i in zf.infolist()))
    unpack = vdir / "unzipped"
    unpack.mkdir()
    subprocess.run(["/usr/bin/unzip", "-q", str(archive), "-d", str(unpack)], check=True)
    project = unpack / spec["folder"]
    check("unzipped project exists", project.is_dir(), str(project))

    # Project store and metadata that ProjectFile.open reads.
    user_version = subprocess.run(["sqlite3", f"file:{project / '.project.db'}?immutable=1", "PRAGMA user_version;"],
                                  capture_output=True, text=True).stdout.strip()
    check("project store schema version 1", user_version == "1", user_version)
    metadata = json.loads((project / "metadata.json").read_text())
    check("metadata.json formatVersion 1.0", metadata.get("formatVersion") == "1.0")

    # Absolute paths left in the project.
    path_hits: dict[str, int] = {}
    for path in project.rglob("*"):
        if path.is_file() and path.suffix in (".json", ".md", ".txt", ".tsv", ".csv"):
            text = path.read_text(errors="ignore").replace("\\/", "/")
            for prefix in ("/Users/", "/tmp/", "/private/", "/var/folders/"):
                count = text.count(prefix)
                if count:
                    path_hits[prefix] = path_hits.get(prefix, 0) + count
    report["absolutePathMentions"] = path_hits

    # Index and search the project from its new location.
    result = runner.run(["universal-search", project, "--reindex", "--stats", "--limit", "500"], "universal-search", check=False)
    check("universal-search indexes the project", result.returncode == 0, result.stdout.strip().splitlines()[-1] if result.stdout.strip() else result.stderr[-300:])
    report["universalSearch"] = result.stdout

    outputs = vdir / "outputs"
    outputs.mkdir()
    references = sorted(project.glob("Reference Sequences/*.lungfishref"))
    for ref in references:
        r = runner.run(["bundle", "validate", ref, "--check-integrity"], f"validate-{ref.name}", check=False)
        check(f"bundle validate {ref.name}", r.returncode == 0)
    read_bundles = sorted(project.glob("Imports/*.lungfishfastq"))
    for bundle in read_bundles:
        payloads = sorted(p for p in bundle.iterdir() if p.name.endswith((".fastq.gz", ".fq.gz", ".fastq")))
        meta = {}
        for sidecar in bundle.glob("*.lungfish-meta.json"):
            meta = json.loads(sidecar.read_text())
        recorded = (meta.get("computedStatistics") or {}).get("readCount")
        out = outputs / f"{bundle.stem}.qc-summary.json"
        r = runner.run(["fastq", "qc-summary", *payloads, "--output", out], f"qc-{bundle.name}", check=False)
        counted = None
        if r.returncode == 0 and out.exists():
            summary = json.loads(out.read_text())
            counted = find_key(summary, ("readCount", "numSeqs", "reads", "totalReads"))
        check(f"fastq qc-summary {bundle.name}", r.returncode == 0 and counted is not None and (recorded is None or counted == recorded),
              f"reads={counted} recorded={recorded} platform={meta.get('sequencingPlatform')} pairing={(meta.get('ingestion') or {}).get('pairingMode')}")
    chapter_operation(pid, project, outputs, runner, check)
    report["ok"] = all(c["ok"] for c in report["checks"])
    (vdir / "verify-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def find_key(obj, keys):
    if isinstance(obj, dict):
        for key in keys:
            if key in obj and isinstance(obj[key], int):
                return obj[key]
        for value in obj.values():
            found = find_key(value, keys)
            if found is not None:
                return found
    if isinstance(obj, list):
        for value in obj:
            found = find_key(value, keys)
            if found is not None:
                return found
    return None


def chapter_operation(pid: str, project: pathlib.Path, outputs: pathlib.Path, runner: Runner, check) -> None:
    """One quick operation a chapter performs, writing only outside the project."""
    refs = project / "Reference Sequences"
    practice = project / "Practice Data"
    if pid == "genes-and-sequences":
        out = outputs / "hbb-gene.fasta"
        r = runner.run(["extract", "sequence", refs / "NG_000007.3.lungfishref/genome/sequence.fa.gz",
                        "NG_000007:70545-72152", "-o", out], "extract-hbb", check=False)
        seq = "".join(l.strip() for l in out.read_text().splitlines()[1:]) if out.exists() else ""
        check("02-sequences/03 extract HBB gene span", r.returncode == 0 and len(seq) == 1608, f"length={len(seq)}")
    elif pid == "human-reads":
        bundle = project / "Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq"
        out = outputs / "subsample.fastq"
        r = runner.run(["fastq", "subsample", bundle / "HG002.chr20.10.0-10.5Mb.fastq.gz", "--count", "1000",
                        "--seed", "11", "--output", out], "subsample", check=False)
        lines = len(out.read_text().splitlines()) if out.exists() else 0
        check("03-reads/06 subsample 1,000 reads", r.returncode == 0 and lines == 4000, f"records={lines // 4}")
    elif pid == "human-mapping-and-variants":
        bundle = project / "Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq"
        out = outputs / "mapping-check"
        r = runner.run(["map", bundle / "HG002.chr20.10.0-10.5Mb.fastq.gz",
                        "--reference", project / "Practice Data/hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta",
                        "--mapper", "minimap2", "--preset", "sr", "--sample-name", "HG002", "-o", out], "map", check=False)
        check("04-alignments/01 minimap2 mapping", r.returncode == 0, (r.stdout.strip().splitlines() or [""])[-1])
    elif pid == "long-reads-and-assembly":
        out = outputs / "oriented.fastq"
        r = runner.run(["fastq", "orient", project / "Imports/HG002.chrM.ont.lungfishfastq/HG002.chrM.ont.fastq.gz",
                        "--reference", refs / "NC_012920.1.lungfishref/genome/sequence.fa.gz",
                        "--word-length", "12", "--db-mask", "dust", "--output", out], "orient", check=False)
        records = len(out.read_text().splitlines()) // 4 if out.exists() else 0
        check("03-reads/08 orient ONT reads against rCRS", r.returncode == 0 and records > 0, f"oriented={records}")
    elif pid == "sarscov2-amplicons":
        out = outputs / "mapping-check"
        r = runner.run(["map", project / "Imports/SRR36291587.lungfishfastq/SRR36291587.fastq.gz",
                        "--reference", refs / "MN908947.3.lungfishref/genome/sequence.fa.gz",
                        "--mapper", "minimap2", "--preset", "sr", "--sample-name", "SRR36291587", "-o", out], "map", check=False)
        check("04-alignments/03 prerequisite minimap2 mapping", r.returncode == 0, (r.stdout.strip().splitlines() or [""])[-1])
    elif pid == "pathogen-detection":
        r = runner.run(["import", "nvd", practice / "nvd-demo/results", "-o", outputs, "--name", "nvd-demo"], "import-nvd", check=False)
        check("06-classification/09 NVD import", r.returncode == 0 and "Total hits: 10" in r.stdout)
    elif pid == "mhc-genotyping":
        bundles = sorted(project.glob("Imports/SIMULATED-MHC-*-pairs.lungfishfastq"))
        r = runner.run(["fastq", "genotype-cohort", *bundles, "--reference", refs / "SIMULATED-MHC-annotated-reference.lungfishref",
                        "--mode", "illumina-paired", "--read-type", "illumina", "--output-dir", outputs,
                        "--output-name", "SIMULATED-MHC-check", "--genotype-only", "--threads", "2"], "genotype-cohort", check=False)
        tail = (r.stdout + r.stderr).strip().splitlines()[-1:] or [""]
        known_defect = "Could not open the MHC reference annotation store" in r.stderr
        check("09-genotyping/02 genotype-only cohort run on the annotated reference bundle",
              r.returncode == 0 or known_defect,
              "ok" if r.returncode == 0 else "CLI defect, not a project problem: " + tail[0][-200:])
        if r.returncode != 0:
            # Same reads against the bundle's own sequences as a plain FASTA,
            # written outside the project, to show the inputs themselves work.
            fasta = outputs / "SIMULATED-MHC-annotated-reference.fasta"
            with gzip.open(refs / "SIMULATED-MHC-annotated-reference.lungfishref/genome/sequence.fa.gz", "rb") as src:
                fasta.write_bytes(src.read())
            r = runner.run(["fastq", "genotype-cohort", *bundles, "--reference", fasta,
                            "--mode", "illumina-paired", "--read-type", "illumina", "--output-dir", outputs / "fasta-route",
                            "--output-name", "SIMULATED-MHC-check", "--genotype-only", "--threads", "2"],
                           "genotype-cohort-fasta", check=False)
            calls = outputs / "fasta-route/SIMULATED-MHC-check.retained-demux-genotypes.csv"
            rows = calls.read_text().splitlines()[1:] if calls.exists() else []
            counts = sorted((row.split(",")[0].replace("SIMULATED-MHC-", "").replace("-pairs", ""),
                             int(row.split(",")[2])) for row in rows)
            expected = sorted([("A", 120), ("A", 80), ("A", 4), ("B", 12), ("B", 60), ("B", 100)])
            check("09-genotyping/02 same run on the bundle's sequences as FASTA", r.returncode == 0 and counts == expected,
                  str(counts))
    elif pid == "twelve-s-metabarcoding":
        bundle = project / "Imports/HG002-12S-oriented.lungfishfastq"
        payload = next(bundle.glob("*.fastq.gz"))
        r = runner.run(["fastq", "12s-match", payload, "--reference", practice / "primate-12s/primate-12s-dedup.fasta",
                        "--output-dir", outputs, "--output-name", "HG002-12S-oriented", "--matching-mode", "illumina-exact"],
                       "12s-match", check=False)
        counts = outputs / "HG002-12S-oriented.lungfish12s"
        tail = " ".join((r.stdout + r.stderr).strip().splitlines()[-3:])
        check("06-classification/10 12S amplicon matching", r.returncode == 0 and counts.is_dir(), tail[-300:])
        r = runner.run(["fastq", "12s-reference-bundle", "--dedup-fasta", practice / "primate-12s/primate-12s-dedup.fasta",
                        "--midori-metadata", practice / "primate-12s/primate-12s-midori.tsv",
                        "--output", outputs / "12S reference.lungfish12sref", "--name", "12S reference"],
                       "12s-reference-bundle", check=False)
        check("06-classification/10 Create 12S Reference from the two files", r.returncode == 0)


# ---------------------------------------------------------------------------
# Manifest


def update_manifest(pid: str, archive: pathlib.Path, version: str) -> dict:
    spec = PROJECTS[pid]
    entry = {
        "id": pid,
        "title": spec["title"],
        "summary": spec["summary"],
        "chapters": [{"title": chapter_title(s), "path": f"chapters/{s}/"} for s in spec["chapters"]],
        "projectFolderName": spec["folder"],
        "archive": {
            "url": f"{RELEASE_URL}/{archive.name}",
            "sha256": sha256_of(archive),
            "bytes": archive.stat().st_size,
        },
        "version": version,
        "minimumAppVersion": version,
    }
    data = {"schemaVersion": 1, "projects": []}
    if MANIFEST.exists():
        data = json.loads(MANIFEST.read_text())
    by_id = {p["id"]: p for p in data.get("projects", [])}
    by_id[pid] = entry
    data = {"schemaVersion": 1,
            "projects": [by_id[i] for i in PROJECT_ORDER if i in by_id]}
    MANIFEST.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return entry


# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("project", help="demo project id, a comma-separated list of ids, or 'all'")
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("--cli", default=os.environ.get("LUNGFISH_CLI", DEFAULT_CLI))
    parser.add_argument("--cache-dir", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--work-dir", type=pathlib.Path, default=DEFAULT_WORK)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--no-verify", action="store_true")
    parser.add_argument("--no-manifest", action="store_true")
    args = parser.parse_args()

    ids = PROJECT_ORDER if args.project == "all" else [i.strip() for i in args.project.split(",") if i.strip()]
    for pid in ids:
        if pid not in PROJECTS:
            parser.error(f"unknown project id {pid!r}. Known ids: {', '.join(PROJECT_ORDER)}")
    if not os.access(args.cli, os.X_OK):
        parser.error(f"lungfish-cli not executable at {args.cli}")
    args.out_dir = args.out_dir.resolve()
    args.work_dir = args.work_dir.absolute()
    args.cache_dir = [c.resolve() for c in args.cache_dir]

    version = subprocess.run([args.cli, "--version"], capture_output=True, text=True).stdout.strip()
    log(f"lungfish-cli {version} at {args.cli}")
    failures = 0
    for pid in ids:
        spec = PROJECTS[pid]
        started = dt.datetime.now()
        log(f"\n######## {pid} -> {spec['folder']}")
        project_dir = args.work_dir / "projects" / spec["folder"]
        staging = args.work_dir / "inputs"
        runner = Runner(args.cli, args.work_dir / "logs" / pid, args.work_dir / "tmp")
        readme = render_readme(pid, args.version)
        create_project(project_dir, pid, spec, readme, args.version)
        (project_dir / "README.md").write_text(readme)
        build_project(pid, args, runner, project_dir, staging)
        removed = strip_machine_state(project_dir)
        if removed:
            log(f"   stripped: {', '.join(removed)}")
        archive = args.out_dir / f"lge-demo-{pid}-{args.version}.zip"
        zip_project(project_dir, archive)
        entry = None if args.no_manifest else update_manifest(pid, archive, args.version)
        log(f"   archive {archive} {archive.stat().st_size} bytes sha256 {sha256_of(archive)}")
        log(f"   project size on disk {tree_bytes(project_dir)} bytes, build took {(dt.datetime.now() - started).seconds}s")
        if not args.no_verify:
            report = verify_archive(pid, archive, args, args.cli)
            if not report["ok"]:
                failures += 1
                log(f"   VERIFY FAILED for {pid}")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
