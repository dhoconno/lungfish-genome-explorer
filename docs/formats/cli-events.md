# CLI events, version 2

A `lungfish-cli` command can report its progress as a stream of JSON lines. The app reads that stream when it runs a command as a subprocess, and a script can read it too. This page gives the wire format, the rule for changing it, the split between standard output and standard error, and the rule for warnings. The shared types are `CLIEvent`, `CLIEventLine`, `CLIEventEmitter` and `CLIEventLineDecoder` in the Workflow module.

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
| `kind` | What it is. A plain string today, and a bundle kind id once the bundle kind registry exists |
| `role` | Why the command made it, such as `alignment` |
| `provenancePath` | The provenance record that describes it |

A reader keeps a `kind` it does not know as a plain string. An element without a `path` is dropped, and the rest of the line is kept. The app still takes the paths it imports from `outputs`, and `artifacts` adds information beside them.

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

Events go to standard output, one line at a time. The app reads standard output through a pipe, where unflushed text waits until the command exits, so a command writes each line with `printEventLine`, which flushes it. Five `msa` commands and two `tree` commands still use plain `print`, so their progress arrives only when they exit.

While events are on, standard output holds event lines and nothing else. Human text goes to standard error, written with `printHumanLine`. A reader skips any line that does not start with `{`, so a fragment of text in front of an event hides that event.

A few older commands write events to standard error instead. `assemble` and the two ONT FASTQ commands do, and they move to standard output in 2.8.

## Warnings

The rule of this format is that only a `log` event with level `warning` makes a run Completed with Warnings. Text on standard error never does, whatever it says. A command that finishes with warnings may also put `warningCount` on its `complete` line, but the count only reports a number. It never makes a run Completed with Warnings on its own, so a command emits each warning it counts as an event. `msa annotate add`, `edit` and `project` still count annotation warnings that they never emit, and they emit them before the panel adopts this rule.

The Operations panel adopts this rule in 2.8 (decision S16). Until then each family of runners keeps the rule it has today.

## Old private shapes

Some commands print events in shapes of their own. The MSA and tree imports, the application export import and the two ONT FASTQ commands do. A dated legacy table that maps their old names onto the events above is planned for the version 2 decoder (decision V13). It is not part of this format yet, and the app still reads those streams with their own parsers.

## Tests

`Tests/Fixtures/cli-events/v1` holds transcripts captured from real runs of version 1. `CLIEventCompatibilityTests` decodes every one with a frozen copy of the version 1 reader and with the current decoder. It also reads version 2 lines back with the frozen reader and decodes a line from a later version that carries unknown keys, names and kinds.
