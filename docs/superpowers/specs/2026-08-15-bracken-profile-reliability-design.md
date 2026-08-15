# Database-Aware Bracken Profile Reliability

**Date:** 2026-08-15
**Status:** Approved design

## Objective

Make Lungfish's Kraken2-plus-Bracken profile workflow scientifically honest for
databases whose taxonomy does not support the current species-level default.
SILVA and Greengenes profiles automatically resolve to genus, explicit CLI rank
requests remain explicit, and every profile run reports whether Bracken actually
completed or whether only the valid Kraken2 classification is available.

This change keeps Bracken read length fixed at the already-built 150-base
distribution. Mixed or inferred read-length support is out of scope.

## Scientific Problem

The current pipeline always defaults Bracken to species. SILVA and Greengenes
Kraken reports can terminate at genus, so Bracken exits without producing a
profile. Lungfish currently treats that exit as a warning, persists only an
optional Bracken path, marks the workflow completed, and lets CLI and batch UI
claim success. The same path also detects the Bracken version with its default
version flags even though Bracken 3.0.1 reports its version with `-v`.

The result is ambiguous: a valid Kraken2 classification survives, but callers
cannot distinguish a completed profile from an unmet profile request. The rank
decision is also not connected to stable database identity, and the exact
requested and resolved Bracken settings are not durably persisted.

## Rank Request and Database Capability Model

Add a public, Codable Bracken request model:

```swift
public enum BrackenRankRequest: Sendable, Codable, Equatable {
    case automatic
    case explicit(TaxonomicRank)
}

public struct BrackenProfileRequest: Sendable, Codable, Equatable {
    public let rank: BrackenRankRequest
    public let readLength: Int
    public let threshold: Int
}
```

The defaults are `automatic`, read length `150`, and threshold `10`.
`ClassificationConfig` carries an optional request plus the selected database's
stable `catalogID` and `installationRecipe`. Optional fields keep old result
sidecars decodable. A legacy profile config without a request resolves to the
same automatic defaults; a classify or extract goal does not request Bracken.

Add a small database capability/resolution API whose input is the stable catalog
identity and installation recipe, not a display-name substring:

- `kraken2-special-silva` or `.kraken2Special(.silva)` resolves automatic rank
  to genus (`G`).
- `kraken2-special-greengenes` or `.kraken2Special(.greengenes)` resolves
  automatic rank to genus (`G`).
- all other Kraken2 database identities resolve automatic rank to species (`S`)
  for compatibility.
- stable built-in catalog identity takes precedence if identity and recipe ever
  conflict; the resolution records which capability rule supplied the answer.

The registry's selected `MetagenomicsDatabaseInfo` is the source of these
identity fields. The app wizard passes them into every generated config. The CLI
does the same after registry lookup. A display name may be recorded for humans,
but is never the capability decision key.

An explicit request is never replaced by a database default. Bracken supports
the rank codes `D`, `P`, `C`, `O`, `F`, `G`, and `S`. An explicit unsupported
rank remains recorded as requested and produces a degraded preflight outcome;
it is not converted to species. The existing fallback in
`brackenLevelCode(for:)` is removed.

The CLI `--bracken-level` option becomes optional. Absence means automatic;
presence means explicit. Help text explains that automatic is genus for SILVA
and Greengenes and species otherwise. `--profile` constructs a config with
`goal: .profile`; it no longer relies only on choosing a different pipeline
method after constructing a classify config.

## Resolved Settings and Durable Outcome

Every returned and persisted `ClassificationResult` includes a structured
profile outcome:

```swift
public enum BrackenProfileState: String, Sendable, Codable, Equatable {
    case notRequested
    case completed
    case degraded
}

public struct BrackenProfileOutcome: Sendable, Codable, Equatable {
    public let state: BrackenProfileState
    public let requestedRank: BrackenRankRequest?
    public let resolvedRank: TaxonomicRank?
    public let resolutionSource: String?
    public let readLength: Int?
    public let threshold: Int?
    public let toolVersion: String?
    public let reasonCode: String?
    public let message: String?
}
```

