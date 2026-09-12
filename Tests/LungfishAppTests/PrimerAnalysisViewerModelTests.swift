import Foundation
import XCTest

@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

final class PrimerAnalysisViewerModelTests: XCTestCase {
  private enum SnapshotError: Error { case enumeratorUnavailable }

  @MainActor
  func testRealSnapshotLoaderRunsOffMain() async throws {
    let fixture = try makeBundle(grouping: .independent)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = ThreadRecorder()
    let model = PrimerAnalysisViewerModel { url in
      let loaded = try loadSnapshotAndThreadState(from: url)
      await recorder.record(loaded.ranOffMain)
      return loaded.snapshot
    }

    await model.load(from: fixture.bundleURL)

    let ranOffMain = await recorder.value()
    XCTAssertTrue(ranOffMain)
    guard case .loaded = model.state else { return XCTFail("Expected loaded state") }
  }

  @MainActor
  func testOlderSuccessAndErrorCannotReplaceNewerLoad() async throws {
    let first = try makeBundle(grouping: .independent)
    let second = try makeBundle(grouping: .combined)
    defer {
      try? FileManager.default.removeItem(at: first.root)
      try? FileManager.default.removeItem(at: second.root)
    }
    let firstSnapshot = try PrimerAnalysisViewerSnapshot.load(from: first.bundleURL)
    let secondSnapshot = try PrimerAnalysisViewerSnapshot.load(from: second.bundleURL)
    let gate = SnapshotGate()
    let model = PrimerAnalysisViewerModel { try await gate.load($0) }
    let oldLoad = Task { await model.load(from: first.bundleURL) }
    await gate.waitUntilStarted(first.bundleURL, count: 1)
    let newLoad = Task { await model.load(from: second.bundleURL) }
    await gate.waitUntilStarted(second.bundleURL, count: 1)
    await gate.succeed(secondSnapshot, for: second.bundleURL)
    await newLoad.value
    await gate.succeed(firstSnapshot, for: first.bundleURL)
    await oldLoad.value

    guard case .loaded(let loaded) = model.state else { return XCTFail("Expected loaded state") }
    XCTAssertEqual(loaded.bundle.manifest.analysisID, second.analysisID)

    let third = Task { await model.load(from: first.bundleURL) }
    await gate.waitUntilStarted(first.bundleURL, count: 2)
    let fourth = Task { await model.load(from: second.bundleURL) }
    await gate.waitUntilStarted(second.bundleURL, count: 2)
    await gate.succeed(secondSnapshot, for: second.bundleURL)
    await fourth.value
    await gate.fail(for: first.bundleURL)
    await third.value
    guard case .loaded(let retained) = model.state else { return XCTFail("Expected loaded state") }
    XCTAssertEqual(retained.bundle.manifest.analysisID, second.analysisID)
  }

  @MainActor
  func testModelReportsFailureForCorruptionAndMissingProvenance() async throws {
    let corrupt = try makeBundle(grouping: .independent)
    defer { try? FileManager.default.removeItem(at: corrupt.root) }
    try Data("changed\n".utf8).write(
      to: corrupt.bundleURL.appendingPathComponent("native/result.txt"))
    let corruptModel = PrimerAnalysisViewerModel()
    await corruptModel.load(from: corrupt.bundleURL)
    guard case .failed = corruptModel.state else {
      return XCTFail("Corrupt saved output must produce a failed viewer state")
    }

    let missing = try makeBundle(grouping: .independent)
    defer { try? FileManager.default.removeItem(at: missing.root) }
    try FileManager.default.removeItem(
      at: missing.bundleURL.appendingPathComponent("provenance/wrapper.json"))
    let missingModel = PrimerAnalysisViewerModel()
    await missingModel.load(from: missing.bundleURL)
    guard case .failed = missingModel.state else {
      return XCTFail("Missing canonical provenance must produce a failed viewer state")
    }
  }

  func testRelocationAndSourceDeletionKeepSavedMetadataAndGroupingLabels() throws {
    let independent = try makeBundle(grouping: .independent, duplicateInputs: true)
    defer { try? FileManager.default.removeItem(at: independent.root) }
    let moved = independent.root.appendingPathComponent("moved.lungfishprimeranalysis")
    try FileManager.default.moveItem(at: independent.bundleURL, to: moved)
    for source in independent.sourceURLs { try FileManager.default.removeItem(at: source) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: moved)
    XCTAssertEqual(snapshot.groupingLabel, "One scheme per alignment")
    XCTAssertEqual(snapshot.bundle.url, moved)
    XCTAssertEqual(snapshot.bundle.manifest.inputs.map(\.label), ["duplicate", "duplicate"])
    XCTAssertEqual(Set(snapshot.bundle.manifest.inputs.map(\.id)), Set(independent.inputIDs))
    XCTAssertEqual(snapshot.bundle.manifest.results.map(\.inputIDs), independent.inputIDs.map { [$0] })

    let combined = try makeBundle(grouping: .combined, includeResults: false)
    defer { try? FileManager.default.removeItem(at: combined.root) }
    let empty = try PrimerAnalysisViewerSnapshot.load(from: combined.bundleURL)
    XCTAssertEqual(empty.groupingLabel, "Combined scheme")
    XCTAssertTrue(empty.bundle.manifest.results.isEmpty)
  }

