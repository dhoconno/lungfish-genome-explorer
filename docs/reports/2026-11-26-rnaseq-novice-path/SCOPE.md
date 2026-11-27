# Scope of the RNA-seq novice path (2026-11-26)

The owner asked overnight for the smallest useful version of `docs/reports/2026-11-26-rnaseq-focus-group/SYNTHESIS.md`, "using expert agents for guidance. Again, don't overengineer." Three seats read the brief (`expert-brief.md`) on Opus 5.5 and wrote `ruling-BIO.md`, `ruling-UX.md` and `ruling-ARCH.md`. The manager set the scope below from them. The owner may be asleep, so the manager decided the open questions and recorded them here.

## In this change

1. **Reference catalog in Plugin Manager > Databases.** A new section, RNA-seq Reference Sets, with two rows, Human, GRCh38 with GENCODE 50 (`human/gencode-50`) and Mouse, GRCm39 with GENCODE M39 (`mouse/gencode-M39`, a new named default). Download runs `lungfish-cli rnaseq install-reference --default <id> --format json` on a download Operations row. The command checks the tools, memory and disk, downloads, checks sha256, builds the set through `ReferenceSetOwner` and builds the k 31 genome-decoy salmon index through `SalmonIndexCache`. All three seats agreed.
2. **Empty picker.** The count pane says "Download a reference set in Plugin Manager to count these reads." with Download Reference Set…, refreshes after an install, and keeps Run off for a set with no index for the chosen settings (UX trap 1, BIO and ARCH trap 3).
3. **Words.** The five label changes UX ruled (Count Reads per Gene, Export Counts and Analysis Scripts, Existing Bulk RNA-seq Counts, Existing Single-cell Counts, the picker sentence) and the two card descriptions. The bulk card is the FASTQ way in (UX section (c)).

## Decisions the manager made

- **Mouse release M39**, the newest GENCODE mouse folder and the same Ensembl release (116) as GENCODE 50 (BIO item 1). Sizes and MD5SUMS md5 matched before the sha256 was pinned.
- **The index is built locally, never downloaded** (BIO item 5), because its key holds the salmon version that ran.
- **Downloads are kept** under `rnaseq-reference-downloads/` (ARCH item 7), because the set's record names each input path. It costs about 1 GB a set.
- **"Reference set" stays the term** (UX). SYNTHESIS's "RNA-seq Reference" rename is deferred as a one-sweep change.
- **"Adjusted p-value cutoff" stays** (UX). The export's new title carries the point.
- **No resume, no Remove** in the first cut. A cancel keeps finished downloads, and the next Download reuses them by sha256. Remove waits for the owner's uses check (backlog RNASEQ-CATALOG-MORE-ROWS).
- **A Mac under about 18 GB of memory** sees Download off with words, because the index build is refused there. No no-decoys fallback (BIO item 4).
- **The plan of 2026-11-25** (`docs/plans/2026-11-25-rnaseq-reference-set-screen.md`, seven development sets, resumable downloads, three catalog commands) was cut to this. Its larger scope is backlog RNASEQ-CATALOG-MORE-ROWS.

## Deferred, as backlog rows in `docs/plans/backlog-later.tsv`

RNASEQ-COMPARE-IN-APP (in-app DESeq2, not small: needs an R environment, a condition grid and a result kind), RNASEQ-TENX-GUIDED (with the Import Embedding and plan-card renames), RNASEQ-FASTQ-START (guided sample grid), RNASEQ-CATALOG-MORE-ROWS, RNASEQ-SMALL-MAC-INDEX, RNASEQ-QUANT-WORDS-LATER (Not host words, picker row names, Advanced disclosure), RNASEQ-INSTALL-REFERENCE-REPLAY. RNASEQ-QUANT-NO-REFERENCE-SET-SCREEN is closed by this change and deleted.

## Added 2026-11-27: the macaques

The owner asked for rhesus and cynomolgus macaque. The manager added each species' default row of P5-REFS, as already pinned in `ReferenceSetDefaults.swift`, not a new choice: `rhesus/ensembl-116`, the same Ensembl release as GENCODE 50 and M39, and `cynomolgus/refseq-GCF_037993035.2`, the T2T assembly BIO set as the cynomolgus default. Neither had been built before, so both were installed on galah before the commit (`EVIDENCE.md`). The T2T assembly has no mitochondrial genome, so the manual says so and names `cynomolgus/ensembl-107` for mitochondrial counts.
