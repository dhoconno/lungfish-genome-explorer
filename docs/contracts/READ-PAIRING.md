# Read pairing

This contract says how Lungfish Genome Explorer (LGE) hands paired reads, merged reads and single reads to every tool. It covers the app and `lungfish-cli` alike. It implements owner decisions 1 and 2 of 2026-10-03. Decision 1 says that pairs which were not merged are used as pairs whenever a tool can take them. Decision 2 says that Kraken2 classifies pairs as pairs and honours merged reads too, with no extra step for the user.

The code lives in `Sources/LungfishWorkflow/ReadPairing`. `ReadSetResolver` makes the plan, `ReadSetPlan` holds it and `ReadPairingCapability` names what a tool can take. Lane A1 of Phase 1.5 added them. Each tool moves onto the resolver in its own lane, and until it does the tool keeps the handling its `FASTQConsumerDeclaration` records.

## Rules

| Rule | What it means |
|---|---|
| Pairs go to a tool as pairs | Mates of one fragment that were not merged reach the tool as a pair whenever the tool can take pairs. |
| Merged reads and single reads go as single reads | A merged read is one fragment. An orphan whose mate was removed, and a read from a single-end run, are each one fragment too. |
| One sample gives one result | When a sample holds pairs and single reads, the user sees one analysis. The section on combining says how. |
| Nothing is dropped or duplicated | Every read of every file in a bundle reaches the tool once. A tool that cannot take some layout refuses the run with a message. It never runs on a part of the sample. |
| One resolver decides | `ReadSetResolver` is the only code that decides pairing. The app and the CLI both call it. No app code, wizard or command decides pairing on its own. |
| The CLI does the work | The recorded `lungfish-cli` command names the bundle or files the user chose, and the CLI runs the resolver itself. Running the recorded command again writes every split and interleave again. |

## Read-set plans

The resolver turns each sample into a `ReadSetPlan` for one tool. A plan holds these parts.

| Part | Type | What it is |
|---|---|---|
| Mate pairs | `ReadSetMatePair` | An R1 file and an R2 file whose records correspond by position, or one file in which every R1 record is followed by its R2 record |
| Single reads | `ReadSetSingleReads` | One file with its role, which is merged, orphan, single-end, merged or orphan when a mixed file cannot tell them apart, or pairs run as single |
| Mixed streams | `ReadSetMixedStream` | One file of adjacent mate pairs and single reads, paired by fragment name, for a tool that pairs by name itself |
| Runs | `ReadSetRun` | The reads one tool run receives. Most plans have one run. |
| Fragment counts | `ReadSetComposition` | Fragments by kind. A pair counts once and a merged read counts once. |
| Steps | `ReadSetStep` | Every split by name and interleave by name the plan wrote, with record counts |

## How each bundle layout becomes a plan

| Row | Layout | Plan |
|---|---|---|
| L1 | Root single-end file | Single reads. A root holding only `preview.fastq` has no payload and stops the plan, because the preview is a subset. A root that is not chunked and holds two files named as R1 and R2 is one mate pair. |
| L2 | Root interleaved file | One interleaved mate pair |
| L3 | Root file of merged reads followed by pairs, or of pairs followed by the unpaired reads of an SRA run's third file | A mixed stream, split by name when the tool takes separate files |
| L4 | Chunked root (`source-files.json`) | Each chunk as single reads. Two chunks named as R1 and R2 are one mate pair only when the bundle records a short-read platform (Illumina, Element, Ultima or MGI). |
| L5a | `full` derivative | Read as a root file. A sidecar classification in the L3 form makes it a mixed stream, as for a re-imported `fastq merge` output. |
| L5b | `fullPaired` derivative | One mate pair |
| L5c, L5d | `fullMixed` derivative from merge or repair | Its roles. R1 and R2 files form a mate pair, merged files are merged reads and unpaired files are orphans. A missing role file stops the plan. |
| L5e | `fullFASTA` derivative | Single records |
| L6 | Virtual derivative | Materialized first, then read whole once and scanned with the merge evidence of every bundle it derives from. A truncated or unreadable materialization stops the plan. When the whole file holds pairs and single reads, it is mixed even if the bounded scan saw only pairs. When it holds no single read it is one interleaved pair, and when it holds no pair it is single reads, whatever merge or repair its lineage records. |

Seven more rules decide the edge cases. Four say which files and platforms may pair.

