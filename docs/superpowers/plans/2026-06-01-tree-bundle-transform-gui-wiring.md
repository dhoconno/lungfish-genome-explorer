# Tree Bundle Transform GUI Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `PhylogeneticTreeViewController.onTreeBundleOperationRequested` in the production app so the "Re-root Here" and "Extract Subtree as New Bundle…" tree-node menu items invoke the existing `lungfish tree reroot` / `tree extract-subtree` CLI and surface the new bundle through `OperationCenter`, then ship a same-version `0.5.0-alpha11` notarized hotfix DMG.

**Architecture:** Mirror the existing CLI-bridge pattern (`inferTreeFromMSAViaCLI` + `CLITreeInferenceRunner`). Add a focused actor `CLITreeTransformRunner` that parses the CLI's `treeTransform*` JSON events, a `ViewerViewController.performTreeBundleOperationViaCLI(_:)` glue method that builds argv and starts an `OperationCenter` op, and a one-line callback assignment at the tree-bundle construction site. Completion routes through the existing `onBundleReadyWithContext` → sidebar-refresh path (no new display code).

**Tech Stack:** Swift 6.2, SwiftPM, `@MainActor`/strict concurrency, AppKit, XCTest. macOS 26 / Apple Silicon. `OperationCenter` (LungfishKit), `lungfish-cli` (LungfishCLI).

---

## Background the implementer needs

- This is **finishing an incomplete feature**. Commit `910549e2` added the GUI menu items + the `onTreeBundleOperationRequested` callback (with unit tests), the full CLI (`lungfish tree reroot` / `extract-subtree`), and the backing `PhylogeneticTreeBundle` methods — but never wrote the app-level glue. The CLI works today; only the GUI bridge is missing.
- Spec: `docs/superpowers/specs/2026-06-01-tree-bundle-transform-gui-wiring-design.md`.
- **The CLI already emits these JSON events** (one per line, on stdout) for reroot/extract-subtree, from `TreeTransformCLIEventEmitter` in `Sources/LungfishCLI/Commands/TreeCommand.swift`:
  - `{"event":"treeTransformStart","progress":0,"message":"..."}`
  - `{"event":"treeTransformProgress","progress":0.65,"message":"..."}`
  - `{"event":"treeTransformComplete","progress":1,"output":"/path/to/out.lungfishtree"}`
  - `{"event":"treeTransformFailed","error":"..."}`
  These are emitted only when `--format json` is passed.
- **Build/test serialization (CRITICAL):** SwiftPM holds one `.build/.lock` per checkout. Never run two `swift build`/`swift test` at once on this checkout. The lead runs the build/test gate; subagents do not run their own builds concurrently.
- **Build/test commands** (always offline to avoid the NCBI `testSRASearch` flake):
  - Build: `swift build 2>&1 | tail -30`
  - A single test: `swift test --skip-update --filter <TestClass>/<testMethod> 2>&1 | tail -40`
  - A test class: `swift test --skip-update --filter <TestClass> 2>&1 | tail -40`
  - Full suite (final gate): `swift test --skip-update 2>&1 | tail -60`
- **Green-bar definition:** A run is GREEN iff XCTest failures are a subset of the 9 known TCC-environmental failures (6 `GenotypeRealBundleSmokeTests`, 2 `ZhangArtifactCanaryTests`, 1 `VCFRobustnessTests.testAllRealVCFsFromDownloads` — all read external volumes / `~/Downloads`) AND swift-testing failures = 0.

## File structure

| File | Responsibility | Change |
| --- | --- | --- |
| `Sources/LungfishKit/OperationCenter.swift` | Add `phylogeneticTreeTransform` operation type | Modify (1 line in enum) |
| `Sources/LungfishApp/Services/CLITreeTransformRunner.swift` | Actor that runs the CLI, parses `treeTransform*` events, drives OperationCenter, completes with the new bundle URL | Create |
| `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` | `performTreeBundleOperationViaCLI(_:)` glue: resolve project/window/writability, compute output URL, build argv, start op, dispatch runner. (Lives HERE because it reuses `private` helpers `enclosingProjectURL`, `nextAvailableBundleURL`, `sanitizedFilesystemStem`, `presentBlockingAlert`, `projectURLForDerivedReferenceBundle` that are file-scoped to this file.) | Modify (add methods near `inferTreeFromMSAViaCLI`, ~line 1783) |
| `Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift` | Assign the callback in `displayPhylogeneticTreeBundle` | Modify (add closure, ~line 89) |
| `Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift` | Unit-test `parseEvent` for the 4 events + a fake-CLI end-to-end `run` test | Create |
| `Tests/LungfishAppTests/TreeBundleTransformArgvTests.swift` | Unit-test the argv builder (flags + output stem/placement) | Create |

> **Spec correction:** the spec's "Files touched" placed `performTreeBundleOperationViaCLI` in the `+AlignmentTreeBundles.swift` extension. It must live in `ViewerViewController.swift` because the helpers it reuses are `private` (file-scoped). Only the callback assignment goes in the extension file. (Task 7 records this correction in the spec.)

---

## Task 1: Add the `phylogeneticTreeTransform` operation type

**Files:**
- Modify: `Sources/LungfishKit/OperationCenter.swift:34`

- [ ] **Step 1: Add the enum case**

In `Sources/LungfishKit/OperationCenter.swift`, the enum currently ends:

```swift
    case phylogeneticTreeImport = "Tree Import"
    case phylogeneticTreeInference = "Tree Inference"
}
```

