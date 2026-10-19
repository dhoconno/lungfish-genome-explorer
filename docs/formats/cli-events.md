# CLI events, version 2

A `lungfish-cli` command can report its progress as a stream of JSON lines. The app reads that stream when it runs a command as a subprocess, and a script can read it too. This page gives the wire format, the rule for changing it, the split between standard output and standard error, the rule for warnings, and the table that says what each command writes. The shared types are `CLIEvent`, `CLIEventLine`, `CLIEventEmitter` and `CLIEventLineDecoder` in the Workflow module.

## Switching events on

A command prints events when it runs with `--format json`. `fastq ont-fluidigm-samples` and `fastq ont-pacbio-barcode-demux` print events on every run, because the app runs them with no switch. `assemble` used `--json-events` until 2.10 and keeps it as a hidden alias of `--format json`. With the switch off, any other command prints human text only. Recorded commands carry `--format json` and replay on later builds, so the switch keeps its name.

## One line, one event

A stream is UTF-8 text. Each line is one JSON object that ends in a newline and holds one event. The shared emitter sorts the keys, but some commands encode events themselves, so a reader parses the JSON and never relies on key order. The encoder also escapes slashes, so a path appears as `\/work\/a.fa` in the raw line.

```
{"event":"start","message":"Starting MSA export.","progress":0,"schemaVersion":2}
{"event":"progress","message":"Loading MSA bundle.","progress":0.15,"schemaVersion":2}
{"event":"complete","output":"\/work\/selected.fa","outputs":["\/work\/selected.fa"],"progress":1,"schemaVersion":2,"warningCount":0}
```

Every line has `event` and `schemaVersion`. The other keys depend on the event.

| `event` | Other keys | Meaning |
| --- | --- | --- |
| `start` | `message`, `progress` (always 0) | The operation began |
| `progress` | `progress` from 0 to 1, `message` | How far it has got |
| `log` | `level`, `message` | A line for the operation log. `level` is `debug`, `info`, `warning` or `error` |
| `output` | `path`, `role`, `artifacts` | A file or folder became available before the end. An analysis run writes one with the role `analysis-directory` once its result folder exists |
| `complete` | `outputs`, `output`, `message`, `progress` (always 1), `artifacts` | The operation finished. `outputs` lists every path it made |
| `failed` | `error`, `detail` | The operation failed. `detail` is optional extra context |

A run that succeeds ends with one `complete` line, and a run that fails ends with one `failed` line. A command may add keys of its own. The `msa` commands add `warningCount` to `complete`, and readers that do not know a key ignore it.

## Outputs and artifacts

`outputs` is the list of paths a command made, in an order the command documents. `output` repeats the first of them, for readers older than the list. A `complete` line names at least one path in `outputs`, because the app's subprocess transport fails a run whose completion names none. A reader that finds a file by position, as the primer trim runner finds its provenance record, depends on that order, so a writer never reorders `outputs` when it adds `artifacts`.

`artifacts` is an optional array on `complete` and `output` lines. It describes outputs in terms a path cannot carry. Each element is an object.

| Key | Meaning |
| --- | --- |
| `path` | The file or folder. This key is required |
| `kind` | What it is, such as the bundle kind id `phylogenetic-tree` or the file kind `bam`. It is a string on the wire |
| `role` | Why the command made it, such as `alignment` |
| `provenancePath` | The provenance record that describes it |

A reader keeps a `kind` it does not know as a plain string. In the app, `CLIEventArtifact.bundleKind` reads a kind that names a bundle kind in `BundleKindRegistry` as that `BundleKindID` when the path carries that kind's folder extension, and gives nil for any other kind, which keeps its string. An element without a `path` is dropped, and the rest of the line is kept. The app takes the paths it imports from `outputs` only, and `artifacts` adds information beside them.

### Roles and the primer trim example

A runner finds an artifact by its role. `CLIEventArtifact.Role` names the roles that a command and an app runner both read, and a writer may use others. The EsViritu roles are named in `EsVirituAnalysisRunTool.ArtifactRole`.

