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

/// Phase 2.12 lane 12.12 M1 (A48-GAP, QA 1). A viewer whose document has no reference bundle builds
/// its region bundle in the app, `createExtractionBundleInProcess` in
/// `ViewerViewController+Extraction.swift`, which hands the extraction to
/// `SequenceExtractionPipeline().buildBundle(from:outputDirectory:desiredBundleName:isConcatenated:)`.
/// The class pins, at the base, what that call builds from a FASTA document and from a GenBank document
/// (files, manifest, name and record, and no annotation track, R-B3), the folder and names an empty and
/// a blank name give, and the bundle `extract sequence <fasta> <region> -o <name>.lungfishref` builds from
/// the same FASTA, so the route's A against C is known before it moves. Each case extracts the way the
/// viewer does, with `SequenceExtractor` over the document's sequence, clamped to its length. Each runs
/// the managed bgzip and samtools faidx, so the class sits in the conformance tier and skips without them
/// unless `LUNGFISH_REQUIRE_TOOLS=1`.
final class RegionExtractionWithoutBundlePinConformanceTests: XCTestCase {
    static let bases = "ACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT"

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "region-without-bundle-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A region of a FASTA document, as the viewer's in-process route builds it.
    func testTheInProcessRouteBuildsARegionOfAFASTADocument() async throws {
        try await requireTools()
        let sequence = try await Self.readFASTADocument(try writeFASTADocument())
        let result = try Self.extract(.region(chromosome: sequence.name, start: 10, end: 40), from: sequence)

        let bundleURL = try await inProcessBundle(result, bundleName: "Region 1", concatenateExons: false)

        try assertSnapshot(await bundleSnapshot(bundleURL), Self.fastaBundle, "fasta bundle")
        try assertSnapshot(recordSnapshot(bundleURL), Self.fastaRecord, "fasta record")
    }

    /// A reverse feature of two parts of a GenBank document, joined, with a 5' flank. The bundle keeps
    /// no annotation of the document (R-B3).
    func testTheInProcessRouteBuildsAFeatureOfAGenBankDocumentWithNoAnnotations() async throws {
        try await requireTools()
        let records = try await GenBankReader(url: try writeGenBankDocument()).readAll()
        let record = try XCTUnwrap(records.first)
        let cds = try XCTUnwrap(record.annotations.first { $0.type == .cds }, "\(record.annotations)")
        let request = ExtractionRequest(source: .annotation(cds), flank5Prime: 2, concatenateExons: true)
        let result = try SequenceExtractor.extract(
            request: request, sequenceProvider: Self.viewerProvider(record.sequence), chromosomeLength: record.sequence.length
        )

        let bundleURL = try await inProcessBundle(result, bundleName: "cdsA", concatenateExons: true)

        let document = "document \(record.sequence.name) annotations="
            + record.annotations.map { "\($0.type.rawValue):\($0.name)@\($0.chromosome ?? "nil")" }.joined(separator: ",")
        try assertSnapshot(
            document + "\n" + (await bundleSnapshot(bundleURL)), Self.genBankBundle, "genbank bundle"
        )
        try assertSnapshot(recordSnapshot(bundleURL), Self.genBankRecord, "genbank record")
    }