Change it to:

```swift
    case phylogeneticTreeImport = "Tree Import"
    case phylogeneticTreeInference = "Tree Inference"
    case phylogeneticTreeTransform = "Tree Transform"
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -30`
Expected: build succeeds (no errors). `OperationType` is a plain `String` enum with no exhaustive `switch` over it that would now be non-exhaustive; if the build surfaces a non-exhaustive switch error anywhere, add a `case .phylogeneticTreeTransform` branch mirroring the adjacent `.phylogeneticTreeInference` branch.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishKit/OperationCenter.swift
git commit -m "feat(operations): add phylogeneticTreeTransform operation type"
```

---

## Task 2: `CLITreeTransformRunner.parseEvent` (TDD — parser first)

This task creates the runner file with ONLY the event enum, result struct, and `parseEvent`, driven by tests. The `run`/`cancel` methods come in Task 3.

**Files:**
- Create: `Sources/LungfishApp/Services/CLITreeTransformRunner.swift`
- Create: `Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift`

- [ ] **Step 1: Write the failing parser tests**

Create `Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift`:

```swift
import XCTest
@testable import LungfishApp
import LungfishKit

final class CLITreeTransformRunnerTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testParseStartEvent() throws {
        let json = #"{"event":"treeTransformStart","progress":0,"message":"Starting tree transform."}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .start(progress, message) = event else {
            return XCTFail("Expected start event, got \(event)")
        }
        XCTAssertEqual(progress, 0)
        XCTAssertEqual(message, "Starting tree transform.")
    }

    func testParseProgressEvent() throws {
        let json = #"{"event":"treeTransformProgress","progress":0.65,"message":"Writing transformed tree bundle."}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .progress(progress, message) = event else {
            return XCTFail("Expected progress event, got \(event)")
        }
        XCTAssertEqual(progress, 0.65, accuracy: 0.0001)
        XCTAssertEqual(message, "Writing transformed tree bundle.")
    }

    func testParseCompleteEvent() throws {
        let json = #"{"event":"treeTransformComplete","progress":1,"output":"/project/Phylogenetic Trees/example-rerooted.lungfishtree"}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .complete(output) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(output, "/project/Phylogenetic Trees/example-rerooted.lungfishtree")
    }

    func testParseFailedEvent() throws {
        let json = #"{"event":"treeTransformFailed","error":"node not found: ABC"}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .failed(error) = event else {
            return XCTFail("Expected failed event, got \(event)")
        }
        XCTAssertEqual(error, "node not found: ABC")
    }

    func testParseIgnoresNonJSONAndUnknownEvents() throws {
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: "Wrote tree bundle: /path"))
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: ""))
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: #"{"event":"somethingElse"}"#))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --skip-update --filter CLITreeTransformRunnerTests 2>&1 | tail -40`
Expected: compile failure — `CLITreeTransformRunner` is not defined.

- [ ] **Step 3: Create the runner file with enum + struct + parseEvent**

Create `Sources/LungfishApp/Services/CLITreeTransformRunner.swift`:

```swift
import Foundation
import LungfishCore
import LungfishKit
import os.log

private let treeTransformRunnerLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "CLITreeTransformRunner"
)

enum CLITreeTransformEvent: Sendable, Equatable {
    case start(progress: Double, message: String)
    case progress(progress: Double, message: String)
    case complete(output: String)
    case failed(error: String)
}

struct CLITreeTransformResult: Sendable, Equatable {
    let bundleURL: URL
}

actor CLITreeTransformRunner {
    enum RunError: Error, LocalizedError {
        case cliNotFound
        case launchFailed(String)
        case nonZeroExit(status: Int32, stderr: String)
        case missingCompletion
        case failedEvent(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The `lungfish-cli` binary could not be found in the app bundle or build products."
            case .launchFailed(let message):
                return "Failed to launch lungfish-cli: \(message)"
            case .nonZeroExit(let status, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "lungfish-cli exited with status \(status)"
                    : "lungfish-cli exited with status \(status): \(trimmed)"
            case .missingCompletion:
                return "lungfish-cli finished without reporting a tree bundle."
            case .failedEvent(let message):
                return message
            }
        }
    }

    private let cliURLOverride: URL?
    private var process: Process?

    init(cliURLOverride: URL? = nil) {
        self.cliURLOverride = cliURLOverride
    }

    static func parseEvent(from line: String) throws -> CLITreeTransformEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        switch event {
        case "treeTransformStart":
            return .start(
                progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
                message: dict["message"] as? String ?? "Starting tree transform..."
            )
        case "treeTransformProgress":
            return .progress(
                progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
                message: dict["message"] as? String ?? "Running tree transform..."
            )
        case "treeTransformComplete":
            return .complete(output: dict["output"] as? String ?? "")
        case "treeTransformFailed":
            return .failed(error: dict["error"] as? String ?? dict["message"] as? String ?? "Tree transform failed")
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run the parser tests to verify they pass**

Run: `swift test --skip-update --filter CLITreeTransformRunnerTests 2>&1 | tail -40`
Expected: all 5 parser tests PASS. (The fake-CLI `run` test is added in Task 3.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/CLITreeTransformRunner.swift Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift
git commit -m "feat(runner): CLITreeTransformRunner event parsing"
```

---

## Task 3: `CLITreeTransformRunner.run` + `cancel` (TDD — fake-CLI end-to-end)

