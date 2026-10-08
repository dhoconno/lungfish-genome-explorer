# Tool output goldens

These goldens hold the stdout, exit code and named outputs of every external tool the Lungfish Genome Explorer (LGE) runs, each run through the LGE runner that serves the tool today. They are the entry criterion for Phase 2 of the architecture program (review finding R7, Phase 2.2 lane 1B). Phase 2 rewrites `NativeToolRunner`, `CondaManager.runTool` and `ProcessManager` on one `ToolProcess` primitive, and these files must stay byte for byte the same across that rewrite. A truncated samtools or bcftools stream, a lost exit code or a changed argv shows up here as a diff.

They were captured on main at 9f6dd500e with the managed tools of dependency set 2026.2 in `~/.lungfish`. The suite is `ToolOutputGoldenTests` in `Tests/LungfishWorkflowTests/ToolGoldens`, with the case table in `ToolGoldenCases+Native.swift` and `ToolGoldenCases+Conda.swift`.

## Running the compare

A SwiftPM test resolves the Stable channel storage `~/.lungfish-stable`, which holds no tools on the capture Mac, so point the run at the storage root the goldens were captured from.

```sh
LUNGFISH_STORAGE_ROOT=$HOME/.lungfish swift test --skip-update --build-system swiftbuild --filter ToolOutputGoldenTests
```

Each case is one test, named after its case ID with hyphens turned into underscores, so a failure names the tool. A failing case prints a unified diff of every golden file that changed. A case whose tool or database is not installed skips through `ToolAvailability`, and `LUNGFISH_REQUIRE_TOOLS=1` turns those skips into failures. The 108 tests take 25 to 35 seconds on the capture Mac, plus the build.

`testCaseTableHasUniqueIDsATestPerCaseAndNoStaleGolden` checks that every case has a test method and that every folder here belongs to a case in the table.

## Capturing

```sh
LUNGFISH_STORAGE_ROOT=$HOME/.lungfish LUNGFISH_CAPTURE_TOOL_GOLDENS=1 swift test --skip-update --build-system swiftbuild --filter ToolOutputGoldenTests
```

Capture runs every case twice, each time in a fresh scratch folder, and writes a case only when both runs produce the same golden files. A case that differs between its two runs fails and leaves its folder alone. Capture replaces the whole folder of each case it writes. Add `--filter ToolOutputGoldenTests/test_<case>` to capture one case. A golden changes only through a reviewed commit that says which cases changed and why.

## What a case folder holds

| File | Contents |
|---|---|
| `case.txt` | The case row, with tool, tier, runner, the runner call and the list of compared items, so a change to the table shows as a diff |
| `argv.txt` | One argument per line, starting with the executable. Pipeline stages are separated by a line holding a single pipe character. |
| `exit.txt` | The exit code, or one exit code per stage for a pipeline |
| `stdout` | The tool's stdout as the runner returned it |
| `stdout.sha256`, `stdout.summary` | Used instead of `stdout` when it is larger than 32 KiB. The summary gives the byte count, the line count and the first and last lines. |
| `stderr` | Only for error paths and for version probes. Success runs leave stderr out because it carries progress and timing. |
| `outputs/<name>` | A named output file, with the same 32 KiB rule. A BAM is stored as `<name>.records.sha256` (the SHA-256 and count of its `samtools view --no-PG` records) and `<name>.header` (`samtools view -H --no-PG`). `<name>.absent` records that a failed run left no output. |

The argv each runner records is the one it launches. `NativeToolRunner.run`, `runProcess` and `runWithFileOutput` return their argv in `NativeToolResult.arguments`, and the file output case adds a `>` line and the output path. `runPipeline` and `CondaManager.runTool` do not return an argv, so the suite records the one they build, the resolved tool path plus the stage arguments, and `micromamba run -n <env> <tool>` plus the arguments. `ProcessManager` cases record the executable and arguments of the `WorkflowEngineLaunch` they run. `conda-environment-probe` runs Python inside `micromamba run` and prints the argv the tool received and the environment it got, which guards the conda argv and environment directly.

## Inputs and scratch folders

Each run gets its own scratch folder under the system temporary folder. Fixture inputs from `Tests/Fixtures` are copied into its `in` folder, small generated inputs are written there, and the tool runs with `work` as its working folder. Staged inputs get the modification time 2020-01-01T00:00:00Z, so the gzip header pigz writes from the input's mtime is the same in every run. The folder is removed after the run.

