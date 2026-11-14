#!/usr/bin/env python3
"""Check that a genome FASTA and a GTF fit together as one reference set.

Both files are streamed through memory, gzip or plain, and no decompressed copy is
written. The output is TSV rows of key and value, so a build step can rerun it.

Usage:
  python3 -I refcheck.py <set folder>
  python3 -I refcheck.py --fasta F --gtf G [--assembly-report R] [--mito-contig NAME]
                         [--expect KEY=VALUE ...]

The folder form takes the one genome FASTA (.fa, .fna or .fasta, plain or .gz, and not a
cdna, ncrna or cds file), the one GTF and the one *assembly_report.txt in the folder.

Rows that matter to a reference set
  gtf_names_missing_from_fasta   GTF sequence names with no FASTA record, must be 0
  genes_with_cds_no_exon         genes with a CDS line and no exon line (ADJ-SC gse296788 Q2)
  mito_contig, mito_genes        found by contig, never by a gene name prefix
  empty_gene_id_features         GTF lines whose gene_id is empty or absent

The mitochondrial contig comes from --mito-contig, else an assembly report row typed
Mitochondrion, else a FASTA header that says mitochondrion, else a contig named MT, chrM,
chrMT, M or Mt. The row mito_contig_source says which. Rows named *_MT_prefix count genes
whose name starts with MT- and are shown only to contrast with the contig rule.

Exit status is 0 when no GTF sequence name is missing and every --expect holds, 1 when one
fails, and 2 when a file cannot be read.
"""
import argparse
import hashlib
import re
import sys
import zlib
from collections import Counter
from pathlib import Path

CHUNK = 1 << 16
GZIP_MAGIC = b"\x1f\x8b"
MITO_NAMES = ("MT", "chrM", "chrMT", "M", "Mt")
FASTA_EXT = (".fa", ".fna", ".fasta")
NOT_GENOME = ("cdna", "ncrna", "cds_from", "rna_from", "pseudo_without", ".pep.", "_rna.", "_protein")
GENE_ID = re.compile(rb'gene_id "([^"]*)"')
GENE_NAME = re.compile(rb'(?:^|[; ])gene(?:_name)? "([^"]*)"')
MAX_LISTED = 200


class RefcheckError(Exception):
    pass


def stream(path, hasher, chunk_size=CHUNK):
    """Yield the bytes of a gzip or plain file, hashing the stored bytes as they are read."""
    try:
        with open(path, "rb") as fh:
            gz = fh.read(2) == GZIP_MAGIC
            fh.seek(0)
            inflater = None
            while True:
                raw = fh.read(chunk_size)
                if not raw:
                    break
                hasher.update(raw)
                if not gz:
                    yield raw
                    continue
                while raw:
                    if inflater is None:
                        inflater = zlib.decompressobj(31)
                    out = inflater.decompress(raw)
                    if out:
                        yield out
                    done = inflater.eof
                    raw = inflater.unused_data if done else b""
                    if done:
                        inflater = None
            if inflater is not None:
                raise RefcheckError(f"{path} ends inside a gzip member, so the file is cut short")
    except zlib.error as e:
        raise RefcheckError(f"{path} is not valid gzip ({e})") from e


def lines_of(chunks):
    carry = b""
    for data in chunks:
        parts = (carry + data).split(b"\n")
        carry = parts.pop()
        yield from parts
    if carry:
        yield carry


class FastaFacts:
    def __init__(self):
        self.names = []  # first word of each header, in file order
        self.mito_headers = []  # names whose header says mitochondrion
        self.bases = 0
        self.sha256 = ""
        self.size = 0


def next_header(block, start):
    """Offset of the first header line that begins after the newline at start, else -1."""
    at = block.find(b"\n>", start)
    return at + 1 if at >= 0 else -1


def scan_fasta(path, chunk_size=CHUNK):
    facts, hasher = FastaFacts(), hashlib.sha256()

    def take(block):  # whole lines, the last one ended by a newline
        header_chars = 0
        pos = 0 if block[:1] == b">" else next_header(block, 0)
        while pos >= 0:
            end = block.index(b"\n", pos)
            line = block[pos:end]
            header_chars += len(line)
            words = line[1:].split(None, 1)
            name = words[0].decode("utf-8", "replace") if words else ""
            facts.names.append(name)
            if b"mitochondri" in line.lower():
                facts.mito_headers.append(name)
            pos = next_header(block, end)
        facts.bases += len(block) - block.count(b"\n") - header_chars

    carry = b""
    for data in stream(path, hasher, chunk_size):
        data = carry + data
        cut = data.rfind(b"\n")
        if cut < 0:
            carry = data
            continue
        carry = data[cut + 1:]
        take(data[:cut + 1])
    if carry:
        take(carry + b"\n")
    facts.sha256, facts.size = hasher.hexdigest(), Path(path).stat().st_size
    return facts


