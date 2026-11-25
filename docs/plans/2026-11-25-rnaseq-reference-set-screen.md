# Plan: download and build RNA-seq reference sets in the app

Date 2026-11-25. Status: plan only, no code changed. The expert panel decides the phase (O75). Nothing is pushed without the owner's go.

## Why

Counting RNA-seq reads in the app needs a reference set and its salmon index under `<storage root>/rnaseq-reference-sets`. A fresh install has none. Today a set is made only in Terminal with `lungfish-cli rnaseq reference-set`, after the person has downloaded the genome and GTF themselves. The Quantify RNA-seq Reads dialog says so in one sentence (`FASTQOperationRNASeqQuantPane.swift:105`) and stops. A bench scientist with no terminal cannot count reads.

The owner asked on 2026-11-25 for in-app downloads, limited at first to the references used while the RNA-seq feature was developed.

## What was checked before writing

Every figure below comes from the built sets on lge_scratch and the staging manifests. Nothing was downloaded and no tool binary ran.

- The sets: `/Volumes/lge_scratch/lge/rnaseq/work/refs-5-1-e/root/rnaseq-reference-sets` (8 sets) and `.../m-index/adopt-root-2/rnaseq-reference-sets` (1 set), plus the RefSeq 5.0 set under `.../p5-refs/lge/RS-COUNTING-GTF/root/rnaseq-reference-sets` and `.../gse296788/lge/RS-REFSET`.
- `reference-set.json` holds each input's sha256 but no URL. `provenance/bundle.lungfish-provenance.json` holds the argv, so the local input path, and each input's sha256 and size. The URL comes from the staging manifests: `scripts/repro/rnaseq/stage/manifests/stage0-refs.tsv` and `~/lungfish-phase-records/phase-5-rnaseq/lanes/STAGE-REFS-tools/stage-refs-q5.tsv`. Each of those rows carries the checksum from the source's own `CHECKSUMS` or `MD5SUMS` file.
- Two inputs are symlinks on lge_scratch. `refs/human/ensembl-100/...primary_assembly.fa.gz` points to the Ensembl 98 file, and `refs/rhesus/ensembl-100/...toplevel.fa.gz` points to the Ensembl 116 file. Each pair has the same BSD sum in its release's `CHECKSUMS` (02415 860559 for human 98 and 100, 34598 852463 for rhesus 100 and 116), so the release-100 URL serves the same bytes. `ReferenceSetDefaults.swift` already gives rhesus 100 and 116 the same genome sha256.

### Finding 1. The cyno 5.0 studies used two different annotations

The brief lists Macaca_fascicularis_5.0 Ensembl 102 for both gse290671 and gse296788. Only gse290671 used Ensembl 102 (`gse290671/README.md:7`, set `...ensembl102-lge-6dbb81628579`, BOMV extra). gse296788 used RefSeq Annotation Release 101, `GCF_000364345.1` (`gse296788/README.md:19`, `gse296788/run.sh:30-38`), with `--assembly-report` and an Mtb Erdman extra. That is the `cynomolgus/refseq-GCF_000364345.1` default row.

The 24 GTF lines with an empty gene_id (`P5-REFS.md:28`) are all exon lines on the mitochondrion `NC_012670.1`. The owner drops them: the built set lists exactly 24 `NC_012670.1 exon` lines under `derivation.droppedFeatures`. In the lge layout it then adds exons to the 13 mitochondrial genes that had only a CDS (`exonsAdded`). The set builds and counts. The screen shows both derivation notes, as `ReferenceSetOutcome.notes` already words them.

So the list has two cyno 5.0 rows, not one.

### Finding 2. The GENCODE 32 set was built from 10x's genome file

`homo_sapiens-GRCh38-gencode32-lge-ee638764d130` took its genome from 10x's `GRCh38-2020-A/genome.fa` (plain, 3,151,417,447 bytes, sha256 `fb742121...`), not from GENCODE. No public URL serves that file alone. It sits inside 10x's refdata tarball. The GTF is GENCODE's own release-32 file.

GENCODE's own `release_32/GRCh38.primary_assembly.genome.fa.gz` is on lge_scratch, staged and checked against `MD5SUMS` (844,691,642 bytes, sha256 `86ef9981...`). 10x built its 2020-A genome from that file and changed only the header lines, as far as is known. Step 0 checks this: build a set from GENCODE's file and compare `derived/transcripts.fa` with the dev set's (`d478640c...`). Equal transcripts mean equal counts. The set id still differs, because the id comes from the input hashes.

