# Tree Bundle Transform GUI Wiring — Design

Date: 2026-06-01
Status: Approved (user-approved 2026-06-01)
Author: dho + Claude

## Execution and release decisions (user-approved)

- **Implementation via sequential subagents on the main checkout.** SwiftPM holds one
  `.build/.lock` per checkout, so implementer subagents are dispatched ONE AT A TIME (no parallel
  builds, no worktrees). The lead reviews between phases and runs the single serialized build/test
  gate. The feature's phases are interdependent (runner → glue → callback wiring → tests), so this
  ordering is natural.
- **Work on a feature branch, then merge to `main`.** Implementation happens on a branch; after the
  green-bar gate it merges to `main`. The release must run from a clean tree at a commit that exists
  on origin (release gotcha: `gh release create --target <sha>` / tag operations require the commit
  pushed first).
- **Same-version hotfix DMG (`0.5.0-alpha11`).** This is a hotfix that KEEPS the version released this
  morning. Do NOT bump the ~8 hardcoded version sites or the 2 test expectations — they stay at
  `0.5.0-alpha11`.
  - This morning's `v0.5.0-alpha11` GitHub release + tag already exist (published 18:26 UTC) with a DMG,
    and `appcast-alpha.xml` already points at it.
  - Publish by **replacing artifacts in place on the existing tag**, which the release script does
    natively: pass `--github-release-tag v0.5.0-alpha11`. The script `gh release upload --clobber`s the
    new notarized DMG onto the SAME existing `v0.5.0-alpha11` release (line ~289), then regenerates
    `appcast-alpha.xml` and `--clobber`s it onto the mutable `sparkle-alpha` release (`--sparkle-publish-release sparkle-alpha`).
    No `gh release create` (no tag collision), no manual asset deletion.
  - **Auto-update DOES reach existing alpha11 users.** Sparkle compares `CFBundleVersion` (the build
    number), NOT the marketing string. The script derives `CFBundleVersion` from `git rev-list --count HEAD`
    (script lines ~424-425, written at ~254). The hotfix adds commits on top of this morning's alpha11, so
    the build number increases and Sparkle offers the update even though the marketing version stays
    `0.5.0-alpha11`. (This corrects an earlier assumption that same-version meant no auto-update.)
  - Canonical invocation (verify flags against the script at release time; the release-build memory is
    ~47 days old): `bash scripts/release/build-notarized-dmg.sh --team-id 29G3WN2GSA
    --notary-profile LungfishNotary --signing-identity "Developer ID Application: Pathogenuity LLC (29G3WN2GSA)"
    --github-release-tag v0.5.0-alpha11 --sparkle-generate-appcast <generate_appcast path>
    --sparkle-publish-release sparkle-alpha` with `LUNGFISH_SPARKLE_PUBLIC_ED_KEY` exported. The EdDSA
    private key is in the login Keychain, so `--sparkle-ed-key-file` is optional.
  - Release hygiene (from project memory): run from a CLEAN tree at a commit pushed to origin; do NOT
    `--reuse-archive` after a successful notarize+staple (it re-signs and corrupts the stapled bundle) —
    on any post-notarization failure, `rm -rf build/Release/Lungfish.xcarchive build/Release/*.dmg` and
    rebuild fresh.
  - Release notes: the script copies `docs/release-notes/v0.5.0-alpha11.md` when present. Since alpha11
    already shipped, decide at release time whether to append a hotfix note to that file (it will be
    re-uploaded to the release). Not a blocker for the code work.

## Problem

`PhylogeneticTreeViewController` (now in `Sources/LungfishPhylogeneticsUI/PhylogeneticTreeViewController.swift`)
exposes a callback `onTreeBundleOperationRequested: ((TreeBundleOperationRequest) -> Void)?`.
It is invoked when the user picks **Re-root Here** or **Extract Subtree as New Bundle…**
from a tree node's context menu. But the callback is never assigned anywhere in `Sources/` —
only in `Tests/LungfishAppTests/BundleViewerTests.swift`. As a result, those two menu items
no-op in the shipping app.

## Investigation: incomplete feature, not abandoned UI