- A bundle whose recorded platform is Oxford Nanopore or PacBio is never paired, by file name or by content. `MatePairFileNaming.matePair(in:sequencingPlatform:)` applies the same rule. A chunked root that records `unknown` or no platform is not paired by file name either, since no importer writes a paired chunked root.
- The platform is the `sequencingPlatform` field the FASTQ sidecar stores, read from the bundle or from the bundle it derives from.
- For TaxTriage, a file the user names is read as that file, even a chunk or one mate of a bundle, except the preview of a virtual bundle, which stands for its bundle. Two or more inputs that are every member file of one bundle are that bundle (`SamplesheetReadSetPlanner.bundleNamedByEveryMemberFile`), the rule `assemble` follows through `AssemblyInputSamples`.
- `ReadSetResolver.plan(for:)` given a URL plans any path inside a bundle as the whole bundle. A tool that must read a named file alone plans a `ReadSetNamedInput` instead, through `plan(for:capability:progress:)`. A file inside a bundle (`.fileAlone`) is read with its own sidecar and none of its bundle's manifest, lineage or platform, as its copy outside every bundle would be read, and the preview of an unmaterialized derivative (`.previewOf`) plans its bundle, with a note sent through `progress`. 12S matching uses this entry, so naming a merge bundle's `merged.fastq` counts the merged reads alone.

Three say how recorded counts and merges decide a file's layout.

- A virtual child of a repair derivative carries only `repair` in its lineage. The resolver reads the parent's roles, so the reads without a mate in a child that holds pairs and single reads are orphans. A child that holds only pairs is one interleaved pair.
- A file is mixed only when its counts show pairs and single reads. A mixed stream whose known counts show no single read is one interleaved pair, and one whose counts show no pair is single reads (`ReadSetSource.resolvingStreamsByTheirCounts`).
- A merge that a file's lineage or recipe records makes adjacent mates mixed, with two exceptions. A recorded count of only pairs outranks that merge when the file holds every read of its bundle and counts as many R1 reads as R2 reads. A layout scan that read the whole of such a file, at most 100,000 records, and found only pairs outranks it too, because the scan counted every record. `FASTQReadLayoutClassifier.classify(inputURL:)` and `FASTQInputLayoutResolver.resolve` apply both, so the resolver, Viral Recon's one-file rows, the dialog's `--pairing` check, the EsViritu wizard and assembly's fallback agree. A recorded count of single reads keeps the file mixed, whether a derived manifest, a read manifest or the file's own sidecar records it, R1 and R2 counts that differ included. A virtual bundle's preview and a chunked root's first chunk never count for their bundle (`holdsEveryRead`).

## What writers record

The resolver plans from recorded counts, so every writer of a FASTQ file that holds pairs beside single reads records them.

