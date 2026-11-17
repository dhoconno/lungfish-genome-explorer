#!/usr/bin/env python3
"""GX's comparer step for Phase 5.1-E: drop 10x's version pattern from LGE's ids, run compare.py, print the gate's bars.

    compare_gx.py SET SOLO_OUT WORK TENX_DIR [--star STAR]

SET is a 10x control set (pbmc_1k_v3, sc5p_v2_hs_PBMC_1k or hgmm_1k_v3). SOLO_OUT is the Solo.out folder that LGE's
STARsolo run returned. WORK is a scratch folder that already holds truth/SET/{filtered,raw}_feature_bc_matrix (10x's own
matrices, extracted from its tar files) and compare/. TENX_DIR holds 10x's SET_metrics_summary.csv and SET_molecule_info.h5.

BIO-SOLO-M4 (Q1, What binds 1): LGE keeps GENCODE's versioned gene ids (ENSG00000243485.5), and 10x's matrices name the
same genes without the version. Before any join, each of LGE's feature ids that matches 10x's own pattern
(tenx_gtf.py:50, anchored) becomes its first group, and every other id (_PAR_Y, hg19_, mm10_) stays as written. 10x's ids
are never changed. The strip is made in a derived copy under WORK/solo/SET/Solo.out and never in LGE's result: the matrix
and barcode files are links to the returned files. The step stops (exit 3) if two of LGE's ids become one. It prints
ids_version_stripped, genes_missing_from_ours (10x ids that LGE lacks) and genes_dropped_by_alignment (LGE ids that 10x
lacks), runs compare.py unchanged, and prints each bar of the GX gate (docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md,
the GX row) next to its figure as meets or misses. Which bars a set must meet, and what a miss means, is a ruling's.

A two-prefix set (hgmm_1k_v3, hg19 and mm10) also needs a per-genome cell call, which the plan's 15 files do not hold
(BIO-GXFH-GEC6 item 12). This step makes it as 5.0's stage_pergenome does (run.sh:204-212), from LGE's returned Gene/raw:
compare.py split-genomes with the prefixes hg19 and mm10, then STAR --runMode soloCellFiltering on each half with
--soloCellFilter EmptyDrops_CR 1000 0.99 10 45000 90000 500 0.01 20000 0.01 10000 (1,000 expected cells a genome), run in the
output folder WORK/solo/SET/pergenome/STARsolo_Gene_PREFIX. The STAR is the one beside this interpreter, which is the 5.0 Mac
environment's (env/bin/python and env/bin/STAR, scripts/repro/rnaseq/env/README.md), or the one --star names. It must report
2.7.11b, and the step stops (exit 5) before it writes anything if it does not. LGE itself makes no per-genome call: these calls
are the comparison's, made on the Mac, and the four species-mix bars (UMI purity, GEM class agreement, per-genome cells,
multiplet fraction) read them. The step stops (exit 2) if WORK/solo/SET/pergenome exists already, and (exit 5) if the split or
a STAR call fails. A one-prefix set has no per-genome step and no species-mix bars, and its output is as before.

Run with python -I. Writes only under WORK.
"""
import gzip
import hashlib
import os
import re
import subprocess
import sys

VERSION_ID = re.compile(rb"^(ENS(?:MUS)?[GTE][0-9]+)\.([0-9]+)$")
FEATURES = ("Gene", "GeneFull_Ex50pAS", "GeneFull")
HERE = os.path.dirname(os.path.abspath(__file__))
# 5.0's per-genome call (tenx-controls/run.sh:204-212): STARsolo's EmptyDrops_CR on each genome's raw matrix, 1,000 expected cells.
TWO_PREFIX_SETS = {"hgmm_1k_v3": ("hg19", "mm10")}
STAR_VERSION = "2.7.11b"
CELL_FILTER = ["--soloCellFilter", "EmptyDrops_CR", "1000", "0.99", "10", "45000", "90000", "500", "0.01", "20000", "0.01", "10000"]
INTRONS_GATED_SETS = {"SC3pv3_GEX_Human_PBMC"}  # repro:86 gates the introns preset on the Cell Ranger 7.0.1 set only (BIO-GXFH-GEC6 item 8)
STAR_HINT = "run it with the 5.0 environment's python, which has STAR beside it, or name a STAR %s with --star PATH" % STAR_VERSION