### Finding 3. The human Ensembl 100 set exists with and without ERCC92

`...ensembl100-lge-2f194923a6ec` is the host alone (gse152418, gse162164, gse163196). `...ensembl100-lge-ca9bd65782ab` adds the spike-in extra ERCC92 (seqc-gse47774). ERCC92.fa (85,553 bytes, sha256 `ab9720a4...`) came from Thermo Fisher's `ERCC92.zip`. The zip's own sha256 is not recorded anywhere, and step 0 measures it.

### Finding 4. Study extras stay with the studies

The dev sets carry study-specific extras: BOMV for gse290671 (from GenBank OK633884.1, with a GTF that `gse290671/bomv_gtf.py` makes), Mtb Erdman for gse296788, and SARS-CoV-2 for gse183579. None has a fixed file URL with a pinned checksum. The first release offers host sets, plus ERCC92 as one optional extra, since it is a fixed commercial file. A person who needs a virus or bacterium adds it with `lungfish-cli rnaseq reference-set --extra`. A later row can add extras to the screen.

## Decision: the barnyard set is out of scope

`homo_sapiens_and_mus_musculus-hg19_and_mm10-ensembl87_and_93` leaves the first release, for five reasons.

1. Only `tenx-controls` used it. It is 10x's species-mixing control, not a study a person would repeat.
2. Its two inputs (`genome.fa` 5,929,890,014 bytes and `genes.gtf` 2,054,199,961 bytes) come only inside 10x's `refdata-cellranger-hg19-and-mm10-3.0.0` tarball. There is no per-file URL. The screen would have to unpack a tarball of about 18 GB, and 10x's terms for its refdata would need a check first.
3. hg19 is retired. Offering it next to GRCh38 invites the wrong pick.
4. It is the largest set by far: 10.6 GB on disk. Its gentrome would be about 6.4 GB, so the scaled index need (`SalmonIndexNeed.scaledNeed`) is about 32 GB of memory and 116 GB of free disk. Most Macs would refuse the index.
5. No bulk or single-cell study a scientist brings needs a human plus mouse reference.

## Decision: add rows, offer only the built ones

`ReferenceSetDefaults.swift` pins eight sets chosen for newer releases. Three of them are development sets too: `rhesus/ensembl-100`, `cynomolgus/ensembl-107` and `cynomolgus/refseq-GCF_000364345.1`. The other five (`human/gencode-50`, `rhesus/ensembl-116`, `rhesus/refseq-GCF_003339765.1` and the two T2T sets) have never been built and checked through the owner (REFSET-T2T-NOT-BUILT, BACKLOG.md:85).

There are three options:

- A. Add rows for the development sets to the same table, and offer in the app only rows marked as built and checked.
- B. Replace the defaults with the development sets.
- C. Show both lists in the app.

**Recommended: A.** One table stays the single source of every URL and sha256, for the CLI's `--default` and for the screen. The newer defaults stay available to the CLI. The app does not offer an unbuilt set to a person with no terminal to recover from a refusal. B would drop sets that the CLI already names and that the owner's chosen roles (human default, rhesus default) depend on. C would put five untested sets in front of a bench scientist. A default row joins the screen when a lane builds and checks it, which is a one-line change.

Option A adds four rows and one field:

- New rows: `human/ensembl-100`, `human/ensembl-93`, `human/gencode-32` and `cynomolgus/ensembl-102`.
- Existing rows offered: `rhesus/ensembl-100`, `cynomolgus/ensembl-107` and `cynomolgus/refseq-GCF_000364345.1`.
- A new field `inApp: InAppOffer?` holds the file sizes, the assembly report where needed, the optional extras and the dev study list that the screen shows. It is `nil` for the five rows the screen does not offer.
- ERCC92 is an optional extra on `human/ensembl-100`, not a row of its own.

## The list of sets

The screen shows seven sets. Sizes are measured from the built sets. "Set on disk" is the set folder, which keeps a copy of the gzip genome and GTF, the counting GTF, `transcripts.fa` and the tables. Downloads are deleted once the set is built.

