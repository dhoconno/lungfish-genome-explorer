// EsVirituStoredUniqueReadsPinTests.swift - Pins what an EsViritu batch result shows and leaves on disk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
import CryptoKit
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishWorkflow
import LungfishKit
@testable import LungfishCore

@MainActor
private final class StoredCountsRecordingViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []
    override init() { super.init(); viewController.view = NSView() }
    func display(_ request: ClassifierAlignmentEvidenceRequest) { requests.append(request) }
    func clear() {}
}

final class EsVirituStoredUniqueReadsPinTests: XCTestCase {
    /// The result folder the test opened. `configureFromDatabase` gives the detection table the result path
    /// as its identity, so the table's metadata column controller writes the key
    /// `org.lungfish.metadata-column-layout.esviritu.detections:<result path>` to `UserDefaults.standard`,
    /// since the EsViritu views have no defaults seam yet (lane 13.52 owns it). `tearDownWithError` removes
    /// that key and then checks that no key named for the folder is left (decision MD45, the 13.53 BIO Fix 1
    /// probe).
    private var openedRoot: URL?

    override func tearDownWithError() throws {
        if let openedRoot {
            let defaults = UserDefaults.standard
            let name = openedRoot.lastPathComponent
            for key in defaults.dictionaryRepresentation().keys where key.contains(name) {
                defaults.removeObject(forKey: key)
            }
            let leaked = defaults.dictionaryRepresentation().keys.filter { $0.contains(name) }
            XCTAssertTrue(leaked.isEmpty, "the pin left \(leaked) in UserDefaults.standard")
        }
        openedRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - A batch result shows its stored unique reads and writes nothing (13.53, V1-5, UX 6)

    /// A production EsViritu batch opens through `configureFromDatabase`. The table shows the stored
    /// `unique_reads`, and selecting a row changes no file of the result folder. The folder holds a stale
    /// `esviritu-unique-reads.v2.json` and a stale aggregated manifest, so a route that reads either, or
    /// deletes or rewrites it, fails here. The BAM files are empty stand-ins that selection never reads, so
    /// the test needs no tool.
    @MainActor func testOpeningAnEsVirituBatchShowsTheStoredUniqueReadsAndWritesNothing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("EsVirituStoredUniqueReads-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        openedRoot = root
        defer { try? fm.removeItem(at: root) }

        var rows: [EsVirituDetectionRow] = []
        for (sample, virus, accession, assembly, reads, unique) in [
            ("S1", "Virus A", "NC_A.1", "ASM_A", 50, 40),
            ("S2", "Virus B", "NC_B.1", "ASM_B", 30, 25),
        ] {
            let bam = root.appendingPathComponent("\(sample).bam")
            let index = root.appendingPathComponent("\(sample).bam.bai")
            try Data().write(to: bam)
            try Data().write(to: index)
            rows.append(Self.row(
                sample: sample, virus: virus, accession: accession, assembly: assembly,
                reads: reads, uniqueReads: unique, bam: bam, index: index
            ))
        }
        try Data(#"{"byAssembly":{"ASM_A":999,"ASM_B":999},"byContig":{}}"#.utf8)
            .write(to: root.appendingPathComponent("esviritu-unique-reads.v2.json"))
        let staleRow = { (sample: String, virus: String, assembly: String, reads: Int) in
            EsVirituBatchAggregatedManifest.CachedRow(
                sample: sample, virusName: virus, family: nil, assembly: assembly, readCount: reads,
                uniqueReads: 7, rpkmf: 1, coverageBreadth: 0.5, coverageDepth: 1
            )
        }
        try MetagenomicsBatchResultStore.saveEsVirituBatchAggregatedManifest(
            EsVirituBatchAggregatedManifest(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                sampleCount: 2,
                sampleIds: ["S1", "S2"],
                cachedRows: [
                    staleRow("S1", "Virus A", "ASM_A", 50),
                    staleRow("S2", "Virus B", "ASM_B", 30),
                ]
            ),
            to: root
        )
        let database = try EsVirituDatabase.create(
            at: root.appendingPathComponent("esviritu.sqlite"),
            rows: rows,
            metadata: ["tool": "test"]
        )
        let before = try Self.fileDigests(in: root)

        let recorder = StoredCountsRecordingViewer()
        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { recorder }
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: root)
        let table = controller.testDetectionTableView
        let storedBySampleAssembly = ["S1\tASM_A": 40, "S2\tASM_B": 25]
        let storedByAssembly = ["ASM_A": 40, "ASM_B": 25]
        XCTAssertEqual(table.uniqueReadCountsBySampleAssembly, storedBySampleAssembly)
        XCTAssertEqual(table.uniqueReadCountsByAssembly, storedByAssembly)
        XCTAssertEqual(Self.shownUniqueReads(in: table).sorted(), ["25", "40"])

        for index in 0..<2 {
            table.testOutlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let deadline = Date().addingTimeInterval(30)
            while recorder.requests.count < index + 1 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(recorder.requests.count, index + 1, "row \(index) did not open its contig")
            XCTAssertEqual(table.uniqueReadCountsBySampleAssembly, storedBySampleAssembly, "after selecting row \(index)")
            XCTAssertEqual(table.uniqueReadCountsByAssembly, storedByAssembly, "after selecting row \(index)")
            XCTAssertEqual(Self.shownUniqueReads(in: table).sorted(), ["25", "40"], "after selecting row \(index)")
        }

        XCTAssertEqual(try Self.fileDigests(in: root), before, "opening and selecting changed the result folder")
        withExtendedLifetime(database) {}
    }

    /// The unique reads text of every top-level row, as the cells show it.
    @MainActor private static func shownUniqueReads(in table: ViralDetectionTableView) -> [String] {
        let outline = table.testOutlineView
        let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("uniqueReads"))
        guard column >= 0 else { return [] }
        return (0..<outline.numberOfRows).compactMap { row in
            guard outline.level(forRow: row) == 0 else { return nil }
            let view = outline.view(atColumn: column, row: row, makeIfNecessary: true)
            if let cell = view as? NSTableCellView { return cell.textField?.stringValue }
            return (view as? NSTextField)?.stringValue
        }
    }

    /// The relative path of every file and folder under `root`, with the file's SHA-256 or `directory`.
    private static func fileDigests(in root: URL) throws -> [String: String] {
        let base = root.resolvingSymlinksInPath()
        var digests: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                digests[relative] = "directory"
            } else {
                let digest = SHA256.hash(data: try Data(contentsOf: url))
                digests[relative] = digest.map { String(format: "%02x", $0) }.joined()
            }
        }
        return digests
    }

    private static func row(
        sample: String, virus: String, accession: String, assembly: String,
        reads: Int, uniqueReads: Int, bam: URL, index: URL
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample,
            virusName: virus,
            description: nil,
            contigLength: 4_200,
            segment: nil,
            accession: accession,
            assembly: assembly,
            assemblyLength: 4_200,
            kingdom: nil,
            phylum: nil,
            tclass: nil,
            torder: nil,
            family: nil,
            genus: nil,
            species: nil,
            subspecies: nil,
            rpkmf: 1,
            readCount: reads,
            uniqueReads: uniqueReads,
            coveredBases: 4_200,
            meanCoverage: 1,
            avgReadIdentity: 0.99,
            pi: nil,
            filteredReadsInSample: 100,
            bamPath: bam.path,
            bamIndexPath: index.path
        )
    }
}
