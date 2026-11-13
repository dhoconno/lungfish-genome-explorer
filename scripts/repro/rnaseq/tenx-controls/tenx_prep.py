#!/usr/bin/env python3
"""Small preparation steps for the 10x control lane.

whitelist MOLECULE_INFO.h5 OUT.txt
    Write the barcode list that Cell Ranger stored in molecule_info.h5. Cell
    Ranger 3 and later store the whole chemistry barcode list there
    (6,794,880 barcodes for 3' v3, 737,280 for 5' v2), and the barcode index
    of every molecule points into it. The list name is in the file's metrics.

combine-gtf PREFIX IN.gtf[.gz] OUT.gtf
    Append one genome's GTF to OUT with the contig, gene_id, gene_name and
    transcript_id prefixed by PREFIX and an underscore, the way
    `cellranger mkref` names a multi-genome reference (hg19_ENSG..., mm10_...).

combine-fasta PREFIX IN.fa[.gz] OUT.fa
    Append one genome's FASTA to OUT with each name cut at the first space
    and prefixed the same way.
"""
import gzip
import re
import sys


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def whitelist(h5, out):
    import h5py
    import json
    with h5py.File(h5, "r") as f:
        bcs = f["barcodes"][()]
        name = None
        if "metrics_json" in f:
            name = json.loads(f["metrics_json"][()]).get("chemistry_barcode_whitelist")
        else:
            raw = f["metrics"].attrs.get("chemistry_barcode_whitelist")
            if raw is not None:
                name = raw.decode() if isinstance(raw, bytes) else str(raw)
                name = name.split("\n")[0].lstrip("V")
    seqs = [b.decode() for b in bcs]
    # Cell Ranger 5 stores 'AAAC...-1'-free 16-mers in a wider string field; keep the 16 bases.
    seqs = [s.split("-")[0] for s in seqs]
    with open(out, "w") as fh:
        for s in seqs:
            fh.write(s + "\n")
    print("whitelist=%s n=%d unique=%d lengths=%s out=%s"
          % (name, len(seqs), len(set(seqs)), sorted({len(s) for s in seqs}), out))


def combine_gtf(prefix, src, dst):
    p = prefix + "_"
    n = 0
    with open_text(src) as fh, open(dst, "a") as out:
        for line in fh:
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            cols[0] = p + cols[0]
            cols[8] = re.sub(r'(gene_id|gene_name|transcript_id) "([^"]+)"',
                             lambda m: '%s "%s%s"' % (m.group(1), p, m.group(2)), cols[8])
            out.write("\t".join(cols) + "\n")
            n += 1
    print("combine-gtf prefix=%s lines=%d" % (prefix, n))


def combine_fasta(prefix, src, dst):
    p = prefix + "_"
    n = 0
    with open_text(src) as fh, open(dst, "a") as out:
        for line in fh:
            if line.startswith(">"):
                out.write(">" + p + line[1:].split()[0] + "\n")
                n += 1
            else:
                out.write(line)
    print("combine-fasta prefix=%s contigs=%d" % (prefix, n))


def check_genes(features, gtf):
    """Compare 10x's gene ids and names with the gene lines of a rebuilt GTF."""
    with gzip.open(features, "rt") as fh:
        rows = [l.rstrip("\n").split("\t") for l in fh]
    dep = {r[0]: r[1] for r in rows if r[2] == "Gene Expression"}
    built = {}
    with open(gtf) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            c = line.split("\t")
            if c[2] != "gene":
                continue
            a = dict(re.findall(r'(\S+) "([^"]*)"', c[8]))
            built[a["gene_id"]] = a.get("gene_name", a["gene_id"])
    same = sum(1 for k, v in dep.items() if built.get(k) == v)
    print("deposit=%d built=%d only_deposit=%d only_built=%d same_name=%d"
          % (len(dep), len(built), len(set(dep) - set(built)), len(set(built) - set(dep)), same))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "check-genes" and len(sys.argv) == 4:
        check_genes(sys.argv[2], sys.argv[3])
    elif cmd == "whitelist" and len(sys.argv) == 4:
        whitelist(sys.argv[2], sys.argv[3])
    elif cmd == "combine-gtf" and len(sys.argv) == 5:
        combine_gtf(*sys.argv[2:])
    elif cmd == "combine-fasta" and len(sys.argv) == 5:
        combine_fasta(*sys.argv[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
