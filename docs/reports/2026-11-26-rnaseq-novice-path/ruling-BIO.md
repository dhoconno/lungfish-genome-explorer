# BIO ruling: the RNA-seq novice path (2026-11-26)

Seat BIO, model claude-opus-5-5 (the prompt named no effort). Code read at `d5a95ec57`. The EBI facts were read live on 2026-11-26.

**Verdict.** I agree with (a), (b) and (c) as the brief scopes them, with the two-row catalog, a local index build, and in-app DESeq2 deferred. My one change to (a): neither catalog row has ever been built, so both are built end to end before the Preview.

## 1. In now

1. **Mouse row `mouse/gencode-M39`.** Use GENCODE M39, which is Ensembl 116, the same Ensembl release as `human/gencode-50` (`scripts/repro/rnaseq/refs/table.py:18`). The M39 GTF header reads "version M39 (Ensembl 116)", and EBI posted both releases on 2026-06-09. M39 is the newest folder under `Gencode_mouse/`. Pin the same pair of files as the human row (`ReferenceSetDefaults.swift:46-48`):
   - Genome: `https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M39/GRCm39.primary_assembly.genome.fa.gz`, 774,679,166 B, MD5SUMS md5 `bffa410b822ae1518413091fed1e4aa8`.
   - GTF: `.../release_M39/gencode.vM39.primary_assembly.annotation.gtf.gz`, 91,741,340 B, md5 `77592612d51d383c889113540a2fa60c`.
   - Fields: species `Mus musculus`, assembly `GRCm39`, accession nil (as the human row), source `GENCODE`, release `M39`. The set id then reads `mus_musculus-GRCm39-gencodem39-lge-<hash>` (`ReferenceSetRequest.swift:121-126`).
   - Add a second base URL. `gencode` at `ReferenceSetDefaults.swift:41` is the human release_50 folder only.
   - GENCODE publishes md5 only. Compute sha256 from the downloaded bytes after size and md5 match, as was done for human 50 (`stage0-refs.tsv:7,27-28`). The human 50 files still match EBI's MD5SUMS today, and the staged genome's sha256 equals the row's.
2. **Build both rows once with the new command before the Preview.** `human/gencode-50` has never been built through the owner (`docs/plans/2026-11-25-rnaseq-reference-set-screen.md:53`), and mouse is new. That plan's rule (`:61`) is not to offer an unbuilt set to a person who has no terminal.
   - For each row, record the set id, the `derived/transcripts.fa` sha256, the index key and its four hashes, and one salmon quant of a small paired sample.
   - Expect `chrM` as the mitochondrial contig, found by the fallback at `ReferenceSetAnnotation.swift:208`.
   - Expect GENCODE `gene_type` to be read as the biotype (`ReferenceSetAnnotation+GTF.swift:92`), so rRNA% works (`RNASeqQualitySummary.swift:77`).
3. **Pass the downloaded bytes unchanged.** Give the gz files to `ReferenceSetOwner.build`, using the same request that `--default` makes, with `expected: named` (`RNASeqReferenceSetSubcommand.swift:137-143`). A set installed from the catalog then has the same id as one built by hand from the same files.
4. **One index setting: k 31 with genome decoys.** This is the right single default:
   - It is salmon's default k.
   - It is the decoy route that seqc-gse47774 reproduced (`seqc-gse47774/index.sh:9`, `run.sh:205`).
   - It equals the pane defaults (`FASTQOperationRNASeqQuantPane.swift:64-65`) and `SalmonIndexRequest`'s defaults (`SalmonIndexCache.swift:43`).
   - Never switch to no decoys because the Mac is small. The options are never chosen from host memory (`SalmonIndexNeed.swift:9-11`, BIO 3). A switch would not help anyway: a no-decoys build is checked against the same fixed need (`SalmonIndexCache+Build.swift:32-33`, `SalmonIndexNeed.swift:28`).
