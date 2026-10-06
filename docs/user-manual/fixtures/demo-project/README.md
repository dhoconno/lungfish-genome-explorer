# The screenshot project (contributor note)

This folder builds the screenshot project, a contributor tool and not reading
material. Readers of the manual never build it. They download the demo
projects with **Help > Demo Projects…** in Lungfish Genome Explorer (LGE), as
the Practice data for this manual section of The Lungfish Genome Explorer
Project chapter explains, and the chapters that read finished results use the
Human Mapping and Variants (with results) demo project. The glossary entry
"Screenshot project" points here. The directory keeps its old name,
`demo-project`, because screenshot recipes and scripts refer to it by path.

`build-demo-project.sh` populates the screenshot project that older screenshot
recipes open. It drives `lungfish-cli` over the committed fixtures in
`docs/user-manual/fixtures/` and fills an LGE project with a reference
sequence, a mapping with two variant tracks, an assembly, an alignment with
its tree, a Kraken 2 classification, and an NVD import. New captures of the
Foundations chapters use the Human Mapping and Variants (with results) demo
project instead, so its track and bundle names match what readers see.

## Running

1. Create the project in the app first. The CLI cannot create a project
   store, only the app can. Choose File then New Project, name it
   "LGE Manual Demo", and save it under the demo root
   (`~/Desktop/lge-docs` by default). If the save dialog put it somewhere
   else, move the `LGE Manual Demo.lungfish` folder into that directory
   afterward, or set Where to that folder before saving. Close the
   project in the app.
2. Run the script from anywhere, with the project closed in the app for
   the whole run.

   ```bash
   bash docs/user-manual/fixtures/demo-project/build-demo-project.sh
   ```

   The script checks for a project store at `LGE Manual Demo.lungfish/.project.db`
   and exits with status 2 and an instruction to repeat step 1 if it is
   missing. It never creates the project directory itself.

The script is idempotent. Every step checks for its own output first and
skips when it is already there, so a re-run after a failure resumes rather
than rebuilding. A second run over a finished project takes under a second.

## What the project contains

The project is `LGE Manual Demo.lungfish` under the demo root. The path has
to end in `.lungfish` because the CLI rejects a `--project` that does not.

| Folder | Contents |
| --- | --- |
| `Imports/` | `HG002` and `HG002-chrM` paired Illumina samples, plus `SRR36291587` |
| `Reference Sequences/` | `HBB.lungfishref` and `chr20_10.0-10.5Mb.lungfishref` |
| `Analyses/mapping-HG002/` | minimap2 short-read mapping of HG002 against chr20 |
| `Analyses/Multiple Sequence Alignments/` | the primate mitochondrial MSA |
| `Phylogenetic Trees/` | the IQ-TREE tree built from that MSA, in the folder the app uses for trees |
| `Analyses/kraken2-SRR36291587/` | Kraken 2 classification of the SARS-CoV-2 reads |
| `Analyses/nvd-demo/` | the NVD BLAST demo import |
| `Analyses/HG002-chrM/` | SPAdes assembly of the mitochondrial reads |

The generated sample sheet and the fetched SARS-CoV-2 reads live outside the
project, in the sibling `LGE Manual Demo.build/` folder next to
`LGE Manual Demo.lungfish` under the demo root. Keeping them there means
they never show up in the app's sidebar or in a screenshot. See
"The reads that are not committed" below.

The chr20 bundle carries three tracks. The alignment track `hg002-minimap2`
is named "HG002 minimap2" in the interface, and two variant tracks sit on
top of it, "HG002 bcftools" with 1,056 variants and "HG002 LoFreq" with 862.
The track identifier is pinned with `--track-id` so later steps and the
screenshot recipes can name it without reading it back.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `LUNGFISH_CLI` | `.build/debug/lungfish-cli` in the primary checkout | The CLI binary to drive |
| `LUNGFISH_DEMO_ROOT` | `$HOME/Desktop/lge-docs` | Directory that will hold the project |
| `LUNGFISH_KRAKEN_DB` | `Viral` | Name of an installed Kraken 2 database |

`lungfish-cli conda db list` shows which databases are installed. This run
used `Viral`, which was already present and is the right size for a
SARS-CoV-2 sample.

