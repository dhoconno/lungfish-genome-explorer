"""LGE's not-host tables of GSE296788 against mtb.py's, gate GN (RS-NOTHOST, milestone 3).

LGE side: the result's cells.sqlite, schema 2 (docs/formats/rnaseq-bundle.md, Single cell): cells, not_host_extras,
not_host_records, not_host_barcodes, not_host_counts (record 0 is the extra's figure over its records),
not_host_calls, ambient_pools and ambient_pool_counts. GN side: compare/<GSM>.gn.tsv and compare/gn_summary.tsv,
which mtb.py wrote at FIX-GN with the Erdman rRNA mask.

First, for each library, the cells of cells.sqlite must equal solo/<GSM>/topcells/barcodes.tsv in set and count
(BIO-NOTHOST-BARCODE item 17), else no GN figure is printed. Then each barcode both sides hold is compared on
is_cell, raw UMIs, whether it is in the ambient pool, its default and masked UMIs over the genome and on each record,
and each cell on q (at mtb.py's printed %.3g) and flag (mtb.py writes 1 or 0 with a pool and the words without one).
mtb.py holds only barcodes with a UMI in the raw matrix, and LGE, as virus.py, every barcode of the raw list with a
not-host UMI, so a non-cell barcode LGE holds at 0 raw UMIs is counted apart and left out of the library's totals.
The pool's figures and the totals are compared with gn_summary.tsv, the rate at mtb.py's printed %.4g. The UMIs at nM 0 or 1 are
compared and reported apart, never gated (GN).

Usage (python3 -I): compare_lge_gn.py RESULT.lungfishrnaseq WORK
Prints one line a library and the total of unequal values, and exits 1 when any value is unequal.
"""
import csv
import math
import os
import sqlite3
import sys

SCAFFOLDS = ("KK339487.1", "KK339488.1")
FLAG = "bacterial RNA above ambient"
RRNA = "umi_on_mtb_rrna_genes_source_not_resolved"


def lge(db_path):
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    names = dict(con.execute("SELECT sample, name FROM samples"))
    records = {name: rid for rid, name in con.execute("SELECT record, name FROM not_host_records")}
    out = {n: {"barcodes": {}, "pool": None, "pool_counts": {}, "cells": set(), "cell_count": 0} for n in names.values()}
    for sid, n in con.execute("SELECT sample, cells FROM samples"):
        out[names[sid]]["cell_count"] = n
    for sid, bc in con.execute("SELECT sample, barcode FROM cells"):
        out[names[sid]]["cells"].add(bc)
    cell_bc = {}
    for sid, bc, cell, raw, in_pool in con.execute("SELECT sample, barcode, cell, raw_umis, in_pool FROM not_host_barcodes"):
        row = dict(is_cell=int(cell is not None), raw=raw, in_pool=in_pool, q="", flag="", nm01=0, rnm01=0,
                   genome=0, masked=0, **{"rec_%s" % s: 0 for s in SCAFFOLDS}, **{"rrec_%s" % s: 0 for s in SCAFFOLDS})
        out[names[sid]]["barcodes"][bc] = row
        if cell is not None:
            cell_bc[(sid, cell)] = bc
    by_id = {rid: name for name, rid in records.items()}
    for sid, bc, record, umis, masked, nm01, masked_nm01 in con.execute(
            "SELECT sample, barcode, record, umis, masked_umis, umis_nm01, masked_umis_nm01 FROM not_host_counts"):
        row = out[names[sid]]["barcodes"][bc]
        if record == 0:
            row.update(genome=umis, masked=masked, nm01=nm01, rnm01=masked_nm01)
        else:
            row["rec_" + by_id[record]] = umis
            row["rrec_" + by_id[record]] = masked
    for sid, cell, q, flag in con.execute("SELECT sample, cell, q, flag FROM not_host_calls"):
        row = out[names[sid]]["barcodes"][cell_bc[(sid, cell)]]
        row.update(q=("%.3g" % q) if q is not None else "", flag=flag)
    for sid, with_umi, pool_n, first, last, lo, hi, umis, words in con.execute("SELECT * FROM ambient_pools"):
        out[names[sid]]["pool"] = dict(with_umi=with_umi, pool_n=pool_n, ranks=("%d-%d" % (first, last)) if first else words,
                                       range=("%d-%d" % (lo, hi)) if lo is not None else "", umis=umis, words=words)
    for sid, record, umis, masked, rate in con.execute("SELECT sample, record, umis, masked_umis, rate FROM ambient_pool_counts"):
        out[names[sid]]["pool_counts"][record] = (umis, masked, rate)
    extras = list(con.execute("SELECT name, kind, mask, mask_words FROM not_host_extras"))
    return out, extras


def same_number(a, b):
    a, b = float(a), float(b)
    return (math.isnan(a) and math.isnan(b)) or a == b


def gn_flag(value):
    """mtb.py's flag column as LGE writes it: 1 is the words of the flag, 0 is empty, and no pool keeps its words."""
    return {"1": FLAG, "0": ""}.get(value, value)


