# Leaf UI Modules — Deferred Items (Phase 5)

Nine leaf feature modules (~68 files, ~41K LOC):
`LungfishTwelveSUI` (11f/2.5K), `LungfishAlignmentUI` (1f/169), `LungfishAssemblyUI` (7f/1.3K),
`LungfishNvdUI` (3f/2.6K), `LungfishNaoMgsUI` (5f/4.0K), `LungfishTaxTriageUI` (6f/6.6K),
`LungfishEsVirituUI` (6f/5.0K), `LungfishGenotypeUI` (27f/17.1K — largest),
`LungfishPhylogeneticsUI` (2f/1.5K).

Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests
(`--filter <Leaf>UITests`) -> independent adversarial review -> revert-on-uncertainty ->
commit. ONE full module-boundary green-bar after ALL leaf batches complete (siblings are
independent; bisect any regression to its leaf).

Leaf-specific binding invariants (never violate / flag):
- **NO leaf may reference a type defined in `LungfishApp`** (the forbidden cycle). Each leaf
  exposes `on...` callbacks; the `ViewerViewController+<X>.swift` glue that wires app services
  to those callbacks stays in `LungfishApp`. Flag any LungfishApp reference.
- macOS 26 API rules (AppKit-heavy VCs): NO `NSSplitViewController` delegate methods,
  `lockFocus`, `wantsLayer`, `runModal`, `synchronize`. Flag existing; never introduce.
- Background->MainActor dispatch rules; distinguish legitimate same-actor `Task { @MainActor }`
  on an already-@MainActor VC from the forbidden GCD/notification-context hop.
- Preserve display-state/export-service structure; `@testable`-pinned internals + `on...`
  callback surface are NOT tightenable.
- NEVER write the literal `Task {` immediately followed by `@MainActor`.
- GenotypeUI files (GenotypeComparisonMatrixView, GenotypeOutlineView, GenotypeHaplotypeTapeView)
  are on main and safe to edit directly (per project memory).

Big files (audit solo, largest first): GenotypeResultViewController (5756),
TaxTriageResultViewController (4738), NaoMgsResultViewController (2809),
GenotypeComparisonMatrixView (2499), NvdResultViewController (2476),
ViralDetectionTableView (1968), EsVirituResultViewController (1937),
PhylogeneticTreeViewController (1495), GenotypeCallEvidenceView (1412),
TwelveSAmpliconResultViewController (1183). Then per-module clusters for the smaller files.

## Deferred items

_(none yet — populated per batch as uncertain changes are reverted)_