**Files:**
- Modify: `Sources/LungfishApp/Services/CLITreeTransformRunner.swift`
- Modify: `Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift`

- [ ] **Step 1: Add the failing end-to-end test**

Append these to `CLITreeTransformRunnerTests` (inside the class, before the closing brace), plus the helper `ReadyBundleCapture` class and `repoRoot`/`makeTemporaryDirectory` helpers at the bottom of the file (outside the class). This mirrors `CLITreeInferenceRunnerTests` exactly:

```swift
    func testRunStreamsTreeTransformEventsIntoOperationCenterAndCompletesWithBundleURL() async throws {
        let tempDir = try makeTemporaryDirectory()
        let output = tempDir.appendingPathComponent("example-rerooted.lungfishtree", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"treeTransformStart","progress":0,"message":"Starting tree transform."}'
        printf '%s\\n' '{"event":"treeTransformProgress","progress":0.65,"message":"Writing transformed tree bundle."}'
        printf '%s\\n' '{"event":"treeTransformComplete","progress":1,"output":"\(output.path)"}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let readyBundles = ReadyBundleCapture()
        let opID = await MainActor.run {
            OperationCenter.shared.onBundleReady = { readyBundles.set($0) }
            return OperationCenter.shared.start(
                title: "Re-root Tree",
                detail: "Launching...",
                operationType: .phylogeneticTreeTransform
            )
        }

        let result = try await CLITreeTransformRunner(cliURLOverride: fakeCLI)
            .run(arguments: ["tree", "reroot"], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, output.path)
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.progress, 1.0)
        XCTAssertEqual(item?.detail, "Tree transform complete")
        XCTAssertEqual(item?.bundleURLs.map(\.path), [output.path])
        XCTAssertEqual(readyBundles.paths(), [output.path])
        XCTAssertTrue(item?.logEntries.contains { $0.level == .info && $0.message.contains("Starting tree transform") } == true)
        await MainActor.run {
            OperationCenter.shared.onBundleReady = nil
        }
    }

    func testRunFailsOperationOnFailedEvent() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"treeTransformStart","progress":0,"message":"Starting tree transform."}'
        printf '%s\\n' '{"event":"treeTransformFailed","error":"node not found: ABC"}'
        exit 1
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.start(
                title: "Re-root Tree",
                detail: "Launching...",
                operationType: .phylogeneticTreeTransform
            )
        }

        do {
            _ = try await CLITreeTransformRunner(cliURLOverride: fakeCLI)
                .run(arguments: ["tree", "reroot"], operationID: opID)
            XCTFail("Expected run to throw")
        } catch {
            // expected
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }
        XCTAssertEqual(item?.state, .failed)
    }
```

And at the bottom of the file (outside the class), add the same helpers `CLITreeInferenceRunnerTests` uses:

```swift
private final class ReadyBundleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func set(_ urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        storage = urls
    }

    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map(\.path)
    }
}
```

And add these two helpers INSIDE the `CLITreeTransformRunnerTests` class:

```swift
    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-tree-transform-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanupURLs.append(url)
        return url
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --skip-update --filter CLITreeTransformRunnerTests/testRunStreamsTreeTransformEventsIntoOperationCenterAndCompletesWithBundleURL 2>&1 | tail -40`
Expected: compile failure — `run(arguments:operationID:)` not defined on the actor.

- [ ] **Step 3: Add `run` and `cancel` to the actor**

In `Sources/LungfishApp/Services/CLITreeTransformRunner.swift`, add these methods INSIDE the `actor CLITreeTransformRunner` body, after `parseEvent`. This is a line-for-line mirror of `CLITreeInferenceRunner.run` with two changes: the success-completion detail string is `"Tree transform complete"`, and the launch log uses the transform logger. Full method:

```swift
    func run(arguments: [String], operationID: UUID) async throws -> CLITreeTransformResult {
        guard let binaryURL = cliURLOverride ?? CLIImportRunner.cliBinaryPath() else {
            await failOperation(operationID, detail: RunError.cliNotFound.localizedDescription)
            throw RunError.cliNotFound
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        process = proc

        final class StreamState: @unchecked Sendable {
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var outputPath: String?
            var failedMessage: String?
        }

        let state = OSAllocatedUnfairLock(initialState: StreamState())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutHandlerGroup = DispatchGroup()
        let stderrHandlerGroup = DispatchGroup()
        let opID = operationID

        @Sendable func handleLine(_ data: Data) {
            guard let line = String(data: data, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            do {
                guard let event = try Self.parseEvent(from: line) else { return }
                switch event {
                case let .start(progress, message):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .info, message: message)
                            OperationCenter.shared.update(id: opID, progress: max(0, min(1, progress)), detail: message)
                        }
                    }
                case let .progress(progress, message):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: max(0, min(1, progress)),
                                detail: message
                            )
                        }
                    }
                case let .complete(output):
                    state.withLock { $0.outputPath = output }
                case let .failed(error):
                    state.withLock { $0.failedMessage = error }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .error, message: error)
                        }
                    }
                }
            } catch {
                treeTransformRunnerLogger.warning("Failed to parse tree transform CLI event")
            }
        }

        @Sendable func consumeStdout(_ data: Data) {
            guard !data.isEmpty else { return }
            let lines = state.withLock { current -> [Data] in
                current.stdoutBuffer.append(data)
                var parsed: [Data] = []
                while let newlineIndex = current.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(current.stdoutBuffer.prefix(upTo: newlineIndex))
                    current.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleLine(line)
            }
        }

        @Sendable func consumeStderr(_ data: Data) {
            guard !data.isEmpty else { return }
            state.withLock { $0.stderrBuffer.append(data) }
        }

        func drainStreamHandlers() {
            stdoutHandlerGroup.wait()
            stderrHandlerGroup.wait()
        }

        stdoutHandle.readabilityHandler = { handle in
            stdoutHandlerGroup.enter()
            defer { stdoutHandlerGroup.leave() }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            consumeStdout(chunk)
        }
        stderrHandle.readabilityHandler = { handle in
            stderrHandlerGroup.enter()
            defer { stderrHandlerGroup.leave() }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            consumeStderr(chunk)
        }

        await performCLIOperationCenterUpdate {
            OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Launching lungfish-cli...")
        }

        do {
            try proc.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            drainStreamHandlers()
            process = nil
            await failOperation(opID, detail: error.localizedDescription)
            throw RunError.launchFailed(error.localizedDescription)
        }

        proc.waitUntilExit()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        drainStreamHandlers()
        consumeStdout(stdoutHandle.readDataToEndOfFile())
        consumeStderr(stderrHandle.readDataToEndOfFile())
        drainStreamHandlers()
        if let trailing = state.withLock({ current -> Data? in
            guard !current.stdoutBuffer.isEmpty else { return nil }
            defer { current.stdoutBuffer.removeAll(keepingCapacity: false) }
            return current.stdoutBuffer
        }) {
            handleLine(trailing)
        }
        process = nil

        let snapshot = state.withLock { current in
            (
                stderr: String(data: current.stderrBuffer, encoding: .utf8) ?? "",
                outputPath: current.outputPath,
                failedMessage: current.failedMessage
            )
        }

        if await isOperationCancelled(opID) {
            throw CancellationError()
        }
        if let failedMessage = snapshot.failedMessage {
            await failOperation(opID, detail: failedMessage)
            throw RunError.failedEvent(failedMessage)
        }
        if proc.terminationStatus != 0 {
            let error = RunError.nonZeroExit(status: proc.terminationStatus, stderr: snapshot.stderr)
            await failOperation(opID, detail: error.localizedDescription)
            throw error
        }
        guard let outputPath = snapshot.outputPath,
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await failOperation(opID, detail: RunError.missingCompletion.localizedDescription)
            throw RunError.missingCompletion
        }

        let bundleURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        await performCLIOperationCenterUpdate {
            OperationCenter.shared.complete(
                id: opID,
                detail: "Tree transform complete",
                bundleURLs: [bundleURL]
            )
        }

        return CLITreeTransformResult(bundleURL: bundleURL)
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    @MainActor
    private func isOperationCancelled(_ id: UUID) -> Bool {
        OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled
    }

    @MainActor
    private func failOperation(_ id: UUID, detail: String?) {
        let message = detail ?? "Tree transform failed"
        guard OperationCenter.shared.items.first(where: { $0.id == id })?.state != .cancelled else {
            return
        }
        OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }
```

- [ ] **Step 4: Run the full runner test class to verify pass**

Run: `swift test --skip-update --filter CLITreeTransformRunnerTests 2>&1 | tail -40`
Expected: all 7 tests PASS (5 parser + 2 run). If the `complete`/`failed` timing is flaky, the 50ms sleep matches the inference test; do not change it.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/CLITreeTransformRunner.swift Tests/LungfishAppTests/CLITreeTransformRunnerTests.swift
git commit -m "feat(runner): CLITreeTransformRunner run/cancel with OperationCenter streaming"
```

---

## Task 4: Argv + output-naming builder (TDD)

A small static helper that turns a `TreeBundleOperationRequest` + output URL into CLI argv, and computes the output stem. Kept separate from the VC so it is unit-testable without AppKit/window state.

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` (add a `enum TreeBundleTransformCommand` at file scope, bottom of file)
- Create: `Tests/LungfishAppTests/TreeBundleTransformArgvTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LungfishAppTests/TreeBundleTransformArgvTests.swift`:

