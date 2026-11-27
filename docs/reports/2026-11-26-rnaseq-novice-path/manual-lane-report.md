# Manual lane: words for the RNA-seq novice path (2026-11-26)

Opus 5.5 (`claude-opus-5-5`). Docs only. No build and no commit, so the manager commits. The work is uncommitted in the `vigorous-easley-016cc5` worktree.

## Files changed

| File | What changed |
|---|---|
| `docs/user-manual/chapters/11-rna-seq/02-counting-bulk-reads.md` | The new section "Install a reference set in Plugin Manager" comes before "Build a reference set with rnaseq reference-set". It has five numbered steps, says what Download does, and covers the memory refusal, the missing pack, cancel and failure. The Procedure now opens with a table of two routes (Plugin Manager for human or mouse, Terminal for other species or added sequences) above the small-Mac list. The task table, the Terminal sentence in What it is, Before you start ("Building a set or an index for another species happens in Terminal") and the pack sentence are updated. A mouse row (`mouse/gencode-M39`) joins the named-defaults table. The section is renamed "Count reads per gene with salmon" and now describes the empty-state button, the self-filling picker and the no-index message. The pane settings heading is now "Count Reads per Gene settings". The troubleshooting row now reads "Download a reference set in Plugin Manager to count these reads.", and a new row covers "This reference set has no salmon index for k". The On the command line section gets a `lungfish-cli rnaseq install-reference --default human/gencode-50` block. The front matter (task, entry points, CLI line, caption) and the SCOPE comment are updated. |
| `docs/user-manual/chapters/11-rna-seq/01-what-is-rna-seq.md` | Entry points, submenu caption, menu table, card table, the named-defaults paragraph (Plugin Manager downloads human and mouse) and the command-line-only paragraph. Card and export labels changed in four sentences. |
| `docs/user-manual/chapters/11-rna-seq/03-reading-and-exporting-bulk-counts.md` | Export label in the entry point, the caption, three sentences, the procedure heading and step 1, and the settings heading. Two links point to the renamed import heading in 02. |
| `docs/user-manual/chapters/11-rna-seq/04-single-cell-counts.md` | Card label in an entry point, one sentence, the procedure heading and step 2. Export label in an entry point and in step 1. The link to the renamed export settings heading in 03 is updated. |
| `docs/user-manual/chapters/11-rna-seq/05-the-cell-map.md` | The link to the renamed single-cell import heading in 04. |
| `docs/user-manual/chapters/01-foundations/06-the-lungfish-project.md` | Tools > RNA-seq row and Sequencing Reads card list. |
| `docs/user-manual/chapters/01-foundations/07-plugin-packs.md` | The pack table row names Count Reads per Gene and the reference sets. Step 1 says the Databases tab also holds the RNA-seq reference sets. A new paragraph in The Databases tab describes the RNA-seq Reference Sets section and links to 02. |
| `docs/user-manual/chapters/03-reads/01-importing-fastq.md` | The two renamed cards in the card table. The bulk row adds that FASTQ files are counted through Sequencing Read Files and Count Reads per Gene. |
| `docs/user-manual/chapters/03-reads/04-trimming-and-filtering.md` | One label (Count Reads per Gene). |
| `docs/user-manual/chapters/appendices/cli-reference.md` | New entry `rnaseq install-reference` after `rnaseq index`, in the shape of that entry, taken from `Tests/Fixtures/golden/cli-help/lungfish-cli.rnaseq.install-reference.txt` (`--default`, `--storage-root`, `--format`). |
| `docs/user-manual/chapters/appendices/file-formats.md` | One export label. |
| `docs/user-manual/ARCHITECTURE.md` | Rows 232 to 234 of the chapter map. |
| `docs/user-manual/parameters.yaml` | Titles and entry points of `rnaseq.quant`, `rnaseq.export` and `import.rnaseq-counts`, plus the notes of `import.rnaseq-counts` (card names, and that each sheet now carries the external-input sentence). No check reads this file. |
| `docs/user-manual/assets/recipes/11-rna-seq/*.yaml` (5 files) | Recipe captions now match the chapter captions, and the PROSE-ONLY capture steps use the new labels. `rnaseq-quantify-pane.yaml:27` describes the new empty state. No image changed. |

Unchanged on purpose: the chapter titles, the sheet titles "Import RNA-seq Counts" and "Import Single-cell Counts", the headings "RNA-seq Counts sheet settings" and "Single-cell Counts sheet settings" (both name the sheets), "Reference set", "Single-cell Plan for a Linux Machine", "Import Embedding", "Not host (%)" and "Adjusted p-value cutoff". `features.yaml` is also unchanged.