| Row | Set | Genome file and sha256 | GTF file and sha256 | Download | Set on disk | Dev studies |
|---|---|---|---|---|---|---|
| `human/ensembl-100` | Human GRCh38, Ensembl 100 | `https://ftp.ensembl.org/pub/release-100/fasta/homo_sapiens/dna/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz`, 881,211,416 B, `197607411dc63c2a5638ab5f24ea23e160fabf46ceaf482a1b01daaf0ad1045a` | `https://ftp.ensembl.org/pub/release-100/gtf/homo_sapiens/Homo_sapiens.GRCh38.100.gtf.gz`, 46,973,686 B, `6deab14681c08eb4e6cffad4e9ded842cadac76386addb3fcda204e97ed93a37` | 0.93 GB | 2.55 GB | gse152418, gse162164, gse163196, seqc-gse47774 (with ERCC92) |
| `human/ensembl-93` | Human GRCh38, Ensembl 93 | `https://ftp.ensembl.org/pub/release-93/fasta/homo_sapiens/dna/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz`, 881,214,682 B, `2a27436d44f0d6350f86894fbe5edec56faa5467028879784508041562406aa0` | `https://ftp.ensembl.org/pub/release-93/gtf/homo_sapiens/Homo_sapiens.GRCh38.93.gtf.gz`, 42,921,931 B, `810e3bb63bb24bd5a005b14397d69280dda34c41a612fb86a18f3c4836fce57d` | 0.92 GB | 2.40 GB | gse155673 |
| `human/gencode-32` | Human GRCh38, GENCODE 32 | `https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_32/GRCh38.primary_assembly.genome.fa.gz`, 844,691,642 B, `86ef9981f90267b036f59db02d0f4b15a2c388bf1dc0376cc5bc35c16e5fcb37` | `https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_32/gencode.v32.primary_assembly.annotation.gtf.gz`, 43,107,903 B, `0c36c37abb0c88637b04a8e401c93f0199a65bbdd0702c9e13bdfbadc053fe1e` | 0.89 GB | about 2.6 GB (the dev set is 4.91 GB because it holds a plain 3.15 GB genome) | tenx-controls (Finding 2) |
| `rhesus/ensembl-100` | Rhesus Mmul_10, Ensembl 100 | `https://ftp.ensembl.org/pub/release-100/fasta/macaca_mulatta/dna/Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz`, 872,921,950 B, `679dd90651c50366858152b62989c26d587340711e60622458815d19b272fd3a` | `https://ftp.ensembl.org/pub/release-100/gtf/macaca_mulatta/Macaca_mulatta.Mmul_10.100.gtf.gz`, 18,987,120 B, `73ba46e5b962e55d1307b0ceea8aedef33e1aed5b7e29840fc9da28d15e5c7a9` | 0.89 GB | 1.58 GB | gse183579, gse304256 |
| `cynomolgus/ensembl-107` | Cynomolgus Macaca_fascicularis_6.0, Ensembl 107 | `https://ftp.ensembl.org/pub/release-107/fasta/macaca_fascicularis/dna/Macaca_fascicularis.Macaca_fascicularis_6.0.dna.toplevel.fa.gz`, 866,733,786 B, `1a7d9bae467018eaf79f622b4fbae849e4f877879144cd1761f3dafac144c535` | `https://ftp.ensembl.org/pub/release-107/gtf/macaca_fascicularis/Macaca_fascicularis.Macaca_fascicularis_6.0.107.gtf.gz`, 18,689,831 B, `aef041357910d2757f272db9d30f64a206d388eb0850fa5713f9fd9eb6aee2c0` | 0.89 GB | 1.56 GB | gse225770 |
| `cynomolgus/ensembl-102` | Cynomolgus Macaca_fascicularis_5.0, Ensembl 102 | `https://ftp.ensembl.org/pub/release-102/fasta/macaca_fascicularis/dna/Macaca_fascicularis.Macaca_fascicularis_5.0.dna.toplevel.fa.gz`, 850,383,525 B, `8bebe62ca52debf87bb1cfad9c4806e6a153708116d5a79754232515543d8471` | `https://ftp.ensembl.org/pub/release-102/gtf/macaca_fascicularis/Macaca_fascicularis.Macaca_fascicularis_5.0.102.gtf.gz`, 16,369,399 B, `1067c633919c74072ca68c0be6399803a86ff3cec4914caf46ea6fe48408d329` | 0.87 GB | 1.44 GB | gse290671 (with BOMV, Finding 4) |
| `cynomolgus/refseq-GCF_000364345.1` | Cynomolgus Macaca_fascicularis_5.0, RefSeq 101 | `https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/364/345/GCF_000364345.1_Macaca_fascicularis_5.0/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.fna.gz`, 805,823,524 B, `0c411a03613308bdc537e11f5978536fb3eded44b0e437b240ecca8985c17d26` | `.../GCF_000364345.1_Macaca_fascicularis_5.0_genomic.gtf.gz`, 20,137,698 B, `43726f01d1ff70520fb02661dd594552dab3b4e53fb8f06c6a4c092d55dfb3c3`, plus `.../GCF_000364345.1_Macaca_fascicularis_5.0_assembly_report.txt`, 837,787 B, `3500f1303ce6d0adf3834227229aac2313af63d853b8f3f0b22c11587a92b2fc` | 0.83 GB | 1.79 GB | gse296788 (with Mtb, Finding 4) |

