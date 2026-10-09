# Genotype GUI export expected files

These files pin the genotype export of the Lungfish Genome Explorer (LGE) app at the byte level. The CLI genotype goldens under `Tests/Fixtures/golden/genotype` drive `lungfish-cli`, which never links LungfishGenotypeUI, and the GUI Excel export never runs the CLI. So nothing else sees the capture code in `GenotypeResultViewController` while Phase 2.3 of the architecture program extracts it into an export coordinator (review finding R6). Equal frozen captures imply equal workbooks, because the export service re-derives the snapshot from its captured inputs and refuses any difference, so the files stop at the capture and need no Python.

They were captured on code whose export behaviour equals main at 7505b9e13, before any move or extraction commit. The suite is `GenotypeExportCharacterizationTests` in `Tests/LungfishGenotypeUITests`, with the scenario builders in `GenotypeCharacterizationScenarios.swift` and the canonical encoder and the file store in `GenotypeCharacterizationSupport.swift`. Every test pins current behaviour, including behaviour the design review flagged as wrong. A fix shows up here as a reviewed diff, never as a silent change.

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
| Haplotyped MiSeq with a resolvable definition | `haplotyped-miseq` | Five animals and two loci. A definition snapshot in the bundle, so the live analysis is re-inferred from the calls. GenBank-style reference metadata with an allele field. A reviewable row catalog with one row that overlaps a native row, one catalog-only reference row in the production shape `reference:<locus>:<allele>`, one production-shape row that names the allele of `01_Mafa_A1_001_01` in a spelling the native matrix does not carry (today a second All row for the same allele, plan finding S1), and one catalog-only animal, AnimalF, that is in no call and no sample, so the All sheet extends its columns and remaps colours and styles for it. A false positive on a positive cell, a false negative on an attested zero, a review on an absent cell, a duplicate review pair, cell, row and column comments, a row style and a cell text style. An identity-bound call override. Min reads 5 and min percent 10, AnimalD hidden, AnimalE outside the smart cohort and AnimalC moved first. The reference row `01_Mafa_A1_001_01` then holds a positive cell, a catalog zero and an unknown cell in the Filtered sheet at once |
| Genotype-only with manual haplotypes | `genotype-only-manual` | Three animals, no analysis and no metadata. Manual assignments for two animals at MHC-A and MHC-B, one label the validator rejects, one cell comment. The haplotype cell colour mode with no analysis, so only its no-evidence path is pinned here, the manual band expanded, min percent 10 on sample-retained reads and a pending quick search for one animal |
| Haplotyped MiSeq without a resolvable definition | `literal-status-miseq` | Three animals and three loci with every call status (called homozygous, heterozygous, ambiguous with a two-group and a one-group token, no haplotype, too many haplotypes, unresolved second haplotype and not assayed). No definition anywhere, so the literal analysis survives and the definition is synthesized from it. The identity-bound override matrix (an exact identity, a stale identity, a nil identity, a dash, a question mark, a malformed timestamp, two overrides on one slot, a nil identity that beats a newer stale one on AnimalC MHC-DRB H1, and two exact overrides on AnimalA MHC-B H2 where the later one wins although it is listed first) plus one manual assignment that a haplotyped MiSeq result ignores |
| Haplotyped MiSeq with the global percent, prevalence and a locus order | `haplotyped-miseq-thresholds` | The data of the first scenario with its four-animal catalog, and three more viewport inputs. The global percent is 7.5 with Hide Low Support off, so the capture's global filter stays 0.0 while the filter context records 7.5. Prevalence is 40, which drops `02_Mafa_A1_002_01` (one of five animals) and keeps `04_Mafa_B_082_01` at exactly 40 percent, counting AnimalE outside the cohort. The sidecar carries the locus display order MHC-B before MHC-A |

## Canonical form

One encoder in `GenotypeCharacterizationSupport.swift` turns a captured value into bytes. Values that are not Codable are walked through Mirror, so a stored property added later shows up and fails the compare instead of being skipped. Arrays, sets and dictionaries are walked element by element before the Codable check, so a set and a dictionary with keys that are not strings are sorted by the canonical text of their elements and never leave `JSONEncoder` in hash-seed order, and a URL inside an array is a plain path like a lone URL. Other Codable values go through `JSONEncoder` with sorted keys. A `Data` becomes decoded JSON when it parses and base64 otherwise, an `AnnotationColor` becomes `#RRGGBBAA` with 8-bit channels, and a payload-free enum becomes its case name. Every floating-point number, whether it comes from a stored property or from a decoded input, is written as the text of `Double.description`, which the Swift standard library owns, so Foundation's number formatting on another macOS release cannot move a digit. Integers and booleans stay JSON numbers and booleans. The output is `JSONSerialization` with sorted keys, pretty printing and unescaped slashes plus a trailing newline. Arrays keep production order, because order is behaviour.

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

The compare never writes into the checkout, because an untracked file there ends a running gate. Each test names the prefix of its files, and the compare fails when the build produces no file, when a produced file is missing on disk, or when a file with that prefix on disk is stale, so an empty build or a renamed value cannot pass. On a mismatch it writes the actual bytes to `$TMPDIR/lungfish-genotype-gui-<uuid>/<file>` and fails with that path and the first differing lines. A missing expected file fails with the capture command of the suite that writes it.

## Updating a file deliberately

A pure-move or extraction commit never touches these files, and review rejects one that does. When a behaviour change is intended, follow these steps.

1. Run the compare and read the whole diff it prints, so you know every value that moved.
2. Capture with `LUNGFISH_CAPTURE_GENOTYPE_GUI_GOLDENS=1` in front of the same command. Capture builds each scenario twice from fresh temp roots and writes only when both builds agree byte for byte, then removes any stale file with the test's prefix.
3. Review `git diff Tests/Fixtures/golden/genotype-gui` and check that only the intended values changed.
4. Commit the files with the code change, naming the scenarios that changed and why.