| Role | What the artifact is |
| --- | --- |
| `alignment` | The alignment the command made |
| `alignment-index` | The index of that alignment |
| `provenance` | The provenance record of the run |
| `variants` | The called variants, a compressed VCF |
| `variants-index` | Their tabix index |
| `variants-database` | The SQLite database of the track |
| `analysis-directory` | The result folder of an analysis run, named by its early `output` line. The app's classifier runner tracks it for Results and Reveal Output Files |
| `classification-report` | The Kraken2 report of a sample, `classification.kreport` |
| `classification-output` | The compressed Kraken2 output of every read |
| `bracken-profile` | The Bracken abundance profile |
| `classification-result` | `classification-result.json`, which the Kraken2 viewer loads |
| `classification-database` | The Kraken2 viewer's index of the result, `kraken2.sqlite` |
| `classifier-database` | The EsViritu viewer's index of the result, `esviritu.sqlite` |
| `esviritu-detections` | The EsViritu detection table of a sample |
| `esviritu-result` | The result file of an EsViritu sample, `esviritu-result.json` |
| `batch-summary` | The summary table of a batch |
| `batch-manifest` | The manifest of a batch |
| `bundle` | A bundle that an import or a fetch made, such as the `.lungfishfastq` bundle of `import fastq` or the `.lungfishref` bundle of `fetch genome` |

`bam primer-trim` is the first command that types its outputs. Its `outputs` keep the version 1 order, the trimmed BAM, then its index, then its record, and its `artifacts` describe the same three paths.

| Path | `kind` | `role` |
| --- | --- | --- |
| The trimmed BAM, in the bundle under `alignments/primer-trimmed` | `bam` | `alignment` |
| Its index | `bai` | `alignment-index` |
| Its record | `provenance` | `provenance` |

The BAM and its index also name the record in `provenancePath`. The app's primer trim runner reads each path by role, and it falls back to the path's place in `outputs` when a version 1 CLI wrote no artifacts.

`variants call` types its outputs the same way, with the kinds `variant-database`, `vcf` and `tbi`, and `align mafft` types its bundle as `multiple-sequence-alignment` with the role `alignment`.

## The version rule

`schemaVersion` is an integer on every line. A line without it was written before the envelope existed and reads as version 1. Every line written since then carries 2.

Additions never change the number. A new event name, a new key, a new artifact kind, a new role and a new log level are all additions. A new number means a removal or a change of meaning, such as dropping a key or giving an existing key another type.

Readers accept any version. A reader follows five rules.

- It ignores keys it does not know.
- It reads a log level it does not know as `info`.
- It keeps an artifact kind it does not know as a plain string.
- It ignores a line whose event name it does not know, and notes the line at debug level.
- It ignores a line from a higher version when it cannot read the fields of that line, where an unreadable line from a version it knows is an error.

Apps built before version 2 also ignore unknown keys. They log a warning for a line with an event name or log level they do not know, and they drop that line. A writer can still add either, and the cost is one warning per line in those apps.

## Standard output and standard error

Events go to standard output, one line at a time. The app reads standard output through a pipe, where unflushed text waits until the command exits, so a command writes each line with `printEventLine`, which flushes it.

While events are on, standard output holds event lines and nothing else. Human text goes to standard error, written with `printHumanLine`. A reader skips any line that does not start with `{`, so a fragment of text in front of an event hides that event.

The app's subprocess transport shows each line of standard error that is not blank in the operation log at info level. The text stays visible there and never counts as a warning.

The two ONT FASTQ commands write events to standard error instead. `assemble` wrote them there until 2.10.

## Warnings

The rule of this format is that only a `log` event with level `warning` makes a run Completed with Warnings. Text on standard error never does, whatever it says. A command that finishes with warnings may also put `warningCount` on its `complete` line, but the count only reports a number. It never makes a run Completed with Warnings on its own, so a command emits each warning it counts as an event. `msa annotate add`, `edit` and `project` count the warnings of their annotation, and each of them logs every one in front of `complete`.

The Operations panel adopts this rule in 2.8 (decision S16). Until then each family of runners keeps the rule it has today.

## Old private shapes

Some commands printed events in shapes of their own before version 2, and a `lungfish-cli` built before the envelope still prints them. The MSA and tree imports and the application export import wrote five names each, and the two ONT FASTQ commands wrote `progress` lines with an extra `operation` key. The app can meet such a CLI through `LUNGFISH_CLI_PATH`, a stale build folder or a `PATH` install.