The optional extra on `human/ensembl-100` is ERCC92: `https://assets.thermofisher.com/TFS-Assets/LSG/manuals/ERCC92.zip`. The CLI unpacks `ERCC92.fa` and checks it against `ab9720a49d9af5463e535fe0c3f6ea2a8c7f9fbf4a4afe29969fb5c1b9e3a2b4`. The zip's sha256 and size are step-0 measurements. It adds 0.1 MB to the set and gives the set id of `...ca9bd65782ab`'s inputs.

Each row's on-screen text stays short: the species, the assembly, the annotation and release, the download size and the set size. Nothing else goes in the row (owner question 2026-11-21 on text in views). The dev study list and the derivation notes sit in a help popover.

## Where the screen lives

The screen is a new section, **RNA-seq Reference Sets**, in the Plugin Manager's Databases tab (`PluginManagerView.swift`, `PluginManagerViewModel.Tab.databases`). It sits below the metagenomics databases and uses the same row pattern: status, Download, a progress bar with its message, Cancel, and Remove. The owner asked for it to work the way reference databases are downloaded today, and a person who has downloaded Kraken2 or EsViritu databases already knows where to look.

The layering rule says new feature UI belongs in a leaf. The rows are a SwiftUI view in `LungfishRNASeqUI` (`RNASeqReferenceSetCatalogView`). Its model is plain values with callbacks: download, cancel, remove and build index. The App wires those to the CLI runner from `PluginManagerViewModel+RNASeqReferenceSets.swift`. The leaf never imports LungfishApp.

The section can be reached in three ways:

- Plugin Manager, Databases tab (menu path unchanged).
- The Quantify RNA-seq Reads dialog's empty state (below).
- `PluginManagerWindowController.show(tab: .databases, focus: .rnaseqReferenceSets)`, a new entry that scrolls to the section.

## How a download and build run

The app runs every step as one `lungfish-cli` process on an Operations row, the way `conda db update` runs today (`CLIManagedToolsRunner`, `PluginManagerViewModel+OperationBegin.swift:49-71`). The row records the exact argv, so the GUI and the CLI cannot drift (CLI-EQUIVALENCE).

### New CLI commands

`lungfish-cli rnaseq catalog` gets three subcommands beside `reference-set` and `index`:

- `rnaseq catalog list [--format json]` lists each offered row: id, names, sizes, whether its set is installed (with its set id), whether a partial download exists and how many bytes it holds, and whether an index exists.
- `rnaseq catalog install <row> [--extra ERCC92] [--index] [--storage-root P] --format json`, in four steps:
  1. **Preflight.** Free disk on the storage root's volume must be at least the download, plus the set, plus 10 percent. With `--index` it must also be 63.9 GB (`SalmonIndexNeed.freeDiskBytes`), and memory must be at least 17.78 GB (`SalmonIndexNeed.peakMemoryBytes`). Otherwise it refuses before any byte moves and says what is short, by how much, and what to do.
  2. **Download** each file in turn (below).
  3. **Build** through `ReferenceSetOwner.build` with the request that `ReferenceSetDefault.named(row)` makes, as `--default` does today. It uses the lge layout, with `--assembly-report` for the RefSeq row. The owner hashes each input again as it copies it, so a file changed after the download check is still caught. A published set of the same id is reused and nothing is built, which the owner already does.
  4. **Optional index** through `SalmonIndexCache.ensure` with k 31 and genome decoys, the Quantify dialog's defaults. On success the download folder is removed.
