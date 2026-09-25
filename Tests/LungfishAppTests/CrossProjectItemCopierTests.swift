// CrossProjectItemCopierTests.swift - Copying bundles and results between projects
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

/// Builds two temporary projects, fills the source with one item of every
/// kind the sidebar knows, and checks that each copies into the target whole,
/// lands in the conventional folder, and is recognised there.
final class CrossProjectItemCopierTests: XCTestCase {
    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CrossProjectItemCopierTests-\(UUID().uuidString)", isDirectory: true)
        sourceProject = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        try fm.createDirectory(at: sourceProject, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetProject, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - Fixture builders

    @discardableResult
    private func makeDirectory(_ relative: String, in project: URL) throws -> URL {
        let url = project.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A single-run Kraken 2 result whose sidecar points at reads inside a
    /// FASTQ bundle of the source project.
    private func makeKrakenResult(named name: String = "kraken2-2026-09-24T10-00-00", readsRelative: String) throws -> URL {
        let dir = try makeDirectory("Analyses/\(name)", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "kraken2", isBatch: false, created: Date(timeIntervalSince1970: 1_758_708_000)),
            to: dir
        )
        let reads = sourceProject.appendingPathComponent(readsRelative)
        try writeJSON([
            "reportPath": "classification.kreport",
            "outputPath": "classification.kraken",
            "runtime": 3.5,
            "toolVersion": "2.1.3",
            "savedAt": "2026-09-24T10:00:10Z",
            "config": [
                "goal": "classify",
                "inputFiles": [reads.absoluteString],
                "originalInputFiles": [reads.absoluteString],
                "isPairedEnd": false,
                "sampleDisplayName": "HG002",
                "databaseName": "standard-8",
                "databaseVersion": "2024-09",
                "databasePath": URL(fileURLWithPath: "/Users/example/.lungfish/kraken2/standard-8").absoluteString,
                "confidence": 0.1,
                "minimumHitGroups": 2,
                "threads": 4,
                "memoryMapping": false,
                "quickMode": false,
                "outputDirectory": dir.absoluteString,
            ],
        ], to: dir.appendingPathComponent("classification-result.json"))
        try writeText(
            "100.00\t10\t0\tR\t1\troot\n 90.00\t9\t9\tS\t562\t    Escherichia coli\n",
            to: dir.appendingPathComponent("classification.kreport")
        )
        try writeText("C\tr1\t562\t100\t562:70\n", to: dir.appendingPathComponent("classification.kraken"))
        return dir
    }

    private func makeReadBundle(_ relative: String, in project: URL) throws -> URL {
        let bundle = try makeDirectory(relative, in: project)
        try writeText("@r1\nACGT\n+\nIIII\n", to: bundle.appendingPathComponent("reads.fastq"))
        return bundle
    }

    private func makeBundle(_ relative: String, in project: URL, files: [String: String] = ["manifest.json": "{\"bundleKind\":\"fixture\"}"]) throws -> URL {
        let bundle = try makeDirectory(relative, in: project)
        for (name, contents) in files {
            try writeText(contents, to: bundle.appendingPathComponent(name))
        }
        return bundle
    }

    private func sidebarTitles(in project: URL) -> [String] {
        func collect(_ nodes: [SidebarScanNode]) -> [String] {
            nodes.flatMap { [$0.url?.lastPathComponent ?? $0.title] + collect($0.children) }
        }
        return collect(SidebarProjectScanner.scanRootNodes(from: project))
    }

    private func relativePath(of url: URL, in project: URL) -> String {
        ProjectItemLinkRewriter.relative(
            path: url.standardizedFileURL.path,
            toAny: ProjectItemLinkRewriter.pathVariants(of: project)
        ) ?? url.path
    }

    // MARK: - Kraken 2 (the reported case)

    func testKrakenResultCopiesWholeIsRecognisedAndReportsMissingReads() throws {
        try makeReadBundle("Imports/HG002.lungfishfastq", in: sourceProject)
        let source = try makeKrakenResult(readsRelative: "Imports/HG002.lungfishfastq/reads.fastq")

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject)

        XCTAssertEqual(relativePath(of: outcome.destinationURL, in: targetProject), "Analyses/kraken2-2026-09-24T10-00-00")
        XCTAssertEqual(outcome.kind, .analysisResult(tool: "kraken2", isBatch: false))
        for name in ["analysis-metadata.json", "classification-result.json", "classification.kreport", "classification.kraken", ProjectItemCopyRecord.filename] {
            XCTAssertTrue(fm.fileExists(atPath: outcome.destinationURL.appendingPathComponent(name).path), "\(name) missing after copy")
        }

        // Recognised by the sidebar from the copied folder alone.
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: outcome.destinationURL))
        XCTAssertEqual(info.tool, "kraken2")
        XCTAssertTrue(sidebarTitles(in: targetProject).contains("kraken2-2026-09-24T10-00-00"))
        XCTAssertEqual(SidebarProjectScanner.analysisItemType(for: info.tool), .classificationResult)
        XCTAssertEqual(ClassifierDatabaseRouter.route(for: outcome.destinationURL)?.tool, "kraken2")

        // Opens its taxonomy from its own kreport even though the reads are absent.
        let loaded = try ClassificationResult.load(from: outcome.destinationURL)
        XCTAssertEqual(loaded.tree.totalReads, 10)
        XCTAssertEqual(loaded.config.outputDirectory.standardizedFileURL, outcome.destinationURL.standardizedFileURL)
        XCTAssertNil(
            ProjectItemLinkRewriter.relative(path: loaded.config.inputFiles[0].path, toAny: ProjectItemLinkRewriter.pathVariants(of: targetProject)),
            "the unresolved link keeps pointing at the old project rather than a path that does not exist here"
        )

        // The missing source is reported, once, with its original path.
        let record = try XCTUnwrap(ProjectItemCopyRecord.load(from: outcome.destinationURL))
        XCTAssertTrue(record.missingSourceReads)
        XCTAssertEqual(record.unresolvedLinks.map(\.displayName), ["reads.fastq"])
        XCTAssertEqual(record.unresolvedLinks.first?.originalPath, sourceProject.appendingPathComponent("Imports/HG002.lungfishfastq/reads.fastq").absoluteString)
        XCTAssertEqual(record.sourceProjectPath, sourceProject.standardizedFileURL.path)
        XCTAssertEqual(record.sourceProjectName, "Source")
        XCTAssertNotNil(record.missingSourceReadsReason)
    }

    func testKrakenResultLinksRepairWhenReadsExistInTargetAndHistoryIsRecorded() throws {
        try makeReadBundle("Imports/HG002.lungfishfastq", in: sourceProject)
        let targetReads = try makeReadBundle("Imports/HG002.lungfishfastq", in: targetProject)
        let source = try makeKrakenResult(readsRelative: "Imports/HG002.lungfishfastq/reads.fastq")

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject)

        XCTAssertFalse(outcome.record.hasMissingSources)
        let loaded = try ClassificationResult.load(from: outcome.destinationURL)
        XCTAssertEqual(loaded.config.inputFiles.first?.standardizedFileURL, targetReads.appendingPathComponent("reads.fastq").standardizedFileURL)

        let manifest = AnalysisManifestStore.load(bundleURL: targetReads, projectURL: targetProject)
        XCTAssertEqual(manifest.analyses.count, 1)
        XCTAssertEqual(manifest.analyses.first?.tool, "kraken2")
        XCTAssertEqual(manifest.analyses.first?.analysisDirectoryName, "kraken2-2026-09-24T10-00-00")
        XCTAssertEqual(manifest.analyses.first?.summary, "Copied from project Source")
    }

    func testNameClashAppendsCounter() throws {
        let source = try makeKrakenResult(readsRelative: "Imports/A.lungfishfastq/reads.fastq")

        let first = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject)
        let second = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject)
        let third = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject)

        XCTAssertEqual(first.destinationURL.lastPathComponent, "kraken2-2026-09-24T10-00-00")
        XCTAssertEqual(second.destinationURL.lastPathComponent, "kraken2-2026-09-24T10-00-00-2")
        XCTAssertEqual(third.destinationURL.lastPathComponent, "kraken2-2026-09-24T10-00-00-3")
        XCTAssertEqual(AnalysesFolder.analysisInfo(for: second.destinationURL)?.tool, "kraken2")

        let ref = try makeBundle("Reference Sequences/NC_045512.lungfishref", in: sourceProject)
        let refFirst = try CrossProjectItemCopier.copy(itemAt: ref, intoProject: targetProject)
        let refSecond = try CrossProjectItemCopier.copy(itemAt: ref, intoProject: targetProject)
        XCTAssertEqual(refFirst.destinationURL.lastPathComponent, "NC_045512.lungfishref")
        XCTAssertEqual(refSecond.destinationURL.lastPathComponent, "NC_045512-2.lungfishref")
    }

    // MARK: - Every item kind

    func testEveryItemKindLandsInItsConventionalFolderAndIsRecognised() throws {
        try makeReadBundle("Imports/HG002.lungfishfastq", in: sourceProject)
        var expectations: [(source: URL, destination: String, sidebarName: String)] = []

        expectations.append((try makeReadBundle("Imports/HG002.lungfishfastq", in: sourceProject), "Imports/HG002.lungfishfastq", "HG002.lungfishfastq"))
        expectations.append((try makeBundle("Reference Sequences/NC_045512.lungfishref", in: sourceProject), "Reference Sequences/NC_045512.lungfishref", "NC_045512.lungfishref"))
        expectations.append((try makeBundle("Phylogenetic Trees/tree.lungfishtree", in: sourceProject), "Phylogenetic Trees/tree.lungfishtree", "tree.lungfishtree"))
        expectations.append((try makeBundle("Analyses/Multiple Sequence Alignments/aln.lungfishmsa", in: sourceProject), "Analyses/Multiple Sequence Alignments/aln.lungfishmsa", "aln.lungfishmsa"))
        expectations.append((try makeBundle("Primer Schemes/artic.lungfishprimers", in: sourceProject), "Primer Schemes/artic.lungfishprimers", "artic.lungfishprimers"))
        expectations.append((try makeBundle("Workflows/pipeline.lungfishflow", in: sourceProject), "Workflows/pipeline.lungfishflow", "pipeline.lungfishflow"))

        let genotype = try makeBundle("Analyses/run.lungfishgenotype", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "ont-genotyping", isBatch: false), to: genotype)
        expectations.append((genotype, "Analyses/run.lungfishgenotype", "run.lungfishgenotype"))

        let czId = try makeBundle("Classifications/sample.lungfishtax", in: sourceProject, files: [
            "cz-id-manifest.json": "{\"sourceFiles\":[\"\(sourceProject.path)/x.csv\"]}",
            "classification-result.json": "{}",
        ])
        expectations.append((czId, "Classifications/sample.lungfishtax", "sample.lungfishtax"))

        let esviritu = try makeDirectory("Analyses/esviritu-batch-2026-09-24T09-00-00", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "esviritu", isBatch: true), to: esviritu)
        try writeText("x", to: esviritu.appendingPathComponent("sample.detected_virus.info.tsv"))
        let esvirituSample = try makeDirectory("Analyses/esviritu-batch-2026-09-24T09-00-00/SampleA", in: sourceProject)
        try writeJSON(["config": ["inputFiles": [sourceProject.appendingPathComponent("Imports/HG002.lungfishfastq/reads.fastq").absoluteString]]],
                      to: esvirituSample.appendingPathComponent("esviritu-result.json"))
        expectations.append((esviritu, "Analyses/esviritu-batch-2026-09-24T09-00-00", "esviritu-batch-2026-09-24T09-00-00"))

        let taxtriage = try makeDirectory("Analyses/taxtriage-2026-09-24T09-00-00", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "taxtriage", isBatch: false), to: taxtriage)
        try writeJSON(["sourceBundleURLs": [sourceProject.appendingPathComponent("Imports/HG002.lungfishfastq").absoluteString]],
                      to: taxtriage.appendingPathComponent("taxtriage-result.json"))
        expectations.append((taxtriage, "Analyses/taxtriage-2026-09-24T09-00-00", "taxtriage-2026-09-24T09-00-00"))

        let minimap = try makeDirectory("Analyses/minimap2-2026-09-24T09-00-00", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "minimap2", isBatch: false), to: minimap)
        try makeBundle("Analyses/minimap2-2026-09-24T09-00-00/viewer.lungfishref", in: sourceProject)
        try writeJSON([
            "mapper": "minimap2",
            "bamPath": "mapped.bam",
            "viewerBundlePath": "@/Analyses/minimap2-2026-09-24T09-00-00/viewer.lungfishref",
            "sourceReferenceBundlePath": "@/Reference Sequences/NC_045512.lungfishref",
        ], to: minimap.appendingPathComponent("mapping-result.json"))
        expectations.append((minimap, "Analyses/minimap2-2026-09-24T09-00-00", "minimap2-2026-09-24T09-00-00"))

        let flye = try makeDirectory("Analyses/flye-2026-09-24T09-00-00", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "flye", isBatch: false), to: flye)
        try writeJSON(["tool": "flye", "contigsPath": "contigs.fasta", "outputDirectory": flye.path],
                      to: flye.appendingPathComponent("assembly-result.json"))
        expectations.append((flye, "Analyses/flye-2026-09-24T09-00-00", "flye-2026-09-24T09-00-00"))

        let spades = try makeDirectory("Analyses/spades-2026-09-24T09-00-00", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "spades", isBatch: false), to: spades)
        expectations.append((spades, "Analyses/spades-2026-09-24T09-00-00", "spades-2026-09-24T09-00-00"))

        let naomgs = try makeDirectory("Analyses/naomgs-SampleA", in: sourceProject)
        try writeJSON(["taxonCount": 3, "sourceFilePath": "\(sourceProject.path)/Imports/a.tsv"], to: naomgs.appendingPathComponent("manifest.json"))
        try writeText("", to: naomgs.appendingPathComponent("hits.sqlite"))
        expectations.append((naomgs, "Analyses/naomgs-SampleA", "naomgs-SampleA"))

        let nvd = try makeDirectory("Analyses/nvd-SampleB", in: sourceProject)
        try writeJSON(["experiment": "E1"], to: nvd.appendingPathComponent("manifest.json"))
        try writeText("", to: nvd.appendingPathComponent("hits.sqlite"))
        expectations.append((nvd, "Analyses/nvd-SampleB", "nvd-SampleB"))

        for expectation in expectations {
            XCTAssertTrue(
                CrossProjectItemCopier.isCopyableProjectItem(expectation.source),
                "\(expectation.source.lastPathComponent) should be a copyable item"
            )
            let outcome = try CrossProjectItemCopier.copy(itemAt: expectation.source, intoProject: targetProject)
            XCTAssertEqual(
                relativePath(of: outcome.destinationURL, in: targetProject),
                expectation.destination,
                "\(expectation.source.lastPathComponent) landed in the wrong folder"
            )
            XCTAssertTrue(
                fm.fileExists(atPath: outcome.destinationURL.appendingPathComponent(ProjectItemCopyRecord.filename).path),
                "\(expectation.source.lastPathComponent) has no copy record"
            )
        }

        let titles = sidebarTitles(in: targetProject)
        for expectation in expectations {
            XCTAssertTrue(titles.contains(expectation.sidebarName), "sidebar does not show \(expectation.sidebarName): \(titles)")
        }

        // The mapping result's reference link resolved because the reference
        // bundle was copied first, and its viewer link moved with the folder.
        let mappingRecord = try XCTUnwrap(ProjectItemCopyRecord.load(from: targetProject.appendingPathComponent("Analyses/minimap2-2026-09-24T09-00-00")))
        XCTAssertFalse(mappingRecord.hasMissingSources)
        XCTAssertEqual(mappingRecord.links.map(\.keyPath), ["sourceReferenceBundlePath"])
    }

    // MARK: - Unresolvable links of other kinds

    func testMappingResultReportsMissingReferenceBundle() throws {
        let minimap = try makeDirectory("Analyses/minimap2-2026-09-24T09-00-00", in: sourceProject)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "minimap2", isBatch: false), to: minimap)
        try writeJSON([
            "mapper": "minimap2",
            "sourceReferenceBundlePath": "@/Reference Sequences/Missing.lungfishref",
        ], to: minimap.appendingPathComponent("mapping-result.json"))

        let outcome = try CrossProjectItemCopier.copy(itemAt: minimap, intoProject: targetProject)

        XCTAssertTrue(outcome.record.hasMissingSources)
        XCTAssertFalse(outcome.record.missingSourceReads, "a missing reference does not disable read-level actions")
        XCTAssertEqual(outcome.record.unresolvedLinks.first?.role, ProjectItemLinkRewriter.Role.referenceBundle)
        XCTAssertEqual(outcome.record.unresolvedLinks.first?.displayName, "Missing.lungfishref")
    }

    // MARK: - Destinations

    func testFinderDropFromOutsideAnyProjectUsesKindConvention() throws {
        let loose = root.appendingPathComponent("Desktop", isDirectory: true)
        let ref = try makeBundle("NC_045512.lungfishref", in: loose)
        let kraken = try makeDirectory("kraken2-2026-09-24T10-00-00", in: loose)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "kraken2", isBatch: false), to: kraken)
        try writeJSON(["config": ["inputFiles": ["/Volumes/Elsewhere/reads.fastq"]]], to: kraken.appendingPathComponent("classification-result.json"))

        let refOutcome = try CrossProjectItemCopier.copy(itemAt: ref, intoProject: targetProject)
        let krakenOutcome = try CrossProjectItemCopier.copy(itemAt: kraken, intoProject: targetProject)

        XCTAssertEqual(relativePath(of: refOutcome.destinationURL, in: targetProject), "Reference Sequences/NC_045512.lungfishref")
        XCTAssertEqual(relativePath(of: krakenOutcome.destinationURL, in: targetProject), "Analyses/kraken2-2026-09-24T10-00-00")
        XCTAssertNil(krakenOutcome.record.sourceProjectPath)
        XCTAssertFalse(krakenOutcome.record.hasMissingSources, "paths outside any project are not source-project links")
    }

    func testDropOntoFolderIsHonouredExceptResultsAlwaysGoUnderAnalyses() throws {
        let ref = try makeBundle("Reference Sequences/NC_045512.lungfishref", in: sourceProject)
        let kraken = try makeKrakenResult(readsRelative: "Imports/A.lungfishfastq/reads.fastq")
        let custom = try makeDirectory("Shared", in: targetProject)
        let reviewed = try makeDirectory("Analyses/Reviewed", in: targetProject)

        let refOutcome = try CrossProjectItemCopier.copy(itemAt: ref, intoProject: targetProject, requestedFolder: custom)
        let krakenToCustom = try CrossProjectItemCopier.copy(itemAt: kraken, intoProject: targetProject, requestedFolder: custom)
        let krakenToReviewed = try CrossProjectItemCopier.copy(itemAt: kraken, intoProject: targetProject, requestedFolder: reviewed)

        XCTAssertEqual(relativePath(of: refOutcome.destinationURL, in: targetProject), "Shared/NC_045512.lungfishref")
        XCTAssertEqual(relativePath(of: krakenToCustom.destinationURL, in: targetProject), "Analyses/kraken2-2026-09-24T10-00-00")
        XCTAssertEqual(relativePath(of: krakenToReviewed.destinationURL, in: targetProject), "Analyses/Reviewed/kraken2-2026-09-24T10-00-00")
        XCTAssertTrue(sidebarTitles(in: targetProject).contains("Reviewed"))
    }

    func testGroupedSourceFolderIsMirrored() throws {
        let kraken = try makeKrakenResult(readsRelative: "Imports/A.lungfishfastq/reads.fastq")
        let grouped = sourceProject.appendingPathComponent("Analyses/Reviewed/\(kraken.lastPathComponent)", isDirectory: true)
        try fm.createDirectory(at: grouped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: kraken, to: grouped)

        let outcome = try CrossProjectItemCopier.copy(itemAt: grouped, intoProject: targetProject)

        XCTAssertEqual(relativePath(of: outcome.destinationURL, in: targetProject), "Analyses/Reviewed/kraken2-2026-09-24T10-00-00")
    }

    func testProjectsAndPackagesAreNotCopyableItems() throws {
        let nested = try makeDirectory("Other.lungfish", in: sourceProject)
        let package = try makeDirectory("flow.lungfishflowpkg", in: sourceProject)
        let plain = try makeDirectory("just-a-folder", in: sourceProject)
        try writeText("x", to: sourceProject.appendingPathComponent("loose.fasta"))

        XCTAssertNil(CrossProjectItemCopier.kind(of: nested))
        XCTAssertNil(CrossProjectItemCopier.kind(of: package))
        XCTAssertNil(CrossProjectItemCopier.kind(of: plain))
        XCTAssertNil(CrossProjectItemCopier.kind(of: sourceProject.appendingPathComponent("loose.fasta")))
        XCTAssertThrowsError(try CrossProjectItemCopier.copy(itemAt: plain, intoProject: targetProject))
    }

    // MARK: - Drop routing

    func testImportPlannerKeepsResultFoldersWholeAndPartitionRoutesThem() throws {
        try makeReadBundle("Imports/HG002.lungfishfastq", in: sourceProject)
        let kraken = try makeKrakenResult(readsRelative: "Imports/HG002.lungfishfastq/reads.fastq")
        let ref = try makeBundle("Reference Sequences/NC_045512.lungfishref", in: sourceProject)
        let loose = sourceProject.appendingPathComponent("loose.fasta")
        try writeText(">x\nACGT\n", to: loose)

        // Dragging the whole Analyses folder from Finder keeps each result whole.
        let plan = SidebarImportPlanner.makePlan(for: [sourceProject.appendingPathComponent("Analyses"), ref, loose])
        XCTAssertEqual(
            Set(plan.sourceURLs.map(\.lastPathComponent)),
            [kraken.lastPathComponent, ref.lastPathComponent, "loose.fasta"]
        )

        let partition = MainSplitViewController.partitionDroppedSources(plan.sourceURLs)
        XCTAssertEqual(Set(partition.projectItems.map(\.lastPathComponent)), [kraken.lastPathComponent, ref.lastPathComponent])
        XCTAssertEqual(partition.other.map(\.lastPathComponent), ["loose.fasta"])
    }

    func testProvenanceReceiptRecordsSourceProject() throws {
        let ref = try makeBundle("Reference Sequences/NC_045512.lungfishref", in: sourceProject, files: ["sequence.fasta": ">x\nACGT\n"])

        let outcome = try CrossProjectItemCopier.copy(itemAt: ref, intoProject: targetProject)

        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: outcome.destinationURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        ))
        let step = try XCTUnwrap(receipt.steps.first { $0.toolName == "lungfish-app" })
        XCTAssertTrue(step.argv.contains("--source-project"))
        XCTAssertTrue(step.argv.contains(sourceProject.standardizedFileURL.path))
        XCTAssertNotNil(step.resolvedOptions["sourceProject"])
    }
}
