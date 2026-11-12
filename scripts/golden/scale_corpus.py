#!/usr/bin/env python3
"""scale_corpus.py build | verify | list

Builds one ready project of real-size inputs for the scale smoke (lane SCALE-SMOKE, trust session). The project
ScaleCorpus.lungfish and its corpus.json go to the golden cache (default /Users/Shared/lungfish-golden/cache/scale-corpus).
It holds a FASTA of 20,000 records with one record of 1.5 Mbp, a FASTA of 100,000 records, a FASTQ bundle of 100,000
reads, a reference bundle with a BAM of about 1 GB, a reference bundle of 3,000 contigs and the results the demo archives
hold (a reference, a FASTQ bundle, a mapping result and an MHC reference). Made data comes from one fixed seed, since the
smoke checks time and memory and not numbers. The reads of the archive picks are public reads and each pick names its
archive and member in corpus.json. The kinds of ViewSwitchKinds.all that no archive holds as a result are listed under
"uncovered" in corpus.json with the reason.

  build --out DIR [--scale full|tiny] [--archives DIR] [--no-bam] [--samtools PATH]
  verify --out DIR      recompute every SHA-256 and compare with corpus.json (exit 1 on a difference)
  list --out DIR        print the SHA-256 list

The tiny scale has the same shape in a few kilobytes and is what the unit tests build.
"""
import argparse
import collections
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

DEFAULT_OUT = Path("/Users/Shared/lungfish-golden/cache/scale-corpus")
DEFAULT_ARCHIVES = Path("/Users/Shared/lungfish-golden/cache/demo-archives")
PROJECT = "ScaleCorpus.lungfish"
SEED = 20261112
STAMP = "2026-11-12T00:00:00Z"


@dataclass(frozen=True)
class Scale:
    name: str
    small_records: int
    large_records: int
    long_record_bases: int
    fastq_reads: int
    bam_bytes: int
    bam_reference_bases: int
    contigs: int


FULL = Scale("full", 20_000, 100_000, 1_500_000, 100_000, 1_000_000_000, 5_000_000, 3_000)
TINY = Scale("tiny", 40, 200, 15_000, 120, 30_000, 20_000, 30)
SCALES = {"full": FULL, "tiny": TINY}


def wrap(sequence, width):
    return "\n".join(sequence[i:i + width] for i in range(0, len(sequence), width))


def base_pool(rng, size):
    return "".join(rng.choices("ACGT", k=size))


def quality_pool(rng, size):
    # Phred 20 to 40 as characters, weighted to the high end as an Illumina run is.
    return "".join(rng.choices([chr(33 + q) for q in range(20, 41)], weights=list(range(1, 22)), k=size))


def write_fasta_list(path, rng, pool, count, long_bases, prefix):
    """count records of 200 to 1,499 bases, one of long_bases at the middle when long_bases is not 0. Returns the sizes."""
    long_at = count // 2 if long_bases else -1
    total = 0
    with open(path, "w") as out:
        for index in range(count):
            length = long_bases if index == long_at else rng.randrange(200, 1500)
            start = rng.randrange(0, len(pool) - length)
            name = "%s_%06d len=%d%s" % (prefix, index + 1, length, " long_record" if index == long_at else "")
            out.write(">%s\n%s\n" % (name, wrap(pool[start:start + length], 70)))
            total += length
    return {"records": count, "bases": total}