    /// The folder, manifest name, identifier and recorded name an empty and a blank name give.
    func testAnEmptyAndABlankNameNameTheBundle() async throws {
        try await requireTools()
        let sequence = try await Self.readFASTADocument(try writeFASTADocument())
        let result = try Self.extract(.region(chromosome: sequence.name, start: 10, end: 40), from: sequence)
        var lines: [String] = []
        for name in ["", "  "] {
            let bundleURL = try await inProcessBundle(result, bundleName: name, concatenateExons: false)
            let manifest = try BundleManifest.load(from: bundleURL)
            let recorded = try record(of: bundleURL).options.explicit["bundle_name"].map { "\($0)" } ?? "nil"
            lines.append("\(name.debugDescription) -> \(bundleURL.lastPathComponent) name=\(manifest.name.debugDescription) "
                + "id=\(manifest.identifier) bundle_name=\(recorded)")
        }
        try assertSnapshot(lines.joined(separator: "\n"), Self.emptyNames, "empty names")
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

    // MARK: - The route at the base

    /// The call `createExtractionBundleInProcess` makes, into the project's `Extractions` folder.
    private func inProcessBundle(
        _ result: LungfishCore.ExtractionResult, bundleName: String, concatenateExons: Bool
    ) async throws -> URL {
        try await SequenceExtractionPipeline().buildBundle(
            from: result, outputDirectory: try extractions(), desiredBundleName: bundleName, isConcatenated: concatenateExons
        )
    }

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

    static let fastaBundle = """
    folder Region_1.lungfishref
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
    name Region_1
    identifier org.lungfish.extracted.region_1
    description nil
    source Unknown Extracted nil Optional("Extracted sequence at NC_TEST.1:11-40 (1-based)")
    genome genome/sequence.fa.gz genome/sequence.fa.gz.fai Optional("genome/sequence.fa.gz.gzi") 30 md5=nil
    chromosome NC_TEST.1:11-40 30 aliases=[] description=Optional("[NC_TEST.1:11-40, 1-based] [30 bp]")
    bases GGATCCATGCAAGCTTGACCTAGGTACCGA
    annotations 0 variants 0
    """

    static let fastaRecord = """
    workflow lungfish gui sequence extraction
    tool lungfish gui sequence extraction
    argv lungfish-gui | sequence | extract-bundle | --chromosome | NC_TEST.1 | --start | 10 | --end | 40 | --name | Region 1 | --output | @/Extractions/Region_1.lungfishref
    steps lungfish gui sequence extraction, bgzip, samtools faidx
    explicit bundle_name=string("Region 1")
    explicit concatenate_exons=boolean(false)
    explicit operation=string("sequence-extraction")
    explicit reverse_complement=boolean(false)
    explicit sample_filter=array([])
    explicit source_bundle=null
    explicit source_bundle_name=null
    explicit source_name=string("NC_TEST.1:11-40")
    default concatenate_exons=boolean(false)
    default reverse_complement=boolean(false)
    default sample_filter=array([])
    resolved bundle_name=string("Region 1")
    resolved chromosome=string("NC_TEST.1")
    resolved concatenate_exons=boolean(false)
    resolved coordinate_system=string("0-based half-open")
    resolved end=integer(40)
    resolved operation=string("sequence-extraction")
    resolved output_bundle=file(file:@/Extractions/Region_1.lungfishref)
    resolved reverse_complement=boolean(false)
    resolved sample_filter=array([])
    resolved source_bundle=null
    resolved source_bundle_name=null
    resolved source_name=string("NC_TEST.1:11-40")
    resolved start=integer(10)
    step lungfish gui sequence extraction | lungfish-gui | sequence | extract-bundle | --chromosome | NC_TEST.1 | --start | 10 | --end | 40 | --name | Region 1 | --output | @/Extractions/Region_1.lungfishref
      output output @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz digest=true
      output index @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz.gzi digest=true
      output output @/Extractions/Region_1.lungfishref/manifest.json digest=true
    step bgzip | bgzip | -f | -@ | <threads> | sequence.fa
      output output @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz digest=true
    step samtools faidx | samtools | faidx | sequence.fa.gz
      input output @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz digest=true
      output index @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz digest=true
    file index @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz.fai digest=true
    file index @/Extractions/Region_1.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output @/Extractions/Region_1.lungfishref/manifest.json digest=true
    """

    static let genBankBundle = """
    document NC_TEST annotations=source:source@NC_TEST,gene:geneA@NC_TEST,CDS:geneA@NC_TEST
    folder cdsA.lungfishref
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
    name cdsA
    identifier org.lungfish.extracted.cdsa
    description Optional("Extracted sequence at NC_TEST:2-16")
    source Unknown Extracted nil Optional("Extracted sequence at NC_TEST:2-16")
    genome genome/sequence.fa.gz genome/sequence.fa.gz.fai Optional("genome/sequence.fa.gz.gzi") 10 md5=nil
    chromosome geneA 10 aliases=[] description=nil
    bases GGATGTTGCC
    annotations 0 variants 0
    """

    static let genBankRecord = """
    workflow lungfish gui sequence extraction
    tool lungfish gui sequence extraction
    argv lungfish-gui | sequence | extract-bundle | --chromosome | NC_TEST | --start | 2 | --end | 16 | --concatenate-exons | --name | cdsA | --output | @/Extractions/cdsA.lungfishref
    steps lungfish gui sequence extraction, bgzip, samtools faidx
    explicit bundle_name=string("cdsA")
    explicit concatenate_exons=boolean(true)
    explicit operation=string("sequence-extraction")
    explicit reverse_complement=boolean(false)
    explicit sample_filter=array([])
    explicit source_bundle=null
    explicit source_bundle_name=null
    explicit source_name=string("geneA")
    default concatenate_exons=boolean(false)
    default reverse_complement=boolean(false)
    default sample_filter=array([])
    resolved bundle_name=string("cdsA")
    resolved chromosome=string("NC_TEST")
    resolved concatenate_exons=boolean(true)
    resolved coordinate_system=string("0-based half-open")
    resolved end=integer(16)
    resolved operation=string("sequence-extraction")
    resolved output_bundle=file(file:@/Extractions/cdsA.lungfishref)
    resolved reverse_complement=boolean(false)
    resolved sample_filter=array([])
    resolved source_bundle=null
    resolved source_bundle_name=null
    resolved source_name=string("geneA")
    resolved start=integer(2)
    step lungfish gui sequence extraction | lungfish-gui | sequence | extract-bundle | --chromosome | NC_TEST | --start | 2 | --end | 16 | --concatenate-exons | --name | cdsA | --output | @/Extractions/cdsA.lungfishref
      output output @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz digest=true
      output index @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz.gzi digest=true
      output output @/Extractions/cdsA.lungfishref/manifest.json digest=true
    step bgzip | bgzip | -f | -@ | <threads> | sequence.fa
      output output @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz digest=true
    step samtools faidx | samtools | faidx | sequence.fa.gz
      input output @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz digest=true
      output index @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz digest=true
    file index @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz.fai digest=true
    file index @/Extractions/cdsA.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output @/Extractions/cdsA.lungfishref/manifest.json digest=true
    """

    static let emptyNames = """
    "" -> NC_TEST.1-11-40.lungfishref name="NC_TEST.1-11-40" id=org.lungfish.extracted.nc_test.1-11-40 bundle_name=string("")
    "  " -> extracted_sequence.lungfishref name="extracted_sequence" id=org.lungfish.extracted.extracted_sequence bundle_name=string("  ")
    """

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