  @MainActor
  func testCancellingLoadCancelsDetachedWorkerAndDoesNotPublishItsResult() async throws {
    let fixture = try makeBundle(grouping: .independent)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL)
    let gate = CancellationGate()
    let model = PrimerAnalysisViewerModel { _ in
      try await gate.waitForCancellation()
      return snapshot
    }
    let load = Task { await model.load(from: fixture.bundleURL) }
    await gate.waitUntilStarted()

    load.cancel()
    await load.value

    let wasCancelled = await gate.wasCancelled
    XCTAssertTrue(wasCancelled)
    guard case .loading = model.state else {
      return XCTFail("A cancelled load must not publish a terminal state")
    }
  }

  func testSnapshotLoadsVerifiedCanonicalProvenanceWithoutChangingBundleBytes() throws {
    let fixture = try makeBundle(grouping: .combined)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try byteSnapshot(of: fixture.bundleURL)

    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL)

    XCTAssertEqual(snapshot.bundle.manifest.analysisID, fixture.analysisID)
    XCTAssertEqual(snapshot.bundle.manifest.runID, fixture.runID)
    XCTAssertEqual(snapshot.provenance.workflowName, "lungfish.primer-analysis.wrap")
    XCTAssertEqual(snapshot.provenance.argv, ["primer-viewer-test-host", "--case", "saved-results"])
    XCTAssertEqual(Data(snapshot.provenanceJSON.utf8), snapshot.bundle.canonicalProvenanceData)
    XCTAssertEqual(try byteSnapshot(of: fixture.bundleURL), before)
  }

  func testOrderingWorksheetIsVerifiedAndRemainsRelativeAfterRelocation() throws {
    let fixture = try makeBundle(grouping: .independent, nativeScheme: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let moved = fixture.root.appendingPathComponent("relocated.lungfishprimeranalysis")
    try FileManager.default.moveItem(at: fixture.bundleURL, to: moved)
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: moved)
    XCTAssertEqual(snapshot.primalSchemeResults.count, 1)
    XCTAssertEqual(snapshot.primalSchemeResults.first?.orderSheetURL,
      moved.appendingPathComponent("native/ordering-v1.csv"))
  }

  func testChecksummedButInconsistentOrderingWorksheetRejectsDisplay() throws {
    let fixture = try makeBundle(grouping: .independent, nativeScheme: true,
      orderSheetOverride: Data("incorrect but checksummed CSV\n".utf8))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Ordering worksheet"))
    }
  }

  private struct Fixture {
    let root: URL
    let bundleURL: URL
    let analysisID: UUID
    let runID: UUID
    let inputIDs: [UUID]
    let sourceURLs: [URL]
  }

  private func makeBundle(
    grouping: PrimerAnalysisGrouping,
    includeResults: Bool = true,
    duplicateInputs: Bool = false,
    nativeScheme: Bool = false,
    orderSheetOverride: Data? = nil
  ) throws -> Fixture {
    let root = canonicalTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let inputURL = root.appendingPathComponent("opaque-input.txt")
    let outputURL = root.appendingPathComponent("opaque-output.txt")
    try Data("input bytes\n".utf8).write(to: inputURL)
    let bed = Data("reference\t0\t2\tLEFT\t1\t+\tAC\n".utf8)
    try (nativeScheme ? bed : Data("output bytes\n".utf8)).write(to: outputURL)
    let outputPath = nativeScheme ? "native/primer.bed" : "native/result.txt"
    var extraArtifacts: [PrimerAnalysisSourceArtifact] = []
    if nativeScheme {
      let referenceURL = root.appendingPathComponent("reference.fasta")
      try Data(">reference\nACGT\n".utf8).write(to: referenceURL)
      let orderURL = root.appendingPathComponent("ordering-v1.csv")
      try (orderSheetOverride ?? PrimalSchemeOrderSheet.csv(fromBED: bed)).write(to: orderURL)
      extraArtifacts = [
        .init(sourceURL: referenceURL, relativePath: "native/reference.fasta", role: "nativeOutput", format: "fasta"),
        .init(sourceURL: orderURL, relativePath: "native/ordering-v1.csv", role: "orderingSheet", format: "csv"),
      ]
    }
    let analysisID = UUID()
    let runID = UUID()
    let inputIDs = duplicateInputs ? [UUID(), UUID()] : [UUID()]
    let secondInputURL = root.appendingPathComponent("opaque-input-2.txt")
    if duplicateInputs { try Data("second input\n".utf8).write(to: secondInputURL) }
    let destination = root.appendingPathComponent("saved.lungfishprimeranalysis", isDirectory: true)
    _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(
      PrimerAnalysisBundleWriteRequest(
        analysisID: analysisID,
        runID: runID,
        grouping: grouping,
        inputs: inputIDs.enumerated().map { index, id in
          PrimerAnalysisInput(
            id: id, label: duplicateInputs ? "duplicate" : "same label",
            artifactPaths: [index == 0 ? "inputs/source.txt" : "inputs/source-2.txt"])
        },
        results: includeResults ? inputIDs.map { id in
          PrimerAnalysisResult(id: UUID(), label: "same label", inputIDs: [id], artifactPaths: [outputPath] + extraArtifacts.map(\.relativePath))
        } : [],
        artifacts: [
          PrimerAnalysisSourceArtifact(sourceURL: inputURL, relativePath: "inputs/source.txt", role: "input", format: "text"),
          PrimerAnalysisSourceArtifact(sourceURL: outputURL, relativePath: outputPath, role: "nativeOutput", format: "text"),
        ] + extraArtifacts + (duplicateInputs ? [PrimerAnalysisSourceArtifact(sourceURL: secondInputURL, relativePath: "inputs/source-2.txt", role: "input", format: "text")] : []),
        destinationURL: destination,
        invocation: PrimerAnalysisWrapperInvocation(
          argv: ["primer-viewer-test-host", "--case", "saved-results"],
          callerVersion: "test-host-1",
          explicitOptions: ["case": .string("saved-results")],
          runtimeIdentity: ProvenanceRuntimeIdentity(
            appVersion: "test", executablePath: "/test/primer-viewer-test-host",
            processIdentifier: 1, operatingSystemVersion: "test", architecture: "arm64",
            user: nil, dependencySet: "test"))))
    return Fixture(
      root: root, bundleURL: destination, analysisID: analysisID, runID: runID,
      inputIDs: inputIDs, sourceURLs: duplicateInputs ? [inputURL, outputURL, secondInputURL] : [inputURL, outputURL])
  }

  private func byteSnapshot(of root: URL) throws -> [String: Data] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys)
    else { throw SnapshotError.enumeratorUnavailable }
    var snapshot: [String: Data] = [:]
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: Set(keys)).isRegularFile == true {
        snapshot[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
      }
    }
    return snapshot
  }

  private func canonicalTemporaryDirectory() -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    let path = FileManager.default.temporaryDirectory.path
    guard realpath(path, &resolved) != nil else {
      XCTFail("Could not canonicalize temporary directory")
      return FileManager.default.temporaryDirectory
    }
    let end = resolved.firstIndex(of: 0) ?? resolved.endIndex
    return URL(
      fileURLWithPath: String(
        decoding: resolved[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self),
      isDirectory: true)
  }
}

