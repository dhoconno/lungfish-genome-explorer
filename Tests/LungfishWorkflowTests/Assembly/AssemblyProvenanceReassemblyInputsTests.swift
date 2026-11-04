// AssemblyProvenanceReassemblyInputsTests.swift - The inputs an assembly record says its user chose
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// `AssemblyProvenance.reassemblyInputPaths` is what Reassemble hands the
/// assembly wizard: the inputs the user chose for the run, never the lineage
/// the record also keeps (R3, lane 1q-2). A record names them in
/// `requested_inputs`. An older record is read from its input records, its
/// steps and the assembler's command line.
final class AssemblyProvenanceReassemblyInputsTests: XCTestCase {

    private let subsetBundle = "/project/Imports/root-subset.lungfishfastq"
    private let rootFASTQ = "/project/Imports/root.lungfishfastq/root.fastq"
    private let materializedCopy = "/project/Assemblies/subset/.lungfish-assembly-inputs/root-subset.fastq"

    // MARK: - requested_inputs

    func testTheBuilderRecordsTheRequestedInputsAndReassemblyReadsThem() throws {
        let built = ProvenanceBuilder.build(
            request: request(inputs: [URL(fileURLWithPath: materializedCopy)]),
            result: result(commandLine: "spades.py -s \(materializedCopy) -o /out"),
            inputRecords: virtualSubsetRecords,
            requestedInputURLs: [URL(fileURLWithPath: "/project/Imports/./root-subset.lungfishfastq/")],
            steps: [virtualSubsetMaterializationStep]
        )
        XCTAssertEqual(built.requestedInputs, [subsetBundle], "standardized absolute paths")

        let decoded = try roundTrip(built)
        XCTAssertEqual(decoded.requestedInputs, [subsetBundle])
        XCTAssertEqual(decoded.reassemblyInputPaths, [subsetBundle])
        XCTAssertEqual(decoded.inputs.map(\.originalPath), [subsetBundle, rootFASTQ, materializedCopy], "the lineage is still recorded")
    }

    func testARecordWithoutRequestedInputsEncodesNoKey() throws {
        let legacy = provenance(inputs: [record(rootFASTQ)], requested: nil)
        let json = try String(decoding: encoded(legacy), as: UTF8.self)
        XCTAssertFalse(json.contains("requested_inputs"), json)
        XCTAssertNil(try roundTrip(legacy).requestedInputs)

        let current = provenance(inputs: [record(rootFASTQ)], requested: [subsetBundle])
        XCTAssertTrue(try String(decoding: encoded(current), as: UTF8.self).contains("\"requested_inputs\""))
    }

    func testRequestedInputsWinOverTheRecordsInTheirOrder() {
        let loose = ["/project/Reads/loose_b.fastq", "/project/Reads/loose_a.fastq"]
        let recorded = provenance(
            inputs: loose.reversed().map { record($0) },
            requested: loose
        )
        XCTAssertEqual(recorded.reassemblyInputPaths, loose)
    }

    // MARK: - Records written before requested_inputs

    /// A virtual bundle's record lists the bundle, the root FASTQ it was cut
    /// from and the copy the run materialized. Only the bundle is an input.
    func testAnOlderVirtualBundleRecordGivesTheBundleAlone() {
        let older = provenance(
            inputs: virtualSubsetRecords,
            steps: [virtualSubsetMaterializationStep],
            commandLine: "spades.py --isolate -s \(materializedCopy) -o /project/Assemblies/subset"
        )
        XCTAssertEqual(older.reassemblyInputPaths, [subsetBundle])
    }

    /// When the user chose the virtual bundle and its root bundle, the root
    /// FASTQ is both lineage and an input the assembler read directly. The
    /// command line tells them apart.
    func testARootFASTQTheAssemblerAlsoReadDirectlyStaysAnInput() {
        let older = provenance(
            inputs: virtualSubsetRecords,
            steps: [virtualSubsetMaterializationStep],
            commandLine: "spades.py --isolate -s \(materializedCopy) -s \(rootFASTQ) -o /project/Assemblies/subset"
        )
        XCTAssertEqual(older.reassemblyInputPaths, [subsetBundle, rootFASTQ])

        let skesa = provenance(
            inputs: virtualSubsetRecords,
            steps: [virtualSubsetMaterializationStep],
            commandLine: "skesa --reads \(materializedCopy),\(rootFASTQ) --contigs_out /out/contigs.fasta"
        )
        XCTAssertEqual(skesa.reassemblyInputPaths, [subsetBundle, rootFASTQ], "SKESA and MEGAHIT join files with commas")
    }

