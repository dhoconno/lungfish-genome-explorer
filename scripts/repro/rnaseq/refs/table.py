#!/usr/bin/env python3
"""Print the P5-REFS rows as Markdown from refcheck answers, the staging ledger and the manifest.

Usage: python3 -I table.py <refcheck_out_dir> <MANIFEST.tsv> [template]
With a template, the line @@ROWS@@ is replaced by the three blocks. Every count, url and
checksum comes from a refcheck answer, the ledger or the manifest, and nothing is typed in.
Only the names and the annotation release of each set are written below, as read from
the GTF headers and NCBI's dataset reports. A set with no answer yet reads "not staged".
Run run_sets.sh first to make the answers.
"""
import sys
from pathlib import Path

DATA = "/Volumes/lge_scratch/lge/rnaseq/"
HERE = Path(__file__).resolve().parent
# folder under refs/, role, assembly name, accession when the GTF header has none, annotation release
SETS = [
    ("human/gencode-50", "human default", "GRCh38 primary assembly", "patch level not in the files", "GENCODE 50 (Ensembl 116)"),
    ("rhesus/ensembl-116", "rhesus default", "Mmul_10", "", "Ensembl 116"),
    ("rhesus/refseq-GCF_003339765.1", "rhesus equal choice", "Mmul_10", "", "NCBI RefSeq Annotation Release 103"),
    ("rhesus/refseq-GCF_049350105.2", "rhesus offered", "T2T-MMU8v2.0", "GCF_049350105.2", "NCBI RefSeq GCF_049350105.2-RS_2025_08"),
    ("cynomolgus/refseq-GCF_037993035.2", "cynomolgus default", "T2T-MFA8v1.1", "GCF_037993035.2", "NCBI RefSeq GCF_037993035.2-RS_2025_03"),
    ("cynomolgus/ensembl-107", "cynomolgus offered", "Macaca_fascicularis_6.0", "", "Ensembl 107"),
    ("cynomolgus/refseq-GCF_000364345.1", "cynomolgus offered", "Macaca_fascicularis_5.0", "", "NCBI RefSeq Annotation Release 101"),
    ("rhesus/ensembl-100", "check set (GR)", "Mmul_10", "", "Ensembl 100"),
]


def tsv_rows(path):
    with open(path, encoding="utf-8") as fh:
        return [line.rstrip("\n").split("\t") for line in fh if line.strip() and not line.startswith("#")]


def answer(out, folder):
    path = Path(out) / (folder.replace("/", "-") + ".tsv")
    rows = dict(r[:2] for r in tsv_rows(path)[1:]) if path.exists() else {}
    return rows if "fasta" in rows else None  # an empty file is a run that has not finished


def header_value(a, key):
    for part in a["gtf_header"].split(" | "):
        if part.startswith(key + " "):
            return part[len(key) + 1:]
    return ""


def mito_cell(a):
    """The mitochondrial contig and its rule, or, when the files hold none, what the assembly report lists."""
    if a["mito_contig"] != "-":
        return f"`{a['mito_contig']}` ({a['mito_contig_source']})"
    records = [r.split("/") for r in a.get("report_mito_records", "-").split(",") if r != "-"]
    listed = ", ".join(f"{name} ({genbank}, RefSeq {refseq}" + ("" if length == "na" else f", {length} bp") + ")"
                       for name, genbank, refseq, length in records)
    return "none in FASTA or GTF" + (f", the report lists {listed}" if listed else "")


def file_cell(a, folder, kind, ledger, manifest):
    if a is None:
        for url, dest, _type, md5 in manifest:
            if dest.startswith(f"refs/{folder}/") and dest.endswith(f"_genomic.{kind}.gz"):
                return f"[{Path(dest).name}]({url}) md5 `{md5}`, not staged"
        return "not staged"
    key = "fasta" if kind == "fna" else "gtf"
    url, sha = ledger.get(a[key], ("no ledger row", ""))
    note = "" if sha == a[key + "_sha256"] else " LEDGER SHA256 DIFFERS"
    return f"[{Path(a[key]).name}]({url}) `{a[key + '_sha256']}`{note}"


def blocks(out, ledger_path, manifest_path):
    ledger = {r[0]: (r[1], r[4]) for r in tsv_rows(ledger_path)[1:]}
    manifest = [(r[0], r[1], r[2], r[3]) for r in tsv_rows(manifest_path) if len(r) > 3 and r[2] == "md5"]
    rows = [(s, answer(out, s[0])) for s in SETS]
    lines = ["| Set | Role | Assembly | Annotation | FASTA (url, sha256) | GTF (url, sha256) |", "|---|---|---|---|---|---|"]
    for (folder, role, name, acc, release), a in rows:
        if a:
            acc = header_value(a, "genome-build-accession") or acc
            release = header_value(a, "annotation-source") or release
        lines.append(f"| `{folder}` | {role} | {name}, {acc or 'accession not in the files'} | {release} | "
                     f"{file_cell(a, folder, 'fna', ledger, manifest)} | {file_cell(a, folder, 'gtf', ledger, manifest)} |")
    lines += ["", "| Set | GTF names missing from FASTA | Genes, CDS and no exon (on mito contig) | Mito contig (rule) | Mito genes (named MT-) | Empty gene_id |", "|---|---|---|---|---|---|"]
    for (folder, *_), a in rows:
        if a is None:
            lines.append(f"| `{folder}` | not staged | | | | |")
            continue
        lines.append(f"| `{folder}` | {a['gtf_names_missing_from_fasta']} {a['gtf_missing_names'].replace('-', '')} | {a['genes_with_cds_no_exon']} ({a['genes_with_cds_no_exon_on_mito']}) | "
                     f"{mito_cell(a)} | {a['mito_genes']} ({a['mito_genes_with_MT_prefix']}) | {a['empty_gene_id_features']} {a['empty_gene_id_by_type'].replace('-', '')} |")
    lines.append("")
    for (folder, *_), a in rows:
        cmd = Path(out, folder.replace("/", "-") + ".cmd")
        if a and cmd.exists():
            extra = cmd.read_text().split("refcheck.py", 1)[1].split(None, 1)[1:]  # what follows the folder
            flags = (" " + extra[0].strip()) if extra else ""
            lines.append(f"- `python3 -I scripts/repro/rnaseq/refs/refcheck.py refs/{folder}{flags}` printed `gtf_names_missing_from_fasta {a['gtf_names_missing_from_fasta']}` and `genes_with_cds_no_exon {a['genes_with_cds_no_exon']}`")
    return lines


def main(argv):
    out, ledger_path = argv[0], argv[1]
    lines = blocks(out, ledger_path, HERE / "manifests" / "p5-refs.tsv")
    if len(argv) > 2:
        for line in Path(argv[2]).read_text().splitlines():
            print("\n".join(lines) if line.strip() == "@@ROWS@@" else line)
    else:
        print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv[1:])