class GtfFacts:
    def __init__(self):
        self.lines = 0
        self.gene_lines = 0
        self.short_lines = 0
        self.seqnames = {}  # contig bytes to line count
        self.genes = {}  # gene_id bytes to [flags, first contig bytes], flags 1 exon, 2 CDS
        self.prefixed = {}  # gene_id bytes to contig bytes, for gene names starting MT-
        self.header = []  # the comment lines before the first feature, which name the build and release
        self.empty_types = Counter()
        self.empty_contigs = Counter()
        self.sha256 = ""
        self.size = 0


def scan_gtf(path, chunk_size=CHUNK):
    facts, hasher = GtfFacts(), hashlib.sha256()
    seqnames, genes = facts.seqnames, facts.genes
    for line in lines_of(stream(path, hasher, chunk_size)):
        if not line:
            continue
        if line[:1] == b"#":
            if not facts.lines and len(facts.header) < 12:
                facts.header.append(text(line).lstrip("#! ").strip().replace("\t", " "))
            continue
        f = line.split(b"\t", 8)
        if len(f) < 9:
            facts.short_lines += 1
            continue
        facts.lines += 1
        contig, ftype, attrs = f[0], f[2], f[8]
        seqnames[contig] = seqnames.get(contig, 0) + 1
        is_gene = ftype == b"gene"
        if is_gene:
            facts.gene_lines += 1
        m = GENE_ID.search(attrs)
        gid = m.group(1) if m else b""
        if not gid:
            facts.empty_types[ftype] += 1
            facts.empty_contigs[contig] += 1
            continue
        flag = 1 if ftype == b"exon" else 2 if ftype == b"CDS" else 0
        rec = genes.get(gid)
        if rec is None:
            genes[gid] = [flag, contig]
        else:
            rec[0] |= flag
        if is_gene:
            n = GENE_NAME.search(attrs)
            if n and n.group(1).startswith(b"MT-"):
                facts.prefixed[gid] = contig
    facts.sha256, facts.size = hasher.hexdigest(), Path(path).stat().st_size
    return facts


def text(raw):
    return raw.decode("utf-8", "replace")


def tally(counts, limit=10):
    items = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    shown = [f"{k}:{v}" for k, v in items[:limit]]
    if len(items) > limit:
        shown.append(f"+{len(items) - limit} more")
    return ",".join(shown) or "-"


def listed(names, limit=MAX_LISTED):
    shown = list(names[:limit])
    if len(names) > limit:
        shown.append(f"(+{len(names) - limit} more)")
    return ",".join(shown) or "-"


