// AlignmentWorkflowCLIGUIParityReplayTests.swift - The Inspector's alignment workflows on the CLI against the in-process route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54 M3 (census rows p36, p37 and p38, decision C4), on lane Q30's `RouteParityHarness`
// (G1, QC-2). The Inspector creates a filtered alignment track, converts mapped reads to annotations, and
// marks or removes duplicates. Side A is the in-process route, the Workflow service the Inspector's task
// awaited (`BundleAlignmentFilterService`, `MappedReadsAnnotationService`, `AlignmentDuplicateService`).
// Side C is the CLI route, whose begin helper records the argv that runs and whose L3 runner runs it
// through the app's transport (`runAlignmentLeafThroughCLI`), and which then reads from the leaf's
// `complete` what the Inspector's completion code reads. Side C' replays the recorded command.
//
// The fixture is the sarscov2 BAM under the tracks of one bundle, which the bundle comparison reads with
// samtools. The duplicate cases hold one track, because the harness numbers the `aln_` IDs a marking draws
// by the sorted order of their random names, so two draws can swap numbers between two runs of one
// command. The annotation request names its track ID, because the contract masks the `aln_` IDs and no
// other, and both routes draw an `ann_` ID from the same service.
//
// One family mask is added, `bamByteDigests`, and the harness is built with it. A BAM that samtools writes
// carries a `@PG` line with the scratch folder and the paths of the run, so its bytes differ in every run
// on either route, and so do the size and digest a record states for it. The contract's
// `contentComparedDigests` masks them where the record names the BAM from the project or by an absolute
// path. It never reads the `<workspace>/` scratch intermediates a filter record lists, nor the
// bundle-relative `source_path` of a manifest entry. The BAM itself is still compared on its header and
// records by samtools. The mask belongs in the contract's "Same result" table (see the lane report), and
// this class is the one place it is used until the contract carries it.
//
// A against C declares each difference with `<ANY>`, C against C' none. The cancel of the same leaves,
// with every core busy, is `AlignmentWorkflowSIGTERMReplayTests`.
//
// It launches the built lungfish-cli and runs samtools, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class AlignmentWorkflowCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case filterAlignment
        case refuseMissingSourceTrack
        case convertMappedReads
        case markDuplicates
        case deduplicateAlignments
    }

    /// Every difference A against C declares. Filtering, converting and a refusal declare none (C4), so
    /// p36 and p37 launch the leaf with no key. The two duplicate cases differ by the leaf's records and by
    /// what their numbering does to the statistics database, and C against C' declares nothing.
    static let declared: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference(
            [.markDuplicates: 5, .deduplicateAlignments: 6],
            "only in C: Project.lungfish/<ANY>.lungfish-provenance.json",
            reason: "The leaf writes the provenance records of its run, the bundle's record and one for the BAM, the index "
                + "and the statistics database of each new track, and the manifest's for a new bundle. The in-process "
                + "service never wrote them, so the CLI route adds the envelope every leaf owes.",
            closedBy: "2.11, when the in-process route goes (C4)"
        ),
        RouteParityDeclaredDifference(
            [.markDuplicates: 9, .deduplicateAlignments: 9],
            "differs: Project.lungfish/<ANY>.stats.db: only in A: <ANY>",
            reason: "Both routes write the same nine rows to the new track's statistics database. A row names the scratch "
                + "folder of the markdup run by a UUID, which the harness numbers across each side's tree in path order. "
                + "The leaf's records come first, so the folder reads <UUID-3> on side C where side A reads <UUID-1>. "
                + "This is the numbering effect of the first entry and no difference in the rows.",
            closedBy: "2.11, when the in-process route goes (C4)"
        ),
        RouteParityDeclaredDifference(
            [.markDuplicates: 9, .deduplicateAlignments: 9],
            "differs: Project.lungfish/<ANY>.stats.db: only in C: <ANY>",
            reason: "The same nine rows as the entry above, read on side C with the shifted UUID number.",
            closedBy: "2.11, when the in-process route goes (C4)"
        ),
    ]

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!
    /// What the leaf's `complete` named on the last run of side C, which the Inspector's completion code reads.
    private var completion: CLIAlignmentActionRunner.Completion?

    override func setUpWithError() throws {
        guard BamFixtureBuilder.locateSamtools() != nil else {
            try ToolAvailability.skipOrFail("samtools is not available, so the bundles cannot be compared")
        }
        scratch = try TestTempDirectory.make(prefix: "alignment-workflow-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: Self.masks, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    // MARK: - The family mask

    nonisolated private static let digestKeys: Set<String> = ["checksumSHA256", "sha256", "checksum"]
    nonisolated private static let sizeKeys: Set<String> = ["fileSize", "sizeBytes", "size_bytes", "file_size_bytes"]

    /// The contract's masks and `bamByteDigests`, for provenance records and manifests.
    nonisolated private static let masks: OutputEquivalence.MaskPolicy = {
        var policy = OutputEquivalence.MaskPolicy.standard
        policy.provenance.append(bamByteDigests)
        policy.records.append(bamByteDigests)
        return policy
    }()

    /// In a JSON object that names a BAM or a BAM index, replaces the digest and the size it states.
    nonisolated private static let bamByteDigests = OutputEquivalence.Mask(name: "bamByteDigests") { text, _ in
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return text }
        var changed = false
        let masked = maskBAMBytes(in: value, changed: &changed)
        guard changed,
              let encoded = try? JSONSerialization.data(
                  withJSONObject: masked, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]
              ),
              let result = String(data: encoded, encoding: .utf8)
        else { return text }
        return result
    }

    nonisolated private static func maskBAMBytes(in value: Any, changed: inout Bool) -> Any {
        if let array = value as? [Any] {
            return array.map { maskBAMBytes(in: $0, changed: &changed) }
        }
        guard var object = value as? [String: Any] else { return value }
        let namesBAM = object.values.contains { item in
            guard let path = (item as? String)?.lowercased() else { return false }
            return path.hasSuffix(".bam") || path.hasSuffix(".bam.bai")
        }
        for (key, item) in object {
            if namesBAM, digestKeys.contains(key) {
                object[key] = "<BAM-SHA256>"
                changed = true
            } else if namesBAM, sizeKeys.contains(key) {
                object[key] = "<BAM-SIZE>"
                changed = true
            } else {
                object[key] = maskBAMBytes(in: item, changed: &changed)
            }
        }
        return object
    }

    // MARK: - The requests

    nonisolated private static func makeFixture(in root: URL, parityCase: Case) throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        try fixture.useAlignment(
            ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        )
        guard parityCase == .markDuplicates || parityCase == .deduplicateAlignments else { return }
        // One alignment track, so a marking draws one `aln_` ID.
        let bundle = fixture.bundleURL
        try BundleManifest.load(from: bundle)
            .removingAlignmentTrack(id: DerivedAlignmentTrackFixture.derivedTrackID)
            .save(to: bundle)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("alignments/filtered"))
    }

    nonisolated private static func bundleURL(in root: URL) -> URL {
        DerivedAlignmentTrackFixture.existing(in: root).bundleURL
    }

    private static func filterRequest(for parityCase: Case) -> AlignmentFilterInspectorLaunchRequest {
        AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: parityCase == .refuseMissingSourceTrack ? "aln-missing" : DerivedAlignmentTrackFixture.sourceTrackID,
            outputTrackName: "Mapped Primary",
            filterRequest: AlignmentFilterRequest(mappedOnly: true, primaryOnly: true, minimumMAPQ: 30)
        )
    }

    private static let annotationLaunch = MappedReadsAnnotationInspectorLaunchRequest(
        sourceTrackID: DerivedAlignmentTrackFixture.sourceTrackID,
        outputTrackName: "Mapped Reads",
        outputTrackID: "mapped_reads_parity",
        primaryOnly: true,
        includeSequence: true,
        includeQualities: true,
        replaceExisting: false
    )

    private static func duplicateKind(of parityCase: Case) -> InspectorViewController.DuplicateWorkflowKind {
        parityCase == .markDuplicates ? .markDuplicates : .createDeduplicatedBundle
    }

    // MARK: - Side A, the service the in-process task awaited

    private static func sideA(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let bundleURL = bundleURL(in: root)
        do {
            switch parityCase {
            case .filterAlignment, .refuseMissingSourceTrack:
                let request = filterRequest(for: parityCase)
                let result = try await BundleAlignmentFilterService().deriveFilteredAlignment(
                    target: .bundle(bundleURL),
                    sourceTrackID: request.sourceTrackID,
                    outputTrackName: request.outputTrackName,
                    filterRequest: request.filterRequest
                )
                return RouteParitySideOutcome(end: .completed, detail: "Created filtered alignment track \"\(result.trackInfo.name)\".")
            case .convertMappedReads:
                let result = try await MappedReadsAnnotationService().convertMappedReads(
                    request: annotationLaunch.workflowRequest(bundleURL: bundleURL)
                )
                return RouteParitySideOutcome(end: .completed, detail: "Created annotation track \"\(result.annotationTrackInfo.name)\".")
            case .markDuplicates:
                let result = try await AlignmentDuplicateService.markDuplicatesInBundle(bundleURL: bundleURL)
                return RouteParitySideOutcome(
                    end: .completed,
                    detail: InspectorViewController.duplicateWorkflowCompletionDetail(kind: .markDuplicates, result: result)
                )
            case .deduplicateAlignments:
                let result = try await AlignmentDuplicateService.createDeduplicatedBundle(from: bundleURL)
                return RouteParitySideOutcome(
                    end: .completed,
                    detail: InspectorViewController.duplicateWorkflowCompletionDetail(kind: .createDeduplicatedBundle, result: result)
                )
            }
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription)
        }
    }

    // MARK: - Side C, the begin helper and the L3 runner through the transport

    /// The row a case begins on the CLI route: its ID, the command it records, and the argv the runner runs.
    struct BegunRow {
        let id: UUID
        let command: String?
        let arguments: [String]
    }

    /// Begins the row of `parityCase` on the CLI route, as the Inspector's launch does, on a reporter or a
    /// center of its own, so the shared center keeps no row of the test.
    static func beginRow(_ parityCase: Case, in root: URL) throws -> BegunRow {
        let bundleURL = bundleURL(in: root)
        switch parityCase {
        case .filterAlignment, .refuseMissingSourceTrack:
            let request = filterRequest(for: parityCase)
            let reporter = RecordingOperationReporter()
            var launched: UUID?
            InspectorViewController.beginFilteredAlignmentWorkflowOperation(
                bundleURL: bundleURL, serviceTarget: .bundle(bundleURL), request: request, route: .cli, reporter: reporter
            ) { launched = $0 }
            return BegunRow(
                id: try XCTUnwrap(launched, "the row started"),
                command: reporter.items.first?.cliCommand,
                arguments: InspectorViewController.filteredAlignmentCLIArguments(serviceTarget: .bundle(bundleURL), request: request)
            )
        case .convertMappedReads:
            let request = annotationLaunch.workflowRequest(bundleURL: bundleURL)
            let reporter = RecordingOperationReporter()
            var launched: UUID?
            InspectorViewController.beginMappedReadsAnnotationWorkflowOperation(request: request, route: .cli, reporter: reporter) {
                launched = $0
            }
            return BegunRow(
                id: try XCTUnwrap(launched, "the row started"),
                command: reporter.items.first?.cliCommand,
                arguments: InspectorViewController.mappedReadsAnnotationCLIArguments(request: request)
            )
        case .markDuplicates, .deduplicateAlignments:
            let kind = duplicateKind(of: parityCase)
            let center = OperationCenter()
            guard case .started(let id) = InspectorViewController.startDuplicateWorkflowOperation(
                kind: kind, bundleURL: bundleURL, route: .cli, routeContext: nil, center: center
            ) else {
                throw XCTSkip("the row did not start")
            }
            guard case .leaf(let arguments) = InspectorViewController.duplicateWorkflowLaunch(kind: kind, bundleURL: bundleURL, route: .cli) else {
                throw XCTSkip("the CLI route runs a leaf")
            }
            return BegunRow(id: id, command: center.items.first { $0.id == id }?.cliCommand, arguments: arguments)
        }
    }

    private func runLeaf(_ row: BegunRow) async -> Result<CLIAlignmentActionRunner.Completion, any Error> {
        let runner = CLIAlignmentActionRunner(cliURLOverride: cli)
        return await withCheckedContinuation { continuation in
            InspectorViewController.runAlignmentLeafThroughCLI(
                arguments: row.arguments, operationID: row.id, runner: runner
            ) { continuation.resume(returning: $0) }
        }
    }

    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let bundleURL = Self.bundleURL(in: root)
        completion = nil
        // The Inspector reads the track count before the row begins, because the leaf's message is text.
        let trackCount = InspectorViewController.duplicateWorkflowTrackCount(
            kind: Self.duplicateKind(of: parityCase), bundleURL: bundleURL
        )
        let row = try Self.beginRow(parityCase, in: root)
        switch await runLeaf(row) {
        case .failure(let error):
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription, recordedCommand: row.command)
        case .success(let leaf):
            completion = leaf
            let detail: String
            switch parityCase {
            case .filterAlignment, .refuseMissingSourceTrack:
                detail = "Created filtered alignment track \"\(Self.filterRequest(for: parityCase).outputTrackName)\"."
            case .convertMappedReads:
                detail = "Created annotation track \"\(InspectorViewController.annotationTrackName(for: Self.annotationLaunch.workflowRequest(bundleURL: bundleURL)))\"."
            case .markDuplicates, .deduplicateAlignments:
                let kind = Self.duplicateKind(of: parityCase)
                let result = try InspectorViewController.duplicateWorkflowResult(
                    kind: kind, bundleURL: bundleURL, trackCount: trackCount, completion: leaf
                )
                detail = InspectorViewController.duplicateWorkflowCompletionDetail(kind: kind, result: result)
            }
            return RouteParitySideOutcome(end: .completed, detail: detail, recordedCommand: row.command)
        }
    }

    private func assertParity(_ parityCase: Case) async throws -> RouteParityResult {
        try await harness.assertParity(
            parityCase, declared: Self.declared,
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { try Self.makeFixture(in: $0, parityCase: parityCase) },
            sideA: { await Self.sideA($0, parityCase) },
            sideC: { try await self.sideC($0, parityCase) }
        )
    }

    private func assertAllCompleted(_ result: RouteParityResult) {
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
    }

    // MARK: - Cases

    func testAFilteredAlignmentIsTheSameBundleAndRecordOnEveryRoute() async throws {
        let result = try await assertParity(.filterAlignment)
        assertAllCompleted(result)
        XCTAssertEqual(result.runs.a.outcome.detail, result.runs.c.outcome.detail, "the row ends on the same words")

        // The Inspector reads the new track's ID from the BAM the leaf named, never from its message.
        let leaf = try XCTUnwrap(completion, "side C completed")
        let createdID = try InspectorViewController.filteredAlignmentTrackID(from: leaf)
        let manifest = try BundleManifest.load(from: Self.bundleURL(in: result.runs.c.root))
        let created = try XCTUnwrap(manifest.alignments.first { $0.id == createdID }, "the manifest holds the track the app opens")
        XCTAssertEqual(created.name, "Mapped Primary")
        XCTAssertEqual(manifest.alignments.count, 3)
    }

    func testAMissingSourceTrackIsRefusedOnEveryRouteWithTheSameWordsAndNothingChanges() async throws {
        let result = try await assertParity(.refuseMissingSourceTrack)
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .failed, "side \(run.side): \(run.outcome.detail)")
            XCTAssertEqual(try BundleManifest.load(from: Self.bundleURL(in: run.root)).alignments.count, 2, "side \(run.side)")
        }
        XCTAssertEqual(result.runs.c.outcome.detail, result.runs.a.outcome.detail, "the alert keeps today's words")
        XCTAssertTrue(result.runs.a.outcome.detail.contains("aln-missing"), result.runs.a.outcome.detail)
    }

    func testMappedReadsAreTheSameAnnotationsAndRecordOnEveryRoute() async throws {
        let result = try await assertParity(.convertMappedReads)
        assertAllCompleted(result)
        XCTAssertEqual(result.runs.a.outcome.detail, result.runs.c.outcome.detail, "the row ends on the same words")

        // The Inspector names the new track from its request, because the leaf's message is text.
        let bundle = Self.bundleURL(in: result.runs.c.root)
        let name = InspectorViewController.annotationTrackName(for: Self.annotationLaunch.workflowRequest(bundleURL: bundle))
        XCTAssertEqual(try BundleManifest.load(from: bundle).annotations.map(\.name), [name])
        XCTAssertEqual(try XCTUnwrap(completion).outputs.count, 1, "the leaf names the annotation database")
    }

    func testMarkedDuplicatesAreTheSameTracksAndRecordOnEveryRoute() async throws {
        let result = try await assertParity(.markDuplicates)
        assertAllCompleted(result)
        XCTAssertEqual(result.runs.a.outcome.detail, "Marked duplicates in 1 alignment track.")
        XCTAssertEqual(result.runs.c.outcome.detail, result.runs.a.outcome.detail, "the count read before begin is the count the service processed")
    }

    func testADeduplicatedBundleIsTheSameBundleAndRecordOnEveryRoute() async throws {
        let result = try await assertParity(.deduplicateAlignments)
        assertAllCompleted(result)
        XCTAssertEqual(result.runs.a.outcome.detail, "Created Sample-deduplicated.lungfishref from 1 alignment track.")
        XCTAssertEqual(result.runs.c.outcome.detail, result.runs.a.outcome.detail, "the bundle the app opens is the one the leaf named")
        let made = Self.bundleURL(in: result.runs.c.root).deletingLastPathComponent().appendingPathComponent("Sample-deduplicated.lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path), "the leaf made the bundle it named")
        XCTAssertEqual(try BundleManifest.load(from: Self.bundleURL(in: result.runs.c.root)).alignments.count, 1, "the source bundle was not changed")
    }
}