## How long each step takes

Measured on the development Mac over one run from an empty project, with the
fixtures and the Kraken 2 database already on disk. The whole script is
about a hundred seconds, and nothing in it is slow enough to need a
background run.

| Step | Time | Notes |
| --- | --- | --- |
| 0 SARS-CoV-2 reads | 5s | Only on the first run, skipped afterwards |
| 1 reads | 15s | Three samples through `import-fastq` |
| 2 references | under 1s | Two `import fasta` calls |
| 3 mapping and variants | 17s | minimap2 plus bcftools plus LoFreq |
| 4 assembly | 26s | SPAdes on the mitochondrial reads |
| 5 alignment and tree | 38s | MAFFT then IQ-TREE |
| 6 classification | 3s | Kraken 2 against the Viral database |
| 7 NVD import | under 1s | Ten BLAST hits across three samples |
| 8 Viral Recon | not run | See below |

Total for a full build is 100 seconds once the reads are cached. A re-run
over the finished project is a second.

## The reads that are not committed

The SARS-CoV-2 fixture commits no FASTQ. Step 0 fetches run SRR36291587
with `fetch sra download ... --use-toolkit`, which writes the uncompressed
`SRR36291587_1.fastq` and `SRR36291587_2.fastq` into `_scratch/sra` inside
the sibling `LGE Manual Demo.build/` folder next to the project. They stay
there and every later run skips the download. The files are about 56 MB
each and are deliberately kept out of the repository, which is why they
live next to the project rather than in the fixture directory or inside
the project itself, where the app's sidebar would show them.

## Viral Recon is a manual step

Step 8 does not run Viral Recon. It checks whether Docker is reachable,
prints a note, and stops. Run the pipeline once by hand so the Viral Recon
chapter has a result to photograph.

1. Start Docker Desktop and wait for it to report that the engine is running.
2. Open the demo project in the app.
3. Choose Tools then Variant Calling then Viral Recon (SARS-CoV-2).
4. Pick the `SRR36291587` sample and the MN908947.3 reference.
5. Run the wizard and leave the app open until the operation finishes.

The run takes far longer than anything the script does, so start it when
you can leave the machine alone. Record the wall-clock time here once it
has been run, because the manual quotes it to set the reader's expectation.

## Corrections made to the drafted commands

Every command was checked against the help dumps in
`docs/user-manual/reviews/fidelity-2026-09/cli-help/` before it was run, and
five of them needed changing.

`import fasta -o` takes the project directory, not the reference folder. It
creates its own `Reference Sequences` subfolder inside whatever it is
given, so passing the reference folder produced a nested
`Reference Sequences/Reference Sequences/`. The script now passes the
project. The same command sanitises the bundle filename, so the reference
named "chr20 10.0-10.5Mb" lands as `chr20_10.0-10.5Mb.lungfishref` and the
skip check has to use the sanitised name.

`tree infer iqtree` requires `--output` with an explicit
`.lungfishtree` path. `--project` alone is not enough.

`variants call --alignment-track` wants a track identifier rather than a
name. `bam adopt-mapping` accepts `--track-id`, so the script sets
`hg002-minimap2` rather than reading an identifier back. The idempotency
checks still read `manifest.json` inside the `.lungfishref` bundle, where
`alignments[]` and `variants[]` each carry an `id` and a `name`.

`import-fastq` pairs R1 with R2 only for the underscore-delimited
conventions `_R1_001`, `_R1`, and `_1`. The `hg002-chr20` and `human-mito`
fixtures use dot-delimited `.R1` and `.R2`, which the detector read as four
separate single-end samples. The script now writes a `sample,r1,r2` sample
sheet into the sibling build folder's `_scratch` and imports through
`--samplesheet`, which states the pairing and also gives the samples the
short names the manual uses.

## Steps that did not complete

Nothing failed outright, but one step finished in a degraded state.

