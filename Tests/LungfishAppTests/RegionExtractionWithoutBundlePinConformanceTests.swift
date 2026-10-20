// RegionExtractionWithoutBundlePinConformanceTests.swift - Pins the region bundle a viewer with no reference bundle builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO
import LungfishTestSupport

/// Phase 2.12 lane 12.12 M1 (A48-GAP, QA 1), reduced by Phase 2.13 lane 13.03 (DEL-REST). A viewer whose
/// document has no reference bundle builds its region bundle with
/// `lungfish-cli extract sequence <staged FASTA> <region> -o <name>.lungfishref`. The in-process route that
/// built it before 2.12, `createExtractionBundleInProcess`, left with its hidden key, and so did the
/// snapshots that pinned what it built. The class pins the bundle the leaf builds from a FASTA document (files,
/// manifest, name and record) and the record of a GenBank document's region, which says that its annotations
/// were not carried (R-B3). Each case extracts the way the viewer does, with `SequenceExtractor` over the
/// document's sequence, clamped to its length. Each runs the managed bgzip and samtools faidx, so the class
/// sits in the conformance tier and skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.
final class RegionExtractionWithoutBundlePinConformanceTests: XCTestCase {
    static let bases = "ACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT"

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "region-without-bundle-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The bundle `extract sequence <fasta> <region> -o <name>.lungfishref` builds from the FASTA document
    /// of the first case, for the same region.
    func testTheFASTAModeBuildsABundleOfTheSameRegion() async throws {
        try await requireTools()
        let document = try writeFASTADocument()
        let output = try extractions().appendingPathComponent("Region 1.lungfishref", isDirectory: true)

        let command = try ExtractSequenceSubcommand.parse([document.path, "NC_TEST.1:11-40", "-o", output.path, "--quiet"])
        try await command.run()

        try assertSnapshot(await bundleSnapshot(output), Self.cliBundle, "cli bundle")
        try assertSnapshot(recordSnapshot(output), Self.cliRecord, "cli record")
    }

