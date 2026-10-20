// VariantExportCLIGUIParityReplayTests+Sides.swift - The fixture, the sides and the comparison of the variant exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

// MARK: - The fixture and the drawer

extension VariantExportCLIGUIParityReplayTests {
    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent(bundleName, isDirectory: true)
    }

    /// The output each side writes, in its root.
    static func outputURL(in root: URL, for parityCase: Case) -> URL {
        root.appendingPathComponent(parityCase.outputName)
    }

    static func envelope(in root: URL, for parityCase: Case) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root, for: parityCase))
        ))
    }

    /// A reference bundle with tracks `first-track` and `second-track`. Each database is made from a VCF beside the
    /// bundle with two samples, and stores bookmarks on rs200 and rs50 (first) and rs10 (second). With
    /// `sharesOneDatabase` the second track names the first track's database.
    nonisolated static func makeBundle(_ root: URL, sharesOneDatabase: Bool) throws {
        let bundle = root.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try makeDatabase(in: root, bundle: bundle, name: "first", samples: ["SAMPLE_B", "SAMPLE_A"], rows: [
            "chr1\t100\trs100\tA\tG\t50\tPASS\t.\tGT\t0/1\t0/0",
            "chr1\t200\trs200\tC\tT\t.\tq10\t.\tGT\t1/1\t0/1",
            "chr2\t50\trs50\tG\tA\t12.5\tPASS\t.\tGT\t0/0\t0/1",
        ], bookmarking: ["rs200", "rs50"])
        let secondDatabase = sharesOneDatabase ? "first.db" : "second.db"
        if !sharesOneDatabase {
            try makeDatabase(in: root, bundle: bundle, name: "second", samples: ["sample_a", "SAMPLE_C"], rows: [
                "chr3\t10\trs10\tT\tC\t60\tPASS\t.\tGT\t0/1\t0/1",
            ], bookmarking: ["rs10"])
        }
        let manifest = BundleManifest(
            name: "Ref",
            identifier: "org.lungfish.test.variant-export",
            source: SourceInfo(organism: "Test", assembly: "Ref"),
            variants: [
                VariantTrackInfo(
                    id: "first-track", name: "First", path: "first.db", indexPath: "first.db",
                    databasePath: "first.db", variantType: .snp, variantCount: 3
                ),
                VariantTrackInfo(
                    id: "second-track", name: "Second", path: secondDatabase, indexPath: secondDatabase,
                    databasePath: secondDatabase, variantType: .snp, variantCount: sharesOneDatabase ? 3 : 1
                ),
            ]
        )
        try manifest.save(to: bundle)
    }

    private nonisolated static func makeDatabase(
        in root: URL, bundle: URL, name: String, samples: [String], rows: [String], bookmarking ids: Set<String>
    ) throws {
        let vcfURL = root.appendingPathComponent("\(name).vcf")
        let header = (["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT"] + samples)
            .joined(separator: "\t")
        try ((["##fileformat=VCFv4.2", header] + rows).joined(separator: "\n") + "\n")
            .write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = bundle.appendingPathComponent("\(name).db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        let database = try VariantDatabase(url: databaseURL, readWrite: true)
        let records = try database.queryForTableExport(
            nameFilter: "", types: [], infoFilters: [], sampleNames: [], smartFilter: nil, activeTokens: [], limit: Int.max
        )
        for record in records where ids.contains(record.variantID) {
            XCTAssertTrue(database.toggleBookmark(variantId: try XCTUnwrap(record.id)))
        }
    }

    /// A drawer over the side's bundle, with the search index the viewer gives it and two sample metadata columns.
    static func drawer(over root: URL) async throws -> AnnotationTableDrawerView {
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: try await ReferenceBundle(url: bundleURL(in: root)), chromosomes: [])
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = index
        drawer.sampleMetadataFields = metadataFields
        return drawer
    }

    /// The invocation the drawer's save panel completion builds for the case.
    static func drawerInvocation(_ root: URL, _ parityCase: Case) async throws -> ViewerExportInvocation {
        let drawer = try await drawer(over: root)
        let output = outputURL(in: root, for: parityCase)
        if parityCase.isBookmarked {
            return BookmarkedVariantExport.invocation(
                databaseURLs: try XCTUnwrap(drawer.bookmarkedVariantsExportDatabaseURLs()),
                outputURL: output,
                force: FileManager.default.fileExists(atPath: output.path)
            )
        }
        return drawer.variantSampleTemplateExportInvocation(bundleURL: bundleURL(in: root), outputURL: output)
    }

    static func begin(
        _ parityCase: Case,
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        if parityCase.isBookmarked {
            return AnnotationTableDrawerView.beginBookmarkedVariantsExportOperation(
                invocation: invocation, runner: runner, environmentAdditions: environmentAdditions, onFailure: onFailure
            )
        }
        return AnnotationTableDrawerView.beginVariantSampleTemplateExportOperation(
            invocation: invocation, runner: runner, environmentAdditions: environmentAdditions, onFailure: onFailure
        )
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

// MARK: - The sides

extension VariantExportCLIGUIParityReplayTests {
    /// Side A. The in-app writers the drawer ran before the leaves, frozen.
    func sideA(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let drawer = try await Self.drawer(over: root)
        let index = try XCTUnwrap(drawer.searchIndex)
        let output = Self.outputURL(in: root, for: parityCase)
        do {
            if parityCase.isBookmarked {
                try Self.frozenExportBookmarkedVariants(index: index, to: output)
            } else {
                try VariantSampleTemplateExportPinTests.frozenTemplate(
                    databases: index.variantDatabaseHandles.map(\.db), fields: drawer.sampleMetadataFields, url: output
                )
            }
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(output.lastPathComponent)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `exportBookmarkedVariants` as the drawer held it at ebdf72d3a, its row loop and `bookmarkedVariantExportSourceURLs`
    /// with the panel's URL a parameter, then `BookmarkedVariantExportService.export` as it stood there.
    private static func frozenExportBookmarkedVariants(index: AnnotationSearchIndex, to url: URL) throws {
        var bookmarkedResults: [AnnotationSearchIndex.SearchResult] = []
        for handle in index.variantDatabaseHandles {
            let records = handle.db.bookmarkedVariants()
            for record in records {
                bookmarkedResults.append(AnnotationSearchIndex.SearchResult(
                    name: record.variantID,
                    chromosome: record.chromosome,
                    start: record.position,
                    end: record.end,
                    trackId: handle.trackId,
                    type: record.variantType,
                    ref: record.ref,
                    alt: record.alt,
                    quality: record.quality,
                    filter: record.filter,
                    sampleCount: record.sampleCount,
                    variantRowId: record.id
                ))
            }
        }
        var seen = Set<String>()
        let sourceURLs: [URL] = index.variantDatabaseHandles.compactMap { handle in
            let url = handle.db.databaseURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return seen.insert(url.path).inserted ? url : nil
        }
        let rows = bookmarkedResults.map {
            BookmarkedVariantExport.Row(
                name: $0.name, type: $0.type, chromosome: $0.chromosome, start: $0.start,
                ref: $0.ref, alt: $0.alt, quality: $0.quality, filter: $0.filter)
        }

        // BookmarkedVariantExportService.export at ebdf72d3a.
        let runClock = ProvenanceRunClock()
        let content = BookmarkedVariantExport.tsv(rows: rows)
        var argv = ["Lungfish Genome Explorer", "export-bookmarked-variants"]
        for sourceURL in sourceURLs { argv += ["--variant-database", sourceURL.path] }
        argv += ["--output", url.path]
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app bookmarked variant export", toolName: "Lungfish.app", toolKind: "gui", sourceURLs: sourceURLs,
            outputURL: url, outputFormat: .text, argv: argv,
            explicitOptions: ["sourceVariantDatabasePaths": .array(sourceURLs.map { .file($0) }),
                "outputPath": .file(url)],
            defaults: ["outputFormat": .string("tsv")],
            resolved: ["variantCount": .integer(rows.count)], runClock: runClock
        )) { stagedURL in
            try content.write(to: stagedURL, atomically: true, encoding: .utf8)
        }
    }

    /// Side C. The drawer's invocation and begin helper, which run the built CLI behind the row on the shared runner.
    func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let invocation = try await Self.drawerInvocation(root, parityCase)
        let failures = VariantExportParityFailures()
        guard let begun = Self.begin(
            parityCase,
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(failures.messages, [])
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }
}

@MainActor
final class VariantExportParityFailures {
    var messages: [String] = []
}

// MARK: - The comparison

extension VariantExportCLIGUIParityReplayTests {
    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record changes hold.
    @discardableResult
    func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try Self.makeBundle(root, sharesOneDatabase: parityCase.sharesOneDatabase) },
            sideA: { root in try await self.sideA(root, parityCase) },
            sideC: { root in try await self.sideC(root, parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "side \(side) names no other side's root")
        }
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "C against C' declares nothing")
        try assertAEqualsC(runs, parityCase)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// A against C on the facts of 1.7, with each record path read relative to its side root. No file but the
    /// record differs, and the record's compared facts are equal. Side A of the template wrote no record.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let outputA = Self.outputURL(in: runs.a.root, for: parityCase)
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: outputA).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: outputA)
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root, for: parityCase)), "the payload byte for byte")
        let c = try Self.envelope(in: runs.c.root, for: parityCase)
        let databases = parityCase.sharesOneDatabase
            ? ["/\(Self.bundleName)/first.db"] : ["/\(Self.bundleName)/first.db", "/\(Self.bundleName)/second.db"]
        let namedInputs = Self.inputs(of: c, under: runs.c.root).keys.sorted()
        if parityCase.isBookmarked {
            XCTAssertEqual(
                namedInputs, databases,
                "each variant database the leaf read once, never the bundle folder, its manifest or a VCF (BIO 6)"
            )
        } else {
            XCTAssertEqual(
                namedInputs, (databases + ["/\(Self.bundleName)/manifest.json"]).sorted(),
                "each variant database the leaf read once and the manifest that lists them, "
                    + "never the bundle folder or a VCF (BIO 6)"
            )
        }
        guard parityCase.isBookmarked else {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: outputA).path),
                "the drawer's template wrote no record before the leaf"
            )
            return
        }
        let a = try Self.envelope(in: runs.a.root, for: parityCase)
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root), Self.inputs(of: c, under: runs.c.root), "inputs and digests")
        let recordedA = try XCTUnwrap(a.output)
        let recordedC = try XCTUnwrap(c.output)
        XCTAssertNotNil(recordedA.checksumSHA256)
        XCTAssertEqual(recordedA.checksumSHA256, recordedC.checksumSHA256, "the output digest")
        XCTAssertEqual(recordedA.fileSize, UInt64(payloadA.count))
        XCTAssertEqual(recordedA.fileSize, recordedC.fileSize, "the output size")
        let resolvedA = a.options.resolvedDefaults
        let resolvedC = c.options.resolvedDefaults
        XCTAssertEqual(Set(resolvedA.keys).intersection(resolvedC.keys), Self.sharedBookmarkResolvedKeys)
        for key in Self.sharedBookmarkResolvedKeys.sorted() {
            XCTAssertEqual(resolvedA[key], resolvedC[key], "resolved \(key)")
        }
    }

    /// The prediction rows of the lane report (BIO 7). The identity fields move from the app's writer to the leaf,
    /// and the record's argv is the row's command (ARCH 2). The template's record is new.
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let c = try Self.envelope(in: runs.c.root, for: parityCase)
        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        guard parityCase.isBookmarked else {
            XCTAssertEqual(Array(rowArguments.prefix(3)), VariantSampleTemplateExport.commandPath)
            XCTAssertEqual(c.workflowName, VariantSampleTemplateExport.workflowName)
            XCTAssertEqual(Set(c.options.resolvedDefaults.keys), ["metadataColumns", "sampleCount"])
            XCTAssertEqual(c.options.resolvedDefaults["sampleCount"]?.integerValue, 4)
            XCTAssertEqual(
                c.options.resolvedDefaults["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), Self.metadataFields
            )
            XCTAssertEqual(c.options.explicit.keys.sorted(), ["metadataColumns", "outputFormat", "outputPath"])
            XCTAssertEqual(c.options.explicit["outputFormat"]?.stringValue, parityCase == .sampleTemplateCSV ? "csv" : "tsv")
            XCTAssertTrue(c.options.defaults.isEmpty)
            return
        }
        let a = try Self.envelope(in: runs.a.root, for: parityCase)
        let outputA = Self.outputURL(in: runs.a.root, for: parityCase)
        let databasesA = a.files.filter { $0.role == .input }.map(\.path)
        let argvA = ["Lungfish Genome Explorer", "export-bookmarked-variants"]
            + databasesA.flatMap { ["--variant-database", $0] } + ["--output", outputA.path]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA, "no /bin/cp replay since the c2 side A fix")
        XCTAssertEqual(a.workflowName, "lungfish app bookmarked variant export")
        XCTAssertEqual(Set(a.options.resolvedDefaults.keys), Self.sharedBookmarkResolvedKeys)
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["outputPath", "sourceVariantDatabasePaths"])
        XCTAssertEqual(a.options.defaults["outputFormat"]?.stringValue, "tsv")

        XCTAssertEqual(Array(rowArguments.prefix(3)), BookmarkedVariantExport.commandPath)
        XCTAssertEqual(c.workflowName, BookmarkedVariantExport.workflowName)
        XCTAssertEqual(Set(c.options.resolvedDefaults.keys), Self.sharedBookmarkResolvedKeys)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["outputPath", "variantDatabasePaths"])
        XCTAssertEqual(c.options.explicit["variantDatabasePaths"]?.arrayValue?.count, 2, "one path for each track")
        XCTAssertEqual(c.options.defaults.keys.sorted(), ["outputFormat"])
        XCTAssertEqual(c.options.defaults["outputFormat"]?.stringValue, "tsv")
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}
