# Provenance compatibility corpus

This folder freezes the provenance sidecars that Lungfish Genome Explorer (LGE) has to keep reading. Each case is a file exactly as an older build wrote it, or as a current writer writes a shape that Phase 2.4 stops writing. The tests read every case through the production readers and compare what the readers say with reviewed expectations. A write-side change that alters what a reader says about old bytes fails those tests.

The folder belongs to Phase 2.4, lane W1A. Write-side lanes never edit it.

## Rules

- A case is never edited. MANIFEST.tsv pins every file by SHA-256, and `ProvenanceCompatCorpus.verifyManifest()` fails when a byte moves.
- Production code never reads a tracked file in place. `ProvenanceCompatCorpus.materialize(_:)` copies a case into a fresh temporary `.lungfish` project and the tests read the copy, because some readers write.
- Expectations are facts, not whole decoded envelopes. Decoding fills values from the reading Mac, so the facts keep only what the bytes say (see Facts below).
- No file here holds an account home path, a macOS per-user cache path or a system temporary path. The capture helper refuses to freeze bytes that do.
- A recapture of any expectation is its own reviewed commit, made after the change that caused it.

## Layout

The folder holds the following files.

```
README.md                    this file
MANIFEST.tsv                 one row per case
cases/<id>/...               the frozen bytes, laid out as they sit in a project
expected/<id>.facts.json     the reviewed facts of each case
```

MANIFEST.tsv has a header row and six tab-separated columns. They are the case id, the path, the shape (S1 to S8), the filename family (F01 to F45), the origin and the SHA-256. The shape and family codes are the ones in the Phase 2.4 reader inventory. A path that starts with `repo:` points at a tracked file elsewhere in the repository, which the corpus references in place instead of duplicating.

`ProvenanceCompatCorpus.verifyManifest()` reads only `cases/` and `expected/`, so another folder may sit beside them.

## Cases

| Case | Shape | Family | What it is |
|---|---|---|---|
| s1-db-receipt-kraken2-viral | S1 | F01 | Real install receipt of the Kraken2 viral database, written by Lungfish 2026.9.1 (4354) |
| s2-analysis-kraken2-fixture | S2 | F01 | Tracked synthetic backfill of a Kraken2 analysis fixture, an envelope without the compat keys |
| s3-ncbi-fetch-alpha11 | S3 | F04 | Real bare run written by lungfish-cli 0.4.0-alpha.11 for an NCBI fetch, referenced in place |
| s4-mcm-mhcref-shipped | S4 | F01 | Real primitive record shipped inside the MCM haplotyping reference bundle |
| s4-msa-mafft-2026-05 | S4 | F01 | Real primitive record that align mafft wrote for an alignment bundle in May 2026 |
| s1-cancelled-single-step | S1 | F01 | Captured run-bearing envelope from the CLI single-step helper, status cancelled while the last step exited 0 |
| s1-recorder-readsetplan | S1 | F01 | Captured run-bearing envelope from ProvenanceRecorder, with a readSetPlan parameter and a save that passes explicit options |
| s1-canonical-envelope-run | S1 | F01 | Captured run-bearing envelope from WorkflowRun.canonicalEnvelope() written through ProvenanceWriter |
| s3-write-sidecar-bare-run | S3 | F01 | Captured bare run from WorkflowRun.writeSidecar, the same run as the case above |
| s3-gatk-container-bare-run | S3 | F01 | Captured bare run from the real GATKPipelineExecutor, two steps that each carry a container image and digest |

The origin column of MANIFEST.tsv says where each file came from and names every edit. Of the five real or tracked files, three are exactly the source bytes (two copies and the one file referenced in place). The other two carry the account edits described next.

The last five cases were captured once, at commit 81e89a306, from the writers as they stood before Phase 2.4 changed any of them. `ProvenanceCompatShapeCaptureTests` and `ProvenanceCompatCLICaptureTests` wrote them inside a temporary project, so their paths are `@/` project paths and `<tool-root>` and `<storage-root>` placeholders, as in a real project. Their runtime identity names the test host that ran the capture. The cases s1-canonical-envelope-run and s3-write-sidecar-bare-run are the same run written both ways, so a writer that moves from `writeSidecar` to `canonicalEnvelope()` can be compared fact by fact. The GATK case came from the real executor with an injected runner, because a containerized bare run is the shape where a dropped image digest would otherwise go unnoticed.

The run behind each captured case is a reusable scenario, in `ProvenanceCompatScenarios` (LungfishTestSupport) and `ProvenanceCompatCLIScenarios` (LungfishCLITests). `ProvenanceCompatScenarioTests` and `ProvenanceCompatCLIScenarioTests` run each scenario again and check that its facts equal the frozen case's facts, ignoring the host values and the run's own wall time. A lane that changes a writer calls the same scenario after the change and compares the same way, so it never copies a run and lets the copy drift.

### The account edits

Two real files held the home folder of the account that wrote them. The folder was replaced by `/srv/corpus`, in the plain spelling and in the escaped-slash spelling that JSON writers emit. The replacement keeps each path absolute, so the reader's rules for paths under a `.lungfish` folder behave as they did on the original bytes.

