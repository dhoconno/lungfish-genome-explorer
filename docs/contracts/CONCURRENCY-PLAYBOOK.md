# Concurrency playbook

This playbook binds all new Swift code in Lungfish Genome Explorer (LGE). Part of the contracts index in `docs/contracts/README.md`. Finding R10 in `docs/reports/2026-10-02-architecture-review/REVIEW.md` records the current state.

LGE builds with Swift 6.2 strict concurrency. UI state is `@MainActor`, long-running work runs off the main actor, and results come back to the main actor through one of the patterns below. Each pattern names code that does it correctly today, so copy from there rather than from the nearest file.

## Pattern 1. Returning to the main actor

Work that finishes on a GCD queue, a pipe reader or any other callback that is not isolated hops back with `DispatchQueue.main.async` and then `MainActor.assumeIsolated` inside it.

```swift
DispatchQueue.main.async {
    MainActor.assumeIsolated {
        _ = OperationCenter.shared.update(id: operationID, progress: fraction, detail: message)
    }
}
```

The reference is `OperationCenterCLIBridge.onEvent(operationID:)` in `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift`. Code already running in an `async` context awaits a `@MainActor` function instead, as `OperationCenterCLIBridge.completeOperation` does.

The project's hard-won runtime notes ban three forms:

- `Task { @MainActor in ... }` started from a GCD background queue
- a bare `DispatchQueue.main.async` that touches `@MainActor` state without `MainActor.assumeIsolated`
- awaiting `@MainActor` work from inside `Task.detached`

One existing site breaks the third ban. `runIQTreeInferenceViaCLI` in `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` runs `CLITreeRunner.run` inside `Task.detached`, and that method awaits the `@MainActor` bridge helpers. Do not copy that shape. `launchVariantCallingOperation` in `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` avoids it by running in a plain `Task` and returning to the main actor with the form shown above.

## Pattern 2. Long-running work off the main actor

A pipeline is a `Sendable` struct or an actor with no `@MainActor` annotation. It takes its inputs as values and reports through callbacks. `ViralVariantCallingPipeline` in `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift` is a `Sendable` struct, and `VariantSQLiteImportCoordinator` in `Sources/LungfishWorkflow/Variants/VariantSQLiteImportCoordinator.swift` is an actor. Never mark a pipeline `@MainActor` to silence a compiler error, because it then blocks the UI for the length of the run.

Cancellation must never queue behind the work it cancels. `CLISubprocessTransport.cancel()` in `Sources/LungfishKit/CLISubprocessTransport.swift` is `nonisolated` and returns at once. It calls `CLIRunCancellation.cancel()` in `Sources/LungfishKit/CLIRunCancellation.swift`, which stores the `ToolProcessRun` of the running CLI and cancels it from any thread. ToolProcess then stops the CLI's process group and its descendants, so a cancel before the launch launches nothing and a cancel during the run never waits behind the actor. The doc comment on `CLIVariantCallingRunner` in `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` records the deadlock that an actor-isolated `cancel()` caused.

Never block a thread on a semaphore while waiting for a `Task` to finish. A blocked cooperative thread starves the pool the task needs, and the two deadlock. Synchronous code that must run an external tool calls `ToolProcess.runBlocking` in `Sources/LungfishCore/Process/ToolProcessRun.swift`, which uses posix_spawn and GCD only and completes even when every cooperative thread is busy. It still blocks its caller, so never call it on the main thread. `docs/contracts/RUNNING-A-TOOL.md` has the rest of the tool-launch rules.

## Pattern 3. Progress callbacks

Progress flows as a `@Sendable (Double, String) -> Void` closure, the `ProgressHandler` typealias in `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift` and `Sources/LungfishWorkflow/Variants/VariantSQLiteImportCoordinator.swift`. The pipeline calls it from any thread. The receiver hops to the main actor with pattern 1. For the Operations panel, the receiver calls both `OperationCenter.shared.update` and `OperationCenter.shared.log`, because without `log` the expanded row keeps no history.

