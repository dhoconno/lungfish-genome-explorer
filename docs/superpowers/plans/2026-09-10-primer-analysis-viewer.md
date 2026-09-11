# Saved Primer Analysis Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open and inspect saved opaque analysis results in a read-only GUI with overview, file inventory and canonical provenance.

**Architecture:** A SwiftUI viewer owns a main-actor loading model. Strict bundle validation and canonical provenance decoding run in a detached task; immutable snapshots and a generation check prevent superseded results from reaching the UI. Root separately owns app registration/open routing/sidebar integration and hosts `PrimerAnalysisViewerView(bundleURL: URL)`.

**Tech Stack:** SwiftUI, Foundation, existing LungfishIO bundle loader and LungfishWorkflow canonical provenance decoder, XCTest.

**Spec:** docs/proposals/2026-09-10-pcr-primer-pack.md and docs/formats/primer-analysis-bundle.md; user approved bounded read-only GUI continuation.

## Global Constraints

- Work only `.worktrees/pcr-primer-design`, branch `codex/pcr-primer-design`, starting HEAD `8712b72f7`; no commits/push until root review.
- No design engines, biological algorithms, installation, optimization, scientific transformation, result attachment or assay fixtures.
- No automatic payload opening/execution, export or write behavior. Viewer must not call generic provenance audit/rehydration APIs.
- Caller entry point is exactly `PrimerAnalysisViewerView(bundleURL: URL)`. Root owns all shared routing/controller/sidebar/registration/docs files; worker must not edit them.
- Display grouping labels exactly `One scheme per alignment` and `Combined scheme` as saved metadata, with input membership; do not infer that any schemes were generated or validated.
- Overview retains stable UUIDs, separate inputs, labels and result membership. Duplicate labels are allowed. Zero results must not be reported as failed validation or absence of native outputs.
- Files exposes explicit inventory relative paths, roles, formats, sizes and digests plus current bundle location. Provenance exposes actual workflow/tool identity, historical invocation/options/runtime/file identities and timing/status; historical publication path and current location are distinct.
- Heavy hashing/decoding is off-main. Loading, failure and valid states are explicit. Superseded/cancelled loads never replace a newer view.
- Preserve verified provenance bytes from the IO loader for display; do not reopen or parse native outputs. All tests use harmless opaque text. No Swift tests until root releases build lock.

### Task 1: Verified immutable read snapshot and GUI viewer

**Files:**
- Modify `Sources/LungfishIO/Bundles/PrimerAnalysisBundle.swift`: expose immutable `public let canonicalProvenanceData: Data` populated from exactly the validated provenance bytes already read by load; add optional synchronous cancellationCheck callback (default no-op) checked per file/read/hash chunk.
- Modify `Tests/LungfishIOTests/Bundles/PrimerAnalysisBundleTests.swift`: assert canonicalProvenanceData equals original verified fixture bytes after relocation.
- Create `Sources/LungfishApp/Views/PrimerAnalysis/PrimerAnalysisViewerModel.swift`: immutable display snapshot and main-actor loading lifecycle.
- Create `Sources/LungfishApp/Views/PrimerAnalysis/PrimerAnalysisViewerView.swift`: read-only loading/error and Overview/Files/Provenance UI.
- Create `Tests/LungfishAppTests/PrimerAnalysisViewerModelTests.swift`: real bundle read-only/corruption/relocation/metadata assertions plus deterministic off-main/supersession/cancellation checks.

**Interfaces:**
```swift
struct PrimerAnalysisViewerSnapshot: Sendable {
    let bundle: PrimerAnalysisBundle
    let provenance: ProvenanceEnvelope
    let provenanceJSON: String
    nonisolated static func load(from url: URL) throws -> Self
}
@MainActor final class PrimerAnalysisViewerModel: ObservableObject {
    enum State { case loading, loaded(PrimerAnalysisViewerSnapshot), failed(String) }
    @Published private(set) var state: State = .loading
    init(loader: @escaping @Sendable (URL) async throws -> PrimerAnalysisViewerSnapshot = { try PrimerAnalysisViewerSnapshot.load(from: $0) })
    func load(from url: URL) async
}
struct PrimerAnalysisViewerView: View {
    init(bundleURL: URL)
}
```
The snapshot's static load is explicitly nonisolated, invokes strict bundle load, decodes `canonicalProvenanceData` via `ProvenanceEnvelopeReader.decodeCanonical`, and uses the same original JSON for selectable display. Any small derived row types stay in the model file. The model's injected loader runs inside Task.detached; generation is captured before await and checked with cancellation before changing state. A cancellation handler cancels the detached worker; the real snapshot reader passes Task.checkCancellation to IO. Retry increments a generation in the view-owned task identity. No global hooks needed.