A single commit, `910549e2` ("Implement tree bundle transform tools"), introduced:

- The GUI menu items + the `onTreeBundleOperationRequested` callback (in the VC), with unit tests.
- The full CLI: `lungfish tree reroot --on <selector>` and `lungfish tree extract-subtree --node <node>`,
  in `Sources/LungfishCLI/Commands/TreeCommand.swift`, with `Tests/LungfishCLITests/TreeCommandTests.swift`.
- The backing bundle methods `PhylogeneticTreeBundle.rerootedBundle(...)` /
  `extractSubtreeBundle(...)` / `relabeledBundle(...)`, with `Tests/LungfishIOTests/PhylogeneticTreeBundleTests.swift`.

The commit did **not** touch the construction site
(`Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift`) or
`ViewerViewController.swift`. The app-level GUI→CLI glue was simply never written.

Conclusion: the operations were meant to ship. The CLI half is complete, tested, and reachable
today (`lungfish tree reroot ...` works). Only the GUI bridge is missing. **We wire the callback**
(option a), rather than deleting working, tested functionality.

### Out of scope (already functional)

- **Tip relabel** (`applyTipLabelColumn`, the tip-label-column picker): purely in-memory in the VC,
  re-renders display labels from `metadata.tsv` columns. It does **not** use `onTreeBundleOperationRequested`
  and already works. No change.
- **Export Subtree…**: writes Newick via an `NSSavePanel` directly in the VC. Already works. No change.
- **Collapse Clade**: in-VC view state. The `.collapse` case of `TreeBundleOperation` exists but
  `requestTreeBundleOperation` is only called for `.reroot` / `.extractSubtree`; collapse is handled
  by `toggleSelectedCladeCollapse`. No callback dispatch for collapse. No change.
- The CLI, the bundle transform methods, and their tests are complete. No change.

## Goal

Wire `onTreeBundleOperationRequested` at the construction site so **Re-root Here** and
**Extract Subtree as New Bundle…** produce a new `.lungfishtree` bundle by invoking the existing CLI,
surfaced through `OperationCenter` exactly like `inferTreeFromMSAViaCLI` (the closest existing analog).

## Design

Mirror the established CLI-bridge pattern used by tree inference and MSA actions:
`OperationCenter.start(...)` → a `Task.detached` running an actor CLI runner that parses the CLI's
JSON event stream and drives `OperationCenter.update / log / complete / fail` → `complete(bundleURLs:)`
routes the new bundle to the sidebar/viewer via the existing
`onBundleReadyWithContext` → `handleMultipleDownloadsSync` path (no new display code).

### 1. New runner — `CLITreeTransformRunner`

New file `Sources/LungfishApp/Services/CLITreeTransformRunner.swift`, a focused near-copy of
`CLITreeInferenceRunner`. The only material difference is the JSON event names it parses. The reroot /
extract-subtree CLI already emits `treeTransform{Start,Progress,Complete,Failed}` events (see
`TreeTransformCLIEventEmitter` and `executeTreeTransform` in `TreeCommand.swift`), distinct from the
`treeInference*` and `msaAction*` event families, so a dedicated parser is the cleanest fit.

- `enum CLITreeTransformEvent { case start/progress/complete/failed }`
- `static func parseEvent(from:) -> CLITreeTransformEvent?` mapping the four `treeTransform*` events.
- `func run(arguments:operationID:) async throws -> CLITreeTransformResult` — identical structure to
  `CLITreeInferenceRunner.run`: stdout/stderr pipe draining with `OSAllocatedUnfairLock` stream state,
  background→MainActor dispatch via `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }`,
  cancellation check, `OperationCenter.shared.complete(id:detail:bundleURLs:[outputURL])` on success,
  `failOperation` on each error path.
- `func cancel()` terminating the process.

Rationale for a new runner over reusing `CLIMSAActionRunner`: that runner parses `msaAction*` events and
its completion strings/error copy are MSA-specific. Reusing it would mean teaching the CLI's tree-transform
path to emit `msaAction*` events (a CLI change we want to avoid) or overloading the runner with a second
event vocabulary. A ~250-line dedicated runner that matches `CLITreeInferenceRunner` line-for-line is the
lower-risk, more readable choice and keeps each runner single-purpose.