```swift
import XCTest
@testable import LungfishApp
import LungfishPhylogeneticsUI

final class TreeBundleTransformArgvTests: XCTestCase {
    private func request(
        operation: PhylogeneticTreeViewController.TreeBundleOperation,
        nodeID: String = "node-7",
        nodeLabel: String = "Clade A"
    ) -> PhylogeneticTreeViewController.TreeBundleOperationRequest {
        PhylogeneticTreeViewController.TreeBundleOperationRequest(
            operation: operation,
            bundleURL: URL(fileURLWithPath: "/proj/Phylogenetic Trees/source.lungfishtree", isDirectory: true),
            nodeID: nodeID,
            nodeLabel: nodeLabel
        )
    }

    func testRerootArguments() {
        let out = URL(fileURLWithPath: "/proj/Phylogenetic Trees/source-rerooted.lungfishtree", isDirectory: true)
        let argv = TreeBundleTransformCommand.arguments(
            for: request(operation: .reroot),
            outputURL: out
        )
        XCTAssertEqual(argv, [
            "tree", "reroot",
            "--bundle", "/proj/Phylogenetic Trees/source.lungfishtree",
            "--on", "node-7",
            "--output", "/proj/Phylogenetic Trees/source-rerooted.lungfishtree",
            "--format", "json",
        ])
    }

    func testExtractSubtreeArguments() {
        let out = URL(fileURLWithPath: "/proj/Phylogenetic Trees/Clade A-subtree.lungfishtree", isDirectory: true)
        let argv = TreeBundleTransformCommand.arguments(
            for: request(operation: .extractSubtree),
            outputURL: out
        )
        XCTAssertEqual(argv, [
            "tree", "extract-subtree",
            "--bundle", "/proj/Phylogenetic Trees/source.lungfishtree",
            "--node", "node-7",
            "--output", "/proj/Phylogenetic Trees/Clade A-subtree.lungfishtree",
            "--format", "json",
        ])
    }

    func testCollapseHasNoArguments() {
        XCTAssertNil(TreeBundleTransformCommand.arguments(
            for: request(operation: .collapse),
            outputURL: URL(fileURLWithPath: "/x", isDirectory: true)
        ))
    }

    func testOutputStemReroot() {
        XCTAssertEqual(
            TreeBundleTransformCommand.outputStem(for: request(operation: .reroot)),
            "source-rerooted"
        )
    }

    func testOutputStemExtractSubtreeUsesNodeLabel() {
        XCTAssertEqual(
            TreeBundleTransformCommand.outputStem(for: request(operation: .extractSubtree, nodeLabel: "Clade A")),
            "Clade A-subtree"
        )
    }

    func testTitleAndDetail() {
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .reroot), "Re-root Tree")
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .extractSubtree), "Extract Subtree")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --skip-update --filter TreeBundleTransformArgvTests 2>&1 | tail -40`
Expected: compile failure — `TreeBundleTransformCommand` not defined.

- [ ] **Step 3: Add the `TreeBundleTransformCommand` enum**

At the BOTTOM of `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` (file scope, after the final closing brace of any type — i.e. a new top-level declaration), add. Note `import LungfishPhylogeneticsUI` must be present at the top of the file; add it if missing (check the existing imports first).

```swift
/// Pure helpers for translating a tree-node transform request into `lungfish tree …` CLI
/// arguments and output naming. Separated from `ViewerViewController` so it is unit-testable
/// without window/project state.
enum TreeBundleTransformCommand {
    /// The output bundle filename stem (no extension), e.g. "source-rerooted" / "Clade A-subtree".
    /// Returns nil for operations that do not produce a bundle (e.g. `.collapse`).
    static func outputStem(for request: PhylogeneticTreeViewController.TreeBundleOperationRequest) -> String? {
        switch request.operation {
        case .reroot:
            let sourceStem = request.bundleURL.deletingPathExtension().lastPathComponent
            return "\(sourceStem)-rerooted"
        case .extractSubtree:
            return "\(request.nodeLabel)-subtree"
        case .collapse:
            return nil
        }
    }

    /// CLI argv for the request, or nil if the operation does not map to a CLI transform.
    static func arguments(
        for request: PhylogeneticTreeViewController.TreeBundleOperationRequest,
        outputURL: URL
    ) -> [String]? {
        let bundlePath = request.bundleURL.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        switch request.operation {
        case .reroot:
            return [
                "tree", "reroot",
                "--bundle", bundlePath,
                "--on", request.nodeID,
                "--output", outputPath,
                "--format", "json",
            ]
        case .extractSubtree:
            return [
                "tree", "extract-subtree",
                "--bundle", bundlePath,
                "--node", request.nodeID,
                "--output", outputPath,
                "--format", "json",
            ]
        case .collapse:
            return nil
        }
    }

    static func title(for operation: PhylogeneticTreeViewController.TreeBundleOperation) -> String {
        switch operation {
        case .reroot: return "Re-root Tree"
        case .extractSubtree: return "Extract Subtree"
        case .collapse: return "Collapse Clade"
        }
    }
}
```

> Note: the test `testRerootArguments` expects `--bundle /proj/Phylogenetic Trees/source.lungfishtree`. `standardizedFileURL.path` on `/proj/Phylogenetic Trees/source.lungfishtree` returns that same path (no symlink resolution for non-existent paths), so the equality holds. If on the test machine `standardizedFileURL` alters the path, relax those two assertions to compare the non-path flags and assert the `--bundle`/`--output` values `hasSuffix` the expected tail.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --skip-update --filter TreeBundleTransformArgvTests 2>&1 | tail -40`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Tests/LungfishAppTests/TreeBundleTransformArgvTests.swift
git commit -m "feat(viewer): TreeBundleTransformCommand argv + output-naming helper"
```

---