The suite only reads the storage root. Conda cases run through a `CondaManager` built on the same conda root with no bundled micromamba and no shared package cache, so its `runTool` never copies the test bundle's micromamba over the installed one and never writes `.mambarc`. The `runTool` code path is the one `CondaManager.shared` runs. Nextflow cases set `NXF_HOME` inside the scratch folder so a probe never writes `~/.nextflow`. LGE itself checks that a `LUNGFISH_STORAGE_ROOT` override is writable by creating and removing a probe file in it (`ManagedStorageLocation.validateSelection`), so the root folder's modification time changes during a run while nothing inside it does.

## Normalization

Two path prefixes are replaced everywhere, in argv, stdout, stderr and text outputs.

| Token | Replaces |
|---|---|
| `<STORAGE_ROOT>` | The managed storage root, `~/.lungfish` on the capture Mac |
| `<SCRATCH>` | The run's scratch folder, in both the `/private/var` and the `/var` spelling |

Binary outputs are compared as they are. Three masks cover fields that change from run to run and that no argv choice removes. Each mask applies only to the cases that list it in `case.txt`.

| Mask | Cases | What it masks | Why it varies |
|---|---|---|---|
| `bracken-program-time` | `bracken-viral-species` | The time after `PROGRAM START TIME` and `PROGRAM END TIME` on stdout, as `<TIMESTAMP>` | Bracken prints the wall-clock start and end of `est_abundance.py` |
| `lofreq-file-date` | `lofreq-call` | The date in the `##fileDate` header line of the VCF, as `<DATE>` | LoFreq writes the run date into the header |
| `sra-log-timestamp` | `fasterq-dump-unknown-option`, `prefetch-unknown-option` | The date and time that start each stderr line, as `<TIMESTAMP>` | The SRA Toolkit stamps every log line with the UTC time |

Every other source of variation was removed by the argv instead of a mask.

| Choice | Cases | What it avoids |
|---|---|---|
| `--no-PG` | samtools view, sort and the BAM output views | A `@PG` line holding the samtools command line |
| `--no-version` | bcftools view, mpileup and call | Version and command headers with the run date |
| One thread (`-t 1`, `-j 1`, `-w 1`, `t=1`, `--threads 1`, `-@ 1`, `--cores 1`) | Every tool that takes a thread count | Output order that follows scheduling |
| `-Xmx1g` | Every BBTools case | A JVM heap the wrapper sizes from the free memory of the moment and prints on stderr |
| `--report=minimal` | cutadapt | The run time in the full report |
| `-v 1` | `minimap2-missing-input` | `[M::]` progress lines that carry CPU time and load |
| `-q` | bowtie2-build | Per-step timings at one-second resolution |
| `--quiet` | vsearch | A banner that names this Mac's memory and core count |
| An argument error as the error path | ribodetector, Flye, EsViritu, MEGAHIT | Logger lines stamped with the time, which a missing input file reaches |

### What stays unmasked

Some values are the same in every run on the capture Mac but would differ on another Mac or after a tool update. They stay unmasked, so the goldens are bound to the capture Mac and to dependency set 2026.2. They are every tool version string, the Python version in paths under the storage root, and the local time zone in the `created` line `nextflow -version` prints.

## Not covered

| Tool | Why |
|---|---|
| primer3, primalscheme3, olivar, varvamp | Run through `NativeToolRunner.runProcess`. Their packs are not installed on the capture Mac, so their cases skip and have no golden folder yet. |
| GATK (`gatk-core`), whatshap (`phasing`), freyja | Run through `CondaManager.runTool` and, for whatshap and freyja, `NativeToolRunner.run`. Not installed on the capture Mac, so their cases skip and have no golden folder yet. |
| IQ-TREE | `lungfish-cli tree infer iqtree` launches it with its own `Process`, outside the three runners Phase 2 rewrites |

Once a skipped tool is installed, capture its cases with the filter above and commit the new folders.

## Cases