The version 2 decoder reads the first two shapes through a dated legacy table, `CLIEventLegacyNames` in the Workflow module (decision V13). It consults the table only for a line that has no `schemaVersion` and whose event name it does not know. A name the table does not know stays an ignored line, and a missing field or a field of the wrong type takes the default that the app's own parsers used, so the decoder never throws on these lines.

| Old names | Version 2 event |
| --- | --- |
| `nativeBundleImportStart`, `applicationExportImportStart` | `start`, with the message `Started <kind> import via lungfish-cli` |
| `nativeBundleImportProgress`, `applicationExportProgress` | `progress`, with the same fraction and message |
| `nativeBundleImportWarning`, `applicationExportWarning` | `log` at level `warning` |
| `nativeBundleImportComplete`, `applicationExportImportComplete` | `complete`, with the bundle or collection in `outputs` and as its one typed artifact |
| `nativeBundleImportFailed`, `applicationExportImportFailed` | `failed`, with the error as its message |

The artifact of an old `complete` line has the role `bundle` and the kind that the extension names for a `.lungfishmsa` or `.lungfishtree` folder, or the role `collection` and the kind `import-collection` for a collection. An old `complete` line also carries a `warningCount`, which the table does not read. The old commands wrote one warning line for each warning they counted, so a reader that counts those lines gets the same number.

A current `lungfish-cli` prints the four import commands as version 2 events. Each run is one `start` line, a `progress` line for each step, a `log` line at level `warning` for each warning, and one `complete` line, or one `failed` line when the import does not finish. The `complete` line names the bundle or collection in `outputs` and describes it with one artifact. The artifact has the kind and role that an old `complete` line reads to, and it names the record that the import wrote in `provenancePath`. A run decodes to the same events as the old stream of the same run. The summary that the command prints, such as `Imported` and the path, goes to standard error while `--format json` is on. With the switch off the commands print the summary on standard output and write each warning and each failure as one `Warning:` or `Error:` line on standard error, and `--quiet` drops the warnings.

The app reads the stream of each import command through `CLISubprocessTransport`, in `CLINativeBundleImportRunner` and `CLIApplicationExportImportRunner`. A current CLI and an older CLI therefore give the same label, the same import and the same operation log apart from the summary lines a version 2 CLI prints on standard error, which the transport logs at info. The runner takes that path from `outputs` only, and it counts the warning lines to decide the label.

The two ONT FASTQ commands need no row. `progress` is a name of version 1, and the decoder ignores the `operation` key, so their lines already read as `progress` events.

`import fastq` and `import-fastq` wrote a shape of their own, S1, with ten event names such as `sampleStart` and `sampleComplete`, and wrote its lines in text mode too unless `--quiet` was given. They print version 2 events since 2.7, as the section on importing FASTQ reads says. The legacy table has no row for S1 (decision T5 of 2.7).

The three `build-db` leaves wrote objects with `progress` and `message` and no `event` key on standard error under `--format json`, beside their human text on standard output. The app never ran them with the switch, and no reader read the objects, so the legacy table has no row for them. Since 2.7 these leaves print version 2 events, as the next section says.

`CLIEventLegacyNamesTests` decodes each transcript in `Tests/Fixtures/cli-events/legacy` and compares every line with a frozen copy of how the two import runners read it. The table is dated 2026-10-11. It is deleted as a unit when the last `.legacy` row goes, 2.9 by today's rows. The unit also holds the legacy branch of the decoder, `CLIEventLegacyNamesTests` with those transcripts, the legacy check in `ImportStreamCapture`, the runner tests that print an old name, and the legacy sections of this page and the fixtures README. The contract table below lists the four import commands and the two ONT FASTQ commands as `.events` rows.

## Building a viewer database

`build-db kraken2`, `build-db esviritu` and `build-db taxtriage` build the SQLite database that a classifier viewer reads, in the result folder they are given. With `--format json` a run is one `start` line, a `progress` line for each step that the database writer reports, with the fraction and the message the writer gives, and one `complete` line. Its `outputs` names the database file, such as `kraken2.sqlite` in the result folder, and its message is the last sentence the run prints about the database. A run that finds the database there and has no `--force` keeps it and completes with the same file. A run that fails ends with one `failed` line.