## Task 5: `performTreeBundleOperationViaCLI(_:)` glue method

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` (add method immediately after `runIQTreeInferenceViaCLI`, which ends near line 1893)

- [ ] **Step 1: Add the glue method**

Insert this method in `ViewerViewController.swift`, right after the closing brace of `runIQTreeInferenceViaCLI(_:projectURL:options:)` (≈ line 1893), so it sits beside the IQ-TREE glue and can use the file-private helpers `enclosingProjectURL`, `nextAvailableBundleURL`, `presentBlockingAlert`, `projectURLForDerivedReferenceBundle`, and `canWriteProjectOutputs`:

```swift
    /// Runs a tree-node transform (re-root / extract-subtree) via the lungfish CLI, mirroring
    /// `inferTreeFromMSAViaCLI`. The selected node already supplies the selector, so no dialog is
    /// shown — the operation starts immediately. Completion routes the new bundle through
    /// OperationCenter's `onBundleReadyWithContext` path (opens it in the sidebar/viewer).
    func performTreeBundleOperationViaCLI(_ request: PhylogeneticTreeViewController.TreeBundleOperationRequest) {
        guard let outputStem = TreeBundleTransformCommand.outputStem(for: request) else {
            // Operations like .collapse are handled in the view controller and never reach here.
            return
        }

        guard let projectURL = Self.enclosingProjectURL(for: request.bundleURL)
                ?? projectURLForDerivedReferenceBundle() else {
            presentBlockingAlert(
                title: "No Project",
                message: "Open a Lungfish project before transforming this tree."
            )
            return
        }

        guard view.window != nil else {
            presentBlockingAlert(
                title: "No Window",
                message: "Open this tree in a project window before transforming it."
            )
            return
        }

        let workflowName = "Tree transform"
        guard canWriteProjectOutputs(projectURL: projectURL, workflowName: workflowName) else { return }

        do {
            let treeDirectory = projectURL.appendingPathComponent("Phylogenetic Trees", isDirectory: true)
            try FileManager.default.createDirectory(at: treeDirectory, withIntermediateDirectories: true)
            let outputURL = Self.nextAvailableBundleURL(
                suggestedName: "\(outputStem).lungfishtree",
                pathExtension: "lungfishtree",
                in: treeDirectory
            )

            guard let args = TreeBundleTransformCommand.arguments(for: request, outputURL: outputURL) else {
                return
            }
            let cliCommand = OperationCenter.buildCLICommand(
                subcommand: args.first ?? "tree",
                args: Array(args.dropFirst())
            )
            let title = TreeBundleTransformCommand.title(for: request.operation)
            let opID = OperationCenter.shared.start(
                title: title,
                detail: "\(title) on \(request.nodeLabel)...",
                operationType: .phylogeneticTreeTransform,
                targetBundleURL: request.bundleURL,
                cliCommand: cliCommand,
                routeContext: OperationRouteContext(
                    projectURL: projectURL,
                    windowStateScope: windowStateScope
                )
            )
            let runner = CLITreeTransformRunner()
            OperationCenter.shared.setCancelCallback(for: opID) {
                Task {
                    await runner.cancel()
                }
            }

            Task.detached {
                do {
                    _ = try await runner.run(arguments: args, operationID: opID)
                } catch is CancellationError {
                    return
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(
                                id: opID,
                                detail: error.localizedDescription,
                                errorMessage: error.localizedDescription
                            )
                        }
                    }
                }
            }
        } catch {
            presentBlockingAlert(
                title: "Tree Transform Failed",
                message: error.localizedDescription
            )
        }
    }
```

- [ ] **Step 2: Verify `OperationRouteContext(projectURL:windowStateScope:)` initializer shape**

Confirm the initializer used by `runIQTreeInferenceViaCLI` (≈ line 1858) is `OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope)`. If `runIQTreeInferenceViaCLI` constructs it differently (e.g. a different label), copy that exact construction so the glue matches the proven call. (`windowStateScope` on `ViewerViewController` is `WindowStateScope?` — passing the optional matches the IQ-TREE call.)

Run: `grep -n "OperationRouteContext(" Sources/LungfishApp/Views/Viewer/ViewerViewController.swift | head`
Expected: shows the same initializer form; adjust the glue's construction to match if needed.

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build 2>&1 | tail -30`
Expected: build succeeds. Common issues and fixes:
- "cannot find 'PhylogeneticTreeViewController'": add `import LungfishPhylogeneticsUI` to the top of `ViewerViewController.swift` (it may already be imported).
- "missing argument for parameter 'workflowRunID'": those `start` params have defaults; no action needed.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController.swift
git commit -m "feat(viewer): performTreeBundleOperationViaCLI runs reroot/extract-subtree via CLI"
```

---

## Task 6: Wire the callback at the construction site

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift:89` (inside `displayPhylogeneticTreeBundle`, after the controller is created and the bundle displayed, before `phylogeneticTreeViewController = controller`)

- [ ] **Step 1: Add the callback assignment**

In `displayPhylogeneticTreeBundle(at:)`, the body currently reads (after the `do/catch` that calls `controller.displayBundle`):

```swift
        phylogeneticTreeViewController = controller
        contentMode = .genomics
        alignmentTreeViewerLogger.info("displayPhylogeneticTreeBundle: Showing \(url.lastPathComponent, privacy: .public)")
    }
```

Insert the callback assignment just before `phylogeneticTreeViewController = controller`:

```swift
        controller.onTreeBundleOperationRequested = { [weak self] request in
            self?.performTreeBundleOperationViaCLI(request)
        }

        phylogeneticTreeViewController = controller
        contentMode = .genomics
        alignmentTreeViewerLogger.info("displayPhylogeneticTreeBundle: Showing \(url.lastPathComponent, privacy: .public)")
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -30`
Expected: build succeeds. `performTreeBundleOperationViaCLI` is internal on `ViewerViewController`, callable from this extension in the same module.

- [ ] **Step 3: Run the existing VC callback test to confirm no behavioral regression**