- `rnaseq catalog remove <set-id>` moves the set folder and its folders under `rnaseq-index-cache/<set-id>` to the Trash. They are not deleted. It refuses while a running operation uses the set. Results in projects name the set by id. The lane checks what a result shows once its set is gone, and the panel rules on it (question 1). A removed set can be built again from the same files and gets the same id.

The app also needs index-only work on an installed set: the existing `lungfish-cli rnaseq index --set <id> --format json` is reused as it is.

### Download with resume, cancel and sha256

A new type in LungfishWorkflow, `ResumableFileDownload`, is used by the catalog and by nothing else at first. No downloader in the tree resumes today (`DatabaseRegistry` and `MetagenomicsDatabaseRegistry` delete their `.partial` files and start over).

- **Where files go.** Files land in `<storage root>/rnaseq-reference-downloads/<row>/`, outside the set folder. A half-downloaded file is never inside `rnaseq-reference-sets`, so the Quantify dialog's set list (`RNASeqQuantReferenceSets.choices`) cannot see it. Each file is written as `<name>.partial` beside `<name>.partial.json`, which holds the URL, the expected size and sha256, and the server's `ETag` and `Last-Modified`.
- **Resume.** A request with a partial file sends `Range: bytes=<have>-` and `If-Range: <ETag or Last-Modified>`. A 206 appends. A 200 means the server ignored or refused the range, or the file changed, so the download starts again from zero and the row says so. A 416 with the full size already held goes straight to the check.
- **Retry.** A dropped connection retries three times with 5, 20 and 60 s pauses, each time resuming. After the third failure the command ends with words, the partial file stays, and the next Download resumes.
- **Cancel.** The row's Cancel sends SIGTERM through the transport. The command stops its URLSession task, flushes, and keeps `.partial` and its JSON. The row then reads "Paused, 412 MB of 881 MB". Download resumes it. A cancel during the build lets the owner's staging folder be removed, which it already does. A cancel during the index does the same for the index stage.
- **Checks.** The byte count is checked against the expected size first. A file that grows past its size stops at once. Then sha256 is computed in one streaming pass. On a mismatch the file is deleted, the command fails with `ReferenceSetError.checksumMismatch` (file, expected, found), and the row says the file did not match and that Download fetches it again. A match renames `.partial` to the final name.
- **Network.** Downloads use HTTPS only. Each URL is pinned in the row, so no URL comes from a server response except a redirect on the same host. Progress events carry bytes so far, total and rate, and the app shows them as the database rows do.
- **Restart and quit.** After the app restarts, `catalog list` reports each partial, so the row shows Paused with its byte count. Quitting the app with a download running keeps the partial files. The lane checks how OperationCenter treats a quit during a running row and follows it.

### The salmon index

The index is a choice, not a default. Download gives a set. Under the set row, **Build salmon index** runs `rnaseq index` as its own Operations row. A checkbox in the Download sheet, "Also build the salmon index", does both in one row.

- **Memory refusal.** A build needs 17,780,281,048 bytes of memory, about 16.6 GiB (`SalmonIndexNeed.peakMemoryBytes`). On a Mac with 16 GB or less, the checkbox and button are off before anything starts. Words beside them say: "Building the salmon index needs about 16.6 GB of memory. This Mac has 16 GB. Build the index on a Mac with more memory, or count with STAR on Linux." The same refusal stays in the CLI (`RunFitPreflight.require`), so a scripted run refuses in the same words.
- **On a 16 GB Mac.** The set is still useful. `lungfish-cli import rnaseq` takes `--reference-set` for salmon or STARsolo results made elsewhere. The Quantify dialog says the index is missing and why.
- **Disk.** The human index is 8.79 GB (`seqc-gse47774/lge/RS-INDEX/.../salmon-2.11.0-k31-genome-decoys`, 8,582,168 KiB). No NHP index has been built through `rnaseq index`. The NHP gentromes (transcripts plus about 2.9 to 3.0 GB of genome) are smaller than the measured 3.52 GB human gentrome, so the same fixed need applies: about 9 GB to keep and 63.9 GB free during the build. Step 0 measures one NHP index to replace "about 9 GB".

Disk for one set, all steps:

| Set | Downloads, deleted after the build | Set kept | Index kept | Free disk to build the index |
|---|---|---|---|---|
| Human (any of the three) | 0.89 to 0.93 GB | 2.4 to 2.6 GB | 8.8 GB | 63.9 GB |
| NHP (any of the four) | 0.83 to 0.89 GB | 1.4 to 1.8 GB | about 9 GB (step 0) | 63.9 GB |

