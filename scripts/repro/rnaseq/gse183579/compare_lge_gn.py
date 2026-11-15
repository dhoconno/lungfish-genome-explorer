"""LGE's not-host tables of GSE183579 against virus.py's, gate GN (RS-NOTHOST).

LGE side: the result's cells.sqlite, schema 2 (docs/formats/rnaseq-bundle.md, Single cell): not_host_barcodes,
not_host_counts (record 0 is the extra's figure over its records), not_host_calls, ambient_pools and
ambient_pool_counts. GN side: virus/<GSM>.barcodes.tsv and virus/summary.tsv, which virus.py wrote.

Each barcode both sides hold is compared on is_cell, its raw UMIs, whether it is in the ambient pool, its genome
UMIs and its UMIs on NC_045512.2, and each cell on q (at virus.py's printed %.3g) and flag. virus.py also writes a
barcode outside the cells whose only viral count is in the gene matrix (viral_gene_umi above 0, genome 0). LGE counts
the BAM only, so it has no such row, and those rows are counted and not compared. The pool's figures are compared
with summary.tsv, the rate at virus.py's printed %.4g. The share of UMIs at nM 0 or 1 is reported, never gated (GN).

Usage (python3 -I): compare_lge_gn.py RESULT.lungfishrnaseq VIRUS_DIR
Prints one line a library and the total of unequal values, and exits 1 when any value is unequal.
"""
import csv
import os
import sqlite3
import sys

RECORD = "NC_045512.2"
FLAG = "viral RNA above ambient"


def lge(db_path):
    """{library: {"barcodes": {barcode: row}, "pool": row, "pool_counts": {record: (umis, rate)}, "nm": [...]}}"""
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    names = dict(con.execute("SELECT sample, name FROM samples"))
    records = {name: rid for rid, name in con.execute("SELECT record, name FROM not_host_records")}
    rec = records[RECORD]
    out = {name: {"barcodes": {}, "pool": None, "pool_counts": {}, "cells": 0} for name in names.values()}
    for sid, n in con.execute("SELECT sample, cells FROM samples"):
        out[names[sid]]["cells"] = n
    cell_bc = {}
    for sid, bc, cell, raw, in_pool in con.execute(
            "SELECT sample, barcode, cell, raw_umis, in_pool FROM not_host_barcodes"):
        out[names[sid]]["barcodes"][bc] = dict(is_cell=int(cell is not None), raw=raw, in_pool=in_pool, genome=0,
                                               record=0, masked=0, nm01=0, q="", flag="")
        if cell is not None:
            cell_bc[(sid, cell)] = bc
    for sid, bc, record, umis, masked, nm01, masked_nm01 in con.execute(
            "SELECT sample, barcode, record, umis, masked_umis, umis_nm01, masked_umis_nm01 FROM not_host_counts"):
        row = out[names[sid]]["barcodes"][bc]
        if record == 0:
            row.update(genome=umis, masked=masked, nm01=nm01 + masked_nm01)
        elif record == rec:
            row["record"] = umis
    for sid, cell, q, flag in con.execute("SELECT sample, cell, q, flag FROM not_host_calls"):
        row = out[names[sid]]["barcodes"][cell_bc[(sid, cell)]]
        row.update(q=("%.3g" % q) if q is not None else "", flag=flag)
    for sid, with_umi, pool_n, first, last, lo, hi, umis, words in con.execute("SELECT * FROM ambient_pools"):
        out[names[sid]]["pool"] = dict(with_umi=with_umi, pool_n=pool_n, ranks=("%d-%d" % (first, last)) if first else words,
                                       range=("%d-%d" % (lo, hi)) if lo is not None else "", umis=umis)
    for sid, record, umis, rate in con.execute("SELECT sample, record, umis, rate FROM ambient_pool_counts"):
        out[names[sid]]["pool_counts"][record] = (umis, rate)
    return out, rec