Run: `swift test --skip-update --filter BundleViewerTests/testPhylogeneticTreeViewportControllerActionsExposeTreeTransforms 2>&1 | tail -40`
Expected: PASS (this test asserts the callback fires for `.reroot`/`.extractSubtree` and not `.collapse`; we did not change the VC, so it must still pass).

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift
git commit -m "feat(viewer): wire onTreeBundleOperationRequested to CLI transform glue"
```

---

## Task 7: Update spec "Files touched" to match implementation

**Files:**
- Modify: `docs/superpowers/specs/2026-06-01-tree-bundle-transform-gui-wiring-design.md`

- [ ] **Step 1: Correct the "Files touched" section**

In the spec, the "Files touched" list says `performTreeBundleOperationViaCLI(_:)` is added to `ViewerViewController+AlignmentTreeBundles.swift`. Replace that bullet so it reads:

```markdown
- `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` — add `performTreeBundleOperationViaCLI(_:)`
  and the `TreeBundleTransformCommand` argv/naming helper (these reuse `private` file-scoped helpers, so
  they must live in this file).
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift` — assign the
  `onTreeBundleOperationRequested` callback in `displayPhylogeneticTreeBundle`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-01-tree-bundle-transform-gui-wiring-design.md
git commit -m "docs(spec): correct files-touched (glue lives in ViewerViewController.swift)"
```

---

## Task 8: Full-suite green-bar gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test --skip-update 2>&1 | tail -60`
Expected: GREEN per the definition above — XCTest failures ⊆ the 9 known TCC-environmental failures, swift-testing failures = 0. The new tests (`CLITreeTransformRunnerTests`, `TreeBundleTransformArgvTests`) pass; `BundleViewerTests`, `TreeCommandTests`, `PhylogeneticTreeBundleTests` still pass.

- [ ] **Step 2: If any NON-environmental failure appears, stop and debug**

Use superpowers:systematic-debugging. Do not proceed to GUI smoke or release until the bar is green. Record the failing test + root cause; fix; re-run Step 1.

- [ ] **Step 3: Record the result**

No commit needed (verification only). Note in the execution log: "Full suite green; failures = <list>, all in the known-9 set."

---

## Task 9: GUI smoke test (Computer Use)

**Files:** none (manual verification via the running app)