The first version of the corpus used `/home/corpus`. macOS mounts `/home` with autofs, so every check of a path below it asks the automounter. A writer or rehydrator that resolves 26 or 35 such paths took tens of seconds on a Mac. `/srv` does not exist on macOS, so the same checks fail at once. A new case that needs a placeholder folder must pick one that no Mac mounts.

- s4-msa-mafft-2026-05 has 26 places in the escaped spelling.
- s1-db-receipt-kraken2-viral has 35 places in the escaped spelling.

The receipt also held the account name itself in two `user` values, one under `runtime` and one under `runtimeIdentity`, because older builds recorded the account. An account name must not enter a committed fixture, so both values were replaced by `lge-user`. The key stays, so the readers still read a legacy `user` field. These edits are the only changes made to any case, and the origin column of MANIFEST.tsv names each of them.

The tracked alpha.11 fetch record cannot be edited here, and it still holds the home paths its writer recorded. The facts rewrite any account folder to `<home>`, so the expectation holds on every Mac.

## Facts

`ProvenanceCompatFacts` (Tests/Support/LungfishTestSupport) projects what the production readers say about one sidecar. This is facts version 2. It records which step of the tolerant reader accepts the bytes, whether the strict readers accept them, what `ops stats` makes of them, the top-level `status` string as the bytes hold it, the workflow and tool names and versions, argv, the durable replay argv, the reproducible command, the exit status, the wall time, the options, the files, the outputs and the steps.

Each step records its argv, durable replay argv, reproducible command, the step graph as positions, exit status, wall time, peak memory, resolved options and the container image, container digest and conda environment its own bytes hold. The facts also record the steps as `legacyWorkflowRun()` shows them, once as the readers get them (`legacyRunSteps`) and once rebuilt from the envelope's own steps (`canonicalRunSteps`, the view the exporters read), each with its container image and digest. The envelope step drops a step's container identity unless the step has a runtime identity of its own, so these views are where a bare run's container identity shows.

The projection leaves out every value a reader fills from the reading machine, which are the executable path, process id, architecture, dependency set, app version, operating system, workflow version and creation date. Such a key appears under `recorded` only when the source bytes hold it. Paths are rewritten to `<project>`, `<tool-root>`, `<storage-root>`, `<tmp>` and `<home>`. A file option recorded as a relative path keeps its relative form, so the facts do not depend on the working directory.

Each expected facts file is written once, with `LUNGFISH_CAPTURE_PROVENANCE_FACTS=1`, on unchanged code. A reviewer reads it against the source bytes. Afterwards `ProvenanceCompatReaderTests` compares the live facts with it byte for byte. The gate never sets the variable.

A lane that changes a writer compares facts with `differences(from:ignoring:)` and never keeps its own list of allowed differences. The helper returns one line per difference, each starting with the path of the field, and takes a set of named fields to ignore. Three documented sets cover the common cases. `ProvenanceCompatFacts.runSpecific` holds what two runs of one writer decide for themselves, which is the host values under `recorded`, the run's wall time and the total wall time `ops stats` derives. It leaves out each step's wall time. Every scenario fixes its step times, so a writer change that loses or alters one fails the comparison, and step wall times compare exactly. `ProvenanceCompatFacts.realToolRun` adds the step wall times to that set. A lane may use it only for a run of a real tool, whose step times are measured. `ProvenanceCompatFacts.shapeChange` holds what a conversion from a bare run to a run-bearing envelope changes by design, which is the decoder, strict acceptance, the embedded run's status and repeated files, so files compare as a set on path, role, SHA-256 and size. The run wall time can be compared within one second.

One field sits outside every set. `stepRecordedContainer` clears only the container image and the container digest from each step's `recorded` map. A conversion from a bare run drops those two keys by design, because an envelope step holds a container only in a runtime identity of its own, and the image and digest then live in the envelope's runtime identity and in both legacy step views. A lane may name the field only together with an exact comparison of `legacyRunSteps` and `canonicalRunSteps`, since those views are where a lost or changed image or digest still shows.

## Adding a case

1. Put the bytes under `cases/<id>/`, laid out as they sit in a project, or reference a tracked file in place with a `repo:` path.
2. Add a row to MANIFEST.tsv. The helper `ProvenanceCompatCorpus.addCapturedCase` writes the file and the row for a case captured from a current writer.
3. Pin the strict-reader acceptance of the case in `ProvenanceCompatReaderTests`.
4. Write the expected facts and read them against the bytes. The command is below.
5. Commit the case, its facts and the pin together.

```
LUNGFISH_CAPTURE_PROVENANCE_FACTS=1 swift test --filter ProvenanceCompatFactsCaptureTests
```

`addCapturedCase` runs only with `LUNGFISH_CAPTURE_PROVENANCE_COMPAT=1`, refuses to overwrite an existing case, and refuses bytes that hold a machine path. The two capture test files named above show how a test calls it.
