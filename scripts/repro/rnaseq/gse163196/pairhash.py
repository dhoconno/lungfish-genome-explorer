"""Order-free fingerprint of the read pairs of one run, to test whether two accessions hold the same reads.

Usage: python3 -I pairhash.py <run> <R1.fastq.gz> <R2.fastq.gz> <pigz>

For every pair it takes md5(Read 1 sequence + TAB + Read 2 sequence) and adds the 128-bit digests
modulo 2**128. Names and qualities are left out, since the 2024 uploads carry Illumina names and
binned qualities (SRA Lite) and the 2020 uploads numbered names and full qualities, and the two
uploads list the pairs in a different order. Equal sums and equal pair counts mean the same
multiset of pairs, up to a chance collision of about 2**-128.
Prints: run, pairs, sum as 32 hex digits.
"""
import hashlib
import subprocess
import sys


def seqs(path, pigz):
    p = subprocess.Popen([pigz, "-dc", "-p", "1", path], stdout=subprocess.PIPE, bufsize=1 << 20)
    for i, line in enumerate(p.stdout):
        if i % 4 == 1:
            yield line.rstrip(b"\n")
    if p.wait() != 0:
        raise SystemExit(f"{path}: pigz failed")


def main():
    run, r1, r2, pigz = sys.argv[1:5]
    total, n, mod = 0, 0, 1 << 128
    for a, b in zip(seqs(r1, pigz), seqs(r2, pigz)):
        total = (total + int.from_bytes(hashlib.md5(a + b"\t" + b).digest(), "big")) % mod
        n += 1
    print(f"{run}\t{n}\t{total:032x}", flush=True)


if __name__ == "__main__":
    main()