The rows parsed, the database path and the cleanup summary go to standard error while the switch is on. Without the switch, which is how the app runs these leaves, the text stays on standard output and no event is printed. The warnings of the read count pass, such as a failed `samtools markdup`, travel with the human text. The other warnings go to standard error in both modes, and `--quiet` drops the text and every warning.

## Analysis runs

`kraken2 classify`, its older spelling `conda classify`, and `esviritu detect` run through the analysis run executor, `AnalysisRunExecutor` in the Workflow module, which writes their stream. `AnalysisRunEvents` in the same module documents it. With `--format json` a run writes these lines in this order.

1. One `start` line.
2. One `output` line with the role `analysis-directory` and the absolute path of the result folder, once the folder exists and before any sample runs. A run the command refuses before it makes a folder, such as one that names a database the registry does not hold, writes none.
3. `progress` lines on the scale of the whole run. Each unit, one sample, starts with the line `Running <label> (<i> of <n>).`, or `Running <label>.` in a run of one sample, and the lines about a virtual input being materialized follow at the start of its range. Its own progress maps onto the run as `(index + fraction) / count`, so the fraction never moves back, and the lines of the finalize, such as the build of the viewer database, come at the end of the range. `log` lines come between them. Each `log` line at level `warning` is one of the run's warnings, and a completed run with a warning reads Completed with Warnings.
4. Exactly one last line. `complete` names the result folder in `outputs`, types the result in `artifacts` with the roles above and names the root record with the role `provenance`. Its message is the completion detail. `failed` holds the reason in `error`.

A cancelled run ends with `failed`, exit status 125 and no `detail`. A run that failed from its samples carries `detail` only when exactly one sample failed, in a run of one sample or in a batch that stops at its first failed sample, so the detail always belongs to the reason in `error`. The text is what the failing sample handed over, such as the last lines of the EsViritu log. The executor turns carriage returns into line breaks and removes colour codes, every other control character but the tab, and every blank line. It keeps the last 20 lines, each cut to 400 characters, within 4,096 bytes. A refused run, a folder that could not be made, a failed finalize and a batch where several samples failed carry none, and no record holds the text. In a batch that goes on past a failed sample, `esviritu detect` logs that sample's last log lines, bounded the same way, as one `error` line starting `EsViritu log (last lines):`, since no `failed` line carries them. `kraken2 classify` hands over no detail, because its reason already holds the standard error of the tool.

## Importing FASTQ reads

`import fastq` and its older spelling `import-fastq` import reads into a project, one bundle for each sample. With `--format json` a run is one `start` line, a `progress` line when a sample starts and when each of its steps starts, `log` lines, and one `complete` line, or one `failed` line. The fraction of a `progress` line is one fraction for the whole import, `(index + share) / count` for sample `index` of `count`, where the share of a step is 0.8 times its number over the step count. The bar of a batch therefore only moves forward, where the private stream S1 that the command printed before 2.7 started each sample again near 0. The texts and levels are the ones the app gave the S1 events. A notice, such as a `--platform` value that the reads contradict, and a skipped sample are `log` lines at level `warning`, and a failed sample is one at level `error`. The platform of each sample, the start and the end of each step, the reads that a recipe step removed and the summary are at level `info`.

The `complete` line names each bundle the run made in `outputs`, in the order the samples finished, and describes each with one artifact of kind `fastq` and role `bundle` that names the record of the bundle in `provenancePath`. A run that made no bundle, because it skipped every sample or was a dry run, completes with no path. A run whose samples failed ends with one `failed` line. Its message is the last failure as `<sample>: <error>`, and its `detail` lists every failure when there are more than one. A cancelled run ends with a `failed` line whose message is `Import cancelled` and exits 125, and an input that the command cannot read ends with a `failed` line that holds the error.

The human text, such as the samples found and the summary, goes to standard error while the switch is on. In text mode the command prints the same human text on standard output as before and no event. The notices and skipped samples that only the S1 lines reported in text mode go to standard error as warning lines, apart from a `--platform` notice, which text mode prints with the human text. `--quiet` drops them.

