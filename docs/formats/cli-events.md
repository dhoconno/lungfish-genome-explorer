# CLI events, version 2

A `lungfish-cli` command can report its progress as a stream of JSON lines. The app reads that stream when it runs a command as a subprocess, and a script can read it too. This page gives the wire format, the rule for changing it, the split between standard output and standard error, the rule for warnings, and the table that says what each command writes. The shared types are `CLIEvent`, `CLIEventLine`, `CLIEventEmitter` and `CLIEventLineDecoder` in the Workflow module.

## Switching events on

A command prints events when it runs with `--format json`. The one exception is `assemble`, which uses `--json-events`. With the switch off, a command prints human text and no event line. Recorded commands carry `--format json` and replay on later builds, so the switch keeps its name.

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
| `output` | `path`, `role`, `artifacts` | A file became available before the end. No command writes one yet |
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

A runner finds an artifact by its role. `CLIEventArtifact.Role` names the roles that a command and an app runner both read, and a writer may use others.

| Role | What the artifact is |
| --- | --- |
| `alignment` | The alignment the command made |
| `alignment-index` | The index of that alignment |
| `provenance` | The provenance record of the run |

`bam primer-trim` is the first command that types its outputs. Its `outputs` keep the version 1 order, the trimmed BAM, then its index, then its record, and its `artifacts` describe the same three paths.

| Path | `kind` | `role` |
| --- | --- | --- |
| The trimmed BAM, in the bundle under `alignments/primer-trimmed` | `bam` | `alignment` |
| Its index | `bai` | `alignment-index` |
| Its record | `provenance` | `provenance` |

The BAM and its index also name the record in `provenancePath`. The app's primer trim runner reads each path by role, and it falls back to the path's place in `outputs` when a version 1 CLI wrote no artifacts.

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

Some commands print events in shapes of their own. The MSA and tree imports, the application export import and the two ONT FASTQ commands do. A dated legacy table that maps their old names onto the events above is planned for the version 2 decoder (decision V13). It is not part of this format yet, and the app still reads those streams with their own parsers. The contract table below lists each of these commands as a `.legacy` row.

## The contract table

`CLIEventContractTable` in `Sources/LungfishCLI/Support/CLIEventContract.swift` holds one row for each of the 236 leaf commands of `lungfish-cli`. A leaf is a command with no subcommands. A row is keyed by the leaf's path without the program name, such as `msa annotate add`, and it says in one of four cases what the leaf writes for a machine reader.

| Case | What the leaf does |
| --- | --- |
| `.events` | Prints the event lines of this page when its switch is on, and names the switch and the stream. Twenty leaves use `--format json` on standard output, and `assemble` uses `--json-events` on standard error |
| `.result` | Prints one JSON document to standard output, under its JSON switch or on every run. The row names the schema of that document |
| `.legacy` | Prints a private stream shape that a later sub-phase retires. The row names the shape and the sub-phase |
| `.text` | Prints human text only, or prints text for a switch it lists. The row gives the reason |

A leaf that lists `--format json` and prints text anyway is a `.text` row, and sub-phases 2.10 to 2.12 settle each of them. Some `.result` leaves print status lines or sequences before their document unless `--quiet` and an output file are given, so a script that needs the document alone passes both.

`CLIEventContractCoverageTests` walks the command tree the way `--experimental-dump-help` does and fails when a leaf has no row or a row names no leaf. A change that adds, renames or removes a command edits its row in the same commit. The same suite fails when the checked-in help of an `.events` leaf does not list its switch, and it decodes the document of each `.result` schema that a Swift type in the CLI, Workflow or IO module reads, with one extra key added. It also counts the `.legacy` rows. Fourteen private shapes are left in Phase 2.6, and a sub-phase that retires one deletes its rows and its entry in the test together, so no separate ratchet counts them.

## Tests

`Tests/Fixtures/cli-events/v1` holds transcripts captured from real runs of version 1. `CLIEventCompatibilityTests` decodes every one with a frozen copy of the version 1 reader and with the current decoder. It also reads version 2 lines back with the frozen reader and decodes a line from a later version that carries unknown keys, names and kinds.

`Tests/Fixtures/cli-events/v2/bam-primer-trim.ndjson` is a version 2 run of `bam primer-trim`. It was captured in process on the sarscov2 fixture, with standard output redirected for the length of the run and the scratch folder rewritten to `/work`. `CLIPrimerTrimRunnerTests` reads it with the runner and with the frozen version 1 reader, which gets the same outcome and `outputs`.

`Tests/Fixtures/cli-events/commands` holds one folder for each of the 21 leaves that emit events, 25 transcripts in all. Twenty were captured in process, and five came from real runs of the built `lungfish-cli` for the leaves that run an external tool. `CLIEventTranscriptCoverageTests` decodes every line under version 2 with no ignored event and expects one terminal event last. It reads each run with the frozen version 1 reader to the same outcome and `outputs`, and it pins the order of `outputs` for `variants call` and `bam primer-trim`. It also runs the 16 leaves that need no tool again and fails when a line differs from its transcript. `Tests/Fixtures/cli-events/results` holds the documents of 13 result schemas, each from a real run.

`CLISubprocessTransportTests` plays every version 1 transcript, and the same run written as version 2 lines, through the transport and gets the same outcome both ways. `OperationCenterCLIBridgeTests` plays four of them through a runner and the bridge, one for each label a run can end on.
