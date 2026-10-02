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