The app reads the stream in `CLIImportRunner` through `CLISubprocessTransport`, which gives the command 5 seconds after SIGTERM to remove its staging folders and stops a child process that keeps the output open half a second after the command exits. The runner shows each `progress` line on the operation's row, moving its bar only forward, and logs each `log` line at its level. It takes the bundles from `outputs` by the role of their artifacts and fails the row with the message of a `failed` line. A `lungfish-cli` built before 2.7 prints S1, which the app no longer reads, so its run fails with a message that names the path of that copy, says it is older than the app and asks the user to reinstall the app.

## Fetching genomes

`fetch genome` makes one bundle for each accession it is given. With `--format json` a run is one `start` line, `progress` lines, `log` lines, and one `complete` line, or one `failed` line. The fraction of a `progress` line is `(index + share) / count` for accession `index` of `count`, where the share is the fraction the bundle builder reports, so the bar of a batch only moves forward. Annotations that NCBI does not have are a `log` line at level `warning`, and a failed accession is one at level `error`.

The `complete` line names each bundle in `outputs`, in the order of the accessions, and describes each with one artifact of kind `reference` and role `bundle`. The artifact names the record of the bundle in `provenancePath`, which is the root record of a new bundle and the record in the `genome` folder after `--into-bundle`. `--fasta-only` and `--no-bundle` name the files they saved in `outputs` with no artifact. A run goes on past an accession that fails and then ends with one `failed` line. Its message is the last failure as `<accession>: <error>`, and its `detail` lists every failure when there are more than one. A cancelled run ends with a `failed` line whose message is `Fetch cancelled` and exits 125.

The human text goes to standard error while the switch is on. In text mode the command prints it on standard output and no event, and its warnings and its failure go to standard error. `--quiet` drops everything but the failure. The NCBI key reaches the command through `--api-key` or the `NCBI_API_KEY` variable, and no line names it. The command printed one `fetch-genome` result document before 2.10.

`fetch ncbi --bundle` speaks the same lines for the bundle of each GenBank record it is given. Without `--bundle` the leaf saves one file for all its accessions and speaks them too. A run is one `start` line, one `progress` line for each accession, a `log` line at level `warning` for a GFF3 that has no feature rows, and one `complete` line that names the `--save-to` file in `outputs` with no artifact, or one `failed` line. Without `--save-to` the records would share standard output with the events, so `--format json` refuses to run. It printed one `fetch-ncbi` result document before 2.10.

`fetch pathoplexus` speaks the same lines for the bundle of each Pathoplexus record it is given. A record whose data use terms are restricted is refused with a `log` line at level `error`, and the run goes on, so a run that ends with a refusal ends with one `failed` line that names it. A record whose INSDC accession GenBank cannot serve is built from the Pathoplexus FASTA, and a `progress` line says so. The leaf is new in 2.10, so it printed no result document before.

`fetch sra download` speaks the same lines for the one run it is given, with and without `--bundle`. It printed a result document with `--format json` before 2.10, and the document is gone. A run is one `start` line, `progress` lines, a `log` line at level `warning` for a fallback to the other archive or a layout warning, and one `complete` line or one `failed` line. A plain run names the FASTQ files in `outputs` with no artifact. With `--bundle` the download takes the first half of the bar and the import the rest, the import's own events never reach standard output, and the `complete` line names the published `.lungfishfastq` bundle with one artifact of kind `fastq`, role `bundle` and the bundle's record. SIGTERM removes what the run staged and ends it with a `failed` line and exit 125.

`demo fetch` speaks the same lines for the one project it is given. It printed the project's record with `--format json` before 2.10, and `demo info <id> --format json` prints that record now. A run is one `start` line, `progress` lines, and one `complete` line or one `failed` line, and standard output holds nothing else. The download takes the first nine tenths of the bar as the share of the bytes received, with one line for each whole percent. Verifying sits at 0.91, unpacking at 0.93 and installing at 0.98, and the bar never steps back. Each `progress` line carries the words the Demo Projects window shows for the same phase, and the window reads a line back into its phase from these numbers. The `complete` line names the installed project folder in `outputs` with no artifact, because a project folder is no bundle. A copy that was already there ends with `start` and `complete` and no progress, and the notice of a replaced copy is a `log` line. A `failed` line carries the words of the error. SIGTERM removes the hidden staging folder and ends the run with a `failed` line that reads `Fetch cancelled` and exit 125.