| Writer | What it records |
|---|---|
| Every importer and read operation | The pairing label follows the count. A file whose count holds any merged or unpaired read records `single_end`, so no positional tool pairs it, and a file of pairs alone records `interleaved`. The batch importer (a run joined with its third file, a merge recipe's output), the FASTQ operations dialog's importer and Merge Into New Bundle all follow it. The Inspector's Pairing row names such a file "Pairs and single reads" with its counts, from the roles `FASTQMixedLayoutHint.recordedRoles(of:)` finds |
| A dialog `fastq merge` | Its single reads are merged reads, except the reads without a mate that its source recorded, which stay orphans, because `fastq merge` writes the merged reads, the unmerged pairs, then the source's orphans unchanged |
| A dialog `fastq repair` | Its single reads are orphans, except the merged reads its source recorded, which stay merged |
| Merge Into New Bundle | One joined file counted by role, each read without a mate taking its role from the input it came from, with the pairing those counts give (`FASTQMixedLayoutHint.readCounts(joining:)`). A root recorded single-end whose file holds pairs or records roles is joined rather than linked as a chunk, while inputs of single reads are linked as chunks as before. A plain input that does not end in a newline gets one, and a paired input's R1 and R2 files are checked by the recorded-pair rule before reformat.sh interleaves them, so mates out of step stop the merge |

## Tool capabilities

Each tool declares one capability in `ReadPairingCapabilityRegistry`, and the resolver gives it the matching form. The declarations sit in one file per family under `Sources/LungfishWorkflow/ReadPairing/Capabilities`, so the lane that moves a family onto the resolver edits only that family's file.

| Capability | Meaning | Tools |
|---|---|---|
| Both in one run, separate files | The tool takes R1, R2 and single-read files together | bowtie2 (`-1 -2 -U`), SPAdes (`-1 -2 --merged -s`), MEGAHIT (`-1 -2 -r`), SKESA (`--reads R1,R2 --reads S`), Kraken2 (staged, below), 12S matching (reads the files itself, below) |
| Both in one run, one stream | The tool pairs adjacent records by name in one stream | minimap2 short-read preset, bwa-mem2 `-p`, fastp trims, deduplicate, primer removal, length filter, merge, repair, deinterleave, search, import clumpify, demultiplex, Illumina MHC genotyping |
| Pairs or single reads per run | The tool takes one kind per run and the results merge exactly | BBMap (two runs, then `samtools merge`) |
| Pairs only when every fragment is paired | The tool cannot pair part of a sample | EsViritu, TaxTriage, Viral Recon and the FASTQ operations that pair by position |
| Single reads only | The tool reads every record on its own | Flye, hifiasm, ONT MHC genotyping, error correction |

A sample that holds only single reads or only pairs reaches every tool as it is found. The plan makes no step, so a tool that moves onto the resolver keeps its command byte for byte for such a sample.

## Which tools use the resolver

A consumer whose declaration sets `adopted` resolves its inputs through `ReadSetResolver`, in shared code the app and the CLI both run. The others keep the handling their `FASTQConsumerDeclaration` records.

| Consumer | Adopted | Where it plans |
|---|---|---|
| `map.minimap2`, `map.bwa-mem2`, `map.bowtie2`, `map.bbmap` | Yes | `MappingInputResolver` |
| `assemble.spades`, `assemble.megahit`, `assemble.skesa` | Yes | `AssemblyReadSetResolution` |
| `classify.kraken2` | Yes | `KrakenReadSetPlanner` |
| `classify.esviritu`, `classify.taxtriage` | Yes | `SamplesheetReadSetPlanner`, and `TaxTriageReadSetPlanner` for TaxTriage |
| `viralrecon.illumina` | Yes | `ViralReconReadPairing.prepareIlluminaSamples` |
| `genotype.illumina-mhc`, `genotype.ont-mhc` | Yes | `plannedInputReads` in `GenotypingInputFiles` |
| `assemble.flye`, `assemble.hifiasm` | No | `ResolvedSequenceInputs.resolveForAssembly`, every read on its own |
| The FASTQ operations, `ingest.clumpify` and `recipe.convert-interleaved-to-paired` | No | Each command. `fastq deduplicate`, `fastq primer-remove` and `fastq length-filter` split a mixed file by name through `FASTQSplitByNameRunner`, and the fastp trims through `FastpPairedRunner`. `fastq error-correct` corrects every record on its own, drops none and writes them in input order, so the mates of a pair stay side by side. `fastq demultiplex` (`fastq.demultiplex`) reads single-end files and separate R1 and R2 files as single reads, and interleaved and mixed files as pairs. It calls every record with cutadapt or the exact matcher, then places the mates of each fragment in its own pass (`DemultiplexMatePass`, `ExactBareMatePairer`), not through `FASTQSplitByNameRunner` |
| `twelve-s.amplicon-matching` | Yes | `TwelveSAmpliconMatchingWorkflow.resolveInputs`, with the `bothInOneRunAsSeparateFiles` capability. The workflow reads the planned files itself, R1 and R2 in step or one interleaved file, splits a mixed stream by name, and materializes a virtual derivative first |

MAFFT, the MAFFT pane's sequence count and the deprecated `fastq ont-genotype` are not registered consumers. MAFFT and its pane read every file of a bundle through `DerivedFASTQBundleInput.readableURLs`, the files the resolver plans with `.singleReadsOnly`, and `fastq ont-genotype` maps a bundle through `plannedInputReads` with the `genotype.ont-mhc` capability, as `fastq genotype --mode ont-sample-bundles` does.

## Combining

| Tool kind | How one sample gives one result |
|---|---|
| Mapping | The output is one sorted, indexed BAM. A one-run tool writes it directly. BBMap maps the pairs and the single reads in two runs, `samtools merge` joins the two sorted BAMs with one read group, and flagstat is computed on the merged BAM. |
| Assembly | One assembler run takes every read set at once with the flags in the capability table. One assembly results. `assemble` and Reassemble plan one sample through `AssemblyReadSetResolution`, and only a sample that still holds pairs and single reads after the split runs from the plan, so a subset that holds only one kind keeps its old resolution. `--read-layout` is refused for a bundle with a file per role, and a sample that names two sets of mate files is refused. |
| Kraken2 | One kraken2 run classifies pairs with `--paired` and single reads as single reads. A header-only mate file is staged beside each single-read file, so kraken2 reads it as a pair whose second mate is empty. That gives each single read exactly the call of a single-end run. The pinned wrapper decompresses every input as it does the first, so an input whose compression differs from the first's is read from a copy staged in the first's compression, recorded as the step `Lungfish Classification Input Compression Staging`. The per-read output and the report are kraken2's own, and Bracken runs on that report. Extraction and BLAST verification read a sample's R1 and R2 files in step, as kraken2 read them. |
| 12S matching | The workflow counts fragments. A merged read, an orphan and a single-end read count once. An unmerged pair counts once when both mates give the identical call, R2 read as its reverse complement, and then counts as its R1 read. A pair whose mates disagree (`different_targets`, `different_candidates`, `one_mate_unresolved`, `one_mate_ambiguous`) is left out of every count but `input_reads` and tallied as `discordant_pairs`. A read without a mate whose name marks mate 2 (`/2`, or a Casava `2:` comment) is read as its reverse complement too, except in a file recorded as merged reads or a long-read run, while `.1` and `.2` suffixes are read as sequenced. Separate R1 and R2 files are read in step and checked with `FASTQPairInterleaver.recordedMates`, so legacy `.1`/`.2` and `_1`/`_2` mates pair, unmarked names pair by position with a warning, and contradictory mate numbers stop the run. Abundance reassignment then runs over fragments as before, and `read-fate.json` records `pairedFragments`. |
| Demultiplex | Every record is called, then the mates of each fragment follow the fragment's call. Mates that agree, or one called mate beside an unassigned one, give that barcode. Mates called different barcodes send the pair to unassigned whole, and merged and orphan reads keep their own call, so no pair is split between bundles. Virtual bundles list both mates and key their trims by fragment. `demux-manifest.json` and the provenance record the calls under `mateCalls`. |
| Samplesheet pipelines | A sample holding only pairs is written as `fastq_1` and `fastq_2`. A sample that mixes merged reads and pairs goes to EsViritu, TaxTriage and Viral Recon with every read single-end. The result states that, and no read is dropped. `ReadSetPlan.singleReadReason` carries the statement, which the EsViritu summary lines, the Operations Panel log and the command's output show. EsViritu and TaxTriage take their files from `SamplesheetReadSetPlanner`, which joins several files of single reads into one, and `esviritu detect --read-format auto` and `taxtriage run` plan a bundle the way the app does. A Viral Recon samplesheet row may name a bundle, which the run plans with `viralrecon.illumina` and stages as gzip files. |

## Provenance

| Item | Rule |
|---|---|
| Recorded command | `lungfish-cli <tool> <inputs> <options>` with the inputs the user chose |
| Steps | Each split and interleave is a provenance step with its inputs, outputs and record counts, from `ReadSetStep.stepExecution(toolVersion:)`. An assembly from a split also records `readPairing` as `paired_files_with_single_reads` |
| Joins | Several files of single reads joined for EsViritu or TaxTriage are a `cat` step, recorded through the `.sources.json` sidecar of `SequenceInputConcatenation` |
| Run parameters | `ReadSetPlan.provenanceParameters` records the capability used, the fragment counts by kind and the reason mates ran as single reads, under `readSetPlan`. TaxTriage records one plan per sample under `read_set_plans`. 12S matching records `readSetPlans` and per-sample `fragmentCounts`, with `discordantPairsByReason`, when a run read pairs or wrote a step, and demultiplex records `mateCalls` for paired input |
| Staged files | A tool step that read files the run staged and deleted, such as kraken2 reading interleaved halves, header-only mates or compression copies, records no `durableReplayArgv`, and neither does the 12S read-set split step, whose argv describes the split rather than a command. Its argv still records what ran, and the run's top-level recorded command reproduces it |
| Earlier runs | A plan holding only single reads or only pairs records nothing new (`recordsNothingNew`), so earlier runs compare byte for byte |

Kraken2 results made before this contract counted each mate of a paired derivative as its own read. They stay as they are on disk. The result viewer labels them as counted per read, and the Kraken2 lane (A2) implements that label.

## Settled in Phase 2.1

The two items this contract left open for Phase 2 are done, and the Combining table states their rules. 12S matching counts a pair once when its mates agree (owner rule of 2026-10-05), and demultiplexing places both mates of a fragment by the fragment's call. Results from merged reads alone count as they did before.

## Adding a tool

Declare the tool's capability in its family file under `Sources/LungfishWorkflow/ReadPairing/Capabilities`, with the same consumer ID as its `FASTQConsumerDeclaration`. `ReadPairingCapabilityRegistryTests` fails for a consumer without one. Then call `ReadSetResolver.plan(for:capability:progress:)` from the shared Workflow code the app and the CLI both run, and set `adopted` on the declaration. Add a behaviour test that runs a stand-in tool on the bundles `ReadSetFixtures` builds in `Tests/Support/LungfishTestSupport/ReadSetFixtures.swift` and checks which files and flags it received.

The resolver's own tests are in `Tests/LungfishWorkflowTests/ReadPairing`. `ReadSetResolverParityTests` checks that a sample of only single reads or only pairs gets the files `ResolvedSequenceInputs` gives it today, for every capability.