def write_fastq_bundle(bundle, rng, pool, reads):
    """reads.fastq and the sidecar of cached statistics, so the dashboard needs no seqkit. The statistics are exact."""
    bundle.mkdir(parents=True)
    qpool = quality_pool(rng, 200_000)
    lengths, quals = collections.Counter(), collections.Counter()
    gc = 0
    with open(bundle / "reads.fastq", "w") as out:
        for index in range(reads):
            length = rng.randrange(100, 151)
            start = rng.randrange(0, len(pool) - length)
            sequence = pool[start:start + length]
            qstart = rng.randrange(0, len(qpool) - length)
            quality = qpool[qstart:qstart + length]
            out.write("@scale_read_%06d\n%s\n+\n%s\n" % (index + 1, sequence, quality))
            lengths[length] += 1
            quals.update(quality.encode())
            gc += sequence.count("G") + sequence.count("C")
    bases = sum(k * v for k, v in lengths.items())
    ordered = sorted(lengths.items(), reverse=True)
    half, running, n50 = bases / 2, 0, 0
    for length, count in ordered:
        running += length * count
        if running >= half:
            n50 = length
            break
    flat = sorted(lengths.elements())
    stats = {"readCount": reads, "baseCount": bases, "meanReadLength": bases / reads, "minReadLength": flat[0],
             "maxReadLength": flat[-1], "medianReadLength": flat[len(flat) // 2], "n50ReadLength": n50,
             "meanQuality": sum((k - 33) * v for k, v in quals.items()) / bases,
             "q20Percentage": 100.0 * sum(v for k, v in quals.items() if k - 33 >= 20) / bases,
             "q30Percentage": 100.0 * sum(v for k, v in quals.items() if k - 33 >= 30) / bases,
             "gcContent": gc / bases, "readLengthHistogram": {str(k): v for k, v in sorted(lengths.items())},
             "qualityScoreHistogram": [x for k, v in sorted(quals.items()) for x in (k - 33, v)],
             "perPositionQuality": []}
    (bundle / "reads.fastq.lungfish-meta.json").write_text(json.dumps({"computedStatistics": stats}, indent=1, sort_keys=True))
    return {"reads": reads, "bases": bases}


def bundle_manifest(name, identifier, notes, total, chromosomes, alignments):
    """A reference bundle manifest with the keys of the bundle browser fixture (LungfishProjectFixtureBuilder)."""
    return {"format_version": "1.0", "name": name, "identifier": identifier, "created_date": STAMP, "modified_date": STAMP,
            "source": {"organism": "Synthetic scale corpus", "assembly": "seeded", "database": "scale_corpus.py", "notes": notes},
            "genome": {"path": "genome/sequence.fa", "index_path": "genome/sequence.fa.fai", "total_length": total,
                       "chromosomes": chromosomes},
            "annotations": [], "variants": [], "tracks": [], "alignments": alignments}


def write_reference(bundle, records):
    """genome/sequence.fa and its .fai at 80 bases a line. Returns the manifest's chromosome list and the total length."""
    genome = bundle / "genome"
    genome.mkdir(parents=True)
    chromosomes, offset, total = [], 0, 0
    with open(genome / "sequence.fa", "w") as fasta, open(genome / "sequence.fa.fai", "w") as index:
        for name, sequence in records:
            header = ">%s\n" % name
            start = offset + len(header)
            fasta.write(header + wrap(sequence, 80) + "\n")
            index.write("%s\t%d\t%d\t80\t81\n" % (name, len(sequence), start))
            chromosomes.append({"name": name, "length": len(sequence), "offset": start, "line_bases": 80, "line_width": 81,
                                "aliases": [], "is_primary": True, "is_mitochondrial": False})
            offset = start + len(sequence) + -(-len(sequence) // 80)
            total += len(sequence)
    return chromosomes, total


def write_contig_bundle(bundle, rng, pool, contigs):
    def records():
        for index in range(contigs):
            length = rng.randrange(1000, 10000)
            start = rng.randrange(0, len(pool) - length)
            yield "scaffold_%04d" % (index + 1), pool[start:start + length]
    chromosomes, total = write_reference(bundle, records())
    manifest = bundle_manifest(bundle.stem, "org.lungfish.scale.contigs", "%d contigs of 1 to 10 kb" % contigs, total, chromosomes, [])
    (bundle / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True))
    return {"contigs": contigs, "bases": total}


def write_sam(stream, rng, reference, qpool, reads, read_length=150):
    """Coordinate-sorted single-end reads of the reference with two seeded mismatches each, so deflate cannot repeat them."""
    span = len(reference) - read_length
    stream.write(("@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chrScale1\tLN:%d\n" % len(reference)).encode())
    for index in range(reads):
        position = (index * span) // reads
        sequence = bytearray(reference[position:position + read_length].encode())
        for _ in range(2):
            sequence[rng.randrange(read_length)] = b"ACGT"[rng.randrange(4)]
        start = rng.randrange(0, len(qpool) - read_length)
        flag = 16 if rng.random() < 0.5 else 0
        stream.write(b"r%d\t%d\tchrScale1\t%d\t60\t%dM\t*\t0\t0\t%s\t%s\n" % (
            index, flag, position + 1, read_length, bytes(sequence), qpool[start:start + read_length].encode()))


def make_bam(path, rng, reference, qpool, reads, samtools):
    process = subprocess.Popen([samtools, "view", "-b", "-@", "4", "-o", str(path), "-"], stdin=subprocess.PIPE, bufsize=1 << 20)
    try:
        write_sam(process.stdin, rng, reference, qpool, reads)
    finally:
        process.stdin.close()
    if process.wait() != 0:
        raise RuntimeError("samtools view failed for %s" % path)


def write_bam_bundle(bundle, rng, pool, scale, samtools):
    """A reference bundle of one contig with a sorted, indexed BAM of about scale.bam_bytes, sized from a pilot of reads."""
    reference = pool[:scale.bam_reference_bases]
    chromosomes, total = write_reference(bundle, [("chrScale1", reference)])
    folder = bundle / "alignments"
    folder.mkdir()
    qpool = quality_pool(random.Random(SEED + 5), 200_000)
    pilot_reads = 50_000 if scale.name == "full" else 200
    make_bam(folder / "pilot.bam", random.Random(SEED + 4), reference, qpool, pilot_reads, samtools)
    per_read = os.path.getsize(folder / "pilot.bam") / pilot_reads
    (folder / "pilot.bam").unlink()
    reads = max(500, int(scale.bam_bytes / per_read))
    bam = folder / "scale.sorted.bam"
    make_bam(bam, rng, reference, qpool, reads, samtools)
    subprocess.run([samtools, "index", "-@", "4", str(bam)], check=True)
    idxstats = subprocess.run([samtools, "idxstats", str(bam)], check=True, capture_output=True, text=True).stdout
    mapped = sum(int(line.split("\t")[2]) for line in idxstats.splitlines() if line and not line.startswith("*"))
    entry = {"id": "aln-scale", "name": "Scale alignment", "format": "bam", "source_path": "alignments/scale.sorted.bam",
             "index_path": "alignments/scale.sorted.bam.bai", "added_date": STAMP, "sample_names": [],
             "file_size_bytes": os.path.getsize(bam), "mapped_read_count": mapped, "unmapped_read_count": 0}
    manifest = bundle_manifest(bundle.stem, "org.lungfish.scale.bam", "%d reads of 150 bases" % reads, total, chromosomes, [entry])
    (bundle / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True))
    return {"reads": reads, "bamBytes": os.path.getsize(bam)}


