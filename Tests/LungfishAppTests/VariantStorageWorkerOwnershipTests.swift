import AppKit
import XCTest
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class VariantStorageWorkerOwnershipTests: XCTestCase {
    func testWorkerKeepsBundleLeaseUntilDrainAndSuppressesReplacedSource() async throws {
        _ = NSApplication.shared
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("worker-\(UUID()).lungfishref")
        let started = expectation(description: "worker entered")
        let finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        var published = false
        let task = try XCTUnwrap(drawer.runVariantStorageMutation(title: "Invented mutation", bundleURL: bundle,
            center: center, work: {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                _ = finish.wait(timeout: .now() + 10)
                return 7
            }, publish: { _ in published = true }))
        await fulfillment(of: [started], timeout: 3)
        let owner = try XCTUnwrap(center.activeLockHolder(for: bundle))
        XCTAssertEqual(owner.state, .running)
        XCTAssertNil(owner.onCancel, "A synchronous durable transaction cannot promise cancellation")
        let blocked = drawer.runVariantStorageMutation(title: "Competing mutation", bundleURL: bundle,
            center: center, work: { XCTFail("Busy bundle must not enter another worker"); return 0 }, publish: { _ in })
        XCTAssertNil(blocked)
        XCTAssertEqual(center.activeLockHolder(for: bundle)?.id, owner.id)
        drawer.searchIndex = AnnotationSearchIndex()
        XCTAssertFalse(published)
        finish.signal()
        await task.value
        XCTAssertFalse(published, "A completed old mutation cannot refresh a newer inspector source")
        XCTAssertTrue(center.canStartOperation(on: bundle))
        XCTAssertEqual(center.items.first { $0.id == owner.id }?.state, .completed)
    }

    func testWorkerPublishesOnlyAfterDatabaseAndProvenanceCommit() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mutation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("invented.lungfishref")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent(BundleManifest.filename))
        let vcf = root.appendingPathComponent("invented.vcf")
        try Data("##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\ninvented\t1\t.\tA\tG\t50\tPASS\t.\n".utf8).write(to: vcf)
        let database = bundle.appendingPathComponent("variants.db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: database)
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()
        var published: VariantDeletionMutationResult?
        let task = try XCTUnwrap(drawer.runVariantStorageMutation(title: "Delete invented variants", bundleURL: bundle,
            center: center, work: {
                XCTAssertFalse(Thread.isMainThread)
                return try VariantDeletionMutationService().deleteAllVariants(bundleURL: bundle,
                    targets: [VariantDeletionMutationTarget(trackId: "invented", databaseURL: database)])
            }, publish: { published = $0 }))
        await task.value
        XCTAssertEqual(published?.totalDeleted, 1)
        XCTAssertEqual(try VariantDatabase(url: database).totalCount(), 0)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertEqual(provenance.workflowName, "Variant deletion")
        XCTAssertTrue(provenance.outputs.contains { $0.path == database.path && $0.role == .output })
        XCTAssertTrue(center.canStartOperation(on: bundle))
    }

    func testFailedWorkerReleasesLeaseWithoutPublishing() async throws {
        _ = NSApplication.shared
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("failure-\(UUID()).lungfishref")
        var published = false
        let task = try XCTUnwrap(drawer.runVariantStorageMutation(title: "Failed update", bundleURL: bundle,
            center: center, work: { () throws -> Int in throw CocoaError(.fileWriteUnknown) },
            publish: { _ in published = true }))
        await task.value
        XCTAssertFalse(published)
        XCTAssertEqual(center.items.first?.state, .failed)
        XCTAssertTrue(center.canStartOperation(on: bundle))
    }
}