An operation that runs through the CLI does not wire this by hand. The CLI emits `CLIEvent` lines and `OperationCenterCLIBridge` turns them into `update` and `log` calls (see `docs/contracts/ADDING-AN-OPERATION.md`).

The async `URLSession.download` call reports no progress. Use `downloadTask(with:)` with a delegate and a `CheckedContinuation`, and copy the file inside `urlSession(_:downloadTask:didFinishDownloadingTo:)`, because the session deletes it as soon as that method returns. `ContinuationDownloadDelegate` in `Sources/LungfishCore/Services/NCBI/NCBIDownloadDelegate.swift` does this.

## Pattern 4. Generation counters for stale results

When a fetch can be superseded (the user scrolls, selects another row, or opens another bundle), each request takes a generation number and the result is applied only if it is still current. Increment and compare on the main actor, and also compare the identity the result belongs to, such as the bundle URL.

```swift
annotationFetchGeneration += 1
let thisGeneration = annotationFetchGeneration
// ... background work ...
guard thisGeneration == viewer.annotationFetchGeneration else { return }
guard viewer.currentReferenceBundle?.url.standardizedFileURL == bundle.url.standardizedFileURL else { return }
```

The reference is `fetchAnnotationsAsync(bundle:region:)` in `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift`, with siblings `fetchVariantsAsync` and `fetchSequenceAsync` in `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Alignment.swift`. New code prefers the typed form, `AsyncRequestGate` in `Sources/LungfishApp/StateManagement/AsyncRequestGate.swift`, which pairs the generation with the request identity. `MainSplitViewController+SidebarSelection.swift` in `Sources/LungfishApp/Views/MainWindow/` uses it for sidebar display requests.

## Ratcheted escape hatches

Four constructs bypass the compiler's isolation checks. Their counts may only fall. The concurrency-hatches ratchet, added under `scripts/ratchets/` by Lane E of Phase 0 and wired into the pre-push hook, fails a push that raises any of them.

| Construct | Count at review | When it is acceptable |
|---|---|---|
| `MainActor.assumeIsolated` | 407 | Only inside `DispatchQueue.main.async` (pattern 1) or behind a main-thread check, as in `enqueueMainRunLoop` in `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift` |
| `@unchecked Sendable` | 223 | Only for a small type whose every stored property is guarded by a lock, like `LockedBool` in `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift`. Prefer an actor or `OSAllocatedUnfairLock`. |
| `nonisolated(unsafe)` | 58 | Not in new code |
| `nonisolated(unsafe) static var` | 23 | Not in new code. These are mostly test probes and fault gates (finding R10). Inject a probe through the initializer, or use a `@TaskLocal` value as `NativeToolRunner.onEvent` in `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` does. |

A change that needs a new hatch explains why in its commit message, and the reviewer decides whether the baseline moves.

## Smaller traps

The runtime notes and the test rules record these as well:

- Create `GlobalOptions` with `GlobalOptions.parse([])`, never its initializer, which crashes under `@MainActor` isolation.
- Never pass a Swift `String` to `%s` in `String(format:)`. It crashes with SIGSEGV. Use `%@` or interpolation.
- In a `@Sendable` closure, call a free or static function rather than an instance method, so the closure does not capture `self` and its isolation.
- Production code never branches on a flag that says tests are running, such as `TestHarness.isRunning`. Inject a presenter or a probe instead (finding R10).
- Async tests wait with `waitUntil` from `Tests/Support/LungfishTestSupport/XCTestAsyncAssertions.swift`, which polls against a clock, never with a fixed number of yields or a sleep.

A test suite that cannot run in parallel goes on the `PARALLEL_HAZARD_SUITES` list in `scripts/full-suite-gate.sh` only with a stated reason, and the program works to shrink that list.
