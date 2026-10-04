# CLI equivalence

This contract binds every operation in Lungfish Genome Explorer (LGE). Part of the contracts index in `docs/contracts/README.md`. It states owner decision 4 of 2026-10-03. Every operation has a `lungfish-cli` equivalent, so Copy Command always gives a command that parses and reproduces the run.

## The rule

Every Operations panel row records a `lungfish-cli` command. The command parses with the shipped parser. Run on the same inputs, it produces the same result as the GUI run, in the sense the table under "Same result" gives for the kind of operation.

| Requirement | What it means |
|---|---|
| Built from what runs | The GUI builds the recorded command from the configuration it executes, with one builder that both the run and the row use. A builder that lives in LungfishWorkflow is preferred, so the CLI command and the GUI share it. |
| Parses | `RecordedCLICommand.parseScript` accepts every line. Each line starts with `lungfish-cli`, uses only real options and passes each command's `validate()`. |
| Names every choice | The command names every option whose GUI value can differ from the CLI default. That includes thresholds, presets, read layout, platform, thread counts and random seeds. A run that draws a random seed draws it before `begin` and records it. |
| Absolute, durable paths | Every path is absolute and names a durable file. No `.`, no `~`, no session scratch file. An input the GUI holds only in memory, such as a list of selected read names, is written to a durable file before `begin`, inside the result's provenance inputs, and the command names that file. |
| One command, or a command script | Prefer one command. An operation that is truly several steps records a command script, which is two or more `lungfish-cli` commands joined by a newline and run in order. Each line parses on its own. A line may name an output of an earlier line. No line is a comment, a note or another program. |
| Same provenance | The GUI run writes a provenance envelope whose argv is the recorded command, so the row and the provenance name the same command. |

A command may be refined after `begin` with `setCommand`, only to a more specific command for the same run, such as one that names outputs resolved after `begin`. The final value obeys every requirement above.

The FASTQ operations dialog row is the first to do this. Its output path is chosen during the run, so the row records `<derived>` as the output at `begin`. After a successful run, `FASTQOperationRowCommand` in `Sources/LungfishApp/Services/FASTQOperationRowCommand.swift` replaces it with the command each imported bundle's manifest records, one line per distinct command in import order. A Savont row takes its executed invocations instead, each naming the published FASTA in `--output`. The row is refined only when every imported bundle or published FASTA exists and every line starts with `lungfish-cli` and holds no `<derived>`. Otherwise the `begin` command stays and one log line says why. A grouped result, such as a demultiplex, keeps the placeholder until Phase 2. `FASTQOperationRowCommandTests` pins the rule, and `FASTQDialogRowCommandReplayTests` replays a refined command onto a second root and compares the payload files.

## Same result

The kind of output decides what "same" means. Every comparison applies the masks in the last row and nothing else. `OutputEquivalence.Kind` in `Tests/Support/LungfishTestSupport/OutputEquivalence.swift` names each kind.

| Kind of operation | Same result means | Examples |
|---|---|---|
| Writes files (`.files`) | Text and binary files are byte for byte identical. A gzip or BGZF file is compared on its decompressed bytes, because the container records a time. A BAM is compared on its header without the `@PG` lines samtools adds and on a hash of `samtools view --no-PG` in file order. A VCF is compared on its records and on its header without date and command lines. A `.bai`, `.csi` or `.tbi` index is never compared byte for byte, because it records the byte offsets of the file it indexes. A BAM index is compared on `samtools idxstats` output and a tabix index on `tabix -l` output when the tool is available. Otherwise the index must exist in both trees. | trim, filter, map, convert, extract reads, consensus to FASTA |
| Writes records into a database (`.database`) | Every table holds the same rows. Compare a sorted dump per table, not the database bytes. | annotation tracks, variant databases, classifier SQLite |
| Creates a bundle or an analysis folder (`.bundle`) | The same bundle. That is the same relative file inventory, the same manifest after masking, and every payload the same under its own kind. | reference import, merge, region extraction, primer export, batch classifier runs |
| Edits a bundle in place (`.bundle`) | Starting from identical copies of the bundle, the bundle after the GUI run and after the CLI run are the same bundle. | add, update and delete annotations, delete variants, attach a track, remove a track |
| Calls a remote service (`.remoteRequest`) | The same request. The submitted sequences and every request parameter are byte for byte identical. With the service replaced by a recorded response, the parsed records are the same. A live result may differ, because the remote database changes. | BLAST submission, NCBI, ENA and SRA fetch, AI haplotyping |
| Changes managed tools or databases (`.managedPlan`) | The same plan and the same receipt entries. `--plan` output from the CLI equals the plan the GUI applied. | plugin install, tools update, database update |
| Masks | Wall-clock times, run and operation UUIDs, identifiers derived from a UUID, such as `aln_` plus 8 hex digits, numbered by first appearance, the two run roots (replaced by `<ROOT>`), the executable path, host, process ID and wall time in provenance, and the checksum and size a manifest or provenance record states for a file that exists in both trees and is itself compared by content rather than by bytes. So does a record for a run's scratch intermediate, a BAM, index, gzip, SQLite or JSON file under the system temporary folder that the run deleted. A record that names any other file, such as an input outside the trees, keeps its checksum. A mask is added only by a reviewed change to this table. | |