# id, kind, archive, member in the archive, place in the project, sidebar words, viewer identifier (None waits for no viewer)
ARCHIVE_PICKS = [
    ("reference", "Reference", "lge-demo-human-mapping-and-variants-2026.9.58.zip",
     "Human Mapping and Variants.lungfish/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref",
     "Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref", "GRCh38.chr20.10.0-10.5Mb", "reference-bundle-view"),
    ("archive-fastq", "FASTQ", "lge-demo-human-reads-2026.9.58.zip",
     "Human Reads.lungfish/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq",
     "Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq", "HG002.chr20.10.0-10.5Mb", "fastq-dataset-view"),
    ("mapping", "Mapping result", "lge-demo-human-mapping-and-variants-results-2026.9.58.zip",
     "Human Mapping and Variants (with results).lungfish/Analyses/minimap2-2026-09-25T00-00-00",
     "Analyses/minimap2-2026-09-25T00-00-00", "minimap2-2026-09-25", None),
    ("mhc", "MHC reference", "lge-demo-mhc-genotyping-2026.9.58.zip",
     "MHC Genotyping.lungfish/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
     "Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref", "SIMULATED-MHC-MCM-teaching",
     "mhc-reference-bundle-view"),
]
KINDS = ["Kraken2", "EsViritu", "TaxTriage", "NAO-MGS", "NVD", "CZ ID", "12S", "Reference", "Assembly", "FASTQ", "Genotype",
         "MHC reference", "MSA", "Tree", "Primer analysis", "Primer order", "FASTA document", "Quick Look", "Status only", "PDF",
         "FASTA collection", "Mapping result"]  # ViewSwitchKinds.all in Tests/LungfishAppTests/SafetyNets


def extract_pick(archive, member, destination):
    root = destination.resolve()
    found = 0
    with zipfile.ZipFile(archive) as bundle:
        for info in bundle.infolist():
            if not (info.filename.rstrip("/") == member or info.filename.startswith(member + "/")):
                continue
            target = (root / info.filename[len(member):].lstrip("/")).resolve()
            if root != target and root not in target.parents:
                raise ValueError("archive member outside its destination: " + info.filename)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(info) as source, open(target, "wb") as sink:
                shutil.copyfileobj(source, sink, 1 << 20)
            found += 1
    if not found:
        raise FileNotFoundError("no member %s in %s" % (member, archive))


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 22), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(root):
    return {str(p.relative_to(root)): sha256_file(p) for p in sorted(root.rglob("*")) if p.is_file()}


def listing(hashes):
    return "".join("%s  %s\n" % (digest, path) for path, digest in sorted(hashes.items()))