### 2. New glue — `performTreeBundleOperationViaCLI(_:)`

Add to `ViewerViewController` (in `ViewerViewController+AlignmentTreeBundles.swift`, beside
`displayPhylogeneticTreeBundle`). Signature:

```swift
func performTreeBundleOperationViaCLI(_ request: PhylogeneticTreeViewController.TreeBundleOperationRequest)
```

Behavior:

1. Switch on `request.operation`. Handle `.reroot` and `.extractSubtree`. For any other case
   (`.collapse`, should never arrive) return without action.
2. Resolve the enclosing project via the existing `Self.enclosingProjectURL(for: request.bundleURL)`
   (falling back to `projectURLForDerivedReferenceBundle()` as IQ-TREE does). If none, show the same
   blocking alert IQ-TREE uses ("No Project" / "Open a Lungfish project before …") and stop.
   (Decision: match IQ-TREE; no save-panel fallback.)
3. Guard `view.window` (same "No Window" alert as IQ-TREE) and `canWriteProjectOutputs(projectURL:workflowName:)`.
4. Compute the output URL in the project's **"Phylogenetic Trees"** folder using the existing helpers
   `Self.nextAvailableBundleURL(suggestedName:pathExtension:in:)` and `Self.sanitizedFilesystemStem(_:)`:
   - reroot: stem `"<source-bundle-stem>-rerooted"`
   - extract-subtree: stem `"<request.nodeLabel>-subtree"`
   - extension `"lungfishtree"`. Create the folder with `createDirectory(withIntermediateDirectories: true)`.
5. Build argv (the CLI is the source of truth for flags; see `RerootSubcommand.canonicalArgv` /
   `ExtractSubtreeSubcommand.canonicalArgv`):
   - reroot: `["tree", "reroot", "--bundle", <src>, "--on", request.nodeID, "--output", <out>, "--format", "json"]`
   - extract-subtree: `["tree", "extract-subtree", "--bundle", <src>, "--node", request.nodeID, "--output", <out>, "--format", "json"]`
   - We pass `request.nodeID` (the normalized node ID) as the selector, which both subcommands accept.
6. `OperationCenter.shared.start(title:detail:operationType: .phylogeneticTreeTransform, targetBundleURL: request.bundleURL, cliCommand:, routeContext: OperationRouteContext(projectURL:, windowStateScope:))`.
   Titles: "Re-root Tree" / "Extract Subtree". Detail names the node label / source.
7. `OperationCenter.shared.setCancelCallback(for: opID) { Task { await runner.cancel() } }`.
8. `Task.detached` running `CLITreeTransformRunner().run(arguments:operationID:)`, swallowing
   `CancellationError`, and on other errors dispatching to MainActor to `OperationCenter.shared.fail(...)` —
   identical to `runIQTreeInferenceViaCLI`.

Decision: these run **immediately on menu click**. No dialog — the selected node already supplies the
selector (`nodeID`/`nodeLabel`), unlike IQ-TREE which needs a model/bootstrap dialog.

A small private argv builder (free function or `enum` static, near the glue) keeps argv construction
testable in isolation; the exact shape mirrors the CLI's own `canonicalArgv`.

### 3. Assign the callback

In `displayPhylogeneticTreeBundle(at:)`, after the controller is created and the bundle displayed
(matching where `MultipleSequenceAlignmentViewController` wires its callbacks above):

```swift
controller.onTreeBundleOperationRequested = { [weak self] request in
    self?.performTreeBundleOperationViaCLI(request)
}
```

### 4. New operation type

Add to `OperationType` in `Sources/LungfishKit/OperationCenter.swift`, after `phylogeneticTreeInference`:

```swift
case phylogeneticTreeTransform = "Tree Transform"
```

No existing case fits cleanly (`phylogeneticTreeInference` is IQ-TREE specific and used for routing/labels;
reroot/extract are non-inference transforms). One short raw-string case is the minimal addition.

### 5. Completion → display (no new code)

