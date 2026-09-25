// ProjectItemCopyRecordTests.swift - Cross-project link rewriting and missing-source record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class ProjectItemCopyRecordTests: XCTestCase {
    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectItemCopyRecordTests-\(UUID().uuidString)", isDirectory: true)
        sourceProject = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetProject, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    /// Writes a Kraken-style result folder whose sidecar points at `readsPath`
    /// (a file inside a FASTQ bundle of the source project) and returns the
    /// simulated copied folder in the target project.
    private func makeCopiedKrakenResult(
        readsPath: String,
        databasePath: String = "/Users/example/.lungfish/kraken2/standard",
        extraSidecar: [String: Any]? = nil
    ) throws -> (source: URL, destination: URL) {
        let name = "kraken2-2026-09-24T10-00-00"
        let source = sourceProject.appendingPathComponent("Analyses/\(name)", isDirectory: true)
        let destination = targetProject.appendingPathComponent("Analyses/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var sidecar: [String: Any] = [
            "reportPath": "classification.kreport",
            "outputPath": "classification.kraken",
            "runtime": 12.5,
            "toolVersion": "2.1.3",
            "config": [
                "goal": "classify",
                "inputFiles": [URL(fileURLWithPath: readsPath).absoluteString],
                "originalInputFiles": [URL(fileURLWithPath: readsPath).absoluteString],
                "databasePath": URL(fileURLWithPath: databasePath).absoluteString,
                "outputDirectory": URL(fileURLWithPath: source.path).absoluteString,
                "confidence": 0.1,
                "argv": ["kraken2", "--db", databasePath, readsPath],
            ],
        ]
        if let extraSidecar {
            sidecar.merge(extraSidecar) { _, new in new }
        }
        let data = try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination.appendingPathComponent("classification-result.json"))
        try "100.00\t10\t0\tR\t1\troot\n".write(
            to: destination.appendingPathComponent("classification.kreport"),
            atomically: true,
            encoding: .utf8
        )
        return (source, destination)
    }

    private func sidecarJSON(at folder: URL, named name: String = "classification-result.json") throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Tests

    func testUnresolvableSourceReadsAreReportedAndSidecarKeepsOriginalPath() throws {
        let readsPath = sourceProject.appendingPathComponent("Imports/HG002.lungfishfastq/reads.fastq.gz").path
        let (source, destination) = try makeCopiedKrakenResult(readsPath: readsPath)

        let links = try ProjectItemLinkRewriter.rewrite(context: .init(
            sourceItemURL: source,
            destinationItemURL: destination,
            sourceProjectURL: sourceProject,
            targetProjectURL: targetProject
        ))

        let unresolved = links.filter { !$0.isResolved }
        XCTAssertEqual(Set(unresolved.map(\.keyPath)), ["config.inputFiles[0]", "config.originalInputFiles[0]"])
        XCTAssertEqual(unresolved.first?.role, ProjectItemLinkRewriter.Role.inputReads)
        XCTAssertEqual(unresolved.first?.displayName, "reads.fastq.gz")

        let json = try sidecarJSON(at: destination)
        let config = try XCTUnwrap(json["config"] as? [String: Any])
        XCTAssertEqual(config["inputFiles"] as? [String], [URL(fileURLWithPath: readsPath).absoluteString])
        // The result folder's own path moved with the copy.
        XCTAssertEqual(config["outputDirectory"] as? String, URL(fileURLWithPath: destination.path).absoluteString)
        // The command line is a historical record and is never rewritten.
        XCTAssertEqual(config["argv"] as? [String], ["kraken2", "--db", "/Users/example/.lungfish/kraken2/standard", readsPath])
        // The database lives outside both projects and is left alone.
        XCTAssertFalse(links.contains { $0.keyPath == "config.databasePath" })

        let record = ProjectItemCopyRecord(
            copiedAt: Date(),
            sourceItemPath: source.path,
            sourceProjectPath: sourceProject.path,
            targetProjectPath: targetProject.path,
            links: links
        )
        XCTAssertTrue(record.hasMissingSources)
        XCTAssertTrue(record.missingSourceReads)
        XCTAssertEqual(record.unresolvedLinks.count, 1, "one row per distinct original path")
        XCTAssertEqual(record.sourceProjectName, "Source")
        XCTAssertEqual(
            record.missingSourceSummaryLines,
            ["Source data not in this project: reads.fastq.gz (was \(readsPath))"]
        )
        XCTAssertEqual(record.missingSourceReadsReason, "Source reads are not in this project (reads.fastq.gz)")
    }

    func testResolvableSourceReadsAreRewrittenToTargetProject() throws {
        let relative = "Imports/HG002.lungfishfastq/reads.fastq.gz"
        let readsPath = sourceProject.appendingPathComponent(relative).path
        let targetReads = targetProject.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: targetReads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: targetReads)
        let (source, destination) = try makeCopiedKrakenResult(readsPath: readsPath)

        let links = try ProjectItemLinkRewriter.rewrite(context: .init(
            sourceItemURL: source,
            destinationItemURL: destination,
            sourceProjectURL: sourceProject,
            targetProjectURL: targetProject
        ))

        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.allSatisfy(\.isResolved))
        XCTAssertEqual(links.first?.resolvedPath, targetReads.standardizedFileURL.path)

        let config = try XCTUnwrap(try sidecarJSON(at: destination)["config"] as? [String: Any])
        XCTAssertEqual(config["inputFiles"] as? [String], [URL(fileURLWithPath: targetReads.standardizedFileURL.path).absoluteString])

        let record = ProjectItemCopyRecord(
            copiedAt: Date(),
            sourceItemPath: source.path,
            sourceProjectPath: sourceProject.path,
            targetProjectPath: targetProject.path,
            links: links
        )
        XCTAssertFalse(record.hasMissingSources)
        XCTAssertFalse(record.missingSourceReads)
        XCTAssertNil(record.missingSourceReadsReason)
    }

    func testProjectRelativePathsAreCheckedAgainstTargetProject() throws {
        let name = "minimap2-2026-09-24T11-00-00"
        let source = sourceProject.appendingPathComponent("Analyses/\(name)", isDirectory: true)
        let destination = targetProject.appendingPathComponent("Analyses/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let presentReference = targetProject.appendingPathComponent("Reference Sequences/NC_045512.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: presentReference, withIntermediateDirectories: true)

        let sidecar: [String: Any] = [
            "mapper": "minimap2",
            "bamPath": "mapped.bam",
            "sourceReferenceBundlePath": "@/Reference Sequences/NC_045512.lungfishref",
            "viewerBundlePath": "@/Analyses/\(name)/viewer.lungfishref",
            "inputReadsBundlePath": "@/Imports/Missing.lungfishfastq",
        ]
        let data = try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
        try data.write(to: destination.appendingPathComponent("mapping-result.json"))

        let links = try ProjectItemLinkRewriter.rewrite(context: .init(
            sourceItemURL: source,
            destinationItemURL: destination,
            sourceProjectURL: sourceProject,
            targetProjectURL: targetProject
        ))

        let byKey = Dictionary(uniqueKeysWithValues: links.map { ($0.keyPath, $0) })
        XCTAssertEqual(byKey["sourceReferenceBundlePath"]?.isResolved, true)
        XCTAssertEqual(byKey["sourceReferenceBundlePath"]?.role, ProjectItemLinkRewriter.Role.referenceBundle)
        XCTAssertEqual(byKey["inputReadsBundlePath"]?.isResolved, false)
        XCTAssertEqual(byKey["inputReadsBundlePath"]?.role, ProjectItemLinkRewriter.Role.inputReads)
        XCTAssertNil(byKey["viewerBundlePath"], "paths inside the copied item are not source links")

        let json = try sidecarJSON(at: destination, named: "mapping-result.json")
        XCTAssertEqual(json["sourceReferenceBundlePath"] as? String, "@/Reference Sequences/NC_045512.lungfishref")
        XCTAssertEqual(json["inputReadsBundlePath"] as? String, "@/Imports/Missing.lungfishfastq")
        XCTAssertEqual(json["bamPath"] as? String, "mapped.bam")
    }

    func testProjectRelativePathIntoRenamedCopyMovesWithTheItem() throws {
        let source = sourceProject.appendingPathComponent("Analyses/minimap2-2026-09-24T11-00-00", isDirectory: true)
        let destination = targetProject.appendingPathComponent("Analyses/minimap2-2026-09-24T11-00-00-2", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sidecar: [String: Any] = ["viewerBundlePath": "@/Analyses/minimap2-2026-09-24T11-00-00/viewer.lungfishref"]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: destination.appendingPathComponent("mapping-result.json"))

        let links = try ProjectItemLinkRewriter.rewrite(context: .init(
            sourceItemURL: source,
            destinationItemURL: destination,
            sourceProjectURL: sourceProject,
            targetProjectURL: targetProject
        ))

        XCTAssertTrue(links.isEmpty)
        let json = try sidecarJSON(at: destination, named: "mapping-result.json")
        XCTAssertEqual(json["viewerBundlePath"] as? String, "@/Analyses/minimap2-2026-09-24T11-00-00-2/viewer.lungfishref")
    }

    func testSidecarsWithoutProjectPathsAreLeftByteIdentical() throws {
        let destination = targetProject.appendingPathComponent("Phylogenetic Trees/tree.lungfishtree", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = Data("{\"sourceFileName\":\"tree.nwk\",\"leaves\":3}".utf8)
        let manifestURL = destination.appendingPathComponent("manifest.json")
        try original.write(to: manifestURL)
        let provenanceURL = destination.appendingPathComponent(".lungfish-provenance.json")
        let provenance = Data("{\"inputs\":[\"\(sourceProject.path)/x.nwk\"]}".utf8)
        try provenance.write(to: provenanceURL)

        let links = try ProjectItemLinkRewriter.rewrite(context: .init(
            sourceItemURL: sourceProject.appendingPathComponent("Phylogenetic Trees/tree.lungfishtree"),
            destinationItemURL: destination,
            sourceProjectURL: sourceProject,
            targetProjectURL: targetProject
        ))

        XCTAssertTrue(links.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenance, "provenance records are never touched here")
    }

    func testFinderCopyWithoutSourceProjectOnlyMovesItemInternalPaths() throws {
        let readsPath = "/Volumes/Data/HG002.lungfishfastq/reads.fastq.gz"
        let (source, destination) = try makeCopiedKrakenResult(readsPath: readsPath)

        let links = try ProjectItemLinkRewriter.rewrite(context: .init(
            sourceItemURL: source,
            destinationItemURL: destination,
            sourceProjectURL: nil,
            targetProjectURL: targetProject
        ))

        XCTAssertTrue(links.isEmpty)
        let config = try XCTUnwrap(try sidecarJSON(at: destination)["config"] as? [String: Any])
        XCTAssertEqual(config["outputDirectory"] as? String, URL(fileURLWithPath: destination.path).absoluteString)
    }

    func testRecordRoundTripsThroughDisk() throws {
        let item = targetProject.appendingPathComponent("Analyses/kraken2-2026-09-24T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        let link = ProjectItemCopyLink(
            file: "classification-result.json",
            keyPath: "config.inputFiles[0]",
            originalPath: "/old/Imports/A.lungfishfastq/reads.fastq.gz",
            resolvedPath: nil,
            role: ProjectItemLinkRewriter.Role.inputReads
        )
        let record = ProjectItemCopyRecord(
            copiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceItemPath: "/old/Analyses/kraken2-2026-09-24T10-00-00",
            sourceProjectPath: "/old",
            targetProjectPath: targetProject.path,
            links: [link]
        )
        try record.save(to: item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: item.appendingPathComponent(ProjectItemCopyRecord.filename).path))
        let loaded = try XCTUnwrap(ProjectItemCopyRecord.load(from: item))
        XCTAssertEqual(loaded, record)
        XCTAssertNil(ProjectItemCopyRecord.load(from: targetProject))
    }
}
