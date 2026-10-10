import CryptoKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// Opening a haplotyped genotype bundle shows the four built-in smart cohorts
/// and writes nothing. The store keeps them in memory, keeps its last
/// persisted state equal to the file, and writes them together with the first
/// edit that publishes the whole sidecar (walk finding F9).
@MainActor
final class GenotypeAnnotationStoreSeedInMemoryTests: XCTestCase {
    private static let builtInNames = [
        "Incomplete haplotypes",
        "Needs review",
        "Homozygous",
        "Recombinants",
    ]

    private struct Layout {
        let root: URL
        let bundleURL: URL

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }

        var recordURL: URL {
            ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        }

        var lockURL: URL {
            ONTGenotypeBundlePublicationLock.lockURL(for: bundleURL)
        }
    }

    private final class PublicationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func inject(_ point: GenotypeAnnotationPublicationFaultPoint) -> Error? {
            if point == .beforeProvenancePublication {
                lock.lock()
                storage += 1
                lock.unlock()
            }
            return nil
        }
    }

    // MARK: - Opening writes nothing

    func testOpeningAFreshBundleWritesNothingAndShowsTheFourBuiltIns() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        let store = try openLikeTheController(layout)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.annotationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.recordURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.lockURL.path))
        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertFalse(store.isReadOnly)
    }

    func testOpeningAnAnnotatedBundleLeavesEveryByteAndEveryRecordDigestValid() throws {
        let layout = try makeCLIAnnotatedBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)
        let digestBefore = sha256Hex(try Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(
            try recordedAnnotationDigests(in: layout).map { $0.digest },
            Array(repeating: digestBefore, count: 4),
            "the fixture must list the sidecar's digest in four records"
        )

        let store = try openLikeTheController(layout)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
        let digestAfter = sha256Hex(try Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(digestAfter, digestBefore)
        for record in try recordedAnnotationDigests(in: layout) {
            XCTAssertEqual(record.digest, digestAfter, "\(record.name) went stale")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.lockURL.path))
        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL)).smartCohorts,
            [],
            "the file still holds no cohorts"
        )
    }

    func testOpeningKeepsTheAnalystsOwnCohortAndAddsOnlyTheMissingBuiltIns() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-26T00:00:00Z")
        sidecar.smartCohorts = [
            GenotypeCohortSmartFilter(
                name: "Needs review",
                description: "Analyst version.",
                scope: "bundle",
                isStarred: true,
                predicate: .commentContains("escalate")
            ),
        ]
        try sidecar.encoded().write(to: layout.annotationURL)
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        let store = try openLikeTheController(layout)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
        XCTAssertEqual(
            store.sidecar.smartCohorts.map(\.name),
            ["Needs review", "Incomplete haplotypes", "Homozygous", "Recombinants"]
        )
        XCTAssertEqual(store.sidecar.smartCohorts.first?.description, "Analyst version.")
    }

    func testAStoreThatDoesNotSeedShowsOnlyWhatTheFileHolds() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }

        let store = try GenotypeAnnotationStore(
            bundleURL: layout.bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )

        XCTAssertTrue(store.sidecar.smartCohorts.isEmpty)
    }

    // MARK: - The first real edit writes the built-ins with itself

    func testFirstSampleNoteOnAFreshBundleWritesTheNoteAndTheBuiltInsInOneWrite() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let counter = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: layout.bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: counter.inject
        )
        XCTAssertEqual(counter.count, 0, "opening publishes nothing")

        try store.addSampleNote(sample: "Animal-1", body: "First note")

        XCTAssertEqual(counter.count, 1, "the edit and the built-ins share one publication")
        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(written.sampleNotes.map(\.body), ["First note"])
        XCTAssertEqual(written.auditLog.map(\.action), ["addSampleNote"])
        XCTAssertEqual(written, store.sidecar)
        try assertFreshRecord(layout, action: "addSampleNote")

        let reopened = try openLikeTheController(layout)
        XCTAssertEqual(reopened.sidecar, written)
    }

    func testFirstSampleNoteOnACLIAnnotatedBundleWritesTheNoteAndTheBuiltInsInOneWrite() throws {
        let layout = try makeCLIAnnotatedBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let counter = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: layout.bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: counter.inject
        )
        let priorDigest = sha256Hex(try Data(contentsOf: layout.annotationURL))
        let priorAuditCount = store.sidecar.auditLog.count

        try store.addSampleNote(sample: "Animal-1", body: "First note")

        XCTAssertEqual(counter.count, 1)
        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(written.sampleNotes.map(\.body), ["First note"])
        XCTAssertEqual(written.auditLog.count, priorAuditCount + 1)
        XCTAssertEqual(written.auditLog.last?.action, "addSampleNote")
        XCTAssertNotEqual(sha256Hex(try Data(contentsOf: layout.annotationURL)), priorDigest)
        try assertFreshRecord(layout, action: "addSampleNote")
    }

    func testFirstCohortSaveWritesTheBuiltInsAndTheSavedCohortTogether() throws {
        let layout = try makeCLIAnnotatedBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let counter = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: layout.bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: counter.inject
        )

        try store.saveSmartCohort(GenotypeCohortSmartFilter(
            name: "Analyst custom",
            scope: "bundle",
            isStarred: true,
            predicate: .hasErrorAtAnyLocus
        ))

        XCTAssertEqual(counter.count, 1)
        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames + ["Analyst custom"])
        try assertFreshRecord(layout, action: "saveSmartCohort")
    }

    /// The Haplotype Calls and Genotype Matrix switch saves the choice through
    /// `updateSettings` (walk finding F10, not changed here). It is a real
    /// write, so it carries the built-ins and must not trip the revision guard.
    func testASettingWriteCarriesTheBuiltInsAndKeepsTheRevisionGuardQuiet() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let counter = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: layout.bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: counter.inject
        )

        try store.updateSettings { $0.preferredSummaryViewMode = "matrix" }

        XCTAssertEqual(counter.count, 1)
        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(written.settings.preferredSummaryViewMode, "matrix")
        XCTAssertEqual(written.auditLog.map(\.action), ["updateSettings"])
        XCTAssertEqual(written, store.sidecar)
        try assertFreshRecord(layout, action: "updateSettings")
    }

    func testTheNextEditAfterTheFirstDoesNotRewriteTheBuiltInsTwice() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try openLikeTheController(layout)
        try store.addSampleNote(sample: "Animal-1", body: "One")

        try store.addSampleNote(sample: "Animal-1", body: "Two")

        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(written.sampleNotes.map(\.body), ["One", "Two"])
    }

    // MARK: - A deleted built-in

    func testADeletedBuiltInIsNotWrittenBackByOpeningAndReturnsOnlyInMemory() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let first = try openLikeTheController(layout)
        try first.addSampleNote(sample: "Animal-1", body: "First note")
        try first.deleteSmartCohort(name: "Homozygous", scope: "bundle")
        XCTAssertFalse(first.sidecar.smartCohorts.map(\.name).contains("Homozygous"))
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        let reopened = try openLikeTheController(layout)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before, "a read must not write the cohort back")
        XCTAssertTrue(reopened.sidecar.smartCohorts.map(\.name).contains("Homozygous"))
        let onDisk = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertFalse(onDisk.smartCohorts.map(\.name).contains("Homozygous"))
    }

    // MARK: - Edits that publish exactly their replayed result

    func testAMatrixEditKeepsTheBuiltInsInMemoryAndTheNextEditStillWritesThem() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try openLikeTheController(layout)

        try await store.upsertMatrixComment(
            body: "Unexpected sample behavior.",
            targets: [.column(sample: "Animal-1")],
            author: "analyst"
        )

        let afterMatrixEdit = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(afterMatrixEdit.matrixComments.map(\.body), ["Unexpected sample behavior."])
        XCTAssertEqual(
            afterMatrixEdit.smartCohorts,
            [],
            "a replayed edit publishes exactly its replayed result"
        )
        XCTAssertEqual(
            store.sidecar.smartCohorts.map(\.name),
            Self.builtInNames,
            "the cohort list in the window must not change"
        )

        try store.addSampleNote(sample: "Animal-1", body: "Later note")

        let afterNote = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(afterNote.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(afterNote.matrixComments.map(\.body), ["Unexpected sample behavior."])
        XCTAssertEqual(afterNote.sampleNotes.map(\.body), ["Later note"])
    }

    func testARejectedMatrixEditKeepsTheBuiltInsAndPublishesNothing() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try openLikeTheController(layout)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-1"
        )

        XCTAssertThrowsError(try store.setMatrixReviewSynchronously(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 0]),
            author: "reviewer"
        )) { error in
            XCTAssertEqual(error as? GenotypeMatrixReviewMutationError, .ineligibleEvidence)
        }

        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(store.matrixMutationRevision, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.annotationURL.path))
    }

    func testACallOverrideOnAFreshBundleStartsFromTheSidecarTheAnalystSees() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try openLikeTheController(layout)

        let result = try store.mutateCallOverrides(
            [overrideMutation(baseline: "M1A", after: "M2A")],
            author: "Analyst",
            analysisIdentity: nil
        )

        XCTAssertTrue(result.didChange)
        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(written.callOverrides.map(\.overrideCall), ["M2A"])
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(written, store.sidecar)
        try assertFreshRecord(layout, action: "mutateCallOverrides")
    }

    func testACallOverrideThatChangesNothingWritesNothingOnAFreshBundle() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try openLikeTheController(layout)
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        let result = try store.mutateCallOverrides(
            [overrideMutation(baseline: "M1A", after: "M1A")],
            author: "Analyst",
            analysisIdentity: nil
        )

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
    }

    // MARK: - A refused write

    func testARefusedWriteKeepsTheUnsavedBuiltInsInTheView() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try openLikeTheController(layout)
        // Another tool annotates the bundle without the built-ins after the
        // window opened it, as `lungfish genotype apply-annotations` does.
        var external = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        external.sampleNotes = [
            .init(sample: "Animal-9", body: "Written elsewhere", author: "cli", timestamp: "2026-08-01T00:00:00Z"),
        ]
        try external.encoded().write(to: layout.annotationURL)
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        XCTAssertThrowsError(try store.addSampleNote(sample: "Animal-1", body: "Refused"))

        // The refused write took the publication lock, which leaves its empty
        // lock file beside the bundle. Nothing else changed.
        var after = try GenotypeBundleTreeSnapshot.entries(of: layout.root)
        after["/" + layout.lockURL.lastPathComponent] = nil
        XCTAssertEqual(after, before)
        XCTAssertEqual(store.sidecar.sampleNotes.map(\.body), ["Written elsewhere"])
        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), Self.builtInNames)
        // The store caught up with the file, so the next edit goes through.
        try store.addSampleNote(sample: "Animal-1", body: "Accepted")
        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(written.sampleNotes.map(\.body), ["Written elsewhere", "Accepted"])
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames)
    }

    // MARK: - Read-only volumes

    func testAReadOnlyBundleStillBrowsesWithTheBuiltInsInMemory() throws {
        try XCTSkipIf(getuid() == 0, "a read-only folder is writable to root")
        let layout = try makeFreshBundle()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: layout.bundleURL.path
            )
            TestTempDirectory.cleanup(layout.root)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: layout.bundleURL.path
        )
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        let store = try openLikeTheController(layout)

        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
        XCTAssertThrowsError(try store.mutateCallOverrides(
            [overrideMutation(baseline: "M1A", after: "M2A")],
            author: "Analyst",
            analysisIdentity: nil
        )) { error in
            XCTAssertEqual(error as? CallOverrideMutationError, .readOnly)
        }
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
    }

    // MARK: - Fixtures

    /// Opens the store the way `GenotypeResultViewController.configure(result:)`
    /// and the Inspector do for a haplotyped result.
    private func openLikeTheController(_ layout: Layout) throws -> GenotypeAnnotationStore {
        try GenotypeAnnotationStore(
            bundleURL: layout.bundleURL,
            author: "analyst",
            seedBuiltInSmartCohorts: true
        )
    }

    /// `<root>/result.lungfishgenotype` holding only a manifest. The lock file
    /// of a publication lands in `root`, so the tree under `root` shows it.
    private func makeFreshBundle() throws -> Layout {
        let root = try TestTempDirectory.make(prefix: "GenotypeSeedInMemory")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(#"{"analysis":"seed-in-memory"}"#.utf8).write(
            to: bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return Layout(root: root, bundleURL: bundleURL)
    }

    /// A bundle annotated by `lungfish genotype apply-annotations`. Its sidecar
    /// holds a sample status and no smart cohorts, and four records list the
    /// sidecar's SHA-256, the bundle root record, the bundle record, the
    /// sidecar's own record in `provenance` and the record beside the sidecar.
    private func makeCLIAnnotatedBundle() throws -> Layout {
        let layout = try makeFreshBundle()
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        sidecar.sampleStatusFlags = [
            .init(sample: "Animal-1", value: .reviewed, author: "cli", timestamp: "2026-08-01T00:00:00Z"),
        ]
        sidecar.append(audit: .init(
            action: "setSampleStatus", sample: "Animal-1", locus: nil, slot: nil,
            before: nil, after: "reviewed", color: nil, reason: nil, rationale: nil,
            author: "cli", timestamp: "2026-08-01T00:00:00Z"
        ))
        let data = try sidecar.encoded()
        try data.write(to: layout.annotationURL)
        try FileManager.default.createDirectory(
            at: layout.bundleURL.appendingPathComponent("provenance", isDirectory: true),
            withIntermediateDirectories: true
        )
        for url in recordURLs(in: layout) {
            let record: [String: Any] = [
                "workflowName": "Genotype annotation sidecar edit",
                "outputs": [[
                    "path": layout.annotationURL.path,
                    "checksumSHA256": sha256Hex(data),
                    "fileSize": data.count,
                ]],
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: url)
        }
        return layout
    }

    private func recordURLs(in layout: Layout) -> [URL] {
        [
            layout.bundleURL.appendingPathComponent(".lungfish-provenance.json"),
            layout.bundleURL.appendingPathComponent("provenance/bundle.lungfish-provenance.json"),
            layout.bundleURL.appendingPathComponent("provenance/annotations.json.lungfish-provenance.json"),
            layout.recordURL,
        ]
    }

    private func recordedAnnotationDigests(in layout: Layout) throws -> [(name: String, digest: String)] {
        try recordURLs(in: layout).map { url in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            let outputs = try XCTUnwrap(object["outputs"] as? [[String: Any]])
            return (url.lastPathComponent, try XCTUnwrap(outputs.first?["checksumSHA256"] as? String))
        }
    }

    /// The record the store wrote for its last publication names `action` and
    /// the digest of the sidecar now on disk.
    private func assertFreshRecord(
        _ layout: Layout,
        action: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: layout.recordURL),
            file: file,
            line: line
        )
        XCTAssertEqual(envelope.workflowName, "Genotype annotation sidecar edit", file: file, line: line)
        XCTAssertEqual(envelope.options.explicit["action"], .string(action), file: file, line: line)
        XCTAssertEqual(
            envelope.outputs.first?.checksumSHA256,
            sha256Hex(try Data(contentsOf: layout.annotationURL)),
            file: file,
            line: line
        )
    }

    private func overrideMutation(baseline: String, after: String) -> CallOverrideMutation {
        .init(
            target: .init(sample: "Animal-1", locus: "MHC-A", slot: .h1),
            baseline: baseline,
            after: after,
            reason: .misCall,
            rationale: "Confirmed by reads"
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
