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
| Commands | 82 | 82 | 2 | 80 | 0 |
| Support | 4 | 4 | 0 | 4 | 0 |
| Output | 2 | 2 | 0 | 2 | 0 |
| Options | 1 | 1 | 0 | 1 | 0 |
| (root) | 1 | 1 | 0 | 1 | 0 |
| **TOTAL** | **90** | **90** | 2 | 88 | 0 |

### Per-file APPLIED / DEFERRED notes

APPLIED (CLI batch 1 plus 2026-07-04 expert-review cleanup):
- `Commands/ImportCommand.swift`: remove dead file-private `scanForFiles(in:extensions:)`
  (~1742-1759) — grep-verified exactly one occurrence (the definition), zero callers in Sources +
  Tests. (Sibling `scanRegularFilesRecursively` is live, kept.)
- `Commands/FastqCommand.swift`: remove dead private `saveProvenance(...)`
  (~620-639, in FastqQualityTrimSubcommand) — grep-verified zero callers in Sources + Tests. Its
  callee `makeProvenanceRun` stays live via `provenanceRunForTesting`.
- `Commands/FastqCommand.swift`: remove dead module-level `writeWorkflowRun(...)`.
  A post-batch expert review found it became zero-caller after `saveProvenance(...)` was removed.
- `Commands/FastqCommand.swift`: remove the discarded `wallTime` binding in
  `FastqQualityTrimSubcommand.run()`. Provenance wall time is recorded from `startedAt` by
  `recordFASTQNativeToolProvenance`, so this local value was a no-op.

DEFERRED (audited, low-value / subtle — NOT applied):
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

- `b9534102` — batch 1: 2 dead private functions (ImportCommand.scanForFiles,
  FastqCommand.saveProvenance). Scoped-green (859/0). 15 big files (>=800L) audited.
- 2026-07-04 expert-review commit — removes FastqCommand.writeWorkflowRun and the discarded
  quality-trim wall-time local.

## Phase 7 (LungfishCLI) — audit COMPLETE

90/90 files audited (100% coverage — reconciled against `find Sources/LungfishCLI -name '*.swift'`
= 90; every directory row audited == total). 15 big files (>=800L) solo + 8 infra
(root/Options/Output/Support) + 68 Commands in 4 directory-sweep chunks. Applied: 1 committed
batch plus expert-review cleanup, **3 provably-safe dead-private-function removals** and one
no-op wall-time cleanup. The layer is statement-level
clean (same pattern as all prior modules); value beyond the 2 removals is in DEFERRED file splits
(the big command files — same-module extension seams, catalogued below).

CLI-clean: NO `import LungfishKit` anywhere; NO direct `GlobalOptions()` init (all use
`@OptionGroup` / `.parse([])`); NO persisted `.sam` alignment writes; NO `%s`-in-`String(format:)`;
NO forbidden GCD->MainActor hops; version literals untouched.

VERIFY-EVERY-CLAIM caught the recurring auditor misfire: a `private` helper CALLED at even one
site is LIVE, not dead. The "8 dead statics" (GenotypeAIHaplotypingSubcommand) and "2 dead
file-private" (BAMCommand) proposals were all live single-/few-caller helpers -> rejected. Cross-
subcommand byte-identical helpers (BuildDbCommand directorySize/formatBytes, TreeCommand 3
EventEmitters, the two importReferenceViaSharedService / replayArgv / validate() pairs) are in
DIFFERENT types -> NOT dedup-able, correctly not proposed.

### Deferred SPLITS (each its own reviewed pass; same-module extension moves)
The large command files are split candidates (drop file size, no logic change). Highest value:
FastqCommand (3208 — 30+ subcommands; split per subcommand-category extension), MSACommand (2922 —
30+ subcommand structs), ImportCommand (1774 — MetadataSubcommand out), BuildDbCommand (1732 —
per-classifier subcommand files + hoist `updateUniqueReadsInDB`), FetchCommand (1700 — provenance
helper extraction), TreeCommand (1403 — event-emitter file), GenotypeAIHaplotypingSubcommand (1384
— extract the `AIHaplotypingInputTableLoader` CSV/JSON parser), GenotypeXlsxWorkbookWriter (1005 —
extract the Budde-palette / style-ID mapping). All are ArgumentParser structs whose run()/validate()
stay reachable; verify per-seam that any cross-file helper is `internal` (private doesn't span
files).

## Deferred items / splits / flags

Module-boundary green-bar: recorded in results.md (full suite --skip ONT + ONT in isolation).