def main(result, virus):
    db = os.path.join(result, "cells.sqlite")
    ours, rec = lge(db)
    summary = {r["library"]: r for r in csv.DictReader(open(os.path.join(virus, "summary.tsv")), delimiter="\t")}
    total = 0
    flagged_all = 0
    print("library\tcompared\tgene_only\tunequal\tpool\tflagged LGE/GN\tnM01 share LGE/GN\tcell nM01 share LGE/GN")
    for lib in sorted(ours):
        mine = ours[lib]
        bad = {}
        gn = {}
        gene_only = 0
        for r in csv.DictReader(open(os.path.join(virus, lib + ".barcodes.tsv")), delimiter="\t"):
            if r["is_cell"] == "0" and r["viral_genome_umi"] == "0":
                gene_only += 1
                continue
            gn[r["barcode"]] = r
        for bc in set(gn) ^ set(mine["barcodes"]):
            bad["barcode in one side only"] = bad.get("barcode in one side only", 0) + 1
        for bc in set(gn) & set(mine["barcodes"]):
            g, m = gn[bc], mine["barcodes"][bc]
            pairs = [("is_cell", g["is_cell"], m["is_cell"]), ("raw UMIs", g["total_umi"], m["raw"]),
                     ("in pool", g["in_ambient_pool"], m["in_pool"]), ("genome UMIs", g["viral_genome_umi"], m["genome"]),
                     ("record UMIs", g["viral_umi_" + RECORD], m["record"]), ("masked UMIs", "0", m["masked"])]
            if g["is_cell"] == "1":
                pairs += [("q", g["q_ambient"], m["q"]), ("flag", g["flag"], m["flag"])]
            for field, a, b in pairs:
                if str(a) != str(b):
                    bad[field] = bad.get(field, 0) + 1
        s, p = summary[lib], mine["pool"]
        umis, rate = mine["pool_counts"].get(0, (0, None))
        cells = [m for m in mine["barcodes"].values() if m["is_cell"]]
        flagged = sum(m["flag"] == FLAG for m in cells)
        pool_pairs = [("cells", s["cells"], mine["cells"]), ("barcodes with a UMI", s["barcodes_with_umi"], p["with_umi"]),
                      ("ranks", s["ambient_ranks"], p["ranks"]), ("pool barcodes", s["ambient_barcodes"], p["pool_n"]),
                      ("pool UMI range", s["ambient_umi_range"], p["range"]), ("pool UMIs", s["ambient_umi"], p["umis"]),
                      ("pool genome UMIs", s["ambient_viral_genome_umi"], umis),
                      ("pool record UMIs", s["ambient_viral_umi_" + RECORD], mine["pool_counts"].get(rec, (0, None))[0]),
                      ("rate", s["ambient_poisson_rate"], ("%.4g" % rate) if rate is not None else "nan"),
                      ("cell genome UMIs", s["cell_viral_genome_umi"], sum(m["genome"] for m in cells)),
                      ("cells above ambient", s["cells_above_ambient"], flagged)]
        pool_bad = [f for f, a, b in pool_pairs if str(a) != str(b)]
        for f in pool_bad:
            bad["pool " + f] = 1
        n = sum(bad.values())
        total += n
        flagged_all += flagged
        rows = list(mine["barcodes"].values())
        share = lambda rs: ("%.4g" % (sum(r["nm01"] for r in rs) / sum(r["genome"] + r["masked"] for r in rs))
                            if sum(r["genome"] + r["masked"] for r in rs) else "nan")
        print("%s\t%d\t%d\t%d%s\t%s\t%d/%s\t%s/%s\t%s/%s" % (
            lib, len(set(gn) & set(mine["barcodes"])), gene_only, n, (" " + repr(bad)) if bad else "",
            "equal" if not pool_bad else "UNEQUAL " + ", ".join(pool_bad), flagged, s["cells_above_ambient"],
            share(rows), s["umi_nm01_share"], share(cells), s["cell_umi_nm01_share"]))
    print("total unequal %d over %d libraries, %d cells flagged" % (total, len(ours), flagged_all))
    return 1 if total else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
