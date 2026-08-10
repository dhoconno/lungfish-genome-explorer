# VSP2 TrimGalore Deduplication Visibility Design

## Goal

Make VSP2 imports that use TrimGalore accurately communicate and preserve the
work they perform. The import must continue to run the VSP2 recipe's
deduplication and trimming stages efficiently, make the combined fastp stage
auditable, and warn at invocation time that TrimGalore's `--clumpify` workflow
also performs its normal adapter, quality, and minimum-length filtering.

This is a visibility and provenance correction. It does not change the selected
VSP2 recipe, the fastp arguments, TrimGalore's filtering behavior, or the final
FASTQ format.

## Observed Behavior

The VSP2 recipe declares consecutive `fastp-dedup` and `fastp-trim` steps. The
recipe engine deliberately fuses those steps into one fastp process, and that
process receives `--dedup`. Recent imported bundles confirm that deduplication
therefore ran.

Two presentation problems make the result look otherwise:

1. The fused process is represented by only one joined label, so the durable
   record does not expose its logical recipe components clearly.
2. The importer attributes the entire input-to-output read-count reduction of
   the fused process to deduplication, even though quality, adapter, and length
   filtering run in the same process. That number is not a valid dedup-only
   count.

The fused fastp process currently discards its native JSON and HTML reports. The
loss of the JSON report removes useful audit evidence about the process.

Separately, the UI calls TrimGalore a compression tool. The invoked
`trim_galore --clumpify` command also performs TrimGalore's normal adapter,
quality, and minimum-length filtering before reordering and compression. The
behavior is acceptable, but it is not apparent when the import is invoked.

## Scope

The change covers recipe execution records, recipe-step artifact persistence,
the read-reduction summary, the FASTQ import sheet, the import operation log,
and focused tests for the VSP2-plus-TrimGalore configuration.

The change does not split the two fastp recipe steps into separate processes,
alter recipe ordering, change scientific command-line arguments other than the
path used to retain fastp's JSON report, add an HTML report, or modify
TrimGalore's filtering defaults.

## Fused Fastp Representation

The recipe planner will retain the ordered logical step names that contributed
to a fused fastp process. The physical execution remains one process with the
same combined fastp arguments, including `--dedup`.

The resulting `RecipeStepResult` will carry ordered logical component IDs and
display names in an optional, backward-compatible field. It will also retain
the actual process exit status, start and completion timestamps, and useful
bounded stderr. Existing metadata without the additive fields will decode with
empty or `nil` values. All copy and path-rewrite helpers for recipe results will
preserve the fields.

Progress and provenance will describe the physical stage as a combined stage,
using language equivalent to **Remove PCR duplicates + Adapter + quality trim**,
while its metadata identifies `fastp-dedup` and `fastp-trim` as the logical
components. This records what was requested without pretending that two
processes ran.

Progress will use the number of physical plan entries as its denominator. A
fused process emits one progress completion and one duration rather than
leaving index gaps based on the larger logical-step count.

## Fastp JSON Artifact

For a fused fastp process, the recipe engine will allocate a temporary JSON
report path and pass it through fastp's existing `-j` option. The JSON file will
be returned as a recipe-step auxiliary output. The existing batch-import
materialization path will copy it into the final bundle's
`metadata/recipe-step-artifacts` directory and rewrite metadata to the final
stored path.

The report is supporting evidence for the combined physical process. It will
not be interpreted as an exact count of reads removed only by deduplication
unless fastp exposes such a count unambiguously. The implementation will not
retain the optional HTML report.

Artifact provenance must continue to record the final stored path, checksum,
file size, producing command and version, resolved options, input and output
paths, runtime identity when applicable, exit status, wall time, and useful
stderr under the repository's existing provenance machinery. The logical
component IDs and names will also be bridged into the canonical provenance
step's resolved options; the producing tool remains `fastp`.

## Read-Reduction Summary

`RecipeAppliedInfo` will distinguish a standalone deduplication step from a
fused step containing deduplication plus filtering:

- A standalone deduplication result may continue to report its input/output
  delta as deduplication removal.
