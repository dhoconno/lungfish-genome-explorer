# CLI events, version 2

A `lungfish-cli` command can report its progress as a stream of JSON lines. The app reads that stream when it runs a command as a subprocess, and a script can read it too. This page gives the wire format, the rule for changing it, the split between standard output and standard error, the rule for warnings, and the table that says what each command writes. The shared types are `CLIEvent`, `CLIEventLine`, `CLIEventEmitter` and `CLIEventLineDecoder` in the Workflow module.

## Switching events on

A command prints events when it runs with `--format json`. `assemble` uses `--json-events` instead, and `fastq ont-fluidigm-samples` and `fastq ont-pacbio-barcode-demux` print events on every run until 2.8, because the app runs them with no switch. With the switch off, any other command prints human text only. Recorded commands carry `--format json` and replay on later builds, so the switch keeps its name.

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
| `bundle` | A bundle that an import made, such as the `.lungfishfastq` bundle of `import fastq` |

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

A few older commands write events to standard error instead. `assemble` and the two ONT FASTQ commands do, and they move to standard output in 2.8.

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

## The contract table

`CLIEventContractTable` in `Sources/LungfishWorkflow/CLIEvents/CLIEventContract.swift` holds one row for each leaf command of `lungfish-cli`. A leaf is a command with no subcommands. A row is keyed by the leaf's path without the program name, such as `msa annotate add`, and it says in one of four cases what the leaf writes for a machine reader.

| Case | What the leaf does |
| --- | --- |
| `.events` | Prints the event lines of this page when its switch is on, and names the switch and the stream. `assemble` uses `--json-events` on standard error until 2.8, the two ONT FASTQ commands print on standard error with no switch until 2.8, and the others use `--format json` on standard output |
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
