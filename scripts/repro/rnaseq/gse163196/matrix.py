"""Gather the per-run outputs of sample.sh into gene by sample tables, plus one table of run figures.

Usage: python3 -I matrix.py <samples.tsv> <runs_dir> <genes.gtf> <out_dir> <deposited_dir>

Writes to out_dir:
  reads.tsv      read counts (featureCounts on the STAR BAM, unique alignments)        route R
  ours_P.tsv     UMI counts, umi_tools count --per-gene --method directional         route P (paper)
  ours_L.tsv     read counts after umi_tools dedup --method directional (positions)  route L (plan)
  deposited.tsv  the 24 deposited 2024 files (12 PBL, 12 CSF), by Ensembl gene id
  deposited_2020.tsv  the 13 deposited 2020 PBL files, by symbol
  genes.tsv      gene id, symbol, biotype of Ensembl 100
  runs.tsv       per run: reads in, reads with the motif, unique alignments, assigned reads, UMIs
Columns are sample names (B26, C95, ...). A 2020 run that was not aligned takes the counts of the
2024 run with the same reads (same_counts_as in samples.tsv), which pairhash.py shows to be equal.
"""
import csv
import glob
import gzip
import os
import re
import sys


def gtf_genes(path):
    genes = {}
    with open(path) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.split("\t", 9)
            if len(f) < 9 or f[2] != "gene":
                continue
            gid = re.search(r'gene_id "([^"]+)"', f[8]).group(1)
            nm = re.search(r'gene_name "([^"]+)"', f[8])
            bt = re.search(r'gene_biotype "([^"]+)"', f[8])
            genes[gid] = (nm.group(1) if nm else gid, bt.group(1) if bt else "NA")
    return genes


def read_fc(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("Geneid"):
                continue
            f = line.rstrip("\n").split("\t")
            out[f[0]] = int(f[-1])
    return out


def read_umi(path):
    out = {}
    with gzip.open(path, "rt") as fh:
        next(fh)
        for line in fh:
            g, c = line.rstrip("\n").split("\t")[:2]
            out[g] = int(c)
    return out


def log_value(path, pattern):
    if not os.path.exists(path):
        return "NA"
    with open(path) as fh:
        for line in fh:
            m = re.search(pattern, line)
            if m:
                return m.group(1).strip()
    return "NA"


def fc_assigned(path):
    if not os.path.exists(path):
        return "NA"
    with open(path) as fh:
        for line in fh:
            if line.startswith("Assigned"):
                return line.split("\t")[1].strip()
    return "NA"


def write_table(path, genes, cols, data):
    with open(path, "w") as fh:
        fh.write("gene_id\t" + "\t".join(cols) + "\n")
        for g in genes:
            fh.write(g + "\t" + "\t".join(str(data[c].get(g, 0)) for c in cols) + "\n")


def main():
    samples_path, runs, gtf, out = sys.argv[1:5]
    os.makedirs(out, exist_ok=True)
    with open(samples_path) as fh:
        samples = list(csv.DictReader(fh, delimiter="\t"))
    genes = gtf_genes(gtf)
    with open(f"{out}/genes.tsv", "w") as fh:
        fh.write("gene_id\tsymbol\tbiotype\n")
        for g, (n, b) in genes.items():
            fh.write(f"{g}\t{n}\t{b}\n")
    tables = {"reads": {}, "ours_P": {}, "ours_L": {}}
    cols = []
    stats = []
    for s in samples:
        run = s["run"]
        src = run if os.path.exists(f"{runs}/{run}/dedup.done") else s["same_counts_as"]
        d = f"{runs}/{src}"
        if src == "NA" or not os.path.exists(f"{d}/dedup.done"):
            continue
        name = s["sample"]
        cols.append(name)
        tables["reads"][name] = read_fc(f"{d}/fc_reads.txt")
        tables["ours_P"][name] = read_umi(f"{d}/umi_count.tsv.gz")
        tables["ours_L"][name] = read_fc(f"{d}/fc_dedup.txt")
        stats.append([name, run, src,
                      log_value(f"{d}/extract.log", r"Input Reads: (\d+)"),
                      log_value(f"{d}/extract.log", r"Reads output: (\d+)"),
                      log_value(f"{d}/Log.final.out", r"Uniquely mapped reads number \|\s*(\d+)"),
                      log_value(f"{d}/Log.final.out", r"Uniquely mapped reads % \|\s*([\d.]+%)"),
                      fc_assigned(f"{d}/fc_reads.txt.summary"),
                      sum(tables["ours_P"][name].values()),
                      sum(tables["ours_L"][name].values()),
                      log_value(f"{d}/dedup.log", r"Number of reads out: (\d+)")])
    for key, data in tables.items():
        write_table(f"{out}/{key}.tsv", list(genes), cols, data)
    with open(f"{out}/runs.tsv", "w") as fh:
        fh.write("sample\trun\taligned_run\tpairs_in\tpairs_with_motif\tunique\tunique_pct\tassigned_reads"
                 "\tumi_P\tdedup_assigned_L\tdedup_reads_out_L\n")
        for row in stats:
            fh.write("\t".join(map(str, row)) + "\n")
    # deposits
    dep_dir = sys.argv[5]
    dep24, dep20 = {}, {}
    for f in sorted(glob.glob(f"{dep_dir}/*/GSM*-B.txt.gz")):
        name = re.search(r"_([BC]\d+)-B\.txt\.gz$", f).group(1)
        with gzip.open(f, "rt") as fh:
            next(fh)
            vals = {}
            for line in fh:
                if not line.strip():  # the 2020 files end with one empty line
                    continue
                g, c = line.rstrip("\n").split("\t")
                if g in vals:
                    raise SystemExit(f"{f}: gene {g} listed twice")
                m = re.match(r"^(.*)\((ENSG\d+)\)$", g)
                vals[m.group(2) if m else g] = int(float(c))
        (dep24 if os.path.basename(f).startswith("GSM8") else dep20)[name] = vals
    ids24 = sorted({g for v in dep24.values() for g in v})
    write_table(f"{out}/deposited.tsv", ids24, list(dep24), dep24)
    ids20 = sorted({g for v in dep20.values() for g in v})
    write_table(f"{out}/deposited_2020.tsv", ids20, list(dep20), dep20)


if __name__ == "__main__":
    main()
