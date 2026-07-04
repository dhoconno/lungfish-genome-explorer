# LungfishKit — Deferred Items (Phase 4)

Module: `Sources/LungfishKit/**` (47 files, ~11K LOC). Shared UI/infra kernel.
Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests
(`--filter LungfishKitTests`) -> independent adversarial review -> revert-on-uncertainty
-> commit.

Kit-specific binding invariants (never violate / refactor away):
- **A leaf or the kernel may NEVER reference a type defined in `LungfishApp`** (forbidden
  cycle). Flag any such reference.
- `OperationCenter` is the source-of-truth for the `update()` + `log()` pairing consumed by
  every pipeline op. Preserve its public API and the op-model types
  (`OperationType`/`OperationLogEntry`/`OperationLogLevel`/`OperationRouteContext`/
  `OperationRetryMetadata`).
- macOS 26 API rules (UI-heavy module): NO `NSSplitViewController` delegate methods,
  `lockFocus`, `wantsLayer`, `runModal`, `synchronize`. Do not introduce them; flag existing.
- Background->MainActor dispatch rules; brand colors live here (`LungfishColors`); accent
  Lungfish Orange `#D47B3A`.
- NEVER write the literal `Task {` immediately followed by `@MainActor`.

Big files (audit solo, largest first): BlastResultsDrawerTab (1946),
MiniBAMViewController (1870), LungfishHelpContent (1007), BatchTableView (974),
OperationCenter (731), MetadataColumnController (512). Clusters: the BLAST drawer cluster,
split-pane infra, pickers, small view components.

## Deferred items

_(none yet — populated per batch as uncertain changes are reverted)_