| Case | Tool | Runner | Tier | Compared |
|---|---|---|---|---|
| `bbtools-bbduk-ktrim` | BBTools bbduk.sh | NativeToolRunner.run | light | argv, exit, stdout, bbduk.fq |
| `bbtools-bbmerge` | BBTools bbmerge.sh | NativeToolRunner.run | light | argv, exit, stdout, merged.fq, unmerged_1.fq, unmerged_2.fq |
| `bbtools-reformat-missing-input` | BBTools reformat.sh | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `bbtools-reformat-stdout` | BBTools reformat.sh | NativeToolRunner.run | light | argv, exit, stdout |
| `bbtools-reformat-stdout-conda` | BBTools reformat.sh | CondaManager.runTool | light | argv, exit, stdout |
| `bcftools-stats` | bcftools | NativeToolRunner.run | light | argv, exit, stdout |
| `bcftools-view` | bcftools | NativeToolRunner.run | light | argv, exit, stdout |
| `bcftools-view-missing-input` | bcftools | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `bedgraphtobigwig-convert` | bedGraphToBigWig | NativeToolRunner.run | light | argv, exit, stdout, coverage.bw |
| `bedgraphtobigwig-usage-error` | bedGraphToBigWig | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `bgzip-compress-to-file` | bgzip | NativeToolRunner.runWithFileOutput | light | argv, exit, stdout, test.vcf.gz |
| `bgzip-decompress-stdout` | bgzip | NativeToolRunner.run | light | argv, exit, stdout |
| `bgzip-missing-input` | bgzip | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `blastn-missing-query` | blastn | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `blastn-subject` | blastn | NativeToolRunner.run | light | argv, exit, stdout |
| `bowtie2-align-paired` | bowtie2 | CondaManager.runTool | light | argv, exit, stdout |
| `bowtie2-build` | bowtie2 | CondaManager.runTool | light | argv, exit, stdout, genome.1.bt2, genome.2.bt2, genome.3.bt2, genome.4.bt2, genome.rev.1.bt2, genome.rev.2.bt2 |
| `bracken-missing-database` | bracken | CondaManager.runTool | light | argv, exit, stdout, stderr |
| `bracken-viral-species` | bracken | CondaManager.runTool | light | argv, exit, stdout, bracken.tsv, bracken.kreport |
| `bwa-mem2-index` | bwa-mem2 | CondaManager.runTool | light | argv, exit, stdout, genome.0123, genome.amb, genome.ann, genome.bwt.2bit.64, genome.pac |
| `bwa-mem2-mem-paired` | bwa-mem2 | CondaManager.runTool | light | argv, exit, stdout |
| `clair3-missing-input` | clair3 | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `clair3-version` | clair3 | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `conda-environment-probe` | python (pysam env) | CondaManager.runTool | light | argv, exit, stdout |
| `cutadapt-adapter-trim` | cutadapt | NativeToolRunner.run | light | argv, exit, stdout, trimmed.fastq |
| `cutadapt-missing-input` | cutadapt | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `deacon-filter` | deacon | NativeToolRunner.run | light | argv, exit, stdout |
| `deacon-filter-conda` | deacon | CondaManager.runTool | light | argv, exit, stdout |
| `deacon-filter-missing-index` | deacon | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `deacon-index-build` | deacon | NativeToolRunner.run | light | argv, exit, stdout, genome.idx |
| `esviritu-error` | EsViritu | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `esviritu-version` | EsViritu | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `fasterq-dump-unknown-option` | fasterq-dump | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `fasterq-dump-version` | fasterq-dump | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `fastp-missing-input` | fastp | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `fastp-paired` | fastp | NativeToolRunner.run | light | argv, exit, stdout, trimmed_1.fq.gz, trimmed_2.fq.gz, fastp.json |
| `flye-error` | Flye | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `flye-version` | Flye | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `hifiasm-error` | hifiasm | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `hifiasm-version` | hifiasm | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `ivar-trim` | ivar | NativeToolRunner.run | light | argv, exit, stdout, trimmed.bam |
| `ivar-trim-missing-input` | ivar | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `kraken2-missing-database` | kraken2 | CondaManager.runTool | light | argv, exit, stdout, stderr |
| `kraken2-viral-paired` | kraken2 | CondaManager.runTool | light | argv, exit, stdout, classification.kreport |
| `lofreq-call` | lofreq | NativeToolRunner.run | light | argv, exit, stdout, lofreq.vcf |
| `lofreq-call-missing-input` | lofreq | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `mafft-auto` | mafft | CondaManager.runTool | light | argv, exit, stdout |
| `medaka-invalid-subcommand` | medaka | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `medaka-variant-no-arguments` | medaka_variant | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `medaka-version` | medaka | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `megahit-error` | MEGAHIT | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `megahit-version` | MEGAHIT | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `minimap2-missing-input` | minimap2 | CondaManager.runTool | light | argv, exit, stdout, stderr |
| `minimap2-sr-paired-stdout` | minimap2 | CondaManager.runTool | light | argv, exit, stdout |
| `nextflow-run-missing-script` | nextflow | ProcessManager.runAndWait | heavy | argv, exit, stdout, stderr |
| `nextflow-version` | nextflow | ProcessManager.runAndWait | heavy | argv, exit, stdout, stderr |
| `pigz-compress-to-file` | pigz | NativeToolRunner.runWithFileOutput | light | argv, exit, stdout, reads.fastq.gz |
| `pigz-missing-input-to-file` | pigz | NativeToolRunner.runWithFileOutput | light | argv, exit, stdout, stderr, reads.fastq.gz |
| `pipeline-bcftools-mpileup-call` | bcftools \| bcftools | NativeToolRunner.runPipeline | light | argv, exit, stdout |
| `pipeline-samtools-missing-input` | samtools \| samtools | NativeToolRunner.runPipeline | light | argv, exit, stdout, stderr |
| `pipeline-samtools-mpileup-ivar-variants` | samtools \| ivar | NativeToolRunner.runPipeline | light | argv, exit, stdout, ivar.tsv |
| `prefetch-unknown-option` | prefetch | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `prefetch-version` | prefetch | NativeToolRunner.run | heavy | argv, exit, stdout, stderr |
| `ribodetector-missing-output-argument` | ribodetector | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `ribodetector-paired` | ribodetector | NativeToolRunner.run | light | argv, exit, stdout, nonrrna_1.fq, nonrrna_2.fq |
| `ribodetector-paired-conda` | ribodetector | CondaManager.runTool | light | argv, exit, stdout, nonrrna_1.fq, nonrrna_2.fq |
| `samtools-depth-large` | samtools | NativeToolRunner.run | light | argv, exit, stdout |
| `samtools-faidx` | samtools | NativeToolRunner.run | light | argv, exit, stdout, genome.fasta.fai |
| `samtools-fastq-to-file` | samtools | NativeToolRunner.runWithFileOutput | light | argv, exit, stdout, reads.fastq |
| `samtools-flagstat` | samtools | NativeToolRunner.run | light | argv, exit, stdout |
| `samtools-idxstats` | samtools | NativeToolRunner.run | light | argv, exit, stdout |
| `samtools-runprocess-missing-input` | samtools | NativeToolRunner.runProcess | light | argv, exit, stdout, stderr |
| `samtools-runprocess-view-count` | samtools | NativeToolRunner.runProcess | light | argv, exit, stdout |
| `samtools-sort-by-name` | samtools | NativeToolRunner.run | light | argv, exit, stdout, name-sorted.bam |
| `samtools-view-header` | samtools | NativeToolRunner.run | light | argv, exit, stdout |
| `samtools-view-missing-input` | samtools | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `samtools-view-records-large` | samtools | NativeToolRunner.run | light | argv, exit, stdout |
| `savont-error` | savont | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `savont-version` | savont | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `seqkit-sliding-large` | seqkit | NativeToolRunner.run | light | argv, exit, stdout |
| `seqkit-stats` | seqkit | NativeToolRunner.run | light | argv, exit, stdout |
| `seqkit-stats-missing-input` | seqkit | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `skesa-error` | SKESA | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `skesa-version` | SKESA | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `snakemake-missing-snakefile` | snakemake | ProcessManager.runAndWait | heavy | argv, exit, stdout, stderr |
| `snakemake-version` | snakemake | ProcessManager.runAndWait | heavy | argv, exit, stdout, stderr |
| `spades-error` | SPAdes | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `spades-version` | SPAdes | CondaManager.runTool | heavy | argv, exit, stdout, stderr |
| `tabix-index-missing-input` | tabix | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `tabix-index-vcf` | tabix | NativeToolRunner.run | light | argv, exit, stdout, test.vcf.gz.tbi |
| `tabix-region-query` | tabix | NativeToolRunner.run | light | argv, exit, stdout |
| `trim-galore-missing-input` | trim_galore | NativeToolRunner.run | light | argv, exit, stdout, stderr |
| `trim-galore-single` | trim_galore | NativeToolRunner.run | light | argv, exit, stdout, test_1_trimmed.fq |
| `vsearch-fastx-uniques` | vsearch | NativeToolRunner.run | light | argv, exit, stdout, uniques.fasta |
| `vsearch-missing-input` | vsearch | NativeToolRunner.run | light | argv, exit, stdout, stderr |
