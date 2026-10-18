// ProvenanceLineageResolverTests.swift - Lineage walks upstream through input sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Synchronization
import XCTest
@testable import LungfishWorkflow

/// A variant track's record names the BAM it read; the BAM's record names the
/// reads it mapped. The resolver follows those links by path (re-rooted into
/// the current project when the record was written elsewhere) and by SHA-256
/// when the recorded path resolves nothing, so the chain starts at the reads.
final class ProvenanceLineageResolverTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    /// The project root the records were written under, on another machine.
    private let foreign = "/elsewhere/Original Demo.lungfish"

    private let readsSHA = String(repeating: "a", count: 64)
    private let bamSHA = String(repeating: "b", count: 64)
    private let vcfSHA = String(repeating: "c", count: 64)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage-resolver-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Copied Demo.lungfish", isDirectory: true)
        for folder in ["Imports/reads.lungfishfastq", "Analyses/minimap2-1/ref.lungfishref/variants"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func record(_ path: String, _ sha: String, _ role: FileRole) -> FileRecord {
        FileRecord(path: path, sha256: sha, sizeBytes: 4, format: nil, role: role)
    }

    /// Writes a legacy `WorkflowRun` sidecar verbatim, as the shipped demos
    /// were written: absolute paths of the recording machine, no placeholders.
    @discardableResult
    private func writeLegacy(_ run: WorkflowRun, to relativePath: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = project.appendingPathComponent(relativePath)
        try encoder.encode(run).write(to: url, options: .atomic)
        return url
    }

    private func run(_ name: String, tool: String, inputs: [FileRecord], outputs: [FileRecord]) -> WorkflowRun {
        WorkflowRun(
            name: name,
            endTime: Date(),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: tool, toolVersion: "1.0",
                    command: [tool, "run"],
                    inputs: inputs, outputs: outputs,
                    exitCode: 0, wallTime: 1
                ),
            ]
        )
    }

    private func writeChain(createBAM: Bool) throws -> URL {
        let readsPath = "\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz"
        let bamPath = "\(foreign)/Analyses/minimap2-1/reads.sorted.bam"
        let vcfPath = "\(foreign)/Analyses/minimap2-1/ref.lungfishref/variants/vc-1.vcf.gz"
        try writeLegacy(
            run("lungfish import fastq", tool: "clumpify.sh",
                inputs: [record("/elsewhere/inputs/raw.fastq.gz", String(repeating: "9", count: 64), .input)],
                outputs: [record(readsPath, readsSHA, .output)]),
            to: "Imports/reads.lungfishfastq/.lungfish-provenance.json"
        )
        try writeLegacy(
            run("lungfish map", tool: "minimap2",
                inputs: [record(readsPath, readsSHA, .input)],
                outputs: [record(bamPath, bamSHA, .output)]),
            to: "Analyses/minimap2-1/.lungfish-provenance.json"
        )
        if createBAM {
            try Data("bam!".utf8).write(to: project.appendingPathComponent("Analyses/minimap2-1/reads.sorted.bam"))
        }
        return try writeLegacy(
            run("lungfish variants call", tool: "bcftools",
                inputs: [record(bamPath, bamSHA, .input)],
                outputs: [record(vcfPath, vcfSHA, .output)]),
            to: "Analyses/minimap2-1/ref.lungfishref/variants/vc-1.lungfish-provenance.json"
        )
    }

    private func resolve(_ sidecar: URL) throws -> [ProvenanceLineageResolver.ResolvedRun] {
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        return ProvenanceLineageResolver().resolve(envelope: envelope, sidecarURL: sidecar)
    }

    // MARK: - Tests

    func testChainStartsAtTheReadsWhenRecordedPathsAreForeign() throws {
        let sidecar = try writeChain(createBAM: false)
        let runs = try resolve(sidecar)
        XCTAssertEqual(runs.map(\.envelope.workflowName), ["lungfish import fastq", "lungfish map", "lungfish variants call"])
        XCTAssertEqual(
            runs.compactMap(\.sidecarURL?.lastPathComponent),
            [".lungfish-provenance.json", ".lungfish-provenance.json", "vc-1.lungfish-provenance.json"]
        )
    }

    func testChainFollowsARerootedPathBeforeFallingBackToChecksums() throws {
        let sidecar = try writeChain(createBAM: true)
        let runs = try resolve(sidecar)
        XCTAssertEqual(runs.map(\.envelope.workflowName), ["lungfish import fastq", "lungfish map", "lungfish variants call"])
        // The variant record's BAM input reads as the copy inside this project.
        let variants = try XCTUnwrap(runs.last)
        XCTAssertEqual(
            variants.envelope.steps.first?.inputs.first?.path,
            project.standardizedFileURL.appendingPathComponent("Analyses/minimap2-1/reads.sorted.bam").path
        )
    }

    func testCycleTerminatesAndUnreadableSidecarsAreSkipped() throws {
        let sidecar = try writeChain(createBAM: false)
        // A record whose output is the reads and whose input is the VCF closes a loop.
        try writeLegacy(
            run("lungfish loop", tool: "loop",
                inputs: [record("\(foreign)/x/vc-1.vcf.gz", vcfSHA, .input)],
                outputs: [record("\(foreign)/x/reads.fastq.gz", readsSHA, .output)]),
            to: "Analyses/loop.lungfish-provenance.json"
        )
        try Data("{ not json".utf8).write(to: project.appendingPathComponent("Analyses/broken.lungfish-provenance.json"))

        let runs = try resolve(sidecar)
        XCTAssertTrue(runs.map(\.envelope.workflowName).contains("lungfish map"), "\(runs.map(\.envelope.workflowName))")
        XCTAssertEqual(runs.last?.envelope.workflowName, "lungfish variants call")
        XCTAssertEqual(Set(runs.map(\.envelope.id)).count, runs.count, "each run appears once")
    }

    func testMissingUpstreamKeepsWhatIsKnown() throws {
        let sidecar = try writeLegacy(
            run("lungfish variants call", tool: "bcftools",
                inputs: [record("\(foreign)/Analyses/minimap2-1/reads.sorted.bam", bamSHA, .input)],
                outputs: [record("\(foreign)/x/vc-1.vcf.gz", vcfSHA, .output)]),
            to: "Analyses/minimap2-1/ref.lungfishref/variants/vc-1.lungfish-provenance.json"
        )
        let runs = try resolve(sidecar)
        XCTAssertEqual(runs.map(\.envelope.workflowName), ["lungfish variants call"])
    }

    /// A reference bundle with no record of its own gets one made from its manifest. That record is
    /// read, not written, so it holds no fact of the Mac reading it.
    func testASynthesizedReferenceRecordHoldsNoFactOfTheReadingMac() throws {
        let bundle = project.appendingPathComponent("Downloads/MN908947.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome/sequence.fa")
        try FileManager.default.createDirectory(at: genome.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(">MN908947\nACGT\n".utf8).write(to: genome)
        try BundleManifest(
            name: "MN908947",
            identifier: "org.ncbi.genbank.mn908947",
            source: SourceInfo(organism: "SARS-CoV-2", assembly: "MN908947", database: "NCBI"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 4, chromosomes: [])
        ).save(to: bundle)
        let sidecar = try writeLegacy(
            run("lungfish map", tool: "minimap2",
                inputs: [record(genome.path, String(repeating: "d", count: 64), .reference)],
                outputs: [record("\(foreign)/Analyses/minimap2-1/reads.sorted.bam", bamSHA, .output)]),
            to: "Analyses/minimap2-1/.lungfish-provenance.json"
        )

        let runs = try resolve(sidecar)
        let synthesized = try XCTUnwrap(runs.first { $0.sidecarURL == nil }?.envelope)
        XCTAssertEqual(synthesized.workflowName, "lungfish reference acquisition")
        XCTAssertNil(synthesized.workflowVersion, "workflowVersion")
        let identity = synthesized.runtimeIdentity
        XCTAssertNil(identity.appVersion, "appVersion")
        XCTAssertNil(identity.executablePath, "executablePath")
        XCTAssertNil(identity.operatingSystemVersion, "operatingSystemVersion")
        XCTAssertNil(identity.architecture, "architecture")
        XCTAssertNil(identity.user, "user")
        XCTAssertNil(identity.dependencySet, "dependencySet")
        XCTAssertNil(identity.managedToolLockSHA256, "managedToolLockSHA256")
    }

    // MARK: - One index per project, and a walk that stops

    /// Two walks of one project share its sidecar index, so each sidecar is read for its checksums
    /// once while it is unchanged, however many walks fall back to the index.
    func testSidecarIndexReadsEachSidecarOncePerProject() throws {
        let sidecar = try writeChain(createBAM: false)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let events = LineageEventLog()

        let first = ProvenanceLineageResolver(observer: { events.record($0) })
            .resolve(envelope: envelope, sidecarURL: sidecar)
        let second = ProvenanceLineageResolver(observer: { events.record($0) })
            .resolve(envelope: envelope, sidecarURL: sidecar)

        let chain = ["lungfish import fastq", "lungfish map", "lungfish variants call"]
        XCTAssertEqual(first.map(\.envelope.workflowName), chain)
        XCTAssertEqual(second.map(\.envelope.workflowName), chain)
        XCTAssertEqual(events.indexedSidecars.count, 3, "\(events.indexedSidecars.map(\.path))")
        XCTAssertEqual(Set(events.indexedSidecars.map(\.path)).count, 3)
        XCTAssertEqual(events.walkEnds, [false, false])
    }

    /// A caller that cancels while the index is being read stops the walk before its next sidecar
    /// read. The walk returns what it gathered and visits nothing upstream.
    func testCancelledWalkStopsReadingSidecars() throws {
        let sidecar = try writeChain(createBAM: false)
        for number in 1...3 {
            try writeLegacy(
                run("lungfish other \(number)", tool: "other", inputs: [],
                    outputs: [record("\(foreign)/Analyses/other-\(number).txt", String(repeating: "\(number)", count: 64), .output)]),
                to: "Analyses/other-\(number).lungfish-provenance.json"
            )
        }
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let events = LineageEventLog()

        let runs = ProvenanceLineageResolver(observer: { events.record($0) }).resolve(
            envelope: envelope,
            sidecarURL: sidecar,
            isCancelled: { !events.indexedSidecars.isEmpty }
        )

        XCTAssertEqual(events.indexedSidecars.count, 1, "\(events.indexedSidecars.map(\.path))")
        XCTAssertEqual(events.walkEnds, [true])
        XCTAssertEqual(runs.map(\.envelope.workflowName), ["lungfish variants call"])
    }

    /// The watcher's report of a changed sidecar, or of the folder holding it, drops that entry,
    /// and a sidecar rewritten in place reads as changed by its size and date alone. Either way
    /// the next walk reads that sidecar again and no other.
    func testChangedSidecarIsReadAgainByTheNextWalk() throws {
        let sidecar = try writeChain(createBAM: false)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let index = ProvenanceSidecarIndex()
        let events = LineageEventLog()
        let resolver = ProvenanceLineageResolver(sidecarIndex: index, observer: { events.record($0) })
        let chain = ["lungfish import fastq", "lungfish map", "lungfish variants call"]
        let mapSidecar = project.appendingPathComponent("Analyses/minimap2-1/.lungfish-provenance.json").standardizedFileURL
        XCTAssertEqual(resolver.resolve(envelope: envelope, sidecarURL: sidecar).map(\.envelope.workflowName), chain)
        XCTAssertEqual(events.indexedSidecars.count, 3)

        let changesBefore = index.changeCount
        index.invalidate([mapSidecar])
        XCTAssertEqual(index.changeCount, changesBefore + 1)
        XCTAssertEqual(resolver.resolve(envelope: envelope, sidecarURL: sidecar).map(\.envelope.workflowName), chain)
        XCTAssertEqual(events.indexedSidecars.dropFirst(3).map(\.path), [mapSidecar.path])

        // A volume that reports folders only names the folder that changed.
        index.invalidate([mapSidecar.deletingLastPathComponent()])
        XCTAssertEqual(resolver.resolve(envelope: envelope, sidecarURL: sidecar).map(\.envelope.workflowName), chain)
        XCTAssertEqual(events.indexedSidecars.dropFirst(4).map(\.path), [mapSidecar.path])

        let importSidecar = try writeLegacy(
            run("lungfish import fastq again", tool: "clumpify.sh",
                inputs: [record("/elsewhere/inputs/raw.fastq.gz", String(repeating: "9", count: 64), .input)],
                outputs: [record("\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz", readsSHA, .output)]),
            to: "Imports/reads.lungfishfastq/.lungfish-provenance.json"
        )
        let runs = resolver.resolve(envelope: envelope, sidecarURL: sidecar)
        XCTAssertEqual(runs.first?.envelope.workflowName, "lungfish import fastq again")
        XCTAssertEqual(events.indexedSidecars.dropFirst(5).map(\.path), [importSidecar.standardizedFileURL.path])
    }

    /// A sidecar that cannot be read is not a sidecar with no record. The error may be brief, such
    /// as a volume that drops for a moment, and the size and date it leaves behind never change to
    /// cure it, so the next walk reads that sidecar again and finds the run the first walk missed.
    func testUnreadableSidecarIsReadAgainByTheNextWalk() throws {
        let sidecar = try writeChain(createBAM: false)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let events = LineageEventLog()
        let resolver = ProvenanceLineageResolver(sidecarIndex: ProvenanceSidecarIndex(), observer: { events.record($0) })
        let importSidecar = project.appendingPathComponent("Imports/reads.lungfishfastq/.lungfish-provenance.json")
        let files = FileManager.default
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: importSidecar.path)
        defer { try? files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: importSidecar.path) }
        try XCTSkipIf(files.isReadableFile(atPath: importSidecar.path), "this user reads a file whose mode is 000")

        let withoutImport = resolver.resolve(envelope: envelope, sidecarURL: sidecar)
        XCTAssertEqual(withoutImport.map(\.envelope.workflowName), ["lungfish map", "lungfish variants call"])

        // The mode change keeps the size and the modification date the first walk saw.
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: importSidecar.path)
        let whole = resolver.resolve(envelope: envelope, sidecarURL: sidecar)
        XCTAssertEqual(
            whole.map(\.envelope.workflowName),
            ["lungfish import fastq", "lungfish map", "lungfish variants call"]
        )
        XCTAssertEqual(
            events.indexedSidecars.filter { $0.path == importSidecar.standardizedFileURL.path }.count,
            2,
            "\(events.indexedSidecars.map(\.path))"
        )
    }
}

/// The events of the walks a test runs, in order. The resolver reports them from the walking thread.
private final class LineageEventLog: Sendable {
    private let events = Mutex<[ProvenanceLineageResolver.Event]>([])

    func record(_ event: ProvenanceLineageResolver.Event) {
        events.withLock { $0.append(event) }
    }

    var indexedSidecars: [URL] {
        events.withLock { events in
            events.compactMap { event in
                if case .indexedSidecar(let url) = event { return url }
                return nil
            }
        }
    }

    var walkEnds: [Bool] {
        events.withLock { events in
            events.compactMap { event in
                if case .walkEnded(let cancelled) = event { return cancelled }
                return nil
            }
        }
    }
}