5. **Build the index on the Mac, never download one.** The index key holds the version of the salmon that ran (`SalmonIndexCache.swift:35`, BIO 4). I disagree with SYNTHESIS item 1's "prebuilt Salmon index". I agree with (a), which builds the index locally.
6. **(b) labels.** "Adjusted p-value cutoff for exported scripts" is accurate, because nothing runs a test in the app. "Counts on Added Reference Sequences (%)" is accurate, because the share counts the manifest's `notHost` features, which are the added extras (`RNASeqQualitySummary.swift:101-109`). The other words are UX's call.
7. **(c) FASTQ way in.** The card must tell the user to choose each sample's R1 and R2 together in Sequencing Read Files, so the two files become one paired bundle. Quant names the sample by its bundle (`SalmonQuantRoute+Reads.swift:59`). A bundle that holds only one mate is counted as single reads.

## 2. Traps

- **The picker lists sets that have no index.** It lists every set folder (`FASTQOperationRNASeqQuantPane.swift:26-40`) and picks a lone set by itself (`:74-76`). After an install whose index build was refused, Run is on and the run then stops. Show "Ready to count" only when `SalmonIndexCache.published(key)` returns for k 31 and genome decoys (`SalmonIndexCache.swift:184`).
- **A 16 GB Mac is refused at the index step.** The build needs 17,780,281,048 B against physical memory (`SalmonIndexNeed.swift:18`, `RunFitPreflight.swift:115-117`). Without a check first, such a Mac downloads about 0.9 GB and builds a set before the refusal. Check memory and disk before the download (plan `:110`). The wording belongs to SWIFT and UX.
- **k or decoys changed in the pane** (`:161-176`) matches no installed index. UX decides whether these move under Advanced.
- **Find an installed set by its file sha256, not by a fixed id.** The id hashes the gffread and lungfish derive versions (`ReferenceSetRequest.swift:119`).
- **Use only the PRI GTF with the primary_assembly genome.**
  - The CHR GTF (`gencode.vM39.annotation.gtf.gz`) drops the genes on scaffolds.
  - The ALL GTF names patches the genome lacks, which `namesMissingFromGenome` refuses.
  - GENCODE's own `transcripts.fa.gz` has pipe headers that need `--gencode`, and the index key carries no build options (BACKLOG `RNASEQ-INDEX-KEY-BUILD-OPTIONS`).
- **A row whose sha256 is nil must not install.** Both hash fields are optional (`ReferenceSetDefaults.swift:19,21`).
- **The M39 genome download is still running.** At 22:08 it held 221,343,744 of 774,679,166 B in `/Volumes/lge_scratch/lge/rnaseq/refs/mouse/gencode-M39/`. Pin the sha256 only after size and md5 match.
- **Two installs of one row** build two salmon processes of about 20 GB each (BACKLOG `RNASEQ-INDEX-TWO-BUILDS-ONE-KEY`). That fix is SWIFT's.
- **Cost of one index:** about 53 min for the GRCh38 decoy build (BACKLOG `RNASEQ-USES-KEYED-BY-PATH`), 8.79 GB kept, and 63.9 GB free during the build (plan `:136`). Mouse's genome is smaller, so the same fixed need applies.

## 3. Deferred (backlog rows)

- `RNASEQ-DE-IN-APP` (S3, BIO): an in-app two-group DESeq2 comparison. This is not small:
  - The RNA-seq pack holds only salmon and gffread (`PluginPack.swift:659-662`), so it needs an R and Bioconductor environment.
  - It also needs a condition grid with a replicate check, and a result kind with its record.
  - It would inherit the open export rows `RNASEQ-EXPORT-*` (BACKLOG:85-89).
- `RNASEQ-SMALL-MAC-INDEX` (S3, BIO with SWIFT): measure the memory need of a no-decoys index, then offer it as an explicit, labelled and recorded choice on 16 GB Macs. This follows `RNASEQ-INDEX-NEED-ONE-SIZE`.
- `RNASEQ-SHORT-READ-K` (S3, BIO): rule on a k below 31 for reads shorter than about 75 bp, after a measured comparison on one study.
- `RNASEQ-CATALOG-DEV-ROWS` (S3, BIO): the 2026-11-25 plan's built development sets (`human/ensembl-100` with ERCC92, the NHP rows), plus resume and remove.
- `RNASEQ-10X-GUIDED` (S3, UX with BIO): Make Cell Map on imported counts, then the guided kit and reference choice.
