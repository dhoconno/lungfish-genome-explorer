// ImportFastaIdentityPinTests.swift - Pins the identity and text summary of import fasta
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Pins P4 and P5 of ruling A48 F2. P4 is the manifest identity a second import of one file records,
/// and P5 the text a person reads, which the switch onto `ReferenceBundleImportService` keeps.
final class ImportFastaIdentityPinTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUp() async throws {
        if let missing = await NativeBundleBuilder().checkRequiredTools() {
            throw XCTSkip("Native reference bundle tools are unavailable: \(missing.description)")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportFastaIdentityPinTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testIdentifierPrefixAndCollisionOrganism() async throws {
        let source = root.appendingPathComponent("X.fa")
        try ">chr1\nACGT\n".write(to: source, atomically: true, encoding: .utf8)
        try await ImportCommand.FASTASubcommand.parse([source.path, "--output-dir", project.path, "--quiet"]).run()
        try await ImportCommand.FASTASubcommand.parse([source.path, "--output-dir", project.path, "--quiet"]).run()

        let references = project.appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
        let first = try BundleManifest.load(from: references.appendingPathComponent("X.lungfishref"))
        let second = try BundleManifest.load(from: references.appendingPathComponent("X_2.lungfishref"))
        // Since the leaf builds through ReferenceBundleImportService (ruling A48 F2, P4) the prefix is
        // the service's and the organism of a FASTA is the uniqued name. It was
        // `org.lungfish.cli.import.` and `X` before.
        for manifest in [first, second] {
            XCTAssertTrue(manifest.identifier.hasPrefix("org.lungfish.import."), manifest.identifier)
        }
        XCTAssertEqual(second.name, "X 2")
        XCTAssertEqual(second.source.assembly, "X 2")
        XCTAssertEqual(second.source.organism, "X 2")
    }

    func testFASTATextSummary() async throws {
        let source = root.appendingPathComponent("source.fa")
        let records = (1...12).map { ">s\($0) record \($0)\nACGT\n" }.joined()
        try records.write(to: source, atomically: true, encoding: .utf8)

        let text = try await captureStandardOutput {
            try await ImportCommand.FASTASubcommand.parse([source.path, "--output-dir", self.project.path]).run()
        }
        XCTAssertEqual(text, Self.summary(
            name: "source", count: 12, length: "48 bp", bundle: "source.lungfishref",
            names: "s1, s2, s3, s4, s5, s6, s7, s8, s9, s10 (+2 more)"
        ))
    }

    func testCompressedFASTATextSummary() async throws {
        let plain = root.appendingPathComponent("plain.fa")
        try ">chr1 first\nACGTACGTAC\n>chr2\nGGCC\n".write(to: plain, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("plain.fa.gz")
        try gzip(plain, to: source)

        let text = try await captureStandardOutput {
            try await ImportCommand.FASTASubcommand.parse([
                source.path, "--output-dir", self.project.path, "--name", "Gz Ref",
            ]).run()
        }
        XCTAssertEqual(text, Self.summary(
            name: "Gz Ref", count: 2, length: "14 bp", bundle: "Gz_Ref.lungfishref", names: "chr1, chr2"
        ))
    }

    func testGenBankTextSummary() async throws {
        let source = root.appendingPathComponent("MN908947.3.gb")
        try ReferenceImportHelperFixtures.annotatedGenBank.write(to: source, atomically: true, encoding: .utf8)

        let text = try await captureStandardOutput {
            try await ImportCommand.FASTASubcommand.parse([source.path, "--output-dir", self.project.path]).run()
        }
        XCTAssertEqual(text, Self.summary(
            name: "MN908947.3", count: 1, length: "120 bp", bundle: "MN908947.3.lungfishref", names: "MN908947"
        ))
    }

    private static func summary(name: String, count: Int, length: String, bundle: String, names: String) -> String {
        """
        Reference Import

        ℹ Preparing reference input...
        ℹ Building .lungfishref bundle...

        Summary

        Name        : \(name)
        Sequences   : \(count)
        Total length: \(length)
        Bundle      : \(bundle)

          Sequences: \(names)

        ✓ Reference import complete: \(name) (\(count) sequences, \(length))

        """
    }

    private func gzip(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try data.write(to: destination, options: .atomic)
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

/// The annotated GenBank record the reference import pins read.
enum ReferenceImportHelperFixtures {
    static let annotatedGenBank = """
    LOCUS       MN908947                 120 bp    RNA     linear   VRL 01-JAN-2024
    DEFINITION  Minimal SARS-CoV-2 annotation fixture.
    ACCESSION   MN908947
    VERSION     MN908947.3
    FEATURES             Location/Qualifiers
         source          1..120
                         /organism="Severe acute respiratory syndrome coronavirus 2"
                         /mol_type="genomic RNA"
         gene            10..90
                         /gene="S"
                         /locus_tag="fixture-gene-S"
         CDS             20..80
                         /gene="S"
                         /product="spike glycoprotein"
                         /protein_id="fixture-protein-S"
         mat_peptide     35..55
                         /gene="S"
                         /product="mature spike peptide"
    ORIGIN
            1 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc
           61 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc
    //
    """
}