    /// A copy this run wrote is never an input, but a copy an earlier run
    /// wrote that this run was handed is one.
    func testOnlyThisRunsOwnCopiesAreDropped() {
        let earlierCopy = "/project/Assemblies/first/.lungfish-assembly-inputs/root-subset.fastq"
        let older = provenance(
            inputs: virtualSubsetRecords + [record(earlierCopy)],
            steps: [virtualSubsetMaterializationStep],
            commandLine: "spades.py -s \(materializedCopy) -s \(earlierCopy) -o /out"
        )
        XCTAssertEqual(older.reassemblyInputPaths, [subsetBundle, earlierCopy])
    }

    /// A joined multi-file bundle is recorded as the bundle, with a `cat` step
    /// from its files.
    func testAJoinedBundleRecordGivesTheBundle() {
        let bundle = "/project/Imports/multi.lungfishfastq"
        let chunks = ["\(bundle)/chunks/run_0.fastq", "\(bundle)/chunks/run_1.fastq"]
        let joined = "/project/Assemblies/multi/.lungfish-assembly-inputs/concatenated-1.fastq"
        let older = provenance(
            inputs: [record(bundle)],
            steps: [ProvenanceStep(
                toolName: "cat",
                inputs: chunks.map { ProvenanceFileDescriptor(path: $0, originPath: bundle) },
                outputs: [ProvenanceFileDescriptor(path: joined, originPath: bundle)]
            )],
            commandLine: "spades.py -s \(joined) -o /out"
        )
        XCTAssertEqual(older.reassemblyInputPaths, [bundle])
    }

    /// Records written before lineage was recorded hold the inputs as given.
    func testRecordsWithoutStepsAreTheInputs() {
        let paired = ["/project/Imports/paired.lungfishfastq/sample_R1.fastq", "/project/Imports/paired.lungfishfastq/sample_R2.fastq"]
        XCTAssertEqual(provenance(inputs: paired.map { record($0) }).reassemblyInputPaths, paired)

        let withoutPath = InputFileRecord(filename: "reads.fastq", sha256: nil, sizeBytes: 0)
        XCTAssertEqual(
            provenance(inputs: [withoutPath, record(paired[0]), record(paired[0])]).reassemblyInputPaths,
            ["reads.fastq", paired[0]],
            "a record without a path gives its file name, and each input appears once"
        )
    }

    // MARK: - Which copy of the reads Reassemble takes (REASSEMBLE-COPY-INPUT)

    /// A copied project reassembles from its own Imports while the original still exists, never from the
    /// original's path.
    func testCopyUsesItsOwnImportsWhileTheOriginalExists() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = root.appendingPathComponent("Mito.lungfish/Imports/reads.fastq")
        let own = root.appendingPathComponent("Mito.lungfish copy/Imports/reads.fastq")
        try write(reads("a"), to: recorded)
        try write(reads("a"), to: own)
        let record = try checksummed(recorded)