## Extracting a region

`extract sequence` prints events with and without `--bundle`. With `--format json` a run that writes a FASTA file is one `start` line and one `complete` line that names the file in `outputs`, or one `failed` line. Without `-o` the FASTA would share standard output with the events, so `--format json` refuses to run and exits 3. A run that builds a region bundle, from a source bundle with `--bundle` or, since 2.12, from a FASTA file with `-o <name>.lungfishref`, is one `start` line, a `progress` line for each step with the words the region extraction row shows, from `Preparing...` to `Bundle ready: <name>`, and one `complete` line that names the published `.lungfishref` bundle, or one `failed` line. A refusal exits 3. SIGTERM ends a region bundle run before it publishes, with a `failed` line that reads `Extraction cancelled. Nothing was published.` and exit 125. The leaf printed one `extract-sequence` result document before 2.11. The region, the sequence name, the span written, its length and the strand that the document held are in the run's record. A run with no region writes the sequences that `--sequence` or `--selection` names, as stored or wrapped to `--line-width` when it is given, and is one `start` line and one `complete` line that names the file in `outputs`, or one `failed` line. It needs `-o`, a refusal exits 3, a failure exits 64, and SIGTERM ends it before it writes, with a `failed` line that reads `The export was cancelled. No file was written.` and exit 125. Its record names the FASTA file and the selection file, when there is one, as its inputs, each with its digest, and `--line-width` as an explicit option when it is given.

## Importing a reference

`import fasta` prints events with `--format json`. A run is one `start` line that reads `Importing <file>`, `progress` lines for the steps of the build in the words of the import service and the bundle builder, from `Preparing reference input...` at 0.02 to `Bundle created successfully` at 1, and one `complete` line that names the published `.lungfishref` bundle in `outputs`, or one `failed` line. With `--annotations` the build takes the first 0.82 of the bar, and the last `progress` line, at 0.88, reads `Attaching projected annotations...`. The command attaches the track, writes the extraction record and, with `--rehydrate-source-provenance`, merges the source's own record before it prints `complete`, so nothing writes to the bundle after the command exits.

A refusal prints a `failed` line and exits 3. A missing input, an empty FASTA and `--annotations` with a compressed input are refusals, and an unsupported format exits 5. SIGTERM ends a run with a `failed` line that reads `Import cancelled. Nothing was published.` and exit 125, and the command removes the bundle if the attach or a record step was still running. A SIGTERM that comes after the last write lets the run finish. The human text, such as the summary, goes to standard error while the switch is on. In text mode the command prints it on standard output and no event. The leaf printed text only before 2.11.

## Merging reference bundles

`bundle merge` prints events with `--format json`. A run is one `start` line that reads `Merging <n> reference bundles`, `progress` lines in the words of the sidebar's row from `Preparing to merge <n> reference bundles...` to `Merge complete`, and one `complete` line that names the published `.lungfishref` bundle in `outputs`, or one `failed` line. A refusal exits 3 and a failure exits 64. SIGTERM ends the run before it publishes, with a `failed` line that reads `Merge cancelled. Nothing was published.` and exit 125. The command builds the bundle in the project's `.tmp` folder, publishes it with one rename and writes its record before it prints `complete`, so nothing writes to the bundle after the command exits.

`blast submit` prints events with `--format json`. A run is one `start` line that reads `Preparing to BLAST <query file name>`, a `progress` line that reads `Submitting <n> sequences to NCBI BLAST`, `progress` lines in the words of the BLAST service from submission to `BLAST verification complete`, and one `complete` line whose `outputs` name `blast-result.json` first and the query copy `query.fasta` second, with a message that gives the RID and the counts, or one `failed` line. A refused input exits 3, a folder that already holds a result exits 4 and a failed search writes a `failed` record beside the query copy and exits 1. SIGTERM cancels the search with no `failed` line, writes a cancelled record beside the query copy and exits 125. No line carries the text of a sequence.