class StepError(Exception):
    """A step of the comparer failed; main reports it and exits 5."""


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 22), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strip_features(src, dst):
    """Write src's features.tsv to dst with each id that matches the pattern cut to its first group."""
    data = open(src, "rb").read()
    out, before, after, changed = [], [], [], 0
    for line in data.split(b"\n"):
        if line == b"":
            out.append(line)
            continue
        head, sep, rest = line.partition(b"\t")
        match = VERSION_ID.match(head)
        new = match.group(1) if match else head
        changed += 1 if match else 0
        before.append(head)
        after.append(new)
        out.append(new + sep + rest)
    with open(dst, "wb") as handle:
        handle.write(b"\n".join(out))
    return {"features": len(before), "stripped": changed, "distinct_before": len(set(before)),
            "distinct_after": len(set(after)), "ids": {name.decode() for name in after}}


def derive(solo_out, dest):
    stats = {}
    for feature in FEATURES:
        for part in ("raw", "filtered"):
            src = os.path.join(solo_out, feature, part)
            if not os.path.isdir(src):
                continue
            dst = os.path.join(dest, feature, part)
            os.makedirs(dst)
            stats[(feature, part)] = strip_features(os.path.join(src, "features.tsv"), os.path.join(dst, "features.tsv"))
            for name in ("barcodes.tsv", "matrix.mtx"):
                os.symlink(os.path.abspath(os.path.join(src, name)), os.path.join(dst, name))
        summary = os.path.join(solo_out, feature, "Summary.csv")
        if os.path.isfile(summary):
            os.symlink(os.path.abspath(summary), os.path.join(dest, feature, "Summary.csv"))
    return stats


def tenx_gene_ids(truth):
    folder = os.path.join(truth, "filtered_feature_bc_matrix")
    path = os.path.join(folder, "features.tsv.gz")
    opener = gzip.open if os.path.exists(path) else open
    if not os.path.exists(path):
        path = os.path.join(folder, "features.tsv")
    ids = set()
    with opener(path, "rt") as handle:
        for line in handle:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3 or cols[2] == "Gene Expression":
                ids.add(cols[0])
    return ids


BARS = [
    ("cell Jaccard", "jaccard", "min", 0.97),
    ("share of 10x cells called", "share_of_10x_cells_called", "min", 0.98),
    ("per-cell UMI r (log1p, shared cells)", "cell_umi_pearson_log1p_shared", "min", 0.995),
    ("per-gene r (log1p, genes with 10 or more in either)", "gene_total_pearson_log1p_ge10", "min", 0.995),
    ("genes beyond 2-fold (10 or more in either)", "gene_share_beyond_2fold_ge10", "max", 0.005),
    ("median UMI per cell, within 1%", "median_umi_per_cell", "ratio", 0.01),
    ("median genes per cell, within 1%", "median_genes_per_cell", "ratio", 0.01),
    ("valid barcodes, within 1 point", "summary:Reads With Valid Barcodes", "diff", 0.01),
    ("sequencing saturation, within 1 point", "summary:Sequencing Saturation", "diff", 0.01),
    ("reads in cells, within 1 point", "summary:Fraction of Unique Reads in Cells", "diff", 0.01),
    ("total genes detected, within 1%", "total_genes_detected", "ratio", 0.01),
]
ALSO = ["cells_called", "cells_shared", "share_of_our_cells_in_10x", "genes_missing_from_ours", "cell_umi_pearson_log1p_all10x",
        "cell_umi_median_ratio_shared", "gene_total_pearson_log1p", "gene_total_pearson_log1p_ge10", "gene_total_median_log2_ratio_ge10",
        "matrix_total_ratio_shared", "median_genes_per_cell_10x_matrix", "summary:Reads Mapped to Genome: Unique", "summary:Number of Reads"]


def read_rows(text):
    rows = {}
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) >= 4:
            rows.setdefault(cols[0], {})[cols[1]] = (cols[2], cols[3], cols[4] if len(cols) > 4 else "")
    return rows


def number(text):
    try:
        return float(text)
    except ValueError:
        return float("nan")


# The four species-mix bars of ADJ-SC (tenx Q2, additions 2) on five rows, from the per-genome calls of pergenome_step. They are
# read on the rows of the label STARsolo_Gene:pergenome. 10x's column is its own summary value; for a statistic that has no 10x
# value the bar is a number or a range.
SPECIES_BARS = [
    ("species: UMI purity (Cell Ranger's rule), 0.005", "cr_umi_purity", "diff", 0.005),
    ("species: GEM class agreement, shared barcodes", "gem_class_agreement_shared", "min", 0.99),
    ("species: hg19 cells, within 5%", "hg19_cells", "ratio", 0.05),
    ("species: mm10 cells, within 5%", "mm10_cells", "ratio", 0.05),
    ("species: GEMs with more than one cell, 10x's bounds", "fraction_gems_gt1_cell", "range", (0.0, 0.006)),
]
SPECIES_ALSO = ["cells_union", "observed_cross_species_multiplets", "inferred_gems_gt1_cell"]