    /// R-B3's record line (2.12 review of lane 12.12, Fix 1). A region bundle of a GenBank file keeps none of
    /// the file's annotations, and the leaf's record says so in the resolved option `source_annotations`.
    /// The words are a literal here, so a rewording is a deliberate change of this pin. A FASTA file and no
    /// file give a record without the line.
    func testTheRecordOfAGenBankDocumentsRegionSaysItsAnnotationsWereNotCarried() async throws {
        try await requireTools()
        let genBank = try writeGenBankDocument()
        let fasta = try writeFASTADocument()
        let genBankRecords = try await GenBankReader(url: genBank).readAll()
        let genBankRecord = try XCTUnwrap(genBankRecords.first)
        let staged = try await StagedSequenceInput.writeFASTA(
            [.init(name: genBankRecord.sequence.name, bases: genBankRecord.sequence.asString())],
            fileName: "sequence.fa", prefix: "extract-sequence-input-", projectURL: try project()
        )

        let fromGenBank = try await leafFeatureBundle(staged: staged, document: genBank, in: "leaf-genbank")
        let fromFASTA = try await leafFeatureBundle(staged: staged, document: fasta, in: "leaf-fasta")
        let fromNoFile = try await leafFeatureBundle(staged: staged, document: nil, in: "leaf-no-file")

        let genBankOptions = try record(of: fromGenBank).options
        XCTAssertEqual(
            genBankOptions.resolvedDefaults["source_annotations"],
            .string("not carried: a region bundle of a GenBank document keeps its sequence only")
        )
        XCTAssertEqual(Self.filePath(genBankOptions.explicit["source_document"]), URL(fileURLWithPath: genBank.path).standardizedFileURL.path)
        XCTAssertEqual(try BundleManifest.load(from: fromGenBank).annotations.count, 0, "the bundle keeps no annotation of the file")
        let fastaOptions = try record(of: fromFASTA).options
        let noFileOptions = try record(of: fromNoFile).options
        XCTAssertNil(fastaOptions.resolvedDefaults["source_annotations"], "a FASTA file has no annotation to leave out")
        XCTAssertNil(noFileOptions.resolvedDefaults["source_annotations"], "no file, so no claim about one")
        XCTAssertEqual(Self.filePath(fastaOptions.explicit["source_document"]), URL(fileURLWithPath: fasta.path).standardizedFileURL.path)
        XCTAssertNil(noFileOptions.explicit["source_document"])
        for options in [fastaOptions, noFileOptions] {
            XCTAssertNil(options.explicit["source_annotations"])
            XCTAssertNil(options.defaults["source_annotations"])
        }

        for name in ["a.gb", "a.gbk", "a.gbff", "a.genbank", "a.gb.gz", "A.GBK"] {
            XCTAssertTrue(ExtractSequenceSubcommand.isGenBank(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.fasta", "a.fa.gz"] {
            XCTAssertFalse(ExtractSequenceSubcommand.isGenBank(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    /// The bundle `extract sequence` builds of the GenBank fixture's CDS from the staged FASTA, in a
    /// folder of its own, as the viewer's argv asks, with `--source-document` when a document is given.
    private func leafFeatureBundle(staged: URL, document: URL?, in folder: String) async throws -> URL {
        let parent = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let output = parent.appendingPathComponent("cdsA.lungfishref", isDirectory: true)
        var arguments = [
            staged.path, "NC_TEST:3-6,11-14", "--feature-name=geneA", "--feature-type", "CDS", "--strand", "-",
            "--concatenate-exons", "--flank-5", "2", "--name=cdsA",
        ]
        if let document { arguments += ["--source-document", document.path] }
        arguments += ["-o", output.path, "--quiet"]
        try await ExtractSequenceSubcommand.parse(arguments).run()
        return output
    }

    /// The path a recorded file option names, or nil when the option is not a file.
    private static func filePath(_ value: ParameterValue?) -> String? {
        guard case .file(let url)? = value else { return nil }
        return url.standardizedFileURL.path
    }

    // MARK: - The viewer's extraction

    /// The viewer's provider over the sequence its document shows (`makeRegionSequenceProvider`).
    static func viewerProvider(_ sequence: LungfishCore.Sequence) -> SequenceExtractor.SequenceProvider {
        { _, start, end in
            let clampedStart = max(0, start)
            let clampedEnd = min(sequence.length, end)
            guard clampedStart < clampedEnd else { return nil }
            return sequence[clampedStart..<clampedEnd]
        }
    }

    static func extract(_ source: ExtractionRequest.Source, from sequence: LungfishCore.Sequence) throws -> LungfishCore.ExtractionResult {
        try SequenceExtractor.extract(
            request: ExtractionRequest(source: source), sequenceProvider: viewerProvider(sequence), chromosomeLength: sequence.length
        )
    }

    static func readFASTADocument(_ url: URL) async throws -> LungfishCore.Sequence {
        let sequences = try await FASTAReader(url: url).readAll()
        return try XCTUnwrap(sequences.first)
    }

    // MARK: - Fixture

    private func project() throws -> URL {
        let url = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func extractions() throws -> URL {
        let url = try project().appendingPathComponent("Extractions", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A FASTA document of one 60 base sequence with a description.
    private func writeFASTADocument() throws -> URL {
        let url = try project().appendingPathComponent("Downloads/test virus.fasta")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ">NC_TEST.1 Test virus segment 4\n\(Self.bases)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A GenBank document of the same 60 bases with a source, a gene and a reverse CDS of two parts.
    private func writeGenBankDocument() throws -> URL {
        let url = try project().appendingPathComponent("Downloads/test virus.gb")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.genBankText.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let genBankText = """
    LOCUS       NC_TEST                   60 bp    DNA     linear   VRL 01-JAN-2026
    DEFINITION  Test virus segment 4.
    ACCESSION   NC_TEST
    VERSION     NC_TEST.1
    FEATURES             Location/Qualifiers
         source          1..60
                         /organism="Test virus"
         gene            3..14
                         /gene="geneA"
         CDS             complement(join(3..6,11..14))
                         /gene="geneA"
                         /product="protein A"
    ORIGIN
            1 acgttgcaac ggatccatgc aagcttgacc taggtaccga attcggccat ggcatgcaat
    //

    """

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }

    // MARK: - Reading a bundle

    private func assertSnapshot(
        _ actual: String, _ expected: String, _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        if actual != expected {
            print("SNAPSHOT-BEGIN \(name)\n\(actual)\nSNAPSHOT-END \(name)")
        }
        XCTAssertEqual(actual, expected, name, file: file, line: line)
    }

    /// The root's path, and the thread count the runner gives bgzip, which follows this Mac's cores.
    private func scrub(_ text: String) -> String {
        text
            .replacingOccurrences(of: root.resolvingSymlinksInPath().path, with: "<root>")
            .replacingOccurrences(of: root.path, with: "<root>")
            .replacingOccurrences(of: #"\| -@ \| \d+ \|"#, with: "| -@ | <threads> |", options: .regularExpression)
    }

    /// Every file of the bundle, its manifest, its genome and its tracks.
    private func bundleSnapshot(_ bundleURL: URL) async throws -> String {
        var lines = ["folder \(bundleURL.lastPathComponent)"]
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            if try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(String(fileURL.standardizedFileURL.path.dropFirst(bundleURL.standardizedFileURL.path.count + 1)))
            }
        }
        lines += files.sorted().map { "file \($0)" }
        let manifest = try BundleManifest.load(from: bundleURL)
        lines.append("name \(manifest.name)")
        lines.append("identifier \(manifest.identifier)")
        lines.append("description \(String(describing: manifest.description))")
        lines.append("source \(manifest.source.organism) \(String(describing: manifest.source.assembly)) "
            + "\(manifest.source.sourceURL?.lastPathComponent ?? "nil") \(String(describing: manifest.source.notes))")
        if let genome = manifest.genome {
            lines.append("genome \(genome.path) \(genome.indexPath) \(String(describing: genome.gzipIndexPath)) "
                + "\(genome.totalLength) md5=\(String(describing: genome.md5Checksum))")
            for chromosome in genome.chromosomes {
                lines.append("chromosome \(chromosome.name) \(chromosome.length) aliases=\(chromosome.aliases) "
                    + "description=\(String(describing: chromosome.fastaDescription))")
            }
            let reference = try await ReferenceBundle(url: bundleURL)
            for chromosome in genome.chromosomes {
                let region = GenomicRegion(chromosome: chromosome.name, start: 0, end: Int(chromosome.length))
                lines.append("bases \(try reference.fetchSequenceSync(region: region))")
            }
        }
        lines.append("annotations \(manifest.annotations.count) variants \(manifest.variants.count)")
        return scrub(lines.joined(separator: "\n"))
    }

    private func record(of bundleURL: URL) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
    }

    /// The bundle's record, without its times and digests, which only need to be present.
    private func recordSnapshot(_ bundleURL: URL) throws -> String {
        let envelope = try record(of: bundleURL)
        var lines = [
            "workflow \(envelope.workflowName)",
            "tool \(envelope.toolName)",
            "argv \(envelope.argv.joined(separator: " | "))",
            "steps \(envelope.steps.map(\.toolName).joined(separator: ", "))",
        ]
        let describe: ([String: ParameterValue]) -> [String] = { options in
            options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        lines += describe(envelope.options.explicit).map { "explicit \($0)" }
        lines += describe(envelope.options.defaults).map { "default \($0)" }
        lines += describe(envelope.options.resolvedDefaults).map { "resolved \($0)" }
        for step in envelope.steps {
            lines.append("step \(step.toolName) | \(step.argv.joined(separator: " | "))")
            lines += step.inputs.sorted { $0.path < $1.path }
                .map { "  input \($0.role) \($0.path) digest=\($0.checksumSHA256 != nil)" }
            lines += step.outputs.sorted { $0.path < $1.path }
                .map { "  output \($0.role) \($0.path) digest=\($0.checksumSHA256 != nil)" }
        }
        lines += envelope.files.sorted { $0.path < $1.path }
            .map { "file \($0.role) \($0.path) digest=\($0.checksumSHA256 != nil)" }
        return scrub(lines.joined(separator: "\n"))
    }

    // MARK: - Snapshots at the base

    static let cliBundle = """
    folder Region 1.lungfishref
    file .lungfish-provenance.json
    file genome/sequence.fa.gz
    file genome/sequence.fa.gz.fai
    file genome/sequence.fa.gz.gzi
    file manifest.json
    file provenance/bundle.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.fai.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.gzi.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.lungfish-provenance.json
    file provenance/manifest.json.lungfish-provenance.json
    name Region 1
    identifier org.lungfish.extracted.region-1
    description nil
    source Unknown Extracted nil Optional("Extracted sequence at NC_TEST.1:11-40 (1-based)")
    genome genome/sequence.fa.gz genome/sequence.fa.gz.fai Optional("genome/sequence.fa.gz.gzi") 30 md5=nil
    chromosome NC_TEST.1:11-40 30 aliases=[] description=Optional("[NC_TEST.1:11-40, 1-based] [30 bp]")
    bases GGATCCATGCAAGCTTGACCTAGGTACCGA
    annotations 0 variants 0
    """

    static let cliRecord = """
    workflow lungfish extract sequence
    tool lungfish extract sequence
    argv lungfish-cli | extract | sequence | @/Downloads/test virus.fasta | NC_TEST.1:11-40 | --output | @/Extractions/Region 1.lungfishref | --next-free-name | --format | json
    steps lungfish extract sequence, bgzip, samtools faidx
    explicit bundle_name=string("NC_TEST.1:11-40")
    explicit concatenate_exons=boolean(false)
    explicit input=file(file:@/Downloads/test%20virus.fasta)
    explicit operation=string("sequence-extraction")
    explicit reverse_complement=boolean(false)
    explicit sample_filter=array([])
    explicit source_bundle=null
    explicit source_bundle_name=null
    explicit source_name=string("NC_TEST.1:11-40")
    default concatenate_exons=boolean(false)
    default reverse_complement=boolean(false)
    default sample_filter=array([])
    resolved bundle_name=string("NC_TEST.1:11-40")
    resolved chromosome=string("NC_TEST.1")
    resolved concatenate_exons=boolean(false)
    resolved coordinate_system=string("0-based half-open")
    resolved end=integer(40)
    resolved input=file(file:@/Downloads/test%20virus.fasta)
    resolved operation=string("sequence-extraction")
    resolved output_bundle=file(file:@/Extractions/Region%201.lungfishref)
    resolved reverse_complement=boolean(false)
    resolved sample_filter=array([])
    resolved source_bundle=null
    resolved source_bundle_name=null
    resolved source_name=string("NC_TEST.1:11-40")
    resolved start=integer(10)
    step lungfish extract sequence | lungfish-cli | extract | sequence | @/Downloads/test virus.fasta | NC_TEST.1:11-40 | --output | @/Extractions/Region 1.lungfishref | --next-free-name | --format | json
      input input @/Downloads/test virus.fasta digest=true
      output output @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz digest=true
      output index @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz.gzi digest=true
      output output @/Extractions/Region 1.lungfishref/manifest.json digest=true
    step bgzip | bgzip | -f | -@ | <threads> | sequence.fa
      output output @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz digest=true
    step samtools faidx | samtools | faidx | sequence.fa.gz
      input output @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz digest=true
      output index @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file input @/Downloads/test virus.fasta digest=true
    file output @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz digest=true
    file index @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz.fai digest=true
    file index @/Extractions/Region 1.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output @/Extractions/Region 1.lungfishref/manifest.json digest=true
    """
}
