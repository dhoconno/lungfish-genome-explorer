// ReferenceImportHelperRoutePinTests.swift - Pins what the reference import helper route writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Pins the bundle, manifest and root record that `ReferenceBundleImportService` writes when it is
/// called as `ReferenceImportHelper` calls it (`ReferenceImportHelper.swift:165-171`), which is side A
/// of the `import fasta` parity class (ruling A48 F2, pin P1, byte-equal items 1, 2 and 4).
final class ReferenceImportHelperRoutePinTests: XCTestCase {
    private var root: URL!
    private var references: URL!

    override func setUp() async throws {
        if let missing = await NativeBundleBuilder().checkRequiredTools() {
            throw XCTSkip("Native reference bundle tools are unavailable: \(missing.description)")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceImportHelperRoutePinTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        references = root.appendingPathComponent("Project.lungfish/Reference Sequences", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFASTAWithNoName() async throws {
        let source = try writeSource("source.fa", Self.twoRecordFASTA)
        let result = try await importLikeTheHelper(source)

        try assertRoute(
            result, source: source, folder: "source.lungfishref", name: "source", organism: "source",
            files: Self.fastaFiles, inputs: [source]
        )
        let fai = try String(
            contentsOf: result.bundleURL.appendingPathComponent("genome/sequence.fa.gz.fai"), encoding: .utf8
        )
        XCTAssertEqual(fai, "chr1\t10\t19\t10\t11\nchr2\t4\t36\t4\t5\n")
    }

    func testCompressedFASTAWithAName() async throws {
        let plain = try writeSource("plain.fa", Self.twoRecordFASTA)
        let source = root.appendingPathComponent("Named.fa.gz")
        try gzip(plain, to: source)
        let result = try await importLikeTheHelper(source, name: "Named Ref")

        try assertRoute(
            result, source: source, folder: "Named_Ref.lungfishref", name: "Named Ref", organism: "Named Ref",
            files: Self.fastaFiles, inputs: [source]
        )
    }

    func testGenBankWithFeaturesAndARecordStore() async throws {
        let source = try writeSource("MN908947.3.gb", Self.annotatedGenBank)
        let result = try await importLikeTheHelper(source)

        try assertRoute(
            result, source: source, folder: "MN908947.3.lungfishref", name: "MN908947.3",
            organism: "Minimal SARS-CoV-2 annotation fixture.", files: Self.genBankFiles, inputs: [source],
            annotationIDs: ["imported_annotations"], referenceSource: source
        )
        let manifest = try BundleManifest.load(from: result.bundleURL)
        XCTAssertEqual(manifest.annotations.map(\.id), ["imported_annotations"])
        XCTAssertEqual(manifest.annotations.first?.featureCount, 3)
        XCTAssertEqual(manifest.recordStore?.recordCount, 1)
    }

    func testASecondImportOfOneFileTakesTheNextName() async throws {
        let source = try writeSource("source.fa", Self.twoRecordFASTA)
        _ = try await importLikeTheHelper(source)
        let second = try await importLikeTheHelper(source)

        try assertRoute(
            second, source: source, folder: "source_2.lungfishref", name: "source 2", organism: "source 2",
            files: Self.fastaFiles, inputs: [source]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: references.path).sorted(),
            ["source.lungfishref", "source_2.lungfishref"]
        )
    }

    func testTwoProvenanceInputsKeepTheirOrder() async throws {
        let source = try writeSource("MN908947.3.gb", Self.annotatedGenBank)
        let zeta = try writeSource("zeta-origin.fasta", ">z\nACGT\n")
        let alpha = try writeSource("alpha-origin.fasta", ">a\nTTGG\n")
        let result = try await importLikeTheHelper(source, provenanceInputs: [zeta, alpha])

        try assertRoute(
            result, source: source, folder: "MN908947.3.lungfishref", name: "MN908947.3",
            organism: "Minimal SARS-CoV-2 annotation fixture.", files: Self.genBankFiles, inputs: [zeta, alpha],
            annotationIDs: ["imported_annotations"], referenceSource: zeta
        )
        // The native steps name the given inputs in their order wherever they read a transient
        // input, and the bundle's own files where they read those.
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        let outside = envelope.steps.dropFirst().flatMap(\.inputs).map(\.path)
            .filter { !$0.hasPrefix(result.bundleURL.path + "/") }
        XCTAssertFalse(outside.isEmpty)
        XCTAssertEqual(Self.firstOccurrences(outside), [zeta.path, alpha.path])
    }

    // MARK: - The helper's call

    private func importLikeTheHelper(
        _ source: URL,
        name: String? = nil,
        provenanceInputs: [URL]? = nil
    ) async throws -> ReferenceBundleImportResult {
        try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: source,
            outputDirectory: references,
            preferredBundleName: name,
            provenanceInputFiles: provenanceInputs,
            progressHandler: nil
        )
    }

    // MARK: - The facts

    private func assertRoute(
        _ result: ReferenceBundleImportResult,
        source: URL,
        folder: String,
        name: String,
        organism: String,
        files: [String],
        inputs: [URL],
        annotationIDs: [String] = [],
        referenceSource: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundle = result.bundleURL
        XCTAssertEqual(bundle.deletingLastPathComponent().standardizedFileURL.path, references.path, file: file, line: line)
        XCTAssertEqual(bundle.lastPathComponent, folder, file: file, line: line)
        XCTAssertEqual(result.bundleName, name, file: file, line: line)
        XCTAssertEqual(try Self.relativeFiles(in: bundle), files, file: file, line: line)

        let manifest = try BundleManifest.load(from: bundle)
        XCTAssertEqual(manifest.name, name, file: file, line: line)
        XCTAssertTrue(manifest.identifier.hasPrefix("org.lungfish.import."), manifest.identifier, file: file, line: line)
        XCTAssertEqual(manifest.identifier.count, "org.lungfish.import.".count + 36, file: file, line: line)
        XCTAssertEqual(manifest.source.organism, organism, file: file, line: line)
        XCTAssertEqual(manifest.source.assembly, name, file: file, line: line)
        XCTAssertEqual(manifest.source.database, "Imported File", file: file, line: line)
        // The manifest stores the source under its portable root, so its tail is what this host can pin.
        let sourceTail = root.lastPathComponent + "/" + source.lastPathComponent
        XCTAssertTrue(
            manifest.source.sourceURL?.absoluteString.hasSuffix(sourceTail) == true,
            "\(String(describing: manifest.source.sourceURL))", file: file, line: line
        )
        XCTAssertEqual(manifest.source.notes, "Imported from \(source.lastPathComponent)", file: file, line: line)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle), file: file, line: line)
        var explicit = envelope.options.explicit
        XCTAssertNotNil(explicit.removeValue(forKey: "identifier"), file: file, line: line)
        var expected: [String: ParameterValue] = [
            "name": .string(name),
            "output_directory": .file(references),
            "bundle_path": .file(URL(fileURLWithPath: bundle.path, isDirectory: true)),
            "compress_fasta": .boolean(true),
            "annotation_count": .integer(annotationIDs.count),
            "variant_count": .integer(0),
            "signal_count": .integer(0),
            "source_url": .file(source),
            "input_files": .array(inputs.map { .file($0) }),
        ]
        if !annotationIDs.isEmpty { expected["annotation_ids"] = .array(annotationIDs.map(ParameterValue.string)) }
        if let referenceSource { expected["reference_source"] = .file(referenceSource) }
        XCTAssertEqual(explicit, expected, file: file, line: line)
        let prefix = bundle.path + "/"
        XCTAssertEqual(envelope.steps.first?.inputs.map(\.path), inputs.map(\.path), file: file, line: line)
        XCTAssertEqual(
            envelope.files.filter { $0.role == .input && !$0.path.hasPrefix(prefix) }.map(\.path),
            inputs.map(\.path), file: file, line: line
        )

