# LungfishApp — Deferred Items (Phase 6)

Module: `Sources/LungfishApp/**` (409 files, ~188K LOC). LARGEST module (composition roots).
Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests
(`--filter LungfishAppTests`) -> independent adversarial review -> revert-on-uncertainty ->
commit. Full module-boundary green-bar at the App boundary.

App-specific binding invariants (never violate / flag):
- **Composition roots STAY in App** (do NOT extract into leaves): `ViewerViewController`,
  `MainSplitViewController`, `InspectorViewController`, `SidebarViewController`, the IQ-TREE
  inference dialog cluster, the Taxonomy hub (CzId + Mapping stay too — Mapping's
  `ReferenceBundleViewportController` embeds `ViewerViewController`). App importing leaves is
  fine (App->leaf OK); a leaf/kernel referencing an App type is the forbidden cycle.
- **Generation-counter patterns** on async fetches reject stale results
  (`ViewerViewController.{fetchAnnotations,fetchSequence,fetchVariants}Async`) — do NOT
  refactor away the generation guards.
- macOS 26 API rules (AppKit-heavy): NO `NSSplitViewController` delegate methods, `lockFocus`,
  `wantsLayer`, `runModal`, `synchronize`. Flag existing; never introduce.
- Background->MainActor dispatch rules; distinguish legitimate same-actor `Task { @MainActor }`
  from the forbidden GCD/notification-context hop. NEVER write literal `Task {` then `@MainActor`.
- OperationCenter update()+log() pairing where App code drives ops; materialization
  (`materializeInputFilesIfNeeded` in AppDelegate); never save alignment as SAM.
- Virtual-FASTQ materialization semantics (preview vs full reconstruction) untouched.

Big files (audit solo, largest first): AnnotationTableDrawerView (5224) + its extensions,
ViewerViewController (3762 — composition root, keep in App), DatabaseBrowserViewController
(3565), MultipleSequenceAlignmentViewController (3521), FASTQDatasetViewController (3032),
AppDelegate+ImportCenter (2843), SidebarViewController (2697 — composition root),
ReadStyleSection (2482), FASTQMetadataDrawerView (2115), FASTQOperationDialogState (2088),
SequenceViewerView (2069), ReadTrackRenderer (1973), WorkflowOperationDialogState (1928),
AppDelegate+Classification (1879), TaxonomyViewController (1783), OperationPreviewView (1764).
Then directory clusters (Views/Viewer, Views/Inspector, Views/Sidebar, Views/DatabaseBrowser,
Views/FASTQ, Views/Metagenomics, App/, Services/, etc.).

If tokens/time run short: complete whole batches, defer the untouched remainder EXPLICITLY
here (never leave a half-applied batch).

## Deferred items

_(none yet — populated per batch as uncertain changes are reverted)_
