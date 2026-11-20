"""Add the ledger rows of CM-TRUTH's truth files, as gse290671/ledger_gf.py adds the rows of GF's tables.

Usage: python3 -I ledger.py <data_root> <truth_dir> <staged_by>

truth_dir holds SHA256SUMS, which truth.py writes last. Each file it lists is checked against its sum, then gets one row
in <data_root>/MANIFEST.tsv, appended under an exclusive flock as stage.py does, with checksum_type sha256,
source_checksum_verified "derived" (made here, not fetched) and the script that made it as the url. A file that already
has a row with the same sha256 is left alone. A file whose row holds another sha256 is a conflict and nothing at all is
written, since a changed truth file needs a person's decision and never a second row in silence.
"""
import datetime
import fcntl
import hashlib
import os
import sys

MADE_BY = "scripts/repro/rnaseq/sc-embed/truth/run.sh"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 22), b""):
            digest.update(block)
    return digest.hexdigest()


def add_rows(root, truth_dir, staged_by, now=None):
    """Returns (rows added, rows already there, conflicting paths). Raises ValueError for a file that differs from
    SHA256SUMS, before the ledger is opened."""
    with open(os.path.join(truth_dir, "SHA256SUMS")) as handle:
        listed = [line.rstrip("\n").split("  ", 1) for line in handle if line.strip()]
    files = []
    for digest, rel in listed:
        path = os.path.join(truth_dir, rel)
        got = sha256(path)
        if got != digest:
            raise ValueError(f"{rel} has sha256 {got}, and SHA256SUMS lists {digest}")
        files.append((path, digest))
    now = now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(os.path.join(root, "MANIFEST.tsv"), "a+") as ledger:
        fcntl.flock(ledger, fcntl.LOCK_EX)
        try:
            ledger.seek(0)
            have = {}
            for line in ledger:
                cells = line.rstrip("\n").split("\t")
                if len(cells) > 4:
                    have[cells[0]] = cells[4]
            conflicts = [path for path, digest in files if path in have and have[path] != digest]
            if conflicts:
                return 0, 0, conflicts
            added = present = 0
            for path, digest in files:
                if path in have:
                    present += 1
                    continue
                ledger.write("\t".join([path, MADE_BY, str(os.path.getsize(path)), "sha256", digest, "derived", now,
                                        staged_by]) + "\n")
                added += 1
            ledger.flush()
        finally:
            fcntl.flock(ledger, fcntl.LOCK_UN)
    return added, present, []


def main(argv):
    if len(argv) != 4:
        print("usage: ledger.py <data_root> <truth_dir> <staged_by>")
        return 2
    try:
        added, present, conflicts = add_rows(argv[1], argv[2], argv[3])
    except (ValueError, OSError) as error:
        print(f"ledger.py: {error}")
        return 1
    if conflicts:
        print("ledger.py: these files differ from their ledger rows, and nothing was written:")
        for path in conflicts:
            print("  " + path)
        return 1
    print(f"ledger: {added} rows added, {present} files already in the ledger")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