Kraken 2 classification succeeds and writes both `classification.kreport`
and `classification.kraken.gz`. It classifies 98.3 percent of the 85,199
reads and names *Betacoronavirus pandemicum* as the dominant species, which
is the correct answer for this sample. Bracken profiling does not produce a
`classification.bracken` file, and because of that `conda classify` exits
with status 64 even though the classification itself is sound. The Viral
database does carry the `kmer_distrib` files Bracken needs, so this is not a
missing install. The likely cause is that the sample resolves to a single
species at the profiled rank, which leaves Bracken with nothing to
redistribute.

The script treats that case as a warning. It checks for the Kraken 2 report
and continues when the report is there, and fails only when no report was
written. Before that guard was added, the non-zero exit killed the script
under `set -e` and step 7 never ran.

Anyone writing the Kraken 2 chapter should screenshot the Kraken 2 report
rather than a Bracken abundance column, because there is no Bracken output
in this project.

## September 7 fixture completion additions

The final step of `build-demo-project.sh` invokes `extend-demo-fixtures.py`.
Run the helper directly to add only these fixtures to an already open demo
without rerunning mapping, classifiers, or assembly from the main script.
It never rebuilds the demo and does not write `.project.db`.

```bash
python3 docs/user-manual/fixtures/demo-project/extend-demo-fixtures.py \
  ont hifi barcode ont-run flye amplicon nao czid 12s benchmark sra sra-import
```

The same `LUNGFISH_CLI` and `LUNGFISH_DEMO_ROOT` overrides apply. Successful
steps with their recorded output present are skipped on later runs. This
incremental rerun was verified on September 7. A destructive rebuild of the
live demo was deliberately not performed while screenshot work was active.

New paths relative to `LGE Manual Demo.lungfish` are listed below.

| Fixture | Output | Observed result |
| --- | --- | --- |
| Public HG002 ONT mitochondrial reads | `Imports/HG002.chrM.ont.lungfishfastq` | 950 reads |
| Public HG002 HiFi mitochondrial reads | `Imports/HG002.chrM.hifi.lungfishfastq` | 363 reads |
| Public HG002 ONT run folder | `ont-run/barcode01.lungfishfastq` | 950 unprocessed reads with native run and child-bundle provenance |
| Public HG002 Flye assembly | `Analyses/HG002-chrM-flye` | Human mitochondrial ONT reads assembled by Flye 2.9.6 with four threads |
| Public HG002 ONT barcode file | `Imports/HG002_chrM_pass_barcode01_0.lungfishfastq` | Barcode01 FASTQ imported with platform ONT |
| Constructed HG002 12S teaching read subset | `Imports/HG002-12S-amplicon.lungfishfastq` | 631 reads |
| Primate 12S exact matching result | `Analyses/HG002-12S.lungfish12s` | 173 oriented reads, 110 human matches, 63 unresolved |
| Existing NAO-MGS test report | `Analyses/naomgs-nao-mgs-demo` | 35 hits, five samples, four distinct taxa |
| Existing CZ-ID test report | `Classifications/czid-demo.lungfishtax` | Three rows, reported pipeline 8.4 |
| Public HG002 GIAB benchmark | `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` | 961 variants, companion index |
| Public SRA run SRR32909537 | `Imports/SRR32909537.lungfishfastq` | Paired FASTQ downloaded through ENA and imported |

NAO-MGS and CZ-ID are existing repository test reports. They are display
fixtures, not newly executed surveillance analyses or newly downloaded public
study outputs. The NAO report has four distinct taxa. Do not describe it as
seven taxa to match the older capture specification. Reference fetching is
explicitly disabled for this report import.

The barcode CLI step imports the supplied barcode01 FASTQ directly. It does
not claim to recreate the GUI ONT Run Folder workflow or its run-level
metadata. Use the original `hg002-long-reads/ont-run` folder when capturing
that import sheet. The separate `ont-run` step imports the run folder through
`lungfish-cli fastq import-ont` and writes the native run-level metadata directly
to `ont-run`, reproducing the captured folder layout without a processing
recipe. The `flye` step uses the public HG002 ONT mitochondrial FASTQ. Run only
`python3 docs/user-manual/fixtures/demo-project/extend-demo-fixtures.py ont-run flye`
to create or verify those two human fixtures. Existing outputs are verified
against their native provenance and skipped even if they predate the helper
audit. Missing metadata, missing payloads, or mismatched file identities stop
the step instead of overwriting an existing result. The 12S fixture is the constructed teaching subset described
in `../primate-12s/README.md`, not a published amplicon sequencing study.
The benchmark is the coordinate-shifted public GIAB subset documented in
`../hg002-chr20/README.md`, imported as a standalone VCF rather than a newly
called or simulated variant set.