> **Prerequisite:** per the binding [GUI testing rule], GUI features must be verified by launching the app and interacting — a code audit does not count. Use the `/run` skill or launch `.build/debug/Lungfish` directly. (Note: the computer-use MCP server may need reconnecting — if its tools are unavailable, ask the user to reconnect it, or use the project's documented launch-and-screenshot path.)

- [ ] **Step 1: Build the debug app and launch it**

Run: `swift build 2>&1 | tail -5` then launch `.build/debug/Lungfish` (see the [LGE launch reference] memory).

- [ ] **Step 2: Open a project containing a `.lungfishtree` bundle**

If none exists, create one: open a `.lungfishmsa` alignment in a project, run Build Tree (IQ-TREE) to produce a `.lungfishtree`, or use an existing test bundle copied into a project's "Phylogenetic Trees" folder.

- [ ] **Step 3: Exercise Re-root Here**

Open the tree, right-click an internal node, choose **Re-root Here**. Confirm:
- An operation titled "Re-root Tree" appears in the Operations Panel and progresses to complete.
- A new `<source>-rerooted.lungfishtree` appears in the sidebar under "Phylogenetic Trees" and opens in the viewer.

- [ ] **Step 4: Exercise Extract Subtree as New Bundle…**

Right-click a node, choose **Extract Subtree as New Bundle…**. Confirm an "Extract Subtree" operation runs and a new `<label>-subtree.lungfishtree` appears and opens.

- [ ] **Step 5: Negative check — collapse still in-VC**

Right-click an internal node, choose **Collapse Clade**. Confirm it collapses in place with NO operation started (collapse is not a CLI transform).

- [ ] **Step 6: Record the smoke result**

Note pass/fail with a screenshot reference. If a step fails, debug (systematic-debugging) before release.

---

## Task 10: Merge feature branch to main and push

**Files:** none (git integration)

> The release MUST run from a clean tree at a commit that exists on origin (release gotcha: tag/`--target` operations fail if the commit is not pushed).

- [ ] **Step 1: Confirm clean tree and green bar already established (Task 8)**

Run: `git status --porcelain` → expect empty. If the implementation happened on a feature branch, you are on it now.

- [ ] **Step 2: Merge to main**

```bash
git switch main
git merge --no-ff <feature-branch> -m "feat: wire tree bundle transform (reroot/extract-subtree) GUI to CLI"
```

(If implementation happened directly on `main` per the subagent-driven flow, skip the merge.)

- [ ] **Step 3: Push main to origin**

```bash
git push origin main
```

Expected: push succeeds; the hotfix commit now exists on origin.

---

## Task 11: Same-version `0.5.0-alpha11` notarized hotfix DMG

**Files:** possibly `docs/release-notes/v0.5.0-alpha11.md` (optional hotfix note)

> **Do NOT bump the version.** This hotfix keeps `0.5.0-alpha11`. Do not touch the ~8 hardcoded version sites or the 2 test expectations. Confirm: `grep -rn "0.5.0-alpha11" Sources/LungfishCLI/LungfishCLI.swift` still shows `0.5.0-alpha11`.

> **Why same version still auto-updates:** the release script sets `CFBundleVersion` from `git rev-list --count HEAD` (script ≈ lines 424-425, written at ≈ 254). The hotfix added commits, so the build number is higher than this morning's alpha11 build, and Sparkle (which compares `CFBundleVersion`, not the marketing string) will offer the update.

- [ ] **Step 1: Pre-flight checks**

Run:
```bash
git status --porcelain          # expect empty (clean tree)
git rev-parse HEAD              # note the SHA
git rev-list --count HEAD       # note the build number; must exceed this morning's alpha11 build number
gh release view v0.5.0-alpha11 --json tagName,createdAt,assets -q '.tagName, .createdAt, (.assets[].name)'
```
Expected: clean tree; the `v0.5.0-alpha11` release exists with a `.dmg` asset (the one to clobber). Confirm no `swift build`/`swift test` is running (`ps aux | grep -E "swift (build|test)" | grep -v grep`) so the release build does not contend for `.build/.lock`.

- [ ] **Step 2: (Optional) Append a hotfix note to release notes**

If `docs/release-notes/v0.5.0-alpha11.md` exists, append a short "Hotfix" line documenting the tree reroot/extract-subtree GUI fix (the script re-uploads this file to the release). Follow the docs prose rules if this file is under a rules-governed path; release notes are typically exempt but keep it plain. Commit + push if changed.

- [ ] **Step 3: Resolve the `generate_appcast` path**

Run: `ls .build/artifacts/sparkle/Sparkle/bin/generate_appcast 2>/dev/null || find ~/Library/Developer/Xcode/DerivedData -name generate_appcast -path '*sparkle*' 2>/dev/null | head -1`
Expected: a path to an executable `generate_appcast`. Note it as `<GEN_APPCAST>`.

- [ ] **Step 4: Export the Sparkle public key and run the release build**

The EdDSA private key is in the login Keychain, so no `--sparkle-ed-key-file` is needed. Run from the repo root on a CLEAN tree:

```bash
export LUNGFISH_SPARKLE_PUBLIC_ED_KEY="FtnZIDTqGTwkglQR0z8iSgVvxvT26a05QB3cI4xQw/c="
bash scripts/release/build-notarized-dmg.sh \
  --team-id "29G3WN2GSA" \
  --notary-profile "LungfishNotary" \
  --signing-identity "Developer ID Application: Pathogenuity LLC (29G3WN2GSA)" \
  --github-release-tag "v0.5.0-alpha11" \
  --sparkle-generate-appcast "<GEN_APPCAST>" \
  --sparkle-publish-release "sparkle-alpha"
```

> First confirm the flag names against the script: `bash scripts/release/build-notarized-dmg.sh --help 2>&1 | head -50` (or read the usage line at the top). The signing identity string vs. fingerprint: the release-build memory used the cert fingerprint `62824489A3E3AECF24912838C155A45828269022`; the script accepts either the full "Developer ID Application: …" name or the fingerprint for `--signing-identity`. If codesign complains the identity is ambiguous/not found, run `security find-identity -v -p codesigning` and pass the exact value it lists.

Expected: the script archives, signs every nested Mach-O, notarizes (check `build/Release/notary-app-log.json` and `notary-dmg-log.json` for `"status":"Valid"` — `notarytool ... --wait` exits 0 even on Invalid), staples, `gh release upload --clobber`s the new DMG onto `v0.5.0-alpha11`, regenerates `appcast-alpha.xml`, and `--clobber`s it onto `sparkle-alpha`.

- [ ] **Step 5: If the build fails AFTER notarization, do a fresh rebuild (never --reuse-archive)**

```bash
rm -rf build/Release/Lungfish.xcarchive build/Release/*.dmg
```
Then re-run Step 4 WITHOUT `--reuse-archive` (reusing re-signs and corrupts the stapled bundle).

- [ ] **Step 6: Verify the published artifacts**

Run:
```bash
gh release view v0.5.0-alpha11 --json assets -q '.assets[].name'          # new DMG present, expected size
gh release view sparkle-alpha --json assets -q '.assets[].name'           # appcast-alpha.xml present
curl -sL "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-alpha/appcast-alpha.xml" | grep -E "sparkle:version|enclosure url" | head
```
Expected: the DMG is the freshly built one; the appcast's `<enclosure>` points at the new DMG on `v0.5.0-alpha11` and `sparkle:version` (the build number / `CFBundleVersion`) is greater than the previous shipped build. Confirm the marketing version in the appcast is still `0.5.0-alpha11`.

- [ ] **Step 7: (Optional) Verify the in-app updater offers the hotfix**

If practical, install the previous alpha11 build and trigger "Check for Updates" — it should offer the new build because `CFBundleVersion` increased. Record the result. (This is the proof that the same-version hotfix reaches existing users.)

---

## Self-review checklist (run before handing off)

- **Spec coverage:** runner (Tasks 2-3), glue (Task 5), callback wiring (Task 6), op type (Task 1), argv/naming (Task 4), completion-routing (reused — verified in Task 3's E2E test), tests (Tasks 2-4, 8), GUI smoke (Task 9), same-version hotfix DMG (Task 11). Relabel/export/collapse intentionally untouched. ✓
- **No placeholders:** every code step shows full code; every command shows expected output. ✓
- **Type consistency:** `CLITreeTransformEvent` / `CLITreeTransformResult` / `CLITreeTransformRunner.parseEvent` / `run(arguments:operationID:)` / `cancel()` used consistently across Tasks 2-3 and 5. `TreeBundleTransformCommand.{outputStem,arguments,title}` used consistently in Tasks 4-5. `OperationType.phylogeneticTreeTransform` (Task 1) used in Tasks 3 and 5. `performTreeBundleOperationViaCLI(_:)` defined in Task 5, called in Task 6. ✓
- **Serialization:** build/test gate is the lead's; no concurrent swift invocations. Release build (Task 11) checks for in-flight swift processes first. ✓
