# Expert brief: the RNA-seq novice path (2026-11-26, overnight)

The owner, not an RNA-seq expert, could not process an RNA-seq dataset entirely in LGE. A simulated focus group found five shared blocks. Read `docs/reports/2026-11-26-rnaseq-focus-group/SYNTHESIS.md` first, then skim the five `report-p*.md` beside it as needed.

The owner wants the fix by morning and said "Again, don't overengineer." The goal is the minimum that lets a beginner go from paired FASTQs to gene counts inside the app. A Preview follows from this branch.

## The manager's proposed core

(a) An RNA-seq reference catalog in Plugin Manager → Databases, beside Kraken2 and the other databases. Two rows to start: human `human/gencode-50` (already a row in `Sources/LungfishWorkflow/RNASeq/ReferenceSetDefaults.swift`) and a new mouse GRCm39 + GENCODE mouse row with pinned URLs and sha256. Download runs one new CLI command (working name `lungfish-cli rnaseq install-reference --default <id>`), which downloads the genome FASTA and GTF to the storage root, checks sha256 against the row, builds the set through `ReferenceSetOwner.build` (as `rnaseq reference-set --default` does), then builds the salmon index through `SalmonIndexCache.ensure` at k 31 with genome decoys (as `rnaseq index` does). The app launches that command through `CLIManagedToolsRunner` on an `OperationCenter` row, as `conda db update` already does. The quantify pane's empty picker says "Install an RNA-seq reference to count your reads." and carries a button that opens Plugin Manager on the Databases tab, instead of naming Terminal commands.

(b) The label rewrites in SYNTHESIS.md "Words and labels to change", where UX agrees.

(c) A clear way in from FASTQ files, only if small (for example a line or button on the "RNA-seq Counts" import card that says counting FASTQs starts from Tools, with the right menu path).

Deferred unless you call them small: the in-app DESeq2 comparison and the guided 10x path. Deferred items become rows in `docs/plans/BACKLOG.md`.

Key code: `Sources/LungfishApp/Views/FASTQ/FASTQOperationRNASeqQuantPane.swift`, `Sources/LungfishCLI/Commands/RNASeqReferenceSetSubcommand.swift`, `Sources/LungfishCLI/Commands/RNASeqIndexSubcommand.swift`, `Sources/LungfishWorkflow/RNASeq/ReferenceSetOwner*.swift`, `Sources/LungfishWorkflow/RNASeq/SalmonIndexCache*.swift`, `Sources/LungfishApp/Views/PluginManager/`, `Sources/LungfishApp/Services/CLIManagedToolsRunner.swift`, the manual at `docs/user-manual/chapters/11-rna-seq/`.

## What to write

One page, at `docs/reports/2026-11-26-rnaseq-novice-path/ruling-<FIELD>.md`, with three short lists:

1. **In now**: what must be in this change from your field's view, each with one line of why. Say if you disagree with any part of (a), (b) or (c), and what to do instead.
2. **Traps**: concrete failure modes the implementer must guard against (with file:line where you can).
3. **Deferred**: what waits, each as a one-line backlog row.

Keep it to one page. Do not edit code. Do not run builds. Finish within about 25 minutes of reading.