Every command retains native CLI provenance. The helper also writes the
actual argv, shell command, CLI version and binary SHA-256, runtime identity,
options, input/output SHA-256 and byte sizes, status, wall time and logs into
`LGE Manual Demo.build/fixture-provenance/<step>/execution.json`. Bundles and
result directories receive a copy named `fixture-execution.json`. Native
provenance retains resolved thread counts and managed tool environments.
The SRA bundle additionally keeps `provenance/source-sra-download.json` with
the original download receipt and final imported payload checksums. Downloaded
FASTQs remain under `LGE Manual Demo.build/_scratch/SRR32909537`.

Verification found all 43 native output records across the eight new bundles
at their final stored paths with matching SHA-256 values and successful exit
status. The verification record lives at
`LGE Manual Demo.build/fixture-provenance/verification.json`. Python syntax,
shell syntax, and the complete incremental helper rerun passed. No screenshot,
chapter, recipe, or MHC MiSeq cohort project files are modified by this helper.

The ONT run and Flye additions were separately verified at their final paths.
ONT has two linked native sidecars and five distinct recorded files, and Flye
has one sidecar and five recorded files. Their recorded SHA-256 values, byte
sizes, options, versions, runtime identities, exit status, and wall time were
checked. The existing-output path was exercised with an unavailable CLI path
to confirm it verifies and skips without starting another scientific run.

## Simulated MHC teaching result

The `mhc-simulated` extension creates two explicitly simulated primate MHC read mixtures from accession-verified public reference sequences, then uses native import and genotype-only workflows. See [the fixture README](../mhc-simulated/README.md) for provenance, expected counts, validation, and the GUI capture route. Run this step independently with `python3 extend-demo-fixtures.py mhc-simulated`. The GUI-compatible result is `Analyses/SIMULATED-MHC-bundle-validated`, using `SIMULATED-MHC-annotated-reference`. The raw-FASTA baseline remains at `Analyses/SIMULATED-MHC-native-teaching`.

## Linked Hello World workflow

Run `python3 extend-demo-fixtures.py hello-workflow` to copy the shipped `Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg` unchanged to `~/Desktop/lge-docs/hello-world-nextflow.lungfishflowpkg`. Link that package from the Workflow Library for the User Workflows screenshot. Its Nextflow runner, required reference and FASTQ inputs, and declared output satisfy the app's Runnable contract. Linking does not execute the workflow.

The helper verifies the manifest fields and entrypoint, runs the CLI's static workflow validation, and records source/output sizes and checksums, validation output, tool version, runtime, and elapsed time in the copied package's `fixture-copy-provenance.json`. Existing copies are verified without being overwritten or executing Nextflow. This preparation step does not generate scientific output.

## Validate a separate project

The Python extension accepts `--project` for an existing project created in the app. Its default remains `LGE Manual Demo.lungfish` under `LUNGFISH_DEMO_ROOT`. An explicit project writes execution audits into the adjacent project-named `.build/fixture-provenance` folder. The real `.project.db` guard still applies, and the helper does not create or copy a project database.

For an isolated human, primate, and simulated fixture check, create `LGE Manual Rebuild Check.lungfish` in the app, close that project, then run the following from the repository root.

```sh
python3 docs/user-manual/fixtures/demo-project/extend-demo-fixtures.py \
  --project "$HOME/Desktop/lge-docs/LGE Manual Rebuild Check.lungfish" \
  ont hifi barcode ont-run flye amplicon 12s benchmark mhc-simulated
```

This subset requires the existing committed and prepared human/primate inputs documented by the individual fixtures. It omits the shell builder's viral steps, remote SRA fetching, classifier report imports, and the shell-only mapping, SPAdes, alignment, and tree steps. Do not invoke the full shell builder to perform this bounded check. The `hello-workflow` step copies a linked package beside the project rather than inside it and is independently verified.