def bars_table(label, rows, bars=None, also=None, gated=True):
    bars = BARS if bars is None else bars
    also = ALSO if also is None else also
    print("  %-52s %-42s %14s %14s %12s  %-12s %s" % ("bar", "comparer row", "LGE", "10x", "statistic", "bar", "figure"))
    for name, measure, kind, bar in bars:
        if measure not in rows.get(label, {}):
            print("  %-52s %-42s no row" % (name, measure))
            continue
        ours, tenx, _note = rows[label][measure]
        a, b = number(ours), number(tenx)
        if kind == "min":
            stat, text, ok = a, ">= %g" % bar, a >= bar
        elif kind == "max":
            stat, text, ok = a, "<= %g" % bar, a <= bar
        elif kind == "ratio":
            stat, text, ok = a / b - 1, "|ratio-1| <= %g" % bar, abs(a / b - 1) <= bar
        elif kind == "range":
            stat, text, ok = a, "%g to %g" % bar, bar[0] <= a <= bar[1]
        else:
            stat, text, ok = a - b, "|diff| <= %g" % bar, abs(a - b) <= bar
        print("  %-52s %-42s %14s %14s %12.5f  %-16s %s" % (name, measure, ours, tenx, stat, text, ("meets" if ok else "MISSES") if gated else "not gated"))
    for measure in also:
        if measure in rows.get(label, {}):
            ours, tenx, note = rows[label][measure]
            print("  (also) %-45s %14s %14s   %s" % (measure, ours, tenx, note))


def check_star(star):
    """Return STAR's version when it is STAR_VERSION, the 5.0 environment's; raise StepError when STAR is missing or another."""
    try:
        done = subprocess.run([star, "--version"], capture_output=True, text=True)
    except OSError as error:
        raise StepError("STAR %s cannot be run: %s; %s" % (star, error, STAR_HINT))
    lines = done.stdout.strip().splitlines()
    version = lines[0].strip() if lines else ""
    if done.returncode != 0 or version != STAR_VERSION:
        raise StepError("STAR %s reports %r, and the 5.0 environment's is %s; %s"
                        % (star, version or done.stderr.strip()[:200], STAR_VERSION, STAR_HINT))
    return version


def run_logged(argv, cwd, log):
    """Run argv in cwd and keep its output in log, so a step's words stay beside its files."""
    done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    with open(log, "w") as handle:
        handle.write(done.stdout)
        handle.write(done.stderr)
    return done


def pergenome_step(solo_out, work, set_name, star, python=None):
    """5.0's stage_pergenome (run.sh:204-212) on LGE's returned Gene/raw. Returns {prefix: path of that genome's barcodes.tsv}.

    compare.py split-genomes makes WORK/solo/SET/pergenome/raw_PREFIX for each prefix, and STAR --runMode soloCellFiltering makes
    the genome's cells in WORK/solo/SET/pergenome/STARsolo_Gene_PREFIX, which compare.py reads. FileExistsError when the
    pergenome folder exists, since nothing is written over an earlier step. StepError when the split or a STAR call fails.
    """
    solo_out, work = os.path.abspath(solo_out), os.path.abspath(work)
    prefixes = TWO_PREFIX_SETS[set_name]
    base = os.path.join(work, "solo", set_name, "pergenome")
    os.makedirs(base)
    split = [python or sys.executable, "-I", os.path.join(HERE, "compare.py"), "split-genomes",
             os.path.join(solo_out, "Gene", "raw"), os.path.join(base, "raw")] + list(prefixes)
    done = run_logged(split, base, os.path.join(base, "split-genomes.out"))
    print("split-genomes exit %d: %s" % (done.returncode, done.stdout.strip().replace("\n", " | ")))
    if done.returncode != 0:
        raise StepError("compare.py split-genomes exit %d: %s" % (done.returncode, done.stderr.strip()[-500:]))
    calls = {}
    for prefix in prefixes:
        out = os.path.join(base, "STARsolo_Gene_" + prefix)
        os.makedirs(out)
        argv = [star, "--runMode", "soloCellFiltering", os.path.join(base, "raw_" + prefix) + "/", out + "/"] + CELL_FILTER
        done = run_logged(argv, out, os.path.join(base, "STARsolo_Gene_%s.out" % prefix))
        barcodes = os.path.join(out, "barcodes.tsv")
        if done.returncode != 0 or not os.path.isfile(barcodes):
            raise StepError("STAR soloCellFiltering for %s exit %d, barcodes.tsv %s: %s"
                            % (prefix, done.returncode, "written" if os.path.isfile(barcodes) else "absent", done.stderr.strip()[-500:]))
        with open(barcodes, "rb") as handle:
            cells = handle.read().count(b"\n")
        print("STAR soloCellFiltering %s exit 0, barcodes.tsv %d lines, sha256 %s" % (prefix, cells, sha256(barcodes)))
        calls[prefix] = barcodes
    return calls