- A fused deduplication-and-trimming result will not expose its delta through
  the deduplication-only summary. A separate component lookup will establish
  that deduplication ran, and the combined stage may report its aggregate delta
  only under combined-stage wording.

The import operation event will use the same terminology. This keeps the useful
read-count delta while removing the scientifically unsupported attribution.
The recipe inspector will state: **Deduplication: Performed in combined fastp
pass; an exact dedup-only removed count is unavailable.** Legacy fused records
will be recognized conservatively from their combined step name or from
`--dedup` together with trimming arguments.

## TrimGalore Invocation Note

When TrimGalore is selected in the FASTQ import sheet, a concise note will
appear beside the compression-tool controls:

> Trim Galore also performs adapter detection/removal, quality trimming, and
> short-read filtering.

The note will be hidden for other clumping tools. It describes the behavior
already invoked by the selected tool and does not modify the executable command.

Immediately before invoking the resolved TrimGalore command, a structured
notice will be emitted once to the operation log: **Trim Galore --clumpify also
performs adapter/quality filtering and may remove short reads.** This also
applies when an automatic tool choice resolves to TrimGalore. It makes the
behavior visible both before invocation and in the durable run narrative. A
shared source of disclosure wording will keep the UI and operation log
consistent without inferring behavior from CLI argument strings.

## Compatibility and Failure Handling

The new logical-components metadata field is optional and defaults to an empty
array while decoding old bundles. Existing recipe metadata remains readable.
The physical fastp and TrimGalore behavior remains unchanged.

If fastp succeeds but does not create a readable requested JSON report, the
recipe import will fail before publishing the final bundle. The implementation
will not manufacture an artifact or silently publish incomplete provenance. If
fastp itself fails, the existing process failure path remains authoritative.
Actual status, timestamps, duration, and normalized stderr from the process
will be propagated rather than synthesized later by the importer.

Temporary report files use the recipe execution's existing temporary workspace
and are moved or copied through the established auxiliary-output path, avoiding
external or user-selected destinations.

## Testing

Development will follow test-driven changes with focused RED/GREEN evidence.
Coverage will include:

- planning consecutive VSP2 fastp steps as one physical process with ordered
  logical components and `--dedup` retained;
- executing a fused step with a JSON report path instead of `/dev/null`, then
  exposing the created report as an auxiliary output;
- encoding, decoding, copying, and path-rewriting `RecipeStepResult` while
  preserving logical component names, actual execution evidence, and
  compatibility with old metadata;
- materializing the fastp report into the final bundle and retaining final-path
  provenance, checksum, and size;
- suppressing a fused read-count delta from the deduplication-only summary,
  while preserving standalone deduplication summaries and identifying that the
  combined stage performed deduplication;
- emitting one progress completion for each physical process;
- showing the TrimGalore invocation note only for TrimGalore and emitting it
  once immediately before explicit or automatically resolved TrimGalore
  execution;
- building CLI arguments that contain both
  `--recipe vsp2-target-enrichment` and `--clumping-tool trim-galore`;
- preserving the expected TrimGalore and fused fastp command arguments.

Focused tests will run first, followed by the relevant package suites and a
fresh debug application build.

## Alternatives Considered

### Split deduplication and trimming into two fastp processes

Separate processes would provide separate input/output deltas, but they would
double FASTQ I/O, change current recipe execution semantics, and still would not
necessarily provide a perfect biological duplicate count. The user requested
that TrimGalore continue in the same way, and no execution split is needed to
make the workflow clear and auditable.

### Keep the fused record and add only UI text

This is the smallest visible patch, but it leaves the durable recipe result
ambiguous, discards fastp's native evidence, and continues to misattribute the
combined read reduction to deduplication. It does not resolve the provenance
problem.

### Parse the fastp report into a dedup-only headline number

The report is valuable evidence, but a derived dedup-only removal count should
not be presented unless fastp defines one that can be mapped unambiguously to
the recipe stage. Retaining the raw report and accurately labeling the combined
delta is safer and more reproducible.

The recommended design keeps the existing efficient execution, adds a small
backward-compatible description of its logical components, retains the native
JSON evidence, and makes TrimGalore's existing filtering explicit at invocation.