def report_candidates(report):
    """Names an NCBI assembly report gives to the sequences it types Mitochondrion."""
    names = []
    with open(report, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if not line.startswith("#") and len(f) > 6 and f[3] == "Mitochondrion":
                names += [f[i] for i in (6, 4, 0, 9) if i < len(f) and f[i] != "na"]
    return names


def find_mito(fa, gtf_names, explicit, report):
    """Return the mitochondrial contig names and which rule found them. Never a name prefix."""
    known = set(fa.names) | gtf_names
    if explicit:
        return [explicit], "argument"
    if report:
        hits = list(dict.fromkeys(n for n in report_candidates(report) if n in known))
        if hits:
            return hits, "assembly report"
    if fa.mito_headers:
        return fa.mito_headers, "FASTA header"
    hits = [n for n in MITO_NAMES if n in known]
    return (hits, "contig name") if hits else ([], "none")


def check(fasta, gtf, *, mito_contig=None, assembly_report=None, chunk_size=CHUNK):
    """Return the facts of a FASTA and GTF pair as (key, value) rows of text."""
    fa = scan_fasta(fasta, chunk_size)
    gt = scan_gtf(gtf, chunk_size)
    seqnames = [text(n) for n in gt.seqnames]
    missing = sorted(set(seqnames) - set(fa.names))
    mito, source = find_mito(fa, set(seqnames), mito_contig, assembly_report)
    mito_set = {m.encode() for m in mito}
    cds_only = sorted((text(g), text(c)) for g, (flags, c) in gt.genes.items() if flags & 2 and not flags & 1)
    return [
        ("fasta", str(fasta)),
        ("fasta_sha256", fa.sha256),
        ("fasta_bytes", str(fa.size)),
        ("fasta_sequences", str(len(fa.names))),
        ("fasta_bases", str(fa.bases)),
        ("gtf", str(gtf)),
        ("gtf_sha256", gt.sha256),
        ("gtf_bytes", str(gt.size)),
        ("gtf_header", " | ".join(gt.header)[:600] or "-"),
        ("gtf_lines", str(gt.lines)),
        ("gtf_gene_lines", str(gt.gene_lines)),
        ("gtf_sequence_names", str(len(seqnames))),
        ("gtf_names_missing_from_fasta", str(len(missing))),
        ("gtf_missing_names", listed(missing)),
        ("genes", str(len(gt.genes))),
        ("genes_with_cds_no_exon", str(len(cds_only))),
        ("genes_with_cds_no_exon_on_mito", str(sum(1 for _, c in cds_only if c.encode() in mito_set))),
        ("genes_with_cds_no_exon_contigs", tally(Counter(c for _, c in cds_only))),
        ("genes_with_cds_no_exon_ids", listed([g for g, _ in cds_only], 20)),
        ("mito_contig", ",".join(mito) or "-"),
        ("mito_contig_source", source),
        ("mito_genes", str(sum(1 for _, c in gt.genes.values() if c in mito_set))),
        ("mito_genes_with_MT_prefix", str(sum(1 for c in gt.prefixed.values() if c in mito_set))),
        ("genes_with_MT_prefix", str(len(gt.prefixed))),
        ("empty_gene_id_features", str(sum(gt.empty_types.values()))),
        ("empty_gene_id_by_type", tally(Counter({text(k): v for k, v in gt.empty_types.items()}))),
        ("empty_gene_id_on", tally(Counter({text(k): v for k, v in gt.empty_contigs.items()}))),
    ]


def is_fasta(name):
    name = name.lower()
    base = name[:-3] if name.endswith(".gz") else name
    return base.endswith(FASTA_EXT) and not any(word in name for word in NOT_GENOME)


def only(found, folder, flag):
    if len(found) != 1:
        names = ", ".join(p.name for p in found) or "none"
        raise RefcheckError(f"found {names} in {folder}, so name the file with {flag}")
    return found[0]


def resolve(args):
    fasta, gtf, report = args.fasta, args.gtf, args.assembly_report
    if args.folder:
        folder = Path(args.folder)
        if not folder.is_dir():
            raise RefcheckError(f"{folder} is not a folder")
        notes = ("readme", "checksums")  # Ensembl keeps README.fasta and CHECKSUMS.gtf beside the data
        files = sorted(p for p in folder.iterdir() if p.is_file() and not p.name.lower().startswith(notes))
        reports = [p for p in files if p.name.endswith("assembly_report.txt")]
        if fasta is None:
            fasta = only([p for p in files if is_fasta(p.name)], folder, "--fasta")
        if gtf is None:
            gtf = only([p for p in files if p.name.lower().endswith((".gtf", ".gtf.gz"))], folder, "--gtf")
        if report is None and len(reports) == 1:
            report = str(reports[0])
    elif not (fasta and gtf):
        raise RefcheckError("give a folder, or both --fasta and --gtf")
    return str(fasta), str(gtf), report


def main(argv=None):
    ap = argparse.ArgumentParser(prog="refcheck.py", description="Check a genome FASTA and a GTF as one reference set.")
    ap.add_argument("folder", nargs="?", help="folder holding one genome FASTA and one GTF")
    ap.add_argument("--fasta")
    ap.add_argument("--gtf")
    ap.add_argument("--assembly-report", help="NCBI assembly report that types the mitochondrion")
    ap.add_argument("--mito-contig", help="name of the mitochondrial contig")
    ap.add_argument("--expect", action="append", default=[], metavar="KEY=VALUE",
                    help="exit 1 unless the row KEY equals VALUE, repeatable")
    args = ap.parse_args(argv)
    try:
        fasta, gtf, report = resolve(args)
        rows = check(fasta, gtf, mito_contig=args.mito_contig, assembly_report=report)
    except (RefcheckError, OSError) as e:
        print(f"refcheck: {e}", file=sys.stderr)
        return 2
    facts = dict(rows)
    failures = []
    if facts["gtf_names_missing_from_fasta"] != "0":
        failures.append(f"gtf_names_missing_from_fasta expected 0 got {facts['gtf_names_missing_from_fasta']}")
    for item in args.expect:
        key, _, want = item.partition("=")
        if facts.get(key) != want:
            failures.append(f"{key} expected {want} got {facts.get(key)}")
    print("key\tvalue")
    for key, value in rows:
        print(f"{key}\t{value}")
    print("result\t" + ("FAIL" if failures else "pass"))
    for failure in failures:
        print(f"refcheck: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