All seven sets with indexes keep about 13 GB of sets and about 62 GB of indexes, about 75 GB in all.

## The Quantify dialog's empty state

`FASTQOperationRNASeqQuantPane.swift:105` names two CLI commands today. The change:

- **No set installed.** The dialog says "No RNA-seq reference set is installed." and shows a button, **Get Reference Sets…**. The button calls a new `onOpenReferenceSets` callback that the App wires to `PluginManagerWindowController.show(tab: .databases, focus: .rnaseqReferenceSets)`. Run stays off.
- **Set chosen but no index for its k and decoys.** This is a new readiness check, a file check through `SalmonIndexCache`'s key with no salmon run. It replaces the run-time `SalmonQuantError.noIndex`. The dialog says "This reference set has no salmon index yet." with **Build Index…**, which opens the same section. On a 16 GB Mac it shows the memory sentence instead.
- **Returning to the dialog.** When the Plugin Manager posts `managedResourcesDidChange` after an install, an open dialog calls `refreshSets()`, so the person does not reopen it. Today the words tell them to.

## Tests

Each test is written to fail first.

**LungfishWorkflow.**

- `ReferenceSetDefaultsTests`: each offered row has a URL, size and sha256 for every file. Each row's genome and GTF sha256 equals the dev set's, pinned as constants from the table above. The five unoffered rows have `inApp == nil`. `named()` still finds all twelve.
- `ResumableFileDownloadTests` use a `URLProtocol` stub, with no network:
  - A whole file downloads in one go.
  - A resume gets a 206 and appends.
  - A 200 answer to a range request restarts from zero.
  - A changed `ETag` restarts.
  - A 416 with a full file goes to the check.
  - A file longer than its size stops.
  - A sha256 mismatch deletes the file and throws `checksumMismatch`.
  - A cancel keeps `.partial` and its JSON.
  - Three dropped connections end with words and keep the partial.
- `RNASeqCatalogInstallTests`:
  - The preflight refuses for disk, and for memory with `--index`. A host of 16 GiB refuses with the 16.6 GB sentence, and 32 GiB passes.
  - A file-URL catalog row pointing at the tiny fixture genome and GTF builds a set through the owner with the stand-in transcript deriver.
  - The download folder is gone afterwards.
  - A second install reuses the set.

**LungfishCLI.**

- `rnaseq catalog list --format json` has a golden.
- `rnaseq catalog install` with a test catalog override, an environment variable that only `LUNGFISH_TEST_*` builds read, writes the JSON events, and its recorded command replays (CLI-EQUIVALENCE).
- `rnaseq catalog remove` moves the set to the Trash and refuses on a set in use.

**LungfishRNASeqUI and LungfishApp.**

- The catalog view model shows each state from `catalog list` JSON: not installed, paused at N bytes, downloading, building, installed without an index, installed with an index, failed with words, and index refused for memory.
- `PluginManagerViewModel` begins the install row with the recorded argv, and Cancel reaches the runner.
- `RNASeqQuantSettings.blockingMessage` gives the two new messages, and the button callback fires.
- The dialog refreshes on `managedResourcesDidChange`.
- `ProjectDeletionPlannerTests` run in the landing filter if a new storage-root folder kind is registered (memory: registry kind trips the deletion pin).

**Real network, outside the unit tier.** One opt-in integration test, `LUNGFISH_NETWORK_TESTS=1`, installs the smallest row (`cynomolgus/refseq-GCF_000364345.1`, 0.83 GB). It cancels at about 30 percent, resumes, checks, builds, and compares `derived/transcripts.fa` with the dev set's sha256 (`4b38e4fc...` in `...refseq101-lge-211e715fcc2c`). It runs once in the lane, booked on GALAH-BOOKINGS, never in a gate.

**GUI walk rows.** The walk on a 16 GB laptop checks the empty state, Get Reference Sets…, download, Cancel then resume, the installed row, and the index refusal. A 32 GB or larger Mac walks the index build.

## Files to change