The exact public spelling may be refined during implementation, but these data
and semantics are required. `notRequested` is used for Kraken-only classify and
extract runs. `completed` requires a successful Bracken invocation, a real
output file, and a successful merge. `degraded` means Kraken2 completed and its
outputs remain valid, but the requested profile did not complete. A degraded
outcome always has a machine-readable reason and a user-readable explanation.

Required degraded reasons include:

- requested rank is not supported by Bracken;
- resolved rank is absent from the actual kreport;
- `database<readLength>mers.kmer_distrib` is missing, not a regular file, empty,
  or unreadable;
- Bracken is unavailable;
- Bracken exits nonzero;
- Bracken reports success but does not produce a readable, non-empty output;
- Bracken output cannot be parsed or merged.

The result sidecar stores this outcome. Older sidecars without it infer
`completed` only when a referenced Bracken file exists; otherwise they infer
`notRequested` because historical data cannot prove why Bracken is absent.
Copyable-command fallback uses the persisted resolved rank, read length, and
threshold rather than hard-coded species defaults.

## Pipeline Preflight and Execution

Kraken2 remains the first scientific step. Once its report exists and parses,
the profile path resolves the request and performs these checks before the
Bracken profiling command:

1. Confirm the resolved rank is one of Bracken's supported ranks.
2. Confirm the parsed kreport contains at least one node at exactly that rank.
3. Confirm `<database>/database<readLength>mers.kmer_distrib` is a readable,
   non-empty regular file.

Failure of any check skips the Bracken profiling command and returns a degraded
result with valid Kraken output. The preflight is recorded as a Lungfish
provenance step with reproducible argv, resolved options, checked paths, timing,
exit status, and useful diagnostic stderr. A missing file is recorded as an
intended/check path option rather than falsely claimed as a consumed file.

If preflight passes, detect the Bracken version with `bracken -v`, construct the
command from the resolved request, and invoke it. The command always records
`-r 150`; no sample inspection or mixed-read correction is introduced. Before
the run, remove only the current run's known Bracken target if it exists so a
stale file cannot be mistaken for new output. A failed or malformed Bracken
output is not exposed as a successful scientific output.

Bracken-stage failures are converted to a degraded result rather than thrown
after Kraken succeeds. Failures before a valid parsed Kraken report remain hard
pipeline failures. Sidecar or provenance write failures also remain hard
failures because an unrecorded scientific result violates Lungfish's provenance
contract.

## Provenance Contract

Sample-level pipeline and CLI provenance record:

- workflow and tool versions, including the value returned by `bracken -v`;
- exact top-level argv, Kraken argv, preflight argv, and Bracken argv when run;
- durable replay argv/command;
- explicit user options separately from defaults and resolved values;
- database name, version, final path, payload digest, catalog ID, and recipe;
- requested rank mode/value, resolved rank, capability source, read length 150,
  threshold, and outcome/reason;
- conda/runtime identity for every invoked managed tool;
- input/output paths, checksums, sizes, roles, and dependencies;
- per-step and total exit status, wall time, and bounded useful stderr.

A completed profile has overall exit status zero. A degraded requested profile
has a nonzero overall scientific-workflow exit status and a failed legacy run
status, while its successful Kraken step and checksummed Kraken outputs remain
present. This avoids claiming the requested profile completed without discarding
the useful classification. A classify-only request remains a normal completed
workflow.

The CLI provenance envelope uses the structured result as its source of truth;
it does not synthesize a successful Bracken step or exit status. Requested,
default, and resolved values must agree between config, sample sidecar, pipeline
envelope, and CLI envelope.

Classification batches gain canonical root provenance. The root envelope rolls
up child sample envelopes and records the exact batch workflow identity,
reproducible app command, database identity, resolved profile options and outcome
counts, original sample inputs, child outputs, summary TSV, batch manifest,
SQLite index when present, checksums, sizes, timings, exit status, and useful
child stderr. Root provenance is written after all root outputs exist and before
the operation is presented as complete. Failure to write it is a batch failure;
sample directories are retained for diagnosis and recovery.