def tree_bytes(path):
    return path.stat().st_size if path.is_file() else sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def build(out, scale, archives=None, samtools="samtools", with_bam=True):
    out = Path(out)
    if (out / "corpus.json").exists():
        raise FileExistsError("%s holds a corpus. Remove it first" % out)
    project = out / PROJECT
    project.mkdir(parents=True)
    rng = random.Random(SEED)
    pool = base_pool(rng, max(2 * scale.long_record_bases, scale.bam_reference_bases, 20_000) + 10_000)
    (project / "metadata.json").write_text(json.dumps({"createdAt": STAMP, "customMetadata": {}, "formatVersion": "1.0",
                                                       "modifiedAt": STAMP, "name": "ScaleCorpus", "version": "1.0"}, indent=1))
    items, uncovered = [], {}

    def add(item_id, kind, row, viewer, relative, detail):
        items.append({"id": item_id, "kind": kind, "row": row, "viewer": viewer, "path": relative,
                      "bytes": tree_bytes(project / relative), **detail})

    add("fasta-small", "FASTA collection", "scale-fasta-small", "fasta-collection-table-pane", "scale-fasta-small.fasta",
        write_fasta_list(project / "scale-fasta-small.fasta", random.Random(SEED + 1), pool, scale.small_records,
                         scale.long_record_bases, "contig"))
    add("fasta-large", "FASTA collection", "scale-fasta-large", "fasta-collection-table-pane", "scale-fasta-large.fasta",
        write_fasta_list(project / "scale-fasta-large.fasta", random.Random(SEED + 2), pool, scale.large_records, 0, "contig"))
    add("fastq", "FASTQ", "Scale FASTQ", "fastq-dataset-view", "Scale FASTQ.lungfishfastq",
        write_fastq_bundle(project / "Scale FASTQ.lungfishfastq", random.Random(SEED + 6), pool, scale.fastq_reads))
    if with_bam:
        add("bam", "Reference", "Scale BAM", "reference-bundle-view", "Scale BAM.lungfishref",
            write_bam_bundle(project / "Scale BAM.lungfishref", random.Random(SEED + 3), pool, scale, samtools))
    add("contigs", "Reference", "Scale Contigs", "reference-bundle-view", "Scale Contigs.lungfishref",
        write_contig_bundle(project / "Scale Contigs.lungfishref", random.Random(SEED + 7), pool, scale.contigs))
    for item_id, kind, archive, member, relative, row, viewer in ARCHIVE_PICKS:
        path = Path(archives or "/nonexistent") / archive
        if not path.is_file():
            uncovered[kind] = "the demo archive %s is not at %s" % (archive, path)
            continue
        extract_pick(path, member, project / relative)
        add(item_id, kind, row, viewer, relative, {"source": "%s:%s" % (archive, member)})
    covered = {item["kind"] for item in items}
    uncovered = {kind: reason for kind, reason in uncovered.items() if kind not in covered}
    for kind in KINDS:
        if kind not in covered:
            uncovered.setdefault(kind, "no result of this kind in the demo archives")
    hashes = sha256_tree(project)
    total = hashlib.sha256(listing(hashes).encode()).hexdigest()
    corpus = {"schemaVersion": 1, "scale": scale.name, "seed": SEED, "project": PROJECT, "items": items,
              "uncovered": uncovered, "sha256": hashes, "corpusSha256": total}
    (out / "corpus.json").write_text(json.dumps(corpus, indent=1, sort_keys=True))
    return corpus


def verify(out):
    corpus = json.loads((Path(out) / "corpus.json").read_text())
    actual = sha256_tree(Path(out) / corpus["project"])
    return sorted(set(actual.items()) ^ set(corpus["sha256"].items()))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    made = commands.add_parser("build")
    made.add_argument("--scale", choices=sorted(SCALES), default="full")
    made.add_argument("--archives", type=Path, default=DEFAULT_ARCHIVES)
    made.add_argument("--no-bam", action="store_true")
    made.add_argument("--samtools", default=shutil.which("samtools") or "samtools")
    commands.add_parser("verify")
    commands.add_parser("list")
    for name in ("build", "verify", "list"):
        commands.choices[name].add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args(argv)
    if args.command == "build":
        corpus = build(args.out, SCALES[args.scale], args.archives, args.samtools, not args.no_bam)
        print(listing(corpus["sha256"]), end="")
        print("corpus sha256 %s (%d files, %d bytes)" % (corpus["corpusSha256"], len(corpus["sha256"]),
                                                        sum(item["bytes"] for item in corpus["items"])))
        return 0
    if args.command == "list":
        print(listing(json.loads((args.out / "corpus.json").read_text())["sha256"]), end="")
        return 0
    differences = verify(args.out)
    print("corpus matches corpus.json" if not differences else "corpus differs: %d entries" % len(differences))
    return 1 if differences else 0


if __name__ == "__main__":
    sys.exit(main())