`extract taxa-collection` prints events with `--format json`. A run is one `start` line that reads `Extracting taxa of a collection…`, `progress` lines in the words of the extraction pipeline from `Starting batch extraction` to `Batch complete`, and one `complete` line whose `outputs` name the gzip FASTQ file of each taxon in the order of the collection, with a message that reads `Extracted <n> taxa from <collection name>`, or one `failed` line. A taxon without reads gets a `progress` line that reads `Skipped <name> (0 reads)` or `Skipped <name> (no matching reads)` and no file. A result folder that is missing or is not a Kraken2 classification result is a refusal that exits 3. SIGTERM cancels the run with a `failed` line that reads `Taxa collection extraction cancelled.`, writes a cancelled record into the output folder and exits 125.

## Running a workflow

`workflow run` prints events on both of its routes, a local workflow's and nf-core's, and `WorkflowRunOutput` in `Sources/LungfishCLI/Commands/RunSubcommand+Output.swift` writes them. With `--format json`, standard output holds only event lines. The first is a `start` line with no message, so a row that shows a start message as its detail keeps the detail it has. The second is an info `log` line, `Preparing workflow: <workflow>`, and each other line that text mode prints on standard output, such as `Created run bundle: <path>`, is an info `log` line too. When the run has to wait for Docker, the engine's two lines, `Docker daemon unavailable. Launching Docker Desktop...` and `Docker daemon ready`, are `progress` lines at 0.01 and 0.02. The run's outcome lines are `log` lines at level `warning`. A Viral Recon run prints one for all its ignored tasks and one for its failed samples, each only when the run has any. Standard error keeps the lines that text mode prints there, apart from the outcome lines, so the tail of a failure reads the same and a reader never takes an outcome twice.

The run ends with one `complete` line or one `failed` line. `complete` names the run bundle and the results folder in `outputs`. Under `--prepare-only` it names the run bundle alone, and under `--dry-run`, which writes nothing, it names nothing. `failed` holds the reason in `error`, and a cancelled run reads `Workflow cancelled` and exits 125.

## Mapping reads

`map` maps the reads of one sample to a reference with a managed mapper. With `--format json` a run is one `start` line whose message is the first detail of the Map Reads row, a `progress` line for each step, one `log` line at level `info` that names the read layout the run maps with and why, and one `complete` line, or one `failed` line. The steps are the ones the Map Reads window shows, with the same words and fractions, which `MappingRunProgress` in the Workflow module gives both of them. A message of the input resolver, such as a virtual bundle being materialized, comes at 0. A step of the mapper and of the BAM normalization comes at the fraction the pipeline gives, up to 1. The line `Preparing reference mapping viewer...` comes at 0.93 when the reference is inside a `.lungfishref` bundle and `--no-viewer-bundle` is not given, and the steps of the viewer bundle follow from 0.93 to 0.99, so a fraction can be lower than the one before it. The app holds its bar where it stands then.

The `complete` line names the result folder in `outputs`. The folder holds `mapping-result.json`, the sorted BAM with its index, and the viewer bundle when one was published. Its message is the completion detail the window shows, the mapped reads over the total. A run that fails ends with one `failed` line that holds the error of the step that failed, such as a mapper that is not installed, in the words the window shows. A cancelled run ends with a `failed` line whose message is `Mapping cancelled` and exits 125.

While the switch is on, the warnings about the mapper's settings and the notes go to standard error. In text mode the command prints its tables and progress lines on standard output as before and no event. Before 2.10 `map --format json` printed one JSON report, the schema `r5-map-report`, with the resolver's messages as text in front of it.

## Assembling reads

`assemble` assembles the reads of one sample with a managed assembler. With `--format json` a run is one `start` line once the assembler is known, a `progress` line for each stage the pipeline reports, a `log` line at level `info` for each line the assembler prints, and one `complete` line that names the output folder, or one `failed` line. A refusal, such as an input that is missing or a read layout the assembler cannot take, prints its words for a person on standard error and ends with a `failed` line that holds the same words. A run that finds no contigs logs a warning before `complete`.