## CLI Behavior

Without `--profile`, behavior remains Kraken-only. With `--profile`:

- no `--bracken-level` means automatic database-aware resolution;
- an explicit `--bracken-level` is validated and preserved exactly;
- the printed configuration shows requested mode and resolved rank;
- a completed profile prints a success message and exits zero;
- a degraded profile prints its Kraken summary and output paths, clearly says
  that Kraken completed but Bracken did not, and exits with the workflow-error
  code after provenance is safely written;
- it never prints the existing unconditional “Classification completed” success
  line for a degraded profile.

The valid Kraken output directory is not deleted on the degraded exit.

## App and Batch Behavior

The wizard has no rank control and therefore always creates an automatic
request. SILVA and Greengenes resolve to genus through their selected registry
entry; other databases retain species as the default.

For a single run, a degraded result is displayed in the taxonomy viewer and the
operation ends through `completeWithWarning`, with a detail message naming the
resolved rank and reason. It is not marked as a successful profile.

For a batch:

- returned degraded results stay in their sample directories and participate in
  Kraken aggregation;
- summary rows use `ok`, `degraded`, or `failed` and include profile state,
  requested rank, resolved rank, and diagnostic message columns;
- the manifest schema is bumped and stores per-sample status/message plus
  completed/degraded/failed counts, with backward-compatible decoding for old
  manifests;
- any degraded or failed sample completes the operation with warnings when at
  least one valid Kraken result exists;
- analysis-manifest entries and UI detail text identify degraded profile results;
  they do not use an unqualified completed profile status;
- true pre-Kraken failures keep their existing failed-row behavior.

## Testing Strategy

Use strict test-driven development with faked managed-tool execution and small
kreport/database fixtures. No test downloads or builds a real database.

Model tests cover Codable compatibility, stable identity propagation, automatic
SILVA/Greengenes genus resolution, ordinary-database species resolution,
explicit-rank preservation, and unsupported-rank handling.

Pipeline tests cover exact preflight order and diagnostics, missing kreport rank,
missing/empty distribution, `bracken -v`, exact genus/species argv, nonzero and
missing-output Bracken outcomes, merge failure, successful completion, stale
output rejection, sidecar round trips, legacy sidecars, and honest provenance.

CLI tests cover optional rank parsing, `goal: .profile`, registry identity
propagation, explicit/default/resolved option maps, degraded exit semantics,
preserved output, and no unconditional success message.

App/batch tests cover wizard automatic requests, warning completion for one
sample, retained degraded directories, summary/manifest status, aggregate counts,
analysis-manifest status, and classification root provenance including degraded
child evidence.

## Non-Goals

- Estimating read length from FASTQ or supporting mixed read lengths.
- Building any distribution other than the existing 150-base distribution.
- Adding a GUI rank selector.
- Changing Kraken confidence, hit-group, or memory-mapping defaults.
- Reinterpreting taxonomic calls or hiding explicit unsupported CLI requests.
- Treating a failed Bracken artifact as a usable abundance profile.

## Acceptance Criteria

1. Automatic SILVA and Greengenes profiles resolve to genus using stable catalog
   identity or installation recipe; other databases remain species by default.
2. Explicit CLI rank requests are recorded and either executed unchanged or
   surfaced as degraded; none are silently rewritten.
3. Lungfish checks the actual kreport rank and exact non-empty 150-base Bracken
   distribution before the profiling command.
4. Bracken version detection uses `-v` and captures Bracken 3.0.1 correctly.
5. Every result and sidecar distinguishes not requested, completed, and degraded
   profiling, while valid Kraken outputs survive all Bracken-stage failures.
6. CLI, app, batch TSV, batch manifest, result summary, and analysis metadata do
   not claim full profile success for a degraded result.
7. Sample and batch-root provenance contain exact commands, complete option
   resolution, stable database identity, runtime identity, checksums, sizes,
   statuses, wall time, and useful stderr.
8. Read length remains explicitly resolved to 150 everywhere.
9. Focused tests and the required broader verification suite pass without live
   scientific tools or network access.
