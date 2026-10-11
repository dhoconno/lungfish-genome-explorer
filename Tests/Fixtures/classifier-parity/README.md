# Classifier parity fixtures

`ClassifierCLIGUIParityReplayTests` runs Kraken2, Bracken and EsViritu through the GUI path and through the command the GUI records, then compares the two results. `ClassifierParityFixtures` in `Tests/Support/LungfishTestSupport` builds one project per side with five bundles. Three of them come from other fixture folders. This folder holds the other two.

| Bundle in the project | Source | What it holds |
|---|---|---|
| `Imports/sarscov2-R1.lungfishfastq` and its derivative `len-150-any-00000000.lungfishfastq` | `Tests/Fixtures/sarscov2/test_1.fastq.gz` | The classifier golden's virtual subset. The root holds 100 reads, the subset the 55 reads of 150 bases or more, and the subset's preview the first 10 of them. It is built as `build_virtual_bundle` in `scripts/golden/captures.py` builds it |
| `Imports/merge.lungfishfastq` | `Tests/Fixtures/read-pairing/kraken2` | 77 merged reads and 23 unmerged pairs from BBMerge |
| `Imports/sarscov2-pair.lungfishfastq` | `Tests/Fixtures/sarscov2/test_1.fastq.gz` and `test_2.fastq.gz` | The 100 SARS-CoV-2 read pairs as a paired derivative, the shape that runs as a pair |
| `Imports/negative-control.lungfishfastq` | `negative-control.fastq` in this folder | 40 synthetic reads with no viral hit |
| `Imports/low-signal-control.lungfishfastq` | `low-signal-control.fastq` in this folder | The 40 reads of the negative control and five SARS-CoV-2 reads |

## The negative control

`negative-control.fastq` holds 40 reads of 150 bases drawn from a fixed 64-bit linear congruential generator, so its bytes do not depend on any random number library. No read matches the Kraken2 Viral database, so Kraken2 classifies none of them and its report holds only the unclassified line. Lane BR's parser fix reads that report, so the Bracken preflight finds no species row and degrades the profile with the reason `rankAbsentFromReport` before Bracken runs. Lane A8 pins case K5 to that outcome on both routes. The GUI row reads Completed with Warnings with one warning line, and the replayed command exits 0 with a `completed` record.

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

## The low-signal control

`low-signal-control.fastq` holds the 40 reads of the negative control, then five reads of `Tests/Fixtures/sarscov2/test_1.fastq.gz` that Kraken2 classifies under Betacoronavirus pandemicum (taxid 3418604) in case K1. The five reads, in file order, are `ERR5069949.2151832`, `ERR5069949.2417063`, `ERR5069949.376959`, `ERR5069949.2953930` and `ERR5069949.2185111`. Kraken2 classifies those five, so the species row holds five reads and the Bracken preflight passes. The wizard's Bracken threshold is ten reads, so Bracken runs and its `est_abundance.py` prints `Error: no reads found. Please check your Kraken report` and exits 1. The `bracken` driver runs under `set -eu`, so it exits 1 too, and the pipeline degrades the profile with the reason `toolFailed`. Case K6 pins that outcome on both routes (F2 bioinformatics ruling 1, corrected in lane A8c).

Lane A8 made it on 2026-10-11. The file is the 40 reads of `negative-control.fastq` followed by the five named reads, copied unchanged from `Tests/Fixtures/sarscov2/test_1.fastq.gz`. The file's SHA-256 is `92c50c757ee3c75db312e4447a1038a09631840ad3e9dd334d468ba30c7cebea`.