| File | Change |
|---|---|
| `Sources/LungfishWorkflow/RNASeq/ReferenceSetDefaults.swift` | Four new rows. `inApp: InAppOffer?` with sizes, assembly report, optional extras and dev studies |
| `Sources/LungfishWorkflow/RNASeq/ReferenceSetCatalog.swift` (new) | list, install (preflight, download, build, index) and remove, used by the CLI |
| `Sources/LungfishWorkflow/Download/ResumableFileDownload.swift` (new) | Range and If-Range resume, `.partial` sidecar, size and sha256 checks, retries, cancel |
| `Sources/LungfishWorkflow/RNASeq/SalmonIndexCache.swift` | A public `hasIndex(setID:k:decoys:)` file check for the dialog |
| `Sources/LungfishCLI/Commands/RNASeqCatalogSubcommand.swift` (new) and `RNASeqCommand.swift` | `rnaseq catalog list`, `install` and `remove` |
| `Sources/LungfishRNASeqUI/Catalog/RNASeqReferenceSetCatalogView.swift` (new) | The rows, the Download sheet with the index checkbox, the popover with notes and studies |
| `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift` | The section in the Databases tab |
| `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel+RNASeqReferenceSets.swift` (new) | State from `catalog list`, begin and cancel of the Operations rows |
| `Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift` | `show(tab:focus:)` |
| `Sources/LungfishApp/Services/CLIManagedToolsRunner.swift` | `installReferenceSet`, `buildIndex` and `removeReferenceSet` invocations |
| `Sources/LungfishApp/Views/FASTQ/FASTQOperationRNASeqQuantPane.swift` | The two new readiness messages, the button, refresh on change |
| `Sources/LungfishCore/Storage/ManagedStorageDeduplicator.swift` | Already skips `.partial`. Check that it skips `.partial.json` |
| `docs/user-manual/features.yaml` | The new section and its menu path |
| `Sources/LungfishWorkflow/AGENTS.md`, `Sources/LungfishRNASeqUI/AGENTS.md` | Entry points |
| Tests | As listed above |

## Step 0 for the lane, before code

These are measurements only, run under a GALAH-BOOKINGS slot, never under QUIET.

1. HEAD each of the 15 URLs. Record the status, `Content-Length`, `Accept-Ranges`, `ETag` and `Last-Modified`. Each size must equal the table.
2. Fetch `ERCC92.zip`, record its size and sha256, and check that the `ERCC92.fa` inside it is `ab9720a4...`.
3. Build `human/gencode-32` from GENCODE's own genome and compare `derived/transcripts.fa` with `d478640c...` (Finding 2). If they differ, BIO rules whether the row ships.
4. Build one NHP salmon index (cyno 6.0, 32 GB or larger Mac) to replace the "about 9 GB" figure.

## Questions for the panel

1. **ARCH, scope of `rnaseq catalog remove`.** Trash, not delete, is proposed. Should the first release leave removal out?
2. **UX.** A section in the Databases tab is proposed over a fourth tab. The backlog row's earlier idea was Import Center cards. The owner's words ("the way reference databases are downloaded today") point to the Plugin Manager.
3. **BIO.** Should ERCC92 ship as an optional extra in the first release, or wait for the extras row?
4. **Phase.** The phase that takes this on, per O75.

## Draft backlog raise (for the panel, not applied)

`RNASEQ-QUANT-NO-REFERENCE-SET-SCREEN` is S3 in `docs/plans/backlog-later.tsv:179`. The proposal raises it to S2. SCOPE-AND-DELIVERY:77 says S2 is "a common task fails". Counting reads is the RNA-seq feature's first task, and on a fresh install it cannot be done without a terminal. An open S2 lives in `BACKLOG.md` under Results and data (SCOPE-AND-DELIVERY:68). So the raise deletes the tsv line and adds this row there:

```
| RNASEQ-QUANT-NO-REFERENCE-SET-SCREEN | S2 | UX | No screen downloads or builds a reference set or its salmon index, so on a fresh install a person with no terminal cannot use Quantify RNA-seq Reads (`FASTQOperationRNASeqQuantPane.swift:105`), whose words name two CLI commands. Plan `docs/plans/2026-11-25-rnaseq-reference-set-screen.md`: a Databases-tab section in the Plugin Manager offering the seven development sets with resumable, sha256-checked downloads, the build through `rnaseq reference-set`'s owner as a CLI process, an optional index refused at 16 GB or less, and an empty state that opens the section. Raised from S3 on 2026-11-25 (owner asked for in-app downloads). | `~/lungfish-phase-records/phase-5-rnaseq/reviews/RS-DIALOG-UX.md:66` |
```

RNASEQ-GFFREAD-FIRST-ROOT notes the same missing route. It stays its own row.