def main(argv):
    star = os.path.join(os.path.dirname(sys.executable), "STAR")
    if len(argv) == 7 and argv[5] == "--star":
        star = argv[6]
        argv = argv[:5]
    if len(argv) != 5:
        print(__doc__)
        return 2
    set_name, solo_out, work, tenx_dir = argv[1:5]
    truth = os.path.join(work, "truth", set_name)
    dest = os.path.join(work, "solo", set_name, "Solo.out")
    pergenome = os.path.join(work, "solo", set_name, "pergenome")
    two_prefix = set_name in TWO_PREFIX_SETS
    print("compare_gx.py sha256 %s" % sha256(os.path.abspath(__file__)))
    print("compare.py sha256 %s" % sha256(os.path.join(HERE, "compare.py")))
    if os.path.exists(dest):
        print("STOP: %s exists already, nothing was written over it" % dest)
        return 2
    if two_prefix:
        if os.path.exists(pergenome):
            print("STOP: %s exists already, nothing was written over it" % pergenome)
            return 2
        try:
            print("STAR %s, version %s" % (star, check_star(star)))
        except StepError as error:
            print("STOP: %s. Nothing was written." % error)
            return 5
    stats = derive(solo_out, dest)
    theirs = tenx_gene_ids(truth)
    collided = False
    for (feature, part), st in sorted(stats.items()):
        ours = st["ids"]
        print("%s/%s: features %d, ids_version_stripped %d, distinct ids %d before and %d after, genes_missing_from_ours %d, "
              "genes_dropped_by_alignment %d (10x has %d gene ids)"
              % (feature, part, st["features"], st["stripped"], st["distinct_before"], st["distinct_after"],
                 len(theirs - ours), len(ours - theirs), len(theirs)))
        if st["distinct_after"] != st["distinct_before"]:
            collided = True
        if st["stripped"] == 0:
            same = sha256(os.path.join(solo_out, feature, part, "features.tsv")) == sha256(os.path.join(dest, feature, part, "features.tsv"))
            print("  no id changed; the derived features.tsv is byte-equal to the returned one: %s" % same)
    if collided:
        print("STOP: two of LGE's ids became one after the strip. The comparer was not run.")
        return 3
    if two_prefix:
        try:
            pergenome_step(solo_out, work, set_name, star)
        except StepError as error:
            print("STOP: %s. The comparer was not run; use a new WORK to run again." % error)
            return 5
    os.makedirs(os.path.join(work, "compare"), exist_ok=True)
    run = subprocess.run([sys.executable, "-I", os.path.join(HERE, "compare.py"), "compare", set_name, work, tenx_dir],
                         capture_output=True, text=True)
    with open(os.path.join(work, "compare", "%s.txt" % set_name), "w") as handle:
        handle.write(run.stdout)
    with open(os.path.join(work, "compare", "%s.err" % set_name), "w") as handle:
        handle.write(run.stderr)
    print("compare.py exit %d, %d rows" % (run.returncode, len(run.stdout.splitlines())))
    if run.returncode != 0:
        print(run.stderr[-1500:])
        return 4
    rows = read_rows(run.stdout)
    print("BARS of the GX gate for %s, exon-only preset (STARsolo_Gene):" % set_name)
    bars_table("STARsolo_Gene", rows)
    if "STARsolo_GeneFull_Ex50pAS" in rows:
        gated = set_name in INTRONS_GATED_SETS
        print("Same rows for STARsolo_GeneFull_Ex50pAS (the introns preset's agreement pins are gated on the Cell Ranger 7.0.1 set only%s):"
              % ("" if gated else "; this set's table gives no verdict (BIO-GXFH-GEC6 item 8)"))
        bars_table("STARsolo_GeneFull_Ex50pAS", rows, gated=gated)
    if two_prefix:
        print("BARS of the species mix for %s (STARsolo_Gene:pergenome, per-genome cells called by this step, as 5.0's stage_pergenome "
              "calls them, from LGE's returned Gene/raw):" % set_name)
        bars_table("STARsolo_Gene:pergenome", rows, SPECIES_BARS, SPECIES_ALSO)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
