"""Add the ledger rows of GF's two truth tables, as gse162164/ledger_rows.py adds its rows.

Usage: python3 -I ledger_gf.py <data_root> <staged_by>

Gate GF's truth is the two exon count tables gf_truth.sh wrote on the 7 gate runs (plan gate GF,
rulings/ADJ-BULK-4.md:99): work/gse290671/gf/rsubread.exon.counts.tsv (Rsubread 2.20.0) and
work/gse290671/gf/subread.exon.txt (subread 2.1.1). The gate BAMs are deleted, so the tables are
kept by their sha256 in MANIFEST.tsv. Rows are appended under an exclusive flock, as stage.py does,
with checksum_type sha256, source_checksum_verified "derived" (made here, not fetched) and the
script that made them as the url. A table that already has a row is left alone. Nothing is
written unless gf/GF_DONE exists and gf/gf.txt reads "GF EQUAL: 7 of 7".
"""
import datetime
import fcntl
import hashlib
import os
import sys

TABLES = ("rsubread.exon.counts.tsv", "subread.exon.txt")
MADE_BY = "scripts/repro/rnaseq/gse290671/gf_truth.sh"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def main(root, staged_by):
    gf = f"{root}/work/gse290671/gf"
    with open(f"{gf}/gf.txt") as fh:
        equal = any(line.startswith("GF EQUAL: 7 of 7") for line in fh)
    if not os.path.exists(f"{gf}/GF_DONE") or not equal:
        print("GF is not done, or its two tables are not equal on the 7 runs: nothing written")
        return 1
    with open(f"{root}/MANIFEST.tsv", "a+") as lh:
        fcntl.flock(lh, fcntl.LOCK_EX)
        try:
            lh.seek(0)
            have = {line.split("\t", 1)[0] for line in lh}
            for name in TABLES:
                path = f"{gf}/{name}"
                if path in have:
                    print(name, "already in the ledger")
                    continue
                size, got = os.path.getsize(path), sha256(path)
                now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                lh.write("\t".join([path, MADE_BY, str(size), "sha256", got, "derived", now, staged_by]) + "\n")
                lh.flush()
                print(name, size, got, "row added")
        finally:
            fcntl.flock(lh, fcntl.LOCK_UN)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