## Narrow exceptions

| Exception | What the row records |
|---|---|
| Clipboard and share destinations | The command that writes the same content to a file. It names `-o` with the suggested file name relative to the working directory, the one place a relative path is allowed, because the clipboard has no path. |
| A row that runs nothing | A row that only reports a failure from before the run started, or a UI-test fixture row, records nil and carries the marker `cli-parity-exempt: not-an-operation`. |
| An owner ruling | The owner may rule that one operation stays GUI only. Its row records nil and carries `cli-parity-exempt: owner-<date>`, citing the decision. No other reason exempts a row. |

A user confirmation inside a run, for example accepting a low-depth consensus, is not an exception. The CLI takes the answer as an explicit flag, and the recorded command passes it.

## Gaps until they close

A row that does not meet the rule today is a gap. Each gap has an ID, and the begin helper's doc comment carries the marker `cli-parity-gap: <ID>` with the closest command and why it falls short. An inline begin call may carry the marker in a comment between the start of its function and the end of the call. The row records nil, never a descriptive text. A test pins it with `assertCLIParityGap(_:id:)`, which asserts that the recorded command fails `RecordedCLICommand.parseScript`. When a command lands, that test fails, and the change replaces it with a parse test and a replay test and removes the marker.

No new gap may be added. A new operation lands with its command.

The gaps counted when this contract landed numbered 43. Three of them first sat in files that other lanes were editing, so they were listed in `scripts/ratchets/cli-parity-gaps.pending` until those lanes gave them markers. Deleting the unreachable FASTQ dashboard derivative path then closed `fastq-dashboard-derivative`. The count is now 42, and every gap carries a marker in `Sources/`, so the pending file holds no gap line.

A gap that a lane cannot mark in its own commit goes in the pending file as `ID file:function lane`. A pending gap needs no pin while its line stays there, and the lane that closes it deletes the line.

## Tests that enforce it

| Test | Applies to | How |
|---|---|---|
| Command parses | every row with a command | `RecordedCLICommand.parseScript(_:)` returns one parsed command per line. Assert that the parsed values equal the run's configuration. |
| Command replays | every row with a command, one replay per operation kind at least | Copy one fixture into two sibling roots, A and B. Run the GUI path on A through the begin helper and the same Workflow call its launch closure makes, with a `RecordingOperationReporter`. Take the recorded command and rewrite it with `RecordedCLICommand.rebased(_:from:to:)`, which replaces root A with root B in every argument that starts with it and fails on an argument that names root A anywhere else. Run it with `RecordedCLICommand.runInProcess(_:)` and compare A and B with `OutputEquivalence.assertSame(_:_:kind:)`. |
| Gap pinned | every gap | `assertCLIParityGap(item.cliCommand, id: "<ID>")`. |
| Provenance names the command | every row that writes provenance | Read the envelope with `ProvenanceEnvelopeReader` and assert that its argv equals the recorded command. |

A replay that needs an external tool runs in the integration tier, which takes every LungfishAppTests class whose name ends in `ReplayTests`. A replay of a remote service runs in the unit tier against a recorded response. A replay of pure Swift code runs in the unit tier. `Tests/LungfishAppTests/CLIReplayHarnessReplayTests.swift` replays a `bam filter` run end to end and serves as the template.

## The ratchet

`scripts/ratchets/cli-parity-gaps.sh` runs in the pre-push hook. It is a source scan with a test cross-check, and it needs no build.

1. It finds every Operations panel `begin` call, which is a call whose argument list names `cliCommand:`. A call inside a function that is itself named `begin` forwards its caller's command and is skipped, and the call to that forwarder counts instead.
2. Its value is the number of distinct `cli-parity-gap: <ID>` markers in `Sources/` plus the lines in `cli-parity-gaps.pending`. The value must not exceed `scripts/ratchets/cli-parity-gaps.baseline`, and `--update` may only lower the baseline.
3. It fails when a marker ID has no `assertCLIParityGap` call with the same ID in `Tests/`, or when a test pins an ID that no marker or pending line carries.
4. It fails when a `begin` call passes the literal `nil` as `cliCommand` and its function carries neither a gap marker nor an exemption marker, and when a marker belongs to no `begin` call.
5. It fails when the function that holds a `begin` call is named in no test under `Tests/LungfishAppTests` that calls `RecordedCLICommand.parse`, `parseScript` or `assertCLIParityGap` and also names the type that holds the call or the stem of its source file. The sites that failed this when the ratchet landed are listed in `cli-parity-gaps.untested`, and that list may only shrink.

`--print` lists every site with its status. Exempt rows are listed and are not counted. The value falls to 0 as the gaps close.