        let outputs = envelope.outputs.filter { $0.path.hasPrefix(prefix) }
        XCTAssertEqual(
            Set(outputs.map { String($0.path.dropFirst(prefix.count)) }).sorted(),
            files.filter { !Self.isRecordFile($0) },
            file: file, line: line
        )
        for output in outputs {
            XCTAssertEqual(
                output.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: output.path)),
                output.path, file: file, line: line
            )
        }
    }

    private static func firstOccurrences(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private static func isRecordFile(_ path: String) -> Bool {
        path == ".lungfish-provenance.json" || path.hasPrefix(ProvenanceWriter.bundleProvenanceDirectoryName + "/")
    }

    private static func relativeFiles(in bundle: URL) throws -> [String] {
        let prefix = bundle.path + "/"
        let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files.append(String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count)))
        }
        return files.sorted()
    }

    private func writeSource(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
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

    // MARK: - Fixtures

    static let fastaFiles = [
        ".lungfish-provenance.json",
        "genome/sequence.fa.gz",
        "genome/sequence.fa.gz.fai",
        "genome/sequence.fa.gz.gzi",
        "manifest.json",
        "provenance/bundle.lungfish-provenance.json",
        "provenance/genome/sequence.fa.gz.fai.lungfish-provenance.json",
        "provenance/genome/sequence.fa.gz.gzi.lungfish-provenance.json",
        "provenance/genome/sequence.fa.gz.lungfish-provenance.json",
        "provenance/manifest.json.lungfish-provenance.json",
    ]

    static let genBankFiles = [
        ".lungfish-provenance.json",
        "annotations/imported_annotations.db",
        "annotations/imported_annotations.gff3",
        "genome/sequence.fa.gz",
        "genome/sequence.fa.gz.fai",
        "genome/sequence.fa.gz.gzi",
        "manifest.json",
        "metadata/genbank_records.sqlite",
        "provenance/annotations/imported_annotations.db.lungfish-provenance.json",
        "provenance/annotations/imported_annotations.gff3.lungfish-provenance.json",
        "provenance/bundle.lungfish-provenance.json",
        "provenance/genome/sequence.fa.gz.fai.lungfish-provenance.json",
        "provenance/genome/sequence.fa.gz.gzi.lungfish-provenance.json",
        "provenance/genome/sequence.fa.gz.lungfish-provenance.json",
        "provenance/manifest.json.lungfish-provenance.json",
        "provenance/metadata/genbank_records.sqlite.lungfish-provenance.json",
    ]

    static let twoRecordFASTA = ">chr1 first record\nACGTACGTAC\n>chr2\nGGCC\n"

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