Changed anchors, with every link to them updated: `#import-salmon-folders-or-a-count-table-with-the-existing-bulk-rna-seq-counts-card`, `#count-reads-per-gene-with-salmon`, `#count-reads-per-gene-settings`, `#export-counts-with-export-counts-and-analysis-scripts`, `#export-counts-and-analysis-scripts-settings`, `#import-cell-ranger-or-starsolo-counts-with-the-existing-single-cell-counts-card`. An `rg` of `docs/user-manual` (without `features.yaml` and `node_modules`) finds none of the old labels or old anchors.

## Lint (`LUNGFISH_MANUAL_STRICT=1 bash docs/user-manual/build/scripts/lint-chapter.sh`)

- Before, on `02-counting-bulk-reads.md`, the result was "no issues found".
- After the first draft, 02 had two warnings: three lists in Procedure, and a colon inside a quoted Operations row title. Both are fixed. The extra lists became a table, and the title is now described without its colon.
- After, 9 of the 11 changed chapters report "no issues found". `03-reading-and-exporting-bulk-counts.md` has 5 warnings and `05-the-cell-map.md` has 3, all of the form "setting '<Label>' of 'rnaseq.export' / 'rnaseq.cell-map-import' is not documented in '## Settings'". These were already there at the base. A lint of the HEAD copies of both files gives the same 5 and 3 warnings. They come from title-case labels in `parameters.yaml` and are not chased here.
- `ARCHITECTURE.md` and the YAML files are not chapters, so they were not linted.

## Screenshots that now show old words (need a new capture)

| Shot id | Chapter | Old words in the image |
|---|---|---|
| `rnaseq-tools-submenu` | 11-rna-seq/01 | Quantify RNA-seq Reads…, Export RNA-seq Counts… (caption changed, no recipe file found) |
| `rnaseq-quantify-pane` | 11-rna-seq/02 | Pane title Quantify RNA-seq Reads. The old empty-state footer probably shows too, since the recipe captures with no set installed |
| `rnaseq-export-dialog` | 11-rna-seq/03 | Row title Export RNA-seq Counts |
| `03-reads/01` Sequencing Reads tab shot, `08-workflows/04` Sequencing Reads tab shot | 03-reads/01, 08-workflows/04 | Card titles RNA-seq Counts and Single-cell Counts, if the RNA-seq cards are in frame (not checked) |
| `plugin-manager-databases-tab` | 01-foundations/07 | Not old words, but the RNA-seq Reference Sets section is missing if it is in frame (not checked) |

`rnaseq-counts-import-sheet` and `single-cell-counts-import-sheet` keep their sheet titles. They now also show the external-input line, but no caption names it.

## Findings (not fixed, outside a docs lane)

- S3 `Sources/LungfishApp/Views/PluginManager/RNASeqReferenceCatalogModel.swift:58` and `RNASeqReferenceSetsSection.swift:55` say "about 18 GB of memory". `rnaseq index`, the manual (`02-counting-bulk-reads.md` Choosing a tool, `cli-reference.md` `rnaseq index`) and About This Mac say 16.6 GB for the same 17,780,281,048-byte need. 18 GB is in billions of bytes, and 16.6 is in the binary units About This Mac uses. The chapter now says in one sentence that the two figures are the same need. One unit in the app would remove that sentence.
- S3 `Sources/LungfishApp/Views/PluginManager/RNASeqReferenceSetsSection.swift:95` turns Download off only for memory. UX ruling trap 5 asks for Download to be off, with the pack sentence on the row, when the RNA-Seq Analysis pack is missing. As built, the click runs and the command refuses with that sentence. The manual describes the build as it is ("Download stops before it downloads anything and says …").
- S4 `RNASeqReferenceSetsSection.swift:81-82`: an installing row shows a spinner and no Cancel button, so a cancel happens only from the Operations Panel. The manual says "If you cancel the Operations row". Kraken2 rows have Cancel on the row (`07-plugin-packs.md`, step 5).

## Sends, suites, deviations

- Sends: none.
- Suites moved: none, since this lane ran no test.
- Deviations: beyond the files the brief named, the lane changed `05-the-cell-map.md`, `03-reads/04-trimming-and-filtering.md`, `appendices/file-formats.md`, `parameters.yaml` and five capture recipes. Each held an old label or a link to a renamed heading. `07-plugin-packs.md` also gained a short paragraph, because its Databases tab said only classification databases.

The lane is complete.

## Fixed by the manager after the lane

All three findings are fixed in the app: the row and refusal say 16.6 GB, Download is off with the pack sentence when gffread or salmon is missing, and an installing row has Cancel. The chapter sentence that reconciled 18 and 16.6 GB is gone.