With `--reference-bundle` the run then publishes a `.lungfishref` bundle of the contigs beside `--output`, named after the project, the bundle the app's Reassemble route opens. Each step of the bundle prints a `progress` line, from `Creating reference bundle...` at 0.92 to `Bundle created successfully` at 1, the words and fractions the Reassemble row shows. The `complete` line then names the output folder and the bundle, in that order. A bundle that is already there ends the run with a `failed` line and exit 3 before the assembler starts.

Before 2.10 the command printed the same lines on standard error behind `--json-events`, and the Reassemble and FASTQ operation rows recorded that switch. It stays as a hidden alias of `--format json`, so a recorded command still replays, and its events now go to standard output too. The summary tables go to standard error while the switch is on.

## The contract table

`CLIEventContractTable` in `Sources/LungfishWorkflow/CLIEvents/CLIEventContract.swift` holds one row for each leaf command of `lungfish-cli`. A leaf is a command with no subcommands. A row is keyed by the leaf's path without the program name, such as `msa annotate add`, and it says in one of four cases what the leaf writes for a machine reader.

| Case | What the leaf does |
| --- | --- |
| `.events` | Prints the event lines of this page when its switch is on, and names the switch and the stream. the two ONT FASTQ commands print on standard error with no switch, and the others, `assemble` among them since 2.10, use `--format json` on standard output |
| `.result` | Prints one JSON document to standard output, under its JSON switch or on every run. The row names the schema of that document |
| `.legacy` | Prints a private stream shape that a later sub-phase retires. The row names the shape and the sub-phase |
| `.text` | Prints human text only, or prints text for a switch it lists. The row gives the reason |

A leaf that lists `--format json` and prints text anyway is a `.text` row, and sub-phases 2.10 to 2.12 settle each of them. Some `.result` leaves print status lines or sequences before their document unless `--quiet` and an output file are given, so a script that needs the document alone passes both.

`CLIEventContractCoverageTests` walks the command tree the way `--experimental-dump-help` does and fails when a leaf has no row or a row names no leaf. A change that adds, renames or removes a command edits its row in the same commit. The same suite fails when the checked-in help of an `.events` leaf does not list its switch, and it decodes each checked-in `.result` document with one extra key added and names every other schema with its reason. It also counts the `.legacy` rows. A sub-phase that retires one deletes its rows and its entry in the test together, so no separate ratchet counts them.

## Tests

`Tests/Fixtures/cli-events/v1` holds transcripts captured from real runs of version 1. `CLIEventCompatibilityTests` decodes every one with a frozen copy of the version 1 reader and with the current decoder. It also reads version 2 lines back with the frozen reader and decodes a line from a later version that carries unknown keys, names and kinds.

`Tests/Fixtures/cli-events/v2/bam-primer-trim.ndjson` is a version 2 run of `bam primer-trim`. It was captured in process on the sarscov2 fixture, with standard output redirected for the length of the run and the scratch folder rewritten to `/work`. `CLIPrimerTrimRunnerTests` reads it with the runner and with the frozen version 1 reader, which gets the same outcome and `outputs`.

`Tests/Fixtures/cli-events/commands` holds one folder for each leaf that emits events. Most transcripts were captured in process, and those of the leaves that run an external tool, `import fastq` among them, came from real runs of the built `lungfish-cli`, which the fixtures README lists under Captured from the built CLI. `CLIEventTranscriptCoverageTests` decodes every line under version 2 with no ignored event and expects one terminal event last. It reads each run with the frozen version 1 reader to the same outcome and `outputs`, and it pins the order of `outputs` for `variants call` and `bam primer-trim`. It also runs the leaves that need no tool again and fails when a line differs from its transcript. `CLIImportRunnerTranscriptTests` plays the three real runs of `import fastq` through the import runner and compares the row with what the runner of the base showed for the same runs of S1. `Tests/Fixtures/cli-events/results` holds the documents of the result schemas that have a fixture, each from a real run.

`CLISubprocessTransportTests` plays every version 1 transcript, and the same run written as version 2 lines, through the transport and gets the same outcome both ways. `OperationCenterCLIBridgeTests` plays four of them through a runner and the bridge, one for each label a run can end on.