- [x] **Step 1: Write meaningful failing tests and run RED after lock release.** Use existing `PrimerAnalysisBundleWriter` with distinct `input` and `nativeOutput` harmless text files and exact test-host argv. A model read test compares the complete bundle byte snapshot before and after; loader corruption test mutates a valid artifact and expects failure rather than a successful overview. Add IO assertion:
```swift
XCTAssertEqual(reopened.canonicalProvenanceData, provenance)
```
Run `swift test --jobs 4 --filter 'PrimerAnalysisViewerModelTests|PrimerAnalysisBundleTests' > .build/primer-analysis-viewer-tests.log 2>&1`; inspect tail and record absent types/property RED.

- [x] **Step 2: Implement verified snapshot and asynchronous model.** Add canonicalProvenanceData only to the existing loader return value. Decode/display those bytes off-main; compute no scientific interpretations. Start each load by incrementing generation and clearing prior loaded state. Resolve detached work, then discard success/errors if generation changed or task was cancelled.
```swift
let worker = Task.detached(priority: .userInitiated) { try await loader(url) }
let snapshot = try await withTaskCancellationHandler {
    try await worker.value
} onCancel: { worker.cancel() }
guard generation == loadGeneration, !Task.isCancelled else { return }
state = .loaded(snapshot)
```
Use a controllable actor gate in tests so an older request finishes after the newer request and cannot overwrite it. Record thread identity synchronously from the injected detached loader to prove filesystem work is off-main.

- [x] **Step 3: Implement viewer with existing app SwiftUI styling.** Use a segmented Overview/Files/Provenance picker and scrollable read-only content; named accessibility identifiers for loading/error/tabs and content. Overview leads with bundle title, saved grouping and input/result counts. Input/result labels and membership labels are primary; stable analysis/run/input/result UUIDs remain in disclosure details, including membership IDs for duplicate-label distinction. Empty results show `No result records are stored in this bundle.` Files lists all manifest artifacts plus the canonical provenance descriptor, sizes and hashes with selectable paths. Provenance shows a concise actual wrapper summary and selectable monospaced original canonical JSON (collapsible if helpful), historical publishedRootPath and current bundle.url. No payload open/export buttons. Use an opaque window background for every state. Keep layout useful in the root's full-size hosting container and include retry after error via explicit user action.

- [x] **Step 4: Complete focused validation.** Assert both grouping labels and separate result memberships, duplicate labels retain distinct IDs, zero results, current paths after relocation and source deletion, unchanged bytes on read, corrupt/missing-provenance failure, cancellation and stale-load discard. Gate ordering must be deterministic, without sleeps. Run the focused command and report exact results; root runs integration and visual checks after hosting is wired.

- [x] **Step 5: Astra review and root integration gate.** Controller reviews every worker file, then independent task review gets immutable diff/report. Fix concrete findings in one batch and rerun affected tests. Root integration confirms registration/opening/lifecycle and reports visual checks. No commit until root review. Update this plan and scoped ledger with evidence.

## Completion evidence

- Initial property and cancellation API RED runs recorded in the task report; final focused/combined command exited 0 at 2026-09-10 20:15:11 CDT: 133 tests executed, 1 expected opt-in visual skip, 0 failures. Log: `.build/primer-analysis-viewer-tests.log`.
- Controller and fresh Astra production/spec/test reviews approved with no remaining actionable findings. Final immutable five-file diff and worker report are retained in `.superpowers/sdd/2026-09-10-primer-analysis-viewer/`.
- Root expanded integration run exited 0 at 2026-09-10 20:16:35 CDT: 209 tests passed, zero failures/skips, including six real SwiftUI renders at 1100/650 pt. Log: `.build/primer-analysis-gui-integrated.log`.
- Root visual-only rerender with the same binary exited 0 at 20:17:43 CDT; log `.build/primer-analysis-visual-final.log`. Actual Overview, Files and Provenance views inspected at both sizes; narrow membership labels and long command/JSON wrapping are readable without overlap. Artifacts: `.build/primer-analysis-visual/`.
- Root routing review approved. Viewer performs read-only integrity-checked reopening; no biological engine, payload execution, automatic provenance repair, import/export or scientific interpretation was added. No commits/pushes made by this worker group; root owns final staging and local commit.
