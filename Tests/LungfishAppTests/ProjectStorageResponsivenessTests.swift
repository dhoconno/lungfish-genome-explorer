import AppKit
import CryptoKit
import Darwin
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishApp

@MainActor
final class ProjectStorageResponsivenessTests: XCTestCase {
    func testNativeProjectOpenReturnsCatalogWithoutHydratingEveryPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invented.lungfish")
        do {
            let project = try ProjectFile.create(at: url, name: "Invented catalog")
            for index in 0..<3 {
                _ = try project.addSequence(Sequence(name: "invented-\(index)", alphabet: .dna, bases: "ACGT"))
            }
            try project.save()
        }
        let session = ProjectSession()
        _ = try session.openProject(at: url)
        XCTAssertEqual(session.documents.count, 3)
        XCTAssertTrue(session.documents.allSatisfy { $0.sequences.isEmpty && $0.annotations.isEmpty },
            "Opening should return catalog entries; selected payload hydration is a separate request")
        session.closeProject()
    }

    /// Opt-in measured fixture. Root runs this before and after the storage change.
    /// Correctness tests use controlled gates; timings here are evidence, not SLAs.
    func testSyntheticStorageBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["LGE_STORAGE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LGE_STORAGE_BENCHMARK=1 for the reproducible storage benchmark")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageBenchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("synthetic.lungfish")
        let documentCount = 256
        let baseCount = 16_384
        let historyCount = 128
        let variantCount = 10_000
        let fixtureStarted = Date()
        var selectedID: UUID!
        do {
            let project = try ProjectFile.create(at: projectURL, name: "Invented storage benchmark")
            let bases = String(repeating: "ACGT", count: baseCount / 4)
            for index in 0..<documentCount {
                let id = try project.addSequence(Sequence(name: String(format: "invented-%04d", index), alphabet: .dna, bases: bases))
                if index == 0 { selectedID = id }
            }
            var old = bases
            for index in 0..<historyCount {
                let new = String(repeating: "N", count: index + 1) + String(bases.dropFirst(index + 1))
                try project.recordEdit(sequenceId: selectedID, diff: SequenceDiff.compute(from: old, to: new), message: "Invented edit \(index)")
                old = new
            }
            try project.save()
        }
        let bundleURL = root.appendingPathComponent("invented.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent(BundleManifest.filename))
        let vcfURL = root.appendingPathComponent("invented.vcf")
        let header = "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
        let rows = (1...variantCount).map { "invented\t\($0)\t.\tA\tG\t50\tPASS\tDP=10\n" }.joined()
        try Data((header + rows).utf8).write(to: vcfURL)
        let databaseURL = bundleURL.appendingPathComponent("variants.db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        let fixtureFiles = try [projectURL.appendingPathComponent(".project.db"), vcfURL, databaseURL].map { url -> [String: Any] in
            let data = try Data(contentsOf: url)
            return ["path": url.path, "sizeBytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let provenance: [String: Any] = ["workflow": "ProjectStorageResponsivenessTests.syntheticFixture", "version": 1,
            "argv": ProcessInfo.processInfo.arguments, "options": ["documents": documentCount, "basesPerDocument": baseCount, "versions": historyCount, "variants": variantCount],
            "runtime": ProcessInfo.processInfo.operatingSystemVersionString, "inputs": [], "outputs": fixtureFiles,
            "exitStatus": 0, "wallTimeSeconds": Date().timeIntervalSince(fixtureStarted), "stderr": ""]
        try JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys]).write(to: root.appendingPathComponent("fixture-provenance.json"))

        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        let split = try XCTUnwrap(controller.mainSplitViewController)
        let session = controller.projectSession
        let open = try await measureMainActorWork {
            delegate.openProject(projectURL, in: controller)
            await delegate.testingWaitForProjectOpen(in: controller)
        }
        let selected = try await measureMainActorWork { await split.externalDocumentLoadTask?.value }
        let hydratedAfterOpen = session.documents.filter { !$0.sequences.isEmpty }.count
        XCTAssertEqual(hydratedAfterOpen, 1)
        let secondController = MainWindowController()
        let secondOpen = try await measureMainActorWork {
            delegate.openProject(projectURL, in: secondController)
            await delegate.testingWaitForProjectOpen(in: secondController)
            await secondController.mainSplitViewController?.externalDocumentLoadTask?.value
        }
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()
        var deletedCount = 0
        let mutation = try await measureMainActorWork {
            let task = try XCTUnwrap(drawer.runVariantStorageMutation(title: "Invented benchmark deletion", bundleURL: bundleURL,
                center: center, work: {
                    try VariantDeletionMutationService().deleteAllVariants(bundleURL: bundleURL,
                        targets: [VariantDeletionMutationTarget(trackId: "invented", databaseURL: databaseURL)])
                }, publish: { deletedCount = $0.totalDeleted }))
            await task.value
        }
        XCTAssertEqual(deletedCount, variantCount)
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["fixture": provenance, "open": open, "selectedContent": selected,
            "secondWindowOpen": secondOpen, "variantMutation": mutation, "peakRSSBytes": usage.ru_maxrss,
            "processorCount": ProcessInfo.processInfo.processorCount, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "measuredEntryPoints": "AppDelegate async open/catalog, selected UI hydration drain, second-window open+selected drain, annotation drawer mutation worker",
            "hydratedDocumentsAfterOpen": hydratedAfterOpen]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("LGE_STORAGE_BENCHMARK " + String(decoding: json, as: UTF8.self))
        if let output = ProcessInfo.processInfo.environment["LGE_STORAGE_BENCHMARK_OUTPUT"] {
            try json.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        controller.close()
        secondController.close()
    }

    private func measureMainActorWork(_ work: @MainActor () async throws -> Void) async throws -> [String: Double] {
        let start = ProcessInfo.processInfo.systemUptime
        var heartbeatDelay = 0.0
        let heartbeat = Task { @MainActor in
            heartbeatDelay = ProcessInfo.processInfo.systemUptime - start
        }
        try await work()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        await heartbeat.value
        return ["wallSeconds": elapsed, "queuedMainActorHeartbeatDelaySeconds": heartbeatDelay]
    }
}
