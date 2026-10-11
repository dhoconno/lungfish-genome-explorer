# Classifier parity fixtures

`ClassifierCLIGUIParityReplayTests` runs Kraken2, Bracken and EsViritu through the GUI path and through the command the GUI records, then compares the two results. `ClassifierParityFixtures` in `Tests/Support/LungfishTestSupport` builds one project per side with four bundles. Three of them come from other fixture folders. This folder holds the fourth.

| Bundle in the project | Source | What it holds |
|---|---|---|
| `Imports/sarscov2-R1.lungfishfastq` and its derivative `len-150-any-00000000.lungfishfastq` | `Tests/Fixtures/sarscov2/test_1.fastq.gz` | The classifier golden's virtual subset. The root holds 100 reads, the subset the 55 reads of 150 bases or more, and the subset's preview the first 10 of them. It is built as `build_virtual_bundle` in `scripts/golden/captures.py` builds it |
| `Imports/merge.lungfishfastq` | `Tests/Fixtures/read-pairing/kraken2` | 77 merged reads and 23 unmerged pairs from BBMerge |
| `Imports/sarscov2-pair.lungfishfastq` | `Tests/Fixtures/sarscov2/test_1.fastq.gz` and `test_2.fastq.gz` | The 100 SARS-CoV-2 read pairs as a paired derivative, the shape that runs as a pair |
| `Imports/negative-control.lungfishfastq` | `negative-control.fastq` in this folder | 40 synthetic reads with no viral hit |

## The negative control

`negative-control.fastq` holds 40 reads of 150 bases drawn from a fixed 64-bit linear congruential generator, so its bytes do not depend on any random number library. No read matches the Kraken2 Viral database, so Kraken2 classifies none of them and Bracken finds no species to profile. The GUI then reads Completed with Warnings, which case K5 checks with the real tools.

It was made on 2026-10-11 with this script, run as `python3 make_negative_control.py negative-control.fastq`.

```python
import sys

state = 20261011


def next_base():
    global state
    state = (state * 6364136223846793005 + 1442695040888963407) % 2**64
    return "ACGT"[(state >> 33) % 4]


with open(sys.argv[1], "w") as out:
    for index in range(1, 41):
        sequence = "".join(next_base() for _ in range(150))
        out.write(f"@negative-control-{index:02d}\n{sequence}\n+\n{'I' * 150}\n")
```

The file's SHA-256 is `a4c0e2b5f5d6537baa573592fdea0fcdc41837911a1483538c8fecd73e0edf6a`.