        let inputs = await provenance(inputs: [record], requested: [recorded.path])
            .reassemblyInputFiles(projectURL: root.appendingPathComponent("Mito.lungfish copy"))
        XCTAssertEqual(inputs.found.map(\.path), [own.path])
        XCTAssertTrue(inputs.missing.isEmpty && inputs.changed.isEmpty && inputs.unverified.isEmpty, "\(inputs)")
    }

    /// The original is gone and the copy's Imports holds the reads, so nothing is missing.
    func testCopyFindsItsOwnImportsWithTheOriginalGone() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = root.appendingPathComponent("Mito.lungfish/Imports/reads.fastq")
        let own = root.appendingPathComponent("Mito.lungfish copy/Imports/reads.fastq")
        try write(reads("a"), to: recorded)
        try write(reads("a"), to: own)
        let record = try checksummed(recorded)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Mito.lungfish"))

        let inputs = await provenance(inputs: [record], requested: [recorded.path])
            .reassemblyInputFiles(projectURL: root.appendingPathComponent("Mito.lungfish copy"))
        XCTAssertTrue(inputs.missing.isEmpty, "\(inputs.missing)")
        XCTAssertEqual(inputs.found.map(\.path), [own.path])
    }

    /// A project renamed since the run holds the bundle the run named under its new name.
    func testMovedProjectFindsItsImports() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBundle = root.appendingPathComponent("Old.lungfish/Imports/sample.lungfishfastq")
        let newBundle = root.appendingPathComponent("New.lungfish/Imports/sample.lungfishfastq")
        try write(reads("a"), to: newBundle.appendingPathComponent("sample.fastq"))
        let record = try checksummed(
            newBundle.appendingPathComponent("sample.fastq"),
            as: oldBundle.appendingPathComponent("sample.fastq").path
        )

        let inputs = await provenance(inputs: [record], requested: [oldBundle.path])
            .reassemblyInputFiles(projectURL: root.appendingPathComponent("New.lungfish"))
        XCTAssertTrue(inputs.missing.isEmpty, "\(inputs.missing)")
        XCTAssertEqual(inputs.found.map(\.path), [newBundle.path])
    }

    /// Reads replaced at the recorded path since the run are not the original reads.
    func testReplacedReadsAtTheRecordedPathAreChanged() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("Sequencer/run1/reads.fastq")
        try write(reads("a"), to: external)
        let record = try checksummed(external)
        try write(reads("b"), to: external)

        let inputs = await provenance(inputs: [record], requested: [external.path])
            .reassemblyInputFiles(projectURL: root.appendingPathComponent("Mito.lungfish"))
        XCTAssertEqual(inputs.changed, [external.path])
        XCTAssertTrue(inputs.found.isEmpty, "\(inputs.found)")
        XCTAssertTrue(inputs.missing.isEmpty && inputs.unverified.isEmpty, "\(inputs)")
    }

    /// A file of the same name in the project's FASTQ folder, with other bytes, is not the recorded read.
    func testSameNameOtherBytesInFASTQIsNotUsed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("Sequencer/run1/reads.fastq")
        let lookalike = root.appendingPathComponent("Mito.lungfish/FASTQ/reads.fastq")
        try write(reads("a"), to: gone)
        let record = try checksummed(gone)
        try FileManager.default.removeItem(at: gone)
        try write(reads("b"), to: lookalike)

        let inputs = await provenance(inputs: [record], requested: [gone.path])
            .reassemblyInputFiles(projectURL: root.appendingPathComponent("Mito.lungfish"))
        XCTAssertFalse(inputs.found.contains { $0.path == lookalike.path }, "\(inputs.found)")
        XCTAssertEqual(inputs.changed, [gone.path])
    }

    /// The record is on the bundle's primary file and the request is on the bundle, so the file is what is compared.
    func testBundleInputComparesItsPrimaryFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Sequencer/sample.lungfishfastq")
        let primary = bundle.appendingPathComponent("sample.fastq")
        try write(reads("a"), to: primary)
        let run = provenance(inputs: [try checksummed(primary)], requested: [bundle.path])

        let unchanged = await run.reassemblyInputFiles(projectURL: nil)
        XCTAssertEqual(unchanged.found.map(\.path), [bundle.path])
        XCTAssertTrue(unchanged.changed.isEmpty && unchanged.unverified.isEmpty, "\(unchanged)")

        try write(reads("b"), to: primary)
        let replaced = await run.reassemblyInputFiles(projectURL: nil)
        XCTAssertEqual(replaced.changed, [bundle.path])
        XCTAssertTrue(replaced.found.isEmpty, "\(replaced.found)")
    }

    /// An older record may hold no checksum, so the reads cannot be checked and the person is asked.
    func testRecordWithoutChecksumIsUnverified() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sequencer/run1/reads.fastq")
        try write(reads("a"), to: file)
        let checked = try checksummed(file)
        let record = InputFileRecord(
            filename: checked.filename, originalPath: checked.originalPath, sha256: nil, sizeBytes: checked.sizeBytes
        )

        let inputs = await provenance(inputs: [record], requested: [file.path]).reassemblyInputFiles(projectURL: nil)
        XCTAssertEqual(inputs.unverified, [file.path])
        XCTAssertEqual(inputs.found.map(\.path), [file.path], "the person may go on once asked")
        XCTAssertTrue(inputs.missing.isEmpty && inputs.changed.isEmpty, "\(inputs)")
    }

    /// Guard. Reads that are still the recorded bytes resolve.
    func testUnchangedExternalReadsResolve() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sequencer/run1/reads.fastq")
        try write(reads("a"), to: file)
        let record = try checksummed(file)

        let inputs = await provenance(inputs: [record], requested: [file.path])
            .reassemblyInputFiles(projectURL: root.appendingPathComponent("Mito.lungfish"))
        XCTAssertEqual(inputs.found.map(\.path), [file.path])
        XCTAssertTrue(inputs.missing.isEmpty && inputs.changed.isEmpty && inputs.unverified.isEmpty, "\(inputs)")
    }

    // MARK: - Files on disk

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reassembly-inputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// FASTQ text of one fixed size, so `reads("a")` and `reads("b")` differ in their bytes alone.
    private func reads(_ tag: String) -> String {
        "@read_\(tag)\nACGTACGTAC\n+\nIIIIIIIIII\n"
    }

    /// The record a run keeps for `file`, with its size and checksum, under `path` (the file's own path when the
    /// run read it where it stands).
    private func checksummed(_ file: URL, as path: String? = nil) throws -> InputFileRecord {
        InputFileRecord(
            filename: file.lastPathComponent,
            originalPath: path ?? file.path,
            sha256: try ProvenanceFileHasher.sha256(of: file),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: file))
        )
    }

    // MARK: - Helpers

    private var virtualSubsetRecords: [InputFileRecord] {
        [record(subsetBundle), record(rootFASTQ), record(materializedCopy)]
    }

    /// The materialization step the in-process run records for a virtual
    /// bundle: the bundle and its root FASTQ in, the copy out, the root FASTQ
    /// and the copy naming the bundle as their origin.
    private var virtualSubsetMaterializationStep: ProvenanceStep {
        ProvenanceStep(
            toolName: "lungfish-cli fastq materialize",
            inputs: [
                ProvenanceFileDescriptor(path: subsetBundle),
                ProvenanceFileDescriptor(path: rootFASTQ, originPath: subsetBundle),
            ],
            outputs: [ProvenanceFileDescriptor(path: materializedCopy, originPath: subsetBundle)]
        )
    }

    private func record(_ path: String) -> InputFileRecord {
        InputFileRecord(
            filename: URL(fileURLWithPath: path).lastPathComponent,
            originalPath: path,
            sha256: String(repeating: "0", count: 64),
            sizeBytes: 10
        )
    }

    private func provenance(
        inputs: [InputFileRecord],
        requested: [String]? = nil,
        steps: [ProvenanceStep] = [],
        commandLine: String = "spades.py -o /out"
    ) -> AssemblyProvenance {
        AssemblyProvenance(
            assembler: "SPAdes",
            assemblerVersion: "4.2.0",
            executionBackend: .micromamba,
            hostOS: "macOS 26.0.0",
            hostArchitecture: "arm64",
            lungfishVersion: "test",
            assemblyDate: Date(timeIntervalSince1970: 1_000),
            wallTimeSeconds: 1,
            commandLine: commandLine,
            parameters: AssemblyParameters(
                mode: "isolate",
                kmerSizes: "managed",
                memoryGB: 0,
                threads: 1,
                skipErrorCorrection: false,
                minContigLength: 0
            ),
            inputs: inputs,
            requestedInputs: requested,
            steps: steps,
            statistics: nil
        )
    }

    private func request(inputs: [URL]) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: inputs,
            projectName: "subset",
            outputDirectory: URL(fileURLWithPath: "/out"),
            threads: 1
        )
    }

    private func result(commandLine: String) -> AssemblyResult {
        AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: URL(fileURLWithPath: "/out/contigs.fasta"),
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "4.2.0",
            commandLine: commandLine,
            outputDirectory: URL(fileURLWithPath: "/out"),
            statistics: AssemblyStatisticsCalculator.compute(fromFASTAString: ">contig1\nACGTACGTAC\n"),
            wallTimeSeconds: 1
        )
    }

    private func encoded(_ provenance: AssemblyProvenance) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try provenance.save(to: directory)
        return try Data(contentsOf: directory.appendingPathComponent(AssemblyProvenance.filename))
    }

    private func roundTrip(_ provenance: AssemblyProvenance) throws -> AssemblyProvenance {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try provenance.save(to: directory)
        return try AssemblyProvenance.load(from: directory)
    }
}
