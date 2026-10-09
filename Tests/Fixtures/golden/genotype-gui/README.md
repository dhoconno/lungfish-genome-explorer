# Genotype GUI export expected files

These files pin the genotype export of the Lungfish Genome Explorer (LGE) app at the byte level. The CLI genotype goldens under `Tests/Fixtures/golden/genotype` drive `lungfish-cli`, which never links LungfishGenotypeUI, and the GUI Excel export never runs the CLI. So nothing else sees the capture code in `GenotypeResultViewController` while Phase 2.3 of the architecture program extracts it into an export coordinator (review finding R6). Equal frozen captures imply equal workbooks, because the export service re-derives the snapshot from its captured inputs and refuses any difference, so the files stop at the capture and need no Python.

They were captured on main at 7505b9e13, before any move or extraction commit. The suite is `GenotypeExportCharacterizationTests` in `Tests/LungfishGenotypeUITests`, with the scenario builders in `GenotypeCharacterizationScenarios.swift` and the canonical encoder and the file store in `GenotypeCharacterizationSupport.swift`. Every test pins current behaviour, including behaviour the design review flagged as wrong. A fix shows up here as a reviewed diff, never as a silent change.

## What each file holds

Each scenario has two files.

| File | Value |
|---|---|
| `<scenario>.excel-capture.json` | The `GenotypeViewportExportSnapshot` that `captureExcelExportSnapshot()` returns, with its frozen Excel capture decoded. The capture carries both worksheets, the effective haplotype calls, the colours, the Export Metadata rows and the seven retained inputs (`result.json`, `annotations.json`, `capture-context.json`, `analysis.json`, `definition.json`, `all-projection.json`, `filtered-projection.json`), each decoded from base64 so a change reads as a plain diff |
| `<scenario>.viewport-snapshot.json` | The `GenotypeViewportExportSnapshot` that `testingCurrentExportSnapshot()` returns, the delimited CSV and TSV path that has had no production caller since 24fe49f05. Phase 2.3 moves it intact and pins it here, and Phase 4a restores an entry point or deletes it with its tests |

The Excel capture always runs first and the delimited one second, because the Excel capture settles pending search and filter state.

## The scenarios

Every scenario is built in code inside a real bundle folder nested like `<root>/Project/Analyses/run/<name>.lungfishgenotype`, so the project root is three levels up and holds no Haplotype Definitions folder. Nothing is loaded from `Tests/Fixtures`. Read counts stay under 1,000 and names are ASCII, so the locale cannot change a number or a sort.

| Scenario | Prefix | What it holds |
|---|---|---|
| Haplotyped MiSeq with a resolvable definition | `haplotyped-miseq` | Five animals and two loci. A definition snapshot in the bundle, so the live analysis is re-inferred from the calls. GenBank-style reference metadata with an allele field. A reviewable row catalog with one row that overlaps a native row and one catalog-only reference row in the production shape `reference:<locus>:<allele>`. A false positive on a positive cell, a false negative on an attested zero, a review on an absent cell, a duplicate review pair, cell, row and column comments, a row style and a cell text style. An identity-bound call override. Min reads 5 and min percent 10, AnimalD hidden, AnimalE outside the smart cohort and AnimalC moved first. The reference row `01_Mafa_A1_001_01` then holds a positive cell, a catalog zero and an unknown cell in the Filtered sheet at once |
| Genotype-only with manual haplotypes | `genotype-only-manual` | Three animals, no analysis and no metadata. Manual assignments for two animals at MHC-A and MHC-B, one label the validator rejects, one cell comment. Haplotype cell colouring, the manual band expanded, min percent 10 on sample-retained reads and a pending quick search for one animal |
| Haplotyped MiSeq without a resolvable definition | `literal-status-miseq` | Three animals and three loci with every call status (called homozygous, heterozygous, ambiguous with a two-group and a one-group token, no haplotype, too many haplotypes, unresolved second haplotype and not assayed). No definition anywhere, so the literal analysis survives and the definition is synthesized from it. The identity-bound override matrix (an exact identity, a stale identity, a nil identity, a dash, a question mark, a malformed timestamp and two overrides on one slot) plus one manual assignment that a haplotyped MiSeq result ignores |

## Canonical form

One encoder in `GenotypeCharacterizationSupport.swift` turns a captured value into bytes. Values that are not Codable are walked through Mirror, so a stored property added later shows up and fails the compare instead of being skipped. Codable values go through `JSONEncoder` with sorted keys. A URL becomes its path, a `Data` becomes decoded JSON when it parses and base64 otherwise, an `AnnotationColor` becomes `#RRGGBBAA` with 8-bit channels, a payload-free enum becomes its case name, and set elements and non-string dictionary keys are sorted by their canonical text. The output is `JSONSerialization` with sorted keys, pretty printing and unescaped slashes plus a trailing newline. Arrays keep production order, because order is behaviour.

## Masks

Every file starts with a `normalization` object that lists the three masks and how many times each one applied. A fourth mask is a reviewed diff.

| Token | Applies to | Guard before masking |
|---|---|---|
| `<ROOT>` | The test's own temp root in plain paths and file URLs, in the `/var` and the `/private/var` spelling | None, it is the fixture root |
| `<GENERATED_AT>` | The top-level `generatedAt` of the frozen Excel capture | Parses as ISO 8601 UTC to the second and lies inside the test's time window |
| `<SHA256>` | A `sourceRevision` digest of the frozen capture whose key names a captured input | Equals the SHA-256 of that input's raw bytes, which are decoded and compared in full |

Row and call ids are SHA-256 of identity text and stay unmasked, so they pin identity encoding.

## Running the compare

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --skip-update --filter 'LungfishGenotypeUITests\.GenotypeExportCharacterizationTests'
```

The compare never writes into the checkout, because an untracked file there ends a running gate. On a mismatch it writes the actual bytes to `$TMPDIR/lungfish-genotype-gui-<uuid>/<file>` and fails with that path and the first differing lines. A missing expected file fails with the capture command in the message.

## Updating a file deliberately

A pure-move or extraction commit never touches these files, and review rejects one that does. When a behaviour change is intended, follow these steps.

1. Run the compare and read the whole diff it prints, so you know every value that moved.
2. Capture with `LUNGFISH_CAPTURE_GENOTYPE_GUI_GOLDENS=1` in front of the same command. Capture builds each scenario twice from fresh temp roots and writes only when both builds agree byte for byte.
3. Review `git diff Tests/Fixtures/golden/genotype-gui` and check that only the intended values changed.
4. Commit the files with the code change, naming the scenarios that changed and why.
