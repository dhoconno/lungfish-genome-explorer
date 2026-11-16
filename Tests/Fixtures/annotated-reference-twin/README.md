# annotated-reference-twin

One annotated reference bundle for the W-32 twin in `Tests/LungfishXCUITests/WalkTwinsXCUITests.swift`. The twin copies `TwinWhole.lungfishref` into its project twice, as `TwinWhole` and as `TwinCut`, gives the second copy its own manifest name and identifier, and cuts that copy's sequence file after the index so that the last gene lies past the cut.

The bundle holds the 6,000 base sequence `chrT` and four genes on it. They are GENEA at 201 to 600, GENEB at 1001 to 1400, GENEC at 1801 to 2200 and HBB at 4801 to 5200, all on the plus strand. It keeps only the files the app reads, which are `manifest.json`, `genome/sequence.fa`, `genome/sequence.fa.fai` and `annotations/genes.db`.

## Why a fixture

The packaged `lungfish-cli bundle create` wrote no annotation database when the twin ran it inside the gate's UI runner, so the annotation table listed no rows and the twin stopped before it reached W-32 (TWIN-W32-b). Run from a shell, the same CLI writes `annotations/genes.db`. The fixture holds a bundle that a shell built, so no tool runs in the runner.

## How it was built

`make_inputs.py` writes `reference.fa` and `genes.gff3` with the generator of `referenceBases` in the twin. The twin checks that the fixture's `genome/sequence.fa` holds the same bases as that generator.

```sh
python3 make_inputs.py <inputs folder>
mkdir <empty output folder>
lungfish-cli bundle create --fasta <inputs folder>/reference.fa --annotation <inputs folder>/genes.gff3 \
  --name TwinWhole --output-dir <empty output folder>
```

The `lungfish-cli` was the one inside Lungfish Preview 2026.11.9 (commit 9182fb867). The CLI said "Native tools available. Using samtools, bgzip" and wrote `TwinWhole.lungfishref`. Everything in it but the four files above was left out.
