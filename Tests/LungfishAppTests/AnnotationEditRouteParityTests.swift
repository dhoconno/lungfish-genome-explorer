// AnnotationEditRouteParityTests.swift - The three in-process annotation edits against their sequence leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A42 M3, decision C3. An annotation edit whose only inputs are the bundle and
// typed or selected values runs in process the Workflow function its `lungfish-cli sequence`
// leaf runs, and its row records that leaf. Each test makes one reference bundle in root A and
// copies it to root C. Side A is the app's edit, its begin helper and the call its launch site
// makes on that row's values. Side C replays the command the row recorded, rebased onto root C,
// through the leaf in this process. The route parity harness compares the two roots
// (Tests/Support/LungfishKitTestSupport/RouteParityHarness.swift), and A against C declares
// nothing. No side launches the CLI, so the class stays in the unit tier and the harness's
// binary never runs.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class AnnotationEditRouteParityTests: XCTestCase {
    enum Case: String, Sendable {
        case addAnnotation
        case updateAnnotation
        case deleteAnnotation
    }

    private var scratch: URL!
    /// The harness's comparison only. This class runs no CLI.
    private let harness = RouteParityHarness(cliBinary: URL(fileURLWithPath: "/usr/bin/false"), kind: .bundle)

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "annotation-edit-parity")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - g6, Add Annotation

    func testAddAnnotationWritesWhatSequenceAddAnnotationWrites() async throws {
        let found = try await routeDifferences(.addAnnotation) { bundle in
            // A minus-strand primer whose name starts with a hyphen, as the sheet allows.
            let annotation = SequenceAnnotation(
                type: .primer,
                name: "-35 box",
                chromosome: "chr1",
                intervals: [AnnotationInterval(start: 4, end: 20)],
                strand: .reverse
            )
            let reporter = RecordingOperationReporter()
            var invocationArgv: [String]?
            await AppDelegate.beginManualReferenceAnnotationOperation(
                annotation: annotation, chromosome: "chr1", bundleURL: bundle, routeContext: nil, reporter: reporter
            ) { _, argv in invocationArgv = argv }
            _ = try await ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName).addAnnotation(
                annotation, toBundleAt: bundle, invocationArgv: try XCTUnwrap(invocationArgv)
            )
            return try XCTUnwrap(reporter.items.first?.cliCommand)
        }
        assertAgree(.addAnnotation, found)
    }

    // MARK: - p1, Update Annotation

    func testUpdateAnnotationWritesWhatSequenceUpdateAnnotationWrites() async throws {
        let found = try await routeDifferences(.updateAnnotation) { bundle in
            let location = ReferenceBundleAnnotationRowLocation(trackID: "imported", rowID: try Self.firstRowID(in: bundle))
            let annotation = SequenceAnnotation(
                type: .gene,
                name: "-10 box",
                chromosome: "chr1",
                intervals: [AnnotationInterval(start: 2, end: 9)],
                strand: .reverse,
                note: "renamed in the Inspector"
            )
            let reporter = RecordingOperationReporter()
            AppDelegate.beginAnnotationUpdateOperation(
                annotation: annotation, location: location, bundleURL: bundle, routeContext: nil, reporter: reporter
            )
            _ = try await ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName).updateAnnotation(
                location,
                name: annotation.name,
                type: annotation.type.rawValue,
                strand: annotation.strand.rawValue,
                note: annotation.note,
                bundleURL: bundle
            )
            return try XCTUnwrap(reporter.items.first?.cliCommand)
        }
        assertAgree(.updateAnnotation, found)
    }

    // MARK: - p2, Delete Annotation

    func testDeleteAnnotationWritesWhatSequenceDeleteAnnotationsWrites() async throws {
        let found = try await routeDifferences(.deleteAnnotation) { bundle in
            let location = ReferenceBundleAnnotationRowLocation(trackID: "imported", rowID: try Self.firstRowID(in: bundle))
            let reporter = RecordingOperationReporter()
            AppDelegate.beginAnnotationDeletionOperation(
                location: location, bundleURL: bundle, routeContext: nil, reporter: reporter
            )
            _ = try await ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName).deleteAnnotation(location, bundleURL: bundle)
            return try XCTUnwrap(reporter.items.first?.cliCommand)
        }
        assertAgree(.deleteAnnotation, found)
    }

    // MARK: - The two sides

    /// Makes the fixture bundle in root A, copies root A to root C, runs `appRoute` on root A's
    /// bundle, replays the command it returns on root C through the leaf in this process, and
    /// returns how root C differs from root A.
    private func routeDifferences(
        _ parityCase: Case,
        appRoute: (URL) async throws -> String
    ) async throws -> [RouteParityDifference] {
        let caseRoot = scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true)
        let rootA = RouteParityHarness.root(of: .a, in: caseRoot)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        let bundleA = try Self.makeBundle(in: rootA, inputs: scratch)
        try FileManager.default.copyItem(at: rootA, to: rootC)

        let command = try await appRoute(bundleA)
        try await RecordedCLICommand.runInProcess(try RecordedCLICommand.rebased(command, from: rootA, to: rootC))

        let sideA = RouteParitySideRun(side: .a, root: rootA, outcome: RouteParitySideOutcome(end: .completed))
        let sideC = RouteParitySideRun(side: .c, root: rootC, outcome: RouteParitySideOutcome(end: .completed, recordedCommand: command))
        return try harness.differences(sideA, sideC)
    }

    /// Fails with every difference of A against C, since the edit declares none (decision C4).
    private func assertAgree(_ parityCase: Case, _ found: [RouteParityDifference], line: UInt = #line) {
        let failures = RouteParityHarness.failures(found: [.aAgainstC: found], parityCase: parityCase, declared: [])
        RouteParityHarness.assertNoFailures(failures, in: parityCase.rawValue, line: line)
    }

    // MARK: - Fixture

    /// A reference bundle of one 40-base chromosome with one SQLite-backed annotation track,
    /// `imported`, of one gene row, the shape `ReferenceBundleAnnotationImportService` writes.
    /// The BED the track is made from stays in `inputs`, outside the root.
    static func makeBundle(in root: URL, inputs: URL) throws -> URL {
        let bundleURL = root.appendingPathComponent("Fixture.lungfishref", isDirectory: true)
        let genome = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotations = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        try ">chr1\n\(String(repeating: "ACGTACGTAC", count: 4))\n"
            .write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t40\t6\t40\t41\n".write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        let bedURL = inputs.appendingPathComponent("imported.bed")
        try "chr1\t2\t9\tgeneA\t0\t+\t2\t9\t0,0,0\t1\t7,\t0,\tgene\tID=geneA;gene=geneA\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        let featureCount = try AnnotationDatabase.createFromBED(
            bedURL: bedURL,
            outputURL: annotations.appendingPathComponent("imported.db")
        )

        let manifest = BundleManifest(
            name: "Fixture",
            identifier: "org.lungfish.test.annotation-edit-parity",
            source: SourceInfo(organism: "Test", assembly: "Fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 40,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 40, offset: 6, lineBases: 40, lineWidth: 41)]
            )
        ).addingAnnotationTrack(AnnotationTrackInfo(
            id: "imported",
            name: "Imported",
            path: "annotations/imported.db",
            databasePath: "annotations/imported.db",
            annotationType: .custom,
            featureCount: featureCount,
            source: "test"
        ))
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// The row ID of the gene row of the `imported` track.
    static func firstRowID(in bundle: URL) throws -> Int64 {
        let database = try AnnotationDatabase(url: bundle.appendingPathComponent("annotations/imported.db"))
        return try XCTUnwrap(database.queryForTable(limit: 10).first?.rowID)
    }
}
