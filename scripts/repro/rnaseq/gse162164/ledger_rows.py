"""Check FASTQ files that are on disk but have no ledger row against ENA's md5 and add their rows.

Usage: python3 -I ledger_rows.py <data_root> <run> [<run> ...]

For each mate of each run, the md5 of studies/GSE162164/fastq/<file> must equal the md5 in
studies/GSE162164/manifest.tsv (ENA's filereport). A match appends one row to MANIFEST.tsv under
an exclusive flock, as stage.py does, with source_checksum_verified yes. A file that already has
a row is left alone. A mismatch is reported and nothing is written for it.
Written for SRR13142280 and SRR13142281, whose mate 2 failed the bulk downloader's md5 check three
times and was then fetched again whole, after the downloader had marked the runs failed.
"""
import datetime
import fcntl
import hashlib
import sys


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def main(root, runs):
    study = f"{root}/studies/GSE162164"
    want = {}
    with open(f"{study}/manifest.tsv") as fh:
        head = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            r = dict(zip(head, line.rstrip("\n").split("\t")))
            want[r["file"]] = r
    ledger = f"{root}/MANIFEST.tsv"
    with open(ledger, "a+") as lh:
        fcntl.flock(lh, fcntl.LOCK_EX)
        try:
            lh.seek(0)
            have = {line.split("\t", 1)[0] for line in lh}
            for run in runs:
                for mate in (1, 2):
                    name = f"{run}_{mate}.fastq.gz"
                    path = f"{study}/fastq/{name}"
                    if path in have:
                        print(name, "already in the ledger")
                        continue
                    got = md5(path)
                    if got != want[name]["md5"]:
                        print(name, "md5", got, "is not ENA's", want[name]["md5"])
                        continue
                    import os
                    size = os.path.getsize(path)
                    if str(size) != want[name]["bytes"]:
                        print(name, "size", size, "is not ENA's", want[name]["bytes"])
                        continue
                    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    lh.write("\t".join([path, want[name]["url"], str(size), "md5", got, "yes", now,
                                        "REPRO-C5"]) + "\n")
                    lh.flush()
                    print(name, "md5 equals ENA's, row added")
        finally:
            fcntl.flock(lh, fcntl.LOCK_UN)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
