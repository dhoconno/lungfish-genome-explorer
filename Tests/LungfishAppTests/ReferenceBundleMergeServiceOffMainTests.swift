import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Drives `ReferenceBundleMergeService.merge` from a real `@MainActor` context, exactly as
/// `SidebarViewController+MenuDelegate` does. The off-main assertions below are only
/// meaningful against this call shape -- running the merge from a test method that is not
/// itself main-actor-isolated would prove nothing about the behaviour users get.
@MainActor
private enum MainActorMergeRunner {
    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String
    ) async throws -> URL {
        MainActor.assertIsolated("Runner must actually start on the main actor")
        return try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: sourceBundleURLs,
            outputDirectory: outputDirectory,
            bundleName: bundleName
        )
    }
}

/// Thread-safe capture box for the `threadingProbe` hook. The probe closure is `@Sendable`
/// and fires from whatever thread `mergeRecordStores` actually runs on; this box lets the
/// (MainActor) test method read the captured value afterward.
private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasMainThread: Bool?
    private var _fired = false

    func record() {
        let isMain = Thread.isMainThread
        lock.lock()
        _wasMainThread = isMain
        _fired = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    var wasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _wasMainThread
    }
}

final class ReferenceBundleMergeServiceOffMainTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleMergeOffMainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ReferenceBundleMergeService.threadingProbe = nil
        ReferenceBundleMergeService.recordStoreThreadingProbe = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    /// The merge body must be ENTERED off the main thread, and must still be off the main
    /// thread after a main-actor progress hop.
    ///
    /// Two probes, covering the two ways this could regress:
    ///
    /// - `threadingProbe` fires at the first statement of `mergeOffMain`, before any
    ///   `await`, so it observes the entry thread.
    /// - `recordStoreThreadingProbe` fires inside `mergeRecordStores`, which runs right
    ///   after an `await reporter.report(...)` that hops *to* the main actor to touch
    ///   OperationCenter. It proves the body is not stranded on main by its own reporting.
    ///
    /// Honest note on what this test does and does not prove today. Under the Swift 6.2
    /// language mode this package builds in, both assertions already hold *without* the
    /// `Task.detached` in `runDetached` -- a `nonisolated async` function does not inherit
    /// its `@MainActor` caller's executor (SE-0338), and a continuation resuming after
    /// `await MainActor.run` lands back on the generic executor. That was checked by
    /// removing the detached hop and re-running this test, which still passed.
    ///
    /// So these assertions are a regression guard on the *observable behaviour* users get,
    /// not a proof that the `Task.detached` is what delivers it. They would catch the real
    /// regression that matters: someone marking `ReferenceBundleMergeService` `@MainActor`,
    /// or otherwise giving the merge body actor isolation.
    func testMergeRunsHeavyWorkOffMainThreadWhenCalledFromMainActor() async throws {
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let bundleA = try await makeGenBankBundle(
            locus: "OFFMAINA",
            geneName: "geneA",
            named: "Off Main A",
            in: projectURL
        )
        let bundleB = try await makeGenBankBundle(
            locus: "OFFMAINB",
            geneName: "geneB",
            named: "Off Main B",
            in: projectURL
        )

        let entryObservation = ThreadObservationBox()
        let recordStoreObservation = ThreadObservationBox()
        ReferenceBundleMergeService.threadingProbe = { entryObservation.record() }
        ReferenceBundleMergeService.recordStoreThreadingProbe = { recordStoreObservation.record() }

        _ = try await MainActorMergeRunner.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Off Main Merge"
        )

        XCTAssertTrue(
            entryObservation.fired,
            "threadingProbe never fired -- test is not exercising the real code path"
        )
        XCTAssertEqual(
            entryObservation.wasMainThread,
            false,
            "reference bundle merge was entered on the main thread -- the merge body gained actor isolation"
        )

        XCTAssertTrue(
            recordStoreObservation.fired,
            "recordStoreThreadingProbe never fired -- test is not exercising the record-store path"
        )
        XCTAssertEqual(
            recordStoreObservation.wasMainThread,
            false,
            "reference bundle merge ran its record-store SQLite work on the main thread"
        )
    }

    private func makeGenBankBundle(
        locus: String,
        geneName: String,
        named bundleName: String,
        in projectURL: URL
    ) async throws -> URL {
        let sourceURL = tempRoot.appendingPathComponent("\(locus).gb")
        let length = 20
        let genBank = """
        LOCUS       \(locus)                \(length) bp    DNA     linear   SYN 01-JAN-2024
        DEFINITION  Synthetic record \(locus) for off-main merge tests.
        ACCESSION   \(locus)
        VERSION     \(locus).1
        FEATURES             Location/Qualifiers
             source          1..\(length)
                             /organism="Synthetic construct"
                             /mol_type="genomic DNA"
             gene            1..\(length)
                             /gene="\(geneName)"
        ORIGIN
                1 atcgatcgatcgatcgatcg
        //

        """
        try genBank.write(to: sourceURL, atomically: true, encoding: .utf8)
        return try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: sourceURL,
            outputDirectory: projectURL,
            preferredBundleName: bundleName
        ).bundleURL
    }
}