`CLITreeTransformRunner` calls `OperationCenter.shared.complete(id:detail:bundleURLs:[outputURL])`.
The existing route — `complete` → `onBundleReadyWithContext` (wired in `AppDelegate`) →
`handleMultipleDownloadsSync(bundleURLs:routeContext:)` → `reloadFromFilesystem()` + select — opens the
new `.lungfishtree` in the originating window. This is exactly the IQ-TREE completion path; we add nothing.

## Data flow

```
User: right-click node → "Re-root Here" / "Extract Subtree as New Bundle…"
  → VC.requestTreeBundleOperation(.reroot|.extractSubtree)
  → onTreeBundleOperationRequested(TreeBundleOperationRequest{operation, bundleURL, nodeID, nodeLabel})
  → ViewerViewController.performTreeBundleOperationViaCLI(request)
     → resolve project / window / writability (alert + stop on failure)
     → compute output URL in "Phylogenetic Trees/"
     → OperationCenter.start(... .phylogeneticTreeTransform ...) → opID
     → Task.detached { CLITreeTransformRunner().run(argv, opID) }
        → lungfish tree reroot|extract-subtree … --format json
        → parses treeTransform* events → OperationCenter.update/log
        → on success: OperationCenter.complete(opID, bundleURLs:[out])
  → onBundleReadyWithContext → handleMultipleDownloadsSync → sidebar reload + open new bundle
```

## Error handling

- No project / no window / not writable: blocking `NSAlert` (reusing IQ-TREE's `presentBlockingAlert`),
  no operation started.
- CLI launch failure, non-zero exit, `treeTransformFailed`, or missing completion output: surfaced via
  `OperationCenter.fail(...)` with the CLI's stderr/error message (runner mirrors `CLITreeInferenceRunner`'s
  `RunError` cases). The CLI already removes a partial output bundle on failure (`executeTreeTransform`'s
  catch), so no orphaned bundle.
- Cancel: `setCancelCallback` terminates the process; runner throws `CancellationError`, swallowed.

## Testing

(Decision: runner-parse + arg-builder unit tests, plus a GUI smoke. No new end-to-end OperationCenter
integration test — `TreeCommandTests` + `PhylogeneticTreeBundleTests` already cover the CLI/bundle E2E.)

1. **New** `Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift` (or add to an existing runner test
   file if one groups these): assert `CLITreeTransformRunner.parseEvent` maps each of
   `treeTransformStart` / `treeTransformProgress` / `treeTransformComplete` / `treeTransformFailed`
   to the right `CLITreeTransformEvent` (mirrors how other runners' parse tests are written), and that
   a non-JSON line / unknown event returns `nil`.
2. **New** arg-builder unit test: for a sample `TreeBundleOperationRequest`, assert the produced argv for
   reroot and extract-subtree match the CLI's expected flags and that the output stem is
   `…-rerooted` / `…-subtree` under "Phylogenetic Trees".
3. **Reused, must still pass**: `BundleViewerTests.testPhylogeneticTreeViewportControllerActionsExposeTreeTransforms`
   (callback fires for reroot/extract, not collapse), `TreeCommandTests`, `PhylogeneticTreeBundleTests`.
4. **GUI smoke (Computer Use)**: launch `.build/debug/Lungfish`, open a project containing a `.lungfishtree`
   bundle (or infer one), right-click a node, choose Re-root Here and Extract Subtree as New Bundle…,
   confirm an operation runs in the Operations Panel and a new `.lungfishtree` appears in the sidebar and opens.
5. **Full suite** green: XCTest failures ⊆ the 9 known TCC-environmental ones, swift-testing = 0.

## Files touched

- `Sources/LungfishApp/Services/CLITreeTransformRunner.swift` — new.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift` —
  assign callback in `displayPhylogeneticTreeBundle`; add `performTreeBundleOperationViaCLI(_:)` (+ argv helper).
- `Sources/LungfishKit/OperationCenter.swift` — add `phylogeneticTreeTransform` case.
- `Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift` (+ arg-builder test) — new.

No CLI, bundle-method, relabel, export, or collapse changes.

## CLI parity

CLI already complete (`lungfish tree reroot`, `lungfish tree extract-subtree`). This change brings the GUI
to parity with the CLI rather than the reverse. No CLI work required.
