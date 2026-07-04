# LungfishCLI — Deferred Items (Phase 7)

Module: `Sources/LungfishCLI/**` (90 files). Executable command layer (ArgumentParser).
Layout: Commands 82, Support 4, Output 2, Options 1, root 1.
Protocol: audit -> apply (behavior-preserving only) -> `swift build --package-path <wt>
--skip-update` then scoped `swift test --package-path <wt> --skip-update --filter LungfishCLITests`
-> independent adversarial review -> revert-on-uncertainty -> commit. Full module-boundary
green-bar (--skip ONT + ONT in isolation) at the CLI boundary.

CLI-specific binding invariants (never violate / flag):
- **`LungfishCLI` does NOT import `LungfishKit`** (layering rule — verified: 0 imports at start).
  Flag any new LungfishKit import.
- **CLI/GUI parity**: CLI commands mirror GUI operations; a CLI command's option surface + output
  contract is a user-facing API — caller-less does NOT mean dead (it is the CLI entry surface).
  Do NOT remove/trim command options, `@Option`/`@Flag`/`@Argument` decls, help text, or output
  fields.
- **`GlobalOptions.parse([])` not direct-init**: `ArgumentParser.GlobalOptions()` direct-init
  crashes under `@MainActor` isolation; the code MUST use `GlobalOptions.parse([])`. Flag/never
  introduce a direct `GlobalOptions()` init.
- **Version-string sites** must not drift (LungfishCLI.swift, SequenceCommand.swift,
  PrimerCommand.swift + 2 test expectations). Do NOT touch version literals.
- `%s` in `String(format:)` with Swift Strings crashes SIGSEGV — use `%@`/interpolation (flag if
  found, do not introduce).
- Background->MainActor dispatch rules; distinguish legitimate same-actor `Task { @MainActor }`
  on an already-@MainActor type from the forbidden GCD/notification-context hop. NEVER write
  literal `Task {` then `@MainActor` as an intro.
- OperationCenter update()+log() pairing where CLI drives ops; NEVER save alignment as SAM;
  materialization / virtual-FASTQ preview-vs-full semantics untouched; Codable/provenance schema
  untouchable.

Big files (audit solo, largest first): FastqCommand (3208), MSACommand (2922),
ImportCommand (1774), BuildDbCommand (1732), FetchCommand (1700), TreeCommand (1403),
GenotypeAIHaplotypingSubcommand (1384), BAMCommand (1319), WorkflowCommand (1208),
GATKCommand (1075), MarkdupCommand (1047), BundleCommand (1032), GenotypeXlsxWorkbookWriter
(1005), VariantsCommand (998), ExtractReadsCommand (968). Then Commands/Support/Output sweeps.

WHAT THE PATTERN HAS BEEN (expect the same): every module so far was already statement-level
clean. Provably-safe applies were dead PRIVATE code (grep-verified zero callers), dead-code
islands, exact-equivalent intra-type dedup, redundant syntax, and MINIMAL access tightening.
Large value is in DEFERRED file splits. TRAP note for CLI: a caller-less command/option is the
user-facing CLI surface — NOT dead. `run()`/`validate()`/parse helpers are ArgumentParser
protocol entry points — NOT dead.

## Coverage ledger (every one of 90 files accounted for)

Columns: files total / audited / applied / clean / deferred.

| Directory | total | audited | applied | clean | deferred |
|---|---|---|---|---|---|
| Commands | 82 | 0 | 0 | 0 | 0 |
| Support | 4 | 0 | 0 | 0 | 0 |
| Output | 2 | 0 | 0 | 0 | 0 |
| Options | 1 | 0 | 0 | 0 | 0 |
| (root) | 1 | 0 | 0 | 0 | 0 |
| **TOTAL** | **90** | **0** | 0 | 0 | 0 |

### Per-file APPLIED / DEFERRED notes

APPLIED (CLI batch 1 — pending build+commit):
- `Commands/ImportCommand.swift`: remove dead file-private `scanForFiles(in:extensions:)`
  (~1742-1759) — grep-verified exactly one occurrence (the definition), zero callers in Sources +
  Tests. (Sibling `scanRegularFilesRecursively` is live, kept.)
- `Commands/FastqCommand.swift`: remove dead private `saveProvenance(...)`
  (~620-639, in FastqQualityTrimSubcommand) — grep-verified zero callers in Sources + Tests. Its
  callees `makeProvenanceRun` (used by provenanceRunForTesting) and module-level `writeWorkflowRun`
  (used elsewhere) both stay live -> no cascade.

DEFERRED (audited, low-value / subtle — NOT applied):
- `Commands/FastqCommand.swift:561` `_ = wallTime`: `wallTime` (computed at 508) is discarded here;
  provenance now uses `startedAt`. Removing the discard alone leaves `let wallTime` unused
  (warning); the clean edit removes both the 508 binding and the 561 discard. Near-zero value,
  touches a provenance-recording site -> deferred.
- `Commands/MarkdupCommand.swift:742` `provenanceExplicitOptions(for:)`: currently a byte-identical
  wrapper over `provenanceResolvedOptions(for:)`, but the explicit-vs-resolved distinction is a
  PROVENANCE-SCHEMA concept (explicit = user-set options vs resolved = incl. defaults). The two
  names may be intentionally distinct even though the bodies coincide today -> deferred (provenance
  semantics, not a safe mechanical dedup).

REJECTED candidates (audited, proven NOT safe — a future pass must not re-propose):
- GenotypeAIHaplotypingSubcommand "8 dead statics" (resolveFormat/loadJSONCalls/loadDelimitedCalls/
  requiredColumn/optionalColumn/value/normalizedHeader/consume in `AIHaplotypingInputTableLoader`):
  an auditor mislabeled LIVE single-/few-caller helpers as dead. Each IS called (e.g. resolveFormat
  is called at 1152; def at 1165). "Used at only one site" != dead. All kept. File is CLEAN.
- BAMCommand "2 dead file-private" (trimmedOptionalTrackID / isPortableAnnotationTrackID): both are
  LIVE — trimmedOptionalTrackID is called at 294/566/852 (def 86). Kept. File is CLEAN.
- Cross-subcommand duplicate helpers in BuildDbCommand (directorySize/formatBytes/fileSize) and
  TreeCommand (3 CLIEventEmitter types): same-named but in DIFFERENT subcommand types -> NOT
  intra-type-dedup-able (and fileSize variants are non-identical). Correctly not proposed.

## Applied batches (commit log)

_(one line per committed batch)_

## Deferred items / splits / flags

_(populated per batch)_