def main(result, work):
    ours, extras = lge(os.path.join(result, "cells.sqlite"))
    compare = os.path.join(work, "compare")
    summary = {r["library"]: r for r in csv.DictReader(open(os.path.join(compare, "gn_summary.tsv")), delimiter="\t")}
    print("extras: " + "; ".join("%s (%s) mask %s, %s" % e for e in extras))
    for lib in sorted(ours):
        top = [l.rstrip("\n").split("\t")[0] for l in open(os.path.join(work, "solo", lib, "topcells", "barcodes.tsv"))]
        mine = ours[lib]
        if set(top) != mine["cells"] or len(top) != mine["cell_count"] or len(top) != len(mine["cells"]):
            print("%s: the cells differ from topcells/barcodes.tsv (%d topcells, %d cells), no GN figure" % (
                lib, len(top), mine["cell_count"]))
            return 1
        print("%s: cells equal topcells/barcodes.tsv in set and count (%d)" % (lib, len(top)))
    total = flagged_all = 0
    print("library\tcompared\tLGE only at 0 raw UMIs\tunequal\tnM01 unequal (not gated)\tpool and totals\tflagged LGE/GN\tnM01 share LGE/GN")
    for lib in sorted(ours):
        mine, bad, near_bad = ours[lib], {}, 0
        gn = {r["barcode"]: r for r in csv.DictReader(open(os.path.join(compare, lib + ".gn.tsv")), delimiter="\t")}
        # mtb.py keeps only barcodes with a UMI in the raw matrix (raw_totals), where LGE, as virus.py, keeps every
        # barcode of the raw list. A non-cell barcode at 0 raw UMIs is in no pool and no cell, so it is counted apart.
        raw0 = {bc for bc in set(mine["barcodes"]) - set(gn)
                if mine["barcodes"][bc]["raw"] == 0 and not mine["barcodes"][bc]["is_cell"]}
        for bc in (set(gn) ^ set(mine["barcodes"])) - raw0:
            bad["barcode in one side only"] = bad.get("barcode in one side only", 0) + 1
        for bc in set(gn) & set(mine["barcodes"]):
            g, m = gn[bc], mine["barcodes"][bc]
            pairs = [("is_cell", g["is_cell"], m["is_cell"]), ("raw UMIs", g["total_umi"], m["raw"]),
                     ("in pool", g["in_ambient_pool"], m["in_pool"]), ("genome UMIs", g["mtb_umi"], m["genome"]),
                     ("masked UMIs", g[RRNA], m["masked"])]
            for s in SCAFFOLDS:
                pairs += [("UMIs on " + s, g["mtb_umi_" + s], m["rec_" + s]), ("masked on " + s, g[RRNA + "_" + s], m["rrec_" + s])]
            if g["is_cell"] == "1":
                pairs += [("q", g["q_ambient"], m["q"]), ("flag", gn_flag(g[FLAG.replace(" ", "_")]), m["flag"])]
            for field, a, b in pairs:
                if str(a) != str(b):
                    bad[field] = bad.get(field, 0) + 1
            near_bad += (str(g["mtb_umi_nm01"]) != str(m["nm01"])) + (str(g[RRNA + "_nm01"]) != str(m["rnm01"]))
        s, p = summary[lib], mine["pool"]
        umis, masked, rate = mine["pool_counts"].get(0, (0, 0, None))
        rows = [m for bc, m in mine["barcodes"].items() if bc not in raw0]
        cells = [m for m in rows if m["is_cell"]]
        flagged = sum(m["flag"] == FLAG for m in cells)
        pool_pairs = [("cells", s["cells"], mine["cell_count"]), ("barcodes with a UMI", s["barcodes_with_umi"], p["with_umi"]),
                      ("ranks", s["ambient_ranks"], p["ranks"]), ("pool barcodes", s["ambient_barcodes"], p["pool_n"]),
                      ("pool UMI range", s["ambient_umi_range"], p["range"]), ("pool UMIs", s["ambient_umi"], p["umis"]),
                      ("pool genome UMIs", s["ambient_mtb_umi"], umis), ("pool masked UMIs", s["ambient_" + RRNA], masked),
                      ("genome UMIs", s["mtb_umi_all"], sum(r["genome"] for r in rows)),
                      ("masked UMIs", s[RRNA + "_all"], sum(r["masked"] for r in rows)),
                      ("cell genome UMIs", s["cell_mtb_umi"], sum(m["genome"] for m in cells)),
                      ("cell masked UMIs", s["cell_" + RRNA], sum(m["masked"] for m in cells)),
                      ("cells flagged", s["cells_flagged"], p["words"] or flagged)]
        for sc in SCAFFOLDS:
            pool_pairs += [("genome UMIs on " + sc, s["mtb_umi_all_" + sc], sum(r["rec_" + sc] for r in rows)),
                           ("masked UMIs on " + sc, s[RRNA + "_all_" + sc], sum(r["rrec_" + sc] for r in rows))]
        pool_bad = [f for f, a, b in pool_pairs if str(a) != str(b)]
        if not same_number(s["ambient_poisson_rate"], ("%.4g" % rate) if rate is not None else "nan"):
            pool_bad.append("rate")
        for f in pool_bad:
            bad["library " + f] = 1
        n = sum(bad.values())
        total += n
        flagged_all += flagged
        raw0_umis = sum(mine["barcodes"][bc]["genome"] + mine["barcodes"][bc]["masked"] for bc in raw0)
        share = lambda a, b: ("%.4g" % (a / b)) if b else "nan"
        print("%s\t%d\t%d (%d UMIs)\t%d%s\t%d\t%s\t%d/%s\t%s/%s" % (
            lib, len(set(gn) & set(mine["barcodes"])), len(raw0), raw0_umis, n, (" " + repr(bad)) if bad else "", near_bad,
            "equal" if not pool_bad else "UNEQUAL " + ", ".join(pool_bad), flagged, s["cells_flagged"],
            share(sum(r["nm01"] for r in rows), sum(r["genome"] for r in rows)), s["nm01_share_default_all"]))
    print("total unequal %d over %d libraries, %d cells flagged" % (total, len(ours), flagged_all))
    return 1 if total else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
