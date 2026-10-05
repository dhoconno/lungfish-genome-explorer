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
| L3 | Root file of merged reads followed by pairs | A mixed stream, split by name when the tool takes separate files |
| L4 | Chunked root (`source-files.json`) | Each chunk as single reads. Two chunks named as R1 and R2 are one mate pair only when the bundle records a short-read platform (Illumina, Element, Ultima or MGI). |
| L5a | `full` derivative | Read as a root file. A sidecar classification in the L3 form makes it a mixed stream, as for a re-imported `fastq merge` output. |
| L5b | `fullPaired` derivative | One mate pair |
| L5c, L5d | `fullMixed` derivative from merge or repair | Its roles. R1 and R2 files form a mate pair, merged files are merged reads and unpaired files are orphans. A missing role file stops the plan. |
| L5e | `fullFASTA` derivative | Single records |
| L6 | Virtual derivative | Materialized first, then read whole once and scanned with the merge evidence of every bundle it derives from. A truncated or unreadable materialization stops the plan. When the whole file holds pairs and single reads, it is mixed even if the bounded scan saw only pairs. When it holds no single read it is one interleaved pair, and when it holds no pair it is single reads, whatever merge or repair its lineage records. |

Five more rules decide the edge cases.

- A bundle whose recorded platform is Oxford Nanopore or PacBio is never paired, by file name or by content. `MatePairFileNaming.matePair(in:sequencingPlatform:)` applies the same rule. A chunked root that records `unknown` or no platform is not paired by file name either, since no importer writes a paired chunked root.
- A virtual child of a repair derivative carries only `repair` in its lineage. The resolver reads the parent's roles, so the reads without a mate in a child that holds pairs and single reads are orphans. A child that holds only pairs is one interleaved pair.
- A file is mixed only when its counts show pairs and single reads. A mixed stream whose known counts show no single read is one interleaved pair, and one whose counts show no pair is single reads (`ReadSetSource.resolvingStreamsByTheirCounts`).
- The platform is the `sequencingPlatform` field the FASTQ sidecar stores, read from the bundle or from the bundle it derives from.
- For TaxTriage, a file the user names is read as that file, even a chunk or one mate of a bundle, except the preview of a virtual bundle, which stands for its bundle. Two or more inputs that are every member file of one bundle are that bundle (`SamplesheetReadSetPlanner.bundleNamedByEveryMemberFile`), the rule `assemble` follows through `AssemblyInputSamples`.

## Tool capabilities

Each tool declares one capability in `ReadPairingCapabilityRegistry`, and the resolver gives it the matching form. The declarations sit in one file per family under `Sources/LungfishWorkflow/ReadPairing/Capabilities`, so the lane that moves a family onto the resolver edits only that family's file.

| Capability | Meaning | Tools |
|---|---|---|
| Both in one run, separate files | The tool takes R1, R2 and single-read files together | bowtie2 (`-1 -2 -U`), SPAdes (`-1 -2 --merged -s`), MEGAHIT (`-1 -2 -r`), SKESA (`--reads R1,R2 --reads S`), Kraken2 (staged, below) |
| Both in one run, one stream | The tool pairs adjacent records by name in one stream | minimap2 short-read preset, bwa-mem2 `-p`, fastp trims, deduplicate, primer removal, length filter, merge, repair, deinterleave, search, import clumpify, Illumina MHC genotyping |
| Pairs or single reads per run | The tool takes one kind per run and the results merge exactly | BBMap (two runs, then `samtools merge`) |
| Pairs only when every fragment is paired | The tool cannot pair part of a sample | EsViritu, TaxTriage, Viral Recon and the FASTQ operations that pair by position |
| Single reads only | The tool reads every record on its own | Flye, hifiasm, ONT MHC genotyping, error correction, 12S matching |

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
| The FASTQ operations, `ingest.clumpify` and `recipe.convert-interleaved-to-paired` | No | Each command. `fastq deduplicate`, `fastq primer-remove` and `fastq length-filter` split a mixed file by name through `FASTQSplitByNameRunner`, and the fastp trims through `FastpPairedRunner`. `fastq error-correct` corrects every record on its own, drops none and writes them in input order, so the mates of a pair stay side by side |
| `twelve-s.amplicon-matching` | No | 12S matching, open for Phase 2 |