private func loadSnapshotAndThreadState(from url: URL) throws -> (
  snapshot: PrimerAnalysisViewerSnapshot, ranOffMain: Bool
) {
  let ranOffMain = !Thread.isMainThread
  let snapshot = try PrimerAnalysisViewerSnapshot.load(from: url)
  return (snapshot, ranOffMain)
}

private actor CancellationGate {
  private var started = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var operationContinuation: CheckedContinuation<Void, Never>?
  private(set) var wasCancelled = false

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func waitForCancellation() async throws {
    started = true
    let waiters = startedWaiters
    startedWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withTaskCancellationHandler {
      await withCheckedContinuation { operationContinuation = $0 }
    } onCancel: {
      Task { await self.cancelOperation() }
    }
    try Task.checkCancellation()
  }

  private func cancelOperation() {
    wasCancelled = true
    operationContinuation?.resume()
    operationContinuation = nil
  }
}

private actor ThreadRecorder {
  private var recorded = false
  func record(_ value: Bool) { recorded = value }
  func value() -> Bool { recorded }
}

private actor SnapshotGate {
  private enum InjectedFailure: Error { case failed }
  private var starts: [URL: Int] = [:]
  private var startWaiters: [URL: [(Int, CheckedContinuation<Void, Never>)]] = [:]
  private var loads: [URL: CheckedContinuation<PrimerAnalysisViewerSnapshot, Error>] = [:]

  func load(_ url: URL) async throws -> PrimerAnalysisViewerSnapshot {
    starts[url, default: 0] += 1
    let count = starts[url, default: 0]
    let ready = startWaiters[url, default: []].filter { $0.0 <= count }
    startWaiters[url]?.removeAll { $0.0 <= count }
    ready.forEach { $0.1.resume() }
    return try await withCheckedThrowingContinuation { loads[url] = $0 }
  }

  func waitUntilStarted(_ url: URL, count: Int) async {
    if starts[url, default: 0] >= count { return }
    await withCheckedContinuation { startWaiters[url, default: []].append((count, $0)) }
  }

  func succeed(_ snapshot: PrimerAnalysisViewerSnapshot, for url: URL) {
    loads.removeValue(forKey: url)?.resume(returning: snapshot)
  }

  func fail(for url: URL) {
    loads.removeValue(forKey: url)?.resume(throwing: InjectedFailure.failed)
  }
}
