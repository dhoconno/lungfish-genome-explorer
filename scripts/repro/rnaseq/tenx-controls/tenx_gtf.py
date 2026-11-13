#!/usr/bin/env python3
"""Rebuild the GTF that a 10x Genomics reference package holds, by 10x's own rules.

Two rule sets are implemented, one for each generation of 10x reference.

mkgtf-3.0.0
    The 3.0.0 references (GRCh38-3.0.0, Ensembl 93) were made with
    `cellranger mkgtf --attribute=gene_biotype:<type>` for 17 gene biotypes.
    mkgtf keeps every GTF line whose gene_biotype attribute is on the list,
    so a gene is kept or dropped whole. Comment lines are kept.

gencode-2020-A
    The 2020-A references (GRCh38-2020-A, GENCODE v32) strip the version
    suffix from gene, transcript and exon ids into separate *_version
    attributes, then keep every line of a gene that has at least one
    transcript whose gene_type and transcript_type are both on the list and
    that carries neither the "readthrough_transcript" nor the "PAR" tag.

none
    Keep every line. 10x built some combined references this way; the lane
    decides by comparing the gene ids with the deposited features.

Usage: python -I tenx_gtf.py RULE IN.gtf[.gz] OUT.gtf

It prints the number of genes kept and the SHA-1 of the output, which Cell
Ranger records as reference_gtf_hash in molecule_info.h5.
"""
import gzip
import hashlib
import re
import sys

BIOTYPES_300 = [
    "protein_coding", "lincRNA", "antisense",
    "IG_LV_gene", "IG_V_gene", "IG_V_pseudogene", "IG_D_gene", "IG_J_gene",
    "IG_J_pseudogene", "IG_C_gene", "IG_C_pseudogene",
    "TR_V_gene", "TR_V_pseudogene", "TR_D_gene", "TR_J_gene",
    "TR_J_pseudogene", "TR_C_gene",
]

BIOTYPES_2020A = [
    "protein_coding", "lncRNA",
    "IG_C_gene", "IG_D_gene", "IG_J_gene", "IG_LV_gene", "IG_V_gene",
    "IG_V_pseudogene", "IG_J_pseudogene", "IG_C_pseudogene",
    "TR_C_gene", "TR_D_gene", "TR_J_gene", "TR_V_gene",
    "TR_V_pseudogene", "TR_J_pseudogene",
]

ATTR = re.compile(r'(\S+) "([^"]*)"')
ID_RE = r'(ENS(?:MUS)?[GTE][0-9]+)\.([0-9]+)'


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", newline="")
    return open(path, "r", newline="")


def attrs(line):
    cols = line.rstrip("\n").split("\t")
    if len(cols) < 9:
        return cols, {}
    return cols, dict(ATTR.findall(cols[8]))


def strip_versions(line):
    # 10x 2020-A: sed -E 's/gene_id "ID";/gene_id "\1"; gene_version "\3";/' and the same for transcript_id and exon_id.
    for key in ("gene", "transcript", "exon"):
        line = re.sub(key + r'_id "' + ID_RE + r'";',
                      key + r'_id "\1"; ' + key + r'_version "\2";', line)
    return line


def rule_300(lines):
    keep = set(BIOTYPES_300)
    for line in lines:
        if line.startswith("#"):
            yield line
            continue
        _, a = attrs(line)
        if a.get("gene_biotype") in keep:
            yield line


def rule_2020a(lines):
    keep = set(BIOTYPES_2020A)
    modified = [strip_versions(l) if not l.startswith("#") else l for l in lines]
    allow = set()
    for line in modified:
        if line.startswith("#"):
            continue
        cols, a = attrs(line)
        if len(cols) < 9 or cols[2] != "transcript":
            continue
        if a.get("gene_type") not in keep or a.get("transcript_type") not in keep:
            continue
        if 'tag "readthrough_transcript"' in line or 'tag "PAR"' in line:
            continue
        allow.add(a["gene_id"])
    # 10x keeps header lines, then `grep -Ff gene_allowlist` on the modified GTF.
    # The allowlist lines are 'gene_id "ENSG..."', so a fixed-string match on that text.
    pats = {'gene_id "%s"' % g for g in allow}
    for line in modified:
        if line.startswith("#"):
            yield line
            continue
        m = re.search(r'gene_id "[^"]+"', line)
        if m and m.group(0) in pats:
            yield line


def rule_none(lines):
    yield from lines


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    rule, src, dst = sys.argv[1:]
    fn = {"mkgtf-3.0.0": rule_300, "gencode-2020-A": rule_2020a, "none": rule_none}[rule]
    with open_text(src) as fh:
        lines = fh.readlines()
    sha = hashlib.sha1()
    genes = set()
    with open(dst, "w", newline="") as out:
        for line in fn(lines):
            out.write(line)
            sha.update(line.encode())
            if not line.startswith("#"):
                m = re.search(r'gene_id "([^"]+)"', line)
                if m:
                    genes.add(m.group(1))
    print("rule=%s genes=%d sha1=%s out=%s" % (rule, len(genes), sha.hexdigest(), dst))


if __name__ == "__main__":
    main()