## Combining

| Tool kind | How one sample gives one result |
|---|---|
| Mapping | The output is one sorted, indexed BAM. A one-run tool writes it directly. BBMap maps the pairs and the single reads in two runs, `samtools merge` joins the two sorted BAMs with one read group, and flagstat is computed on the merged BAM. |
| Assembly | One assembler run takes every read set at once with the flags in the capability table. One assembly results. `assemble` and Reassemble plan one sample through `AssemblyReadSetResolution`, and only a sample that still holds pairs and single reads after the split runs from the plan, so a subset that holds only one kind keeps its old resolution. `--read-layout` is refused for a bundle with a file per role, and a sample that names two sets of mate files is refused. |
| Kraken2 | One kraken2 run classifies pairs with `--paired` and single reads as single reads. A header-only mate file is staged beside each single-read file, so kraken2 reads it as a pair whose second mate is empty. That gives each single read exactly the call of a single-end run. The per-read output and the report are kraken2's own, and Bracken runs on that report. |
| Samplesheet pipelines | A sample holding only pairs is written as `fastq_1` and `fastq_2`. A sample that mixes merged reads and pairs goes to EsViritu, TaxTriage and Viral Recon with every read single-end. The result states that, and no read is dropped. `ReadSetPlan.singleReadReason` carries the statement, which the EsViritu summary lines, the Operations Panel log and the command's output show. EsViritu and TaxTriage take their files from `SamplesheetReadSetPlanner`, which joins several files of single reads into one, and `esviritu detect --read-format auto` and `taxtriage run` plan a bundle the way the app does. A Viral Recon samplesheet row may name a bundle, which the run plans with `viralrecon.illumina` and stages as gzip files. |

## Provenance

| Item | Rule |
|---|---|
| Recorded command | `lungfish-cli <tool> <inputs> <options>` with the inputs the user chose |
| Steps | Each split and interleave is a provenance step with its inputs, outputs and record counts, from `ReadSetStep.stepExecution(toolVersion:)`. An assembly from a split also records `readPairing` as `paired_files_with_single_reads` |
| Joins | Several files of single reads joined for EsViritu or TaxTriage are a `cat` step, recorded through the `.sources.json` sidecar of `SequenceInputConcatenation` |
| Run parameters | `ReadSetPlan.provenanceParameters` records the capability used, the fragment counts by kind and the reason mates ran as single reads, under `readSetPlan`. TaxTriage records one plan per sample under `read_set_plans` |
| Earlier runs | A plan holding only single reads or only pairs records nothing new (`recordsNothingNew`), so earlier runs compare byte for byte |

Kraken2 results made before this contract counted each mate of a paired derivative as its own read. They stay as they are on disk. The result viewer labels them as counted per read, and the Kraken2 lane (A2) implements that label.

## Open for Phase 2

| Item | State |
|---|---|
| 12S fragment counting | 12S matching counts each record on its own. Counting a pair once, and the rule for a pair whose mates match different species, are open. |
| Mate-aware demultiplex | Demultiplex assigns each record to a barcode on its own, so the two mates of a fragment can land in different barcodes. Both mates following the fragment's call is open. |

## Adding a tool

Declare the tool's capability in its family file under `Sources/LungfishWorkflow/ReadPairing/Capabilities`, with the same consumer ID as its `FASTQConsumerDeclaration`. `ReadPairingCapabilityRegistryTests` fails for a consumer without one. Then call `ReadSetResolver.plan(for:capability:progress:)` from the shared Workflow code the app and the CLI both run, and set `adopted` on the declaration. Add a behaviour test that runs a stand-in tool on the bundles `ReadSetFixtures` builds in `Tests/Support/LungfishTestSupport/ReadSetFixtures.swift` and checks which files and flags it received.

The resolver's own tests are in `Tests/LungfishWorkflowTests/ReadPairing`. `ReadSetResolverParityTests` checks that a sample of only single reads or only pairs gets the files `ResolvedSequenceInputs` gives it today, for every capability.
