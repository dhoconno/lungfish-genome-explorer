import Foundation

enum LungfishProjectFixtureBuilder {
    private struct ProjectMetadataFixture: Encodable {
        let author: String?
        let createdAt: Date
        let customMetadata: [String: String]
        let description: String?
        let formatVersion: String
        let modifiedAt: Date
        let name: String
        let version: String
    }

    private struct AnalysisMetadataFixture: Encodable {
        let created: Date
        let isBatch: Bool
        let tool: String
    }

    private struct ReferenceBundleManifestFixture: Encodable {
        let formatVersion: String
        let name: String
        let identifier: String
        let createdDate: Date
        let modifiedDate: Date
        let source: ReferenceBundleSourceFixture
        let genome: ReferenceBundleGenomeFixture
        let annotations: [String]
        let variants: [String]
        let tracks: [String]
        let alignments: [String]
        let browserSummary: ReferenceBundleBrowserSummaryFixture

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case name
            case identifier
            case createdDate = "created_date"
            case modifiedDate = "modified_date"
            case source
            case genome
            case annotations
            case variants
            case tracks
            case alignments
            case browserSummary = "browser_summary"
        }
    }

    private struct ReferenceBundleSourceFixture: Encodable {
        let organism: String
        let assembly: String
        let database: String
        let notes: String
    }

    private struct ReferenceBundleGenomeFixture: Encodable {
        let path: String
        let indexPath: String
        let totalLength: Int
        let chromosomes: [ReferenceBundleChromosomeFixture]

        enum CodingKeys: String, CodingKey {
            case path
            case indexPath = "index_path"
            case totalLength = "total_length"
            case chromosomes
        }
    }

    private struct ReferenceBundleChromosomeFixture: Encodable {
        let name: String
        let length: Int
        let offset: Int
        let lineBases: Int
        let lineWidth: Int
        let aliases: [String]
        let isPrimary: Bool
        let isMitochondrial: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case length
            case offset
            case lineBases = "line_bases"
            case lineWidth = "line_width"
            case aliases
            case isPrimary = "is_primary"
            case isMitochondrial = "is_mitochondrial"
        }
    }

    private struct ReferenceBundleBrowserSummaryFixture: Encodable {
        let schemaVersion: Int
        let aggregate: ReferenceBundleBrowserAggregateFixture
        let sequences: [ReferenceBundleBrowserSequenceFixture]
    }

    private struct ReferenceBundleBrowserAggregateFixture: Encodable {
        let annotationTrackCount: Int
        let variantTrackCount: Int
        let alignmentTrackCount: Int
        let totalMappedReads: Int?
    }

    private struct ReferenceBundleBrowserSequenceFixture: Encodable {
        let name: String
        let displayDescription: String?
        let length: Int
        let aliases: [String]
        let isPrimary: Bool
        let isMitochondrial: Bool
        let metrics: String?
    }

    private enum FixtureCopyTarget {
        case projectRoot
        case directory(name: String)
    }

    static func makeAnalysesProject(named name: String = "FixtureProject") throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-xcui-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectURL = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        let analysesDirectory = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let source = LungfishFixtureCatalog.analyses.appendingPathComponent(
            "spades-2026-01-15T13-00-00",
            isDirectory: true
        )
        let destination = analysesDirectory.appendingPathComponent(
            "spades-2026-01-15T13-00-00",
            isDirectory: true
        )

        try fileManager.createDirectory(at: analysesDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try writeProjectMetadata(to: projectURL, name: name)
        try writeAnalysisMetadata(to: destination, tool: "spades")
        return projectURL
    }

    static func makeIlluminaAssemblyProject(named name: String = "IlluminaAssemblyFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_1.fastq.gz"), .projectRoot),
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_2.fastq.gz"), .projectRoot),
            ]
        )
    }

    static func makeIlluminaMappingProject(named name: String = "IlluminaMappingFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_1.fastq.gz"), .projectRoot),
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_2.fastq.gz"), .projectRoot),
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("genome.fasta"), .projectRoot),
            ]
        )
    }

    static func makeMappingInspectorNavigationProject(named name: String = "MappingInspectorNavigationFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_1.fastq.gz"), .projectRoot),
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_2.fastq.gz"), .projectRoot),
                (LungfishFixtureCatalog.repoRoot.appendingPathComponent("TestData/TestGenome.lungfishref"), .projectRoot),
            ]
        )
    }

    static func makeBundleBrowserProject(named name: String = "BundleBrowserFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [],
            referenceBundleRecords: [
                ("chr1", String(repeating: "A", count: 200)),
                ("chr2", String(repeating: "C", count: 120)),
                ("chrM", String(repeating: "G", count: 60)),
            ]
        )
    }

    static func makeOntAssemblyProject(named name: String = "OntAssemblyFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.assemblyUI.appendingPathComponent("ont/reads.fastq"), .projectRoot),
            ]
        )
    }

    static func makeViralReconIlluminaProject(named name: String = "ViralReconIlluminaFixture") throws -> URL {
        let projectURL = try makeViralReconProjectScaffold(named: name)
        try writeViralReconIlluminaBundle(projectURL: projectURL, sampleName: "SampleA")
        try writeViralReconIlluminaBundle(projectURL: projectURL, sampleName: "SampleB")
        try writeViralReconPrimerScheme(projectURL: projectURL)
        return projectURL
    }

    static func makeViralReconONTProject(named name: String = "ViralReconONTFixture") throws -> URL {
        let projectURL = try makeViralReconProjectScaffold(named: name)
        try writeViralReconONTBundle(
            projectURL: projectURL,
            bundleName: "Barcode01",
            sampleName: "Barcode01",
            barcode: "barcode01"
        )
        try writeViralReconONTBundle(
            projectURL: projectURL,
            bundleName: "Barcode02",
            sampleName: "Barcode02",
            barcode: "barcode02"
        )
        try writeViralReconPrimerScheme(projectURL: projectURL)
        return projectURL
    }

    static func makePacBioHiFiAssemblyProject(named name: String = "HiFiAssemblyFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.assemblyUI.appendingPathComponent("pacbio-hifi/reads.fastq"), .projectRoot),
            ]
        )
    }

    /// Creates an XCUI fixture project containing a `.lungfishref` bundle that
    /// wraps the real sarscov2 fixture BAM. The project's `Primer Schemes/`
    /// folder is pre-populated with the mt192765-integration scheme so the
    /// primer-trim dialog has a project-local scheme to select.
    static func makeMappedBundleProject(named name: String = "PrimerTrimMappedFixture") throws -> URL {
        let projectURL = try makePrimerTrimProjectScaffold(named: name)
        try writePrimerTrimReferenceBundle(projectURL: projectURL)
        try copyIntegrationSchemeIntoProject(projectURL: projectURL)
        return projectURL
    }

    /// Same as `makeMappedBundleProject` but the source BAM has already been
    /// primer-trimmed: a `<bam-sans-ext>.primer-trim-provenance.json` sidecar
    /// is dropped alongside the BAM so that the variant-calling dialog's
    /// auto-confirm path triggers when the user opens the bundle.
    static func makePrimerTrimmedBundleProject(named name: String = "PrimerTrimmedFixture") throws -> URL {
        let projectURL = try makeMappedBundleProject(named: name)
        try writeStubPrimerTrimSidecar(projectURL: projectURL)
        return projectURL
    }

    private static func makeProject(
        named name: String,
        fixtures: [(source: URL, target: FixtureCopyTarget)],
        referenceBundleRecords: [(name: String, sequence: String)] = []
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-xcui-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectURL = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try writeProjectMetadata(to: projectURL, name: name)

        for fixture in fixtures {
            let destinationDirectory: URL
            switch fixture.target {
            case .projectRoot:
                destinationDirectory = projectURL
            case .directory(let name):
                destinationDirectory = projectURL.appendingPathComponent(name, isDirectory: true)
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            }

            try fileManager.copyItem(
                at: fixture.source,
                to: destinationDirectory.appendingPathComponent(fixture.source.lastPathComponent)
            )
        }

        if !referenceBundleRecords.isEmpty {
            try writeReferenceBundle(
                named: "TestGenome",
                records: referenceBundleRecords,
                to: projectURL
            )
        }

        return projectURL
    }

    private static func writeProjectMetadata(to projectURL: URL, name: String) throws {
        let timestamp = Date()
        let metadata = ProjectMetadataFixture(
            author: nil,
            createdAt: timestamp,
            customMetadata: [:],
            description: nil,
            formatVersion: "1.0",
            modifiedAt: timestamp,
            name: name,
            version: "1.0"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataURL = projectURL.appendingPathComponent("metadata.json")
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private static func writeAnalysisMetadata(to analysisURL: URL, tool: String) throws {
        let metadata = AnalysisMetadataFixture(
            created: Date(),
            isBatch: false,
            tool: tool
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataURL = analysisURL.appendingPathComponent("analysis-metadata.json")
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private static func writeReferenceBundle(
        named bundleName: String,
        records: [(name: String, sequence: String)],
        to projectURL: URL
    ) throws {
        let fileManager = FileManager.default
        let bundleURL = projectURL.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeURL, withIntermediateDirectories: true)

        let fastaURL = genomeURL.appendingPathComponent("sequence.fa")
        let faiURL = genomeURL.appendingPathComponent("sequence.fa.fai")

        var fastaLines: [String] = []
        var faiLines: [String] = []
        var chromosomes: [ReferenceBundleChromosomeFixture] = []
        var browserSequences: [ReferenceBundleBrowserSequenceFixture] = []
        var offset = 0

        for record in records {
            let header = ">\(record.name)"
            let lineBases = max(1, record.sequence.utf8.count)
            let lineWidth = lineBases + 1
            let sequenceOffset = offset + header.utf8.count + 1
            let isMitochondrial = record.name.caseInsensitiveCompare("chrM") == .orderedSame
            let aliases = aliases(for: record.name)

            fastaLines.append(header)
            fastaLines.append(record.sequence)
            faiLines.append("\(record.name)\t\(record.sequence.utf8.count)\t\(sequenceOffset)\t\(lineBases)\t\(lineWidth)")

            chromosomes.append(
                ReferenceBundleChromosomeFixture(
                    name: record.name,
                    length: record.sequence.utf8.count,
                    offset: sequenceOffset,
                    lineBases: lineBases,
                    lineWidth: lineWidth,
                    aliases: aliases,
                    isPrimary: !isMitochondrial,
                    isMitochondrial: isMitochondrial
                )
            )
            browserSequences.append(
                ReferenceBundleBrowserSequenceFixture(
                    name: record.name,
                    displayDescription: nil,
                    length: record.sequence.utf8.count,
                    aliases: aliases,
                    isPrimary: !isMitochondrial,
                    isMitochondrial: isMitochondrial,
                    metrics: nil
                )
            )

            offset = sequenceOffset + record.sequence.utf8.count + 1
        }

        try (fastaLines.joined(separator: "\n") + "\n").write(
            to: fastaURL,
            atomically: true,
            encoding: .utf8
        )
        try (faiLines.joined(separator: "\n") + "\n").write(
            to: faiURL,
            atomically: true,
            encoding: .utf8
        )

        let timestamp = Date(timeIntervalSince1970: 1_713_744_000)
        let manifest = ReferenceBundleManifestFixture(
            formatVersion: "1.0",
            name: bundleName,
            identifier: "org.lungfish.xcui.\(bundleName.lowercased())",
            createdDate: timestamp,
            modifiedDate: timestamp,
            source: ReferenceBundleSourceFixture(
                organism: "Bundle Browser Fixture",
                assembly: "xcui",
                database: "UI Test",
                notes: "Deterministic multi-contig bundle browser fixture"
            ),
            genome: ReferenceBundleGenomeFixture(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: records.reduce(0) { $0 + $1.sequence.utf8.count },
                chromosomes: chromosomes
            ),
            annotations: [],
            variants: [],
            tracks: [],
            alignments: [],
            browserSummary: ReferenceBundleBrowserSummaryFixture(
                schemaVersion: 1,
                aggregate: ReferenceBundleBrowserAggregateFixture(
                    annotationTrackCount: 0,
                    variantTrackCount: 0,
                    alignmentTrackCount: 0,
                    totalMappedReads: nil
                ),
                sequences: browserSequences
            )
        )
        try writeJSON(
            manifest,
            to: bundleURL.appendingPathComponent("manifest.json")
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func aliases(for chromosomeName: String) -> [String] {
        switch chromosomeName {
        case "chr1":
            return ["1"]
        case "chr2":
            return ["2"]
        case "chrM":
            return ["MT"]
        default:
            return []
        }
    }

    // MARK: - Viral Recon helpers

    private static func makeViralReconProjectScaffold(named name: String) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-xcui-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectURL = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: projectURL.appendingPathComponent("Primer Schemes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeProjectMetadata(to: projectURL, name: name)
        return projectURL
    }

    private static func writeViralReconIlluminaBundle(projectURL: URL, sampleName: String) throws {
        let fileManager = FileManager.default
        let bundleURL = projectURL.appendingPathComponent("\(sampleName).lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let r1 = bundleURL.appendingPathComponent("\(sampleName)_R1.fastq.gz")
        let r2 = bundleURL.appendingPathComponent("\(sampleName)_R2.fastq.gz")
        try fileManager.copyItem(
            at: LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_1.fastq.gz"),
            to: r1
        )
        try fileManager.copyItem(
            at: LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_2.fastq.gz"),
            to: r2
        )

        try writeFASTQSidecar(for: r1, assemblyReadType: "illuminaShortReads", platform: "illumina")
        try writeFASTQSidecar(for: r2, assemblyReadType: "illuminaShortReads", platform: "illumina")
        try writeFASTQMetadataCSV(
            to: bundleURL,
            rows: [
                ("sample_name", sampleName),
                ("sequencing_platform", "illumina"),
            ]
        )
        try writeSourceFilesManifest(for: bundleURL, fastqURLs: [r1, r2])
    }

    private static func writeViralReconONTBundle(
        projectURL: URL,
        bundleName: String,
        sampleName: String,
        barcode: String
    ) throws {
        let fileManager = FileManager.default
        let bundleURL = projectURL.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let reads = bundleURL.appendingPathComponent("reads.fastq")
        try fileManager.copyItem(
            at: LungfishFixtureCatalog.assemblyUI.appendingPathComponent("ont/reads.fastq"),
            to: reads
        )

        try writeFASTQSidecar(for: reads, assemblyReadType: "ontReads", platform: "oxfordNanopore")
        try writeFASTQMetadataCSV(
            to: bundleURL,
            rows: [
                ("sample_name", sampleName),
                ("sequencing_platform", "ont"),
                ("barcode", barcode),
            ]
        )
        try """
        filename\tread_id
        reads.fastq\t\(sampleName)-read-1
        """.write(
            to: bundleURL.appendingPathComponent("sequencing_summary.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeViralReconPrimerScheme(projectURL: URL) throws {
        let schemeURL = projectURL
            .appendingPathComponent("Primer Schemes", isDirectory: true)
            .appendingPathComponent("A-UI-ViralRecon-SARS2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: schemeURL, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "schema_version": 1,
            "name": "a-ui-viralrecon-sars2",
            "display_name": "A UI Viral Recon Project Scheme",
            "description": "Deterministic SARS-CoV-2 primer scheme for Viral Recon UI tests.",
            "organism": "Severe acute respiratory syndrome coronavirus 2",
            "reference_accessions": [
                ["accession": "MN908947.3", "canonical": true],
                ["accession": "NC_045512.2", "equivalent": true],
            ],
            "primer_count": 2,
            "amplicon_count": 1,
            "source": "ui-test",
            "version": "0.1.0",
            "created": "2026-04-28T00:00:00Z",
        ]
        try writeJSONObject(manifest, to: schemeURL.appendingPathComponent("manifest.json"))
        try """
        # A UI Viral Recon Project Scheme

        Deterministic SARS-CoV-2 primer scheme fixture for Viral Recon UI tests.
        """.write(
            to: schemeURL.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        MN908947.3\t0\t4\tamplicon_1_LEFT\t1\t+
        MN908947.3\t4\t8\tamplicon_1_RIGHT\t1\t-
        """.write(
            to: schemeURL.appendingPathComponent("primers.bed"),
            atomically: true,
            encoding: .utf8
        )
        try """
        >amplicon_1_LEFT
        AAAA
        >amplicon_1_RIGHT
        CCCC
        """.write(
            to: schemeURL.appendingPathComponent("primers.fasta"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeFASTQSidecar(
        for fastqURL: URL,
        assemblyReadType: String,
        platform: String
    ) throws {
        let metadata: [String: Any] = [
            "assemblyReadType": assemblyReadType,
            "sequencingPlatform": platform,
        ]
        try writeJSONObject(metadata, to: fastqURL.appendingPathExtension("lungfish-meta.json"))
    }

    private static func writeFASTQMetadataCSV(to bundleURL: URL, rows: [(String, String)]) throws {
        var lines = ["key,value"]
        lines += rows.map { "\($0.0),\($0.1)" }
        try (lines.joined(separator: "\n") + "\n").write(
            to: bundleURL.appendingPathComponent("metadata.csv"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeSourceFilesManifest(for bundleURL: URL, fastqURLs: [URL]) throws {
        let entries: [[String: Any]] = try fastqURLs.map { fastqURL in
            [
                "filename": fastqURL.lastPathComponent,
                "originalPath": fastqURL.path,
                "sizeBytes": try fileSize(at: fastqURL),
                "isSymlink": false,
            ]
        }
        try writeJSONObject(
            [
                "version": 1,
                "files": entries,
            ],
            to: bundleURL.appendingPathComponent("source-files.json")
        )
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func writeJSONObject(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Primer-trim helpers

    private static func makePrimerTrimProjectScaffold(named name: String) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-xcui-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectURL = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try writeProjectMetadata(to: projectURL, name: name)
        try fileManager.createDirectory(
            at: projectURL.appendingPathComponent("Primer Schemes", isDirectory: true),
            withIntermediateDirectories: true
        )
        return projectURL
    }

    /// Authors a `.lungfishref` bundle that wraps the sarscov2 reference FASTA
    /// and paired-end BAM as an alignment track.
    private static func writePrimerTrimReferenceBundle(projectURL: URL) throws {
        let fileManager = FileManager.default
        let bundleURL = projectURL.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        let sourceFasta = LungfishFixtureCatalog.sarscov2.appendingPathComponent("genome.fasta")
        let sourceFai = LungfishFixtureCatalog.sarscov2.appendingPathComponent("genome.fasta.fai")
        let destFasta = genomeDir.appendingPathComponent("sequence.fa")
        let destFai = genomeDir.appendingPathComponent("sequence.fa.fai")
        try fileManager.copyItem(at: sourceFasta, to: destFasta)
        try fileManager.copyItem(at: sourceFai, to: destFai)

        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try fileManager.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        let sourceBAM = LungfishFixtureCatalog.sarscov2
            .appendingPathComponent("test.paired_end.sorted.bam")
        let sourceBAI = sourceBAM.appendingPathExtension("bai")
        let bundleBAM = alignmentsDir.appendingPathComponent("source.sorted.bam")
        let bundleBAI = bundleBAM.appendingPathExtension("bai")
        try fileManager.copyItem(at: sourceBAM, to: bundleBAM)
        try fileManager.copyItem(at: sourceBAI, to: bundleBAI)

        let timestamp = Date(timeIntervalSince1970: 1_713_744_000)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoTimestamp = isoFormatter.string(from: timestamp)

        let faiContents = try String(contentsOf: destFai, encoding: .utf8)
        let firstLine = faiContents.split(separator: "\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: "\t").map(String.init)
        let chromName = parts.indices.contains(0) ? parts[0] : "MT192765.1"
        let chromLength = (parts.indices.contains(1) ? Int(parts[1]) : nil) ?? 29829
        let chromOffset = (parts.indices.contains(2) ? Int(parts[2]) : nil) ?? 120
        let chromLineBases = (parts.indices.contains(3) ? Int(parts[3]) : nil) ?? 80
        let chromLineWidth = (parts.indices.contains(4) ? Int(parts[4]) : nil) ?? 81

        let manifestJSON: [String: Any] = [
            "format_version": "1.0",
            "name": "Sample",
            "identifier": "org.lungfish.xcui.primer-trim.\(UUID().uuidString)",
            "created_date": isoTimestamp,
            "modified_date": isoTimestamp,
            "source": [
                "organism": "Severe acute respiratory syndrome coronavirus 2",
                "assembly": "MT192765.1",
                "database": "test",
                "notes": "XCUI primer-trim fixture"
            ],
            "genome": [
                "path": "genome/sequence.fa",
                "index_path": "genome/sequence.fa.fai",
                "total_length": chromLength,
                "chromosomes": [[
                    "name": chromName,
                    "length": chromLength,
                    "offset": chromOffset,
                    "line_bases": chromLineBases,
                    "line_width": chromLineWidth,
                    "aliases": [],
                    "is_primary": true,
                    "is_mitochondrial": false
                ]]
            ],
            "annotations": [],
            "variants": [],
            "tracks": [],
            "alignments": [[
                "id": "aln-source",
                "name": "Source Alignment",
                "format": "bam",
                "source_path": "alignments/source.sorted.bam",
                "index_path": "alignments/source.sorted.bam.bai",
                "added_date": isoTimestamp,
                "sample_names": []
            ]]
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifestJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))
    }

    private static func copyIntegrationSchemeIntoProject(projectURL: URL) throws {
        let schemeSource = LungfishFixtureCatalog.repoRoot
            .appendingPathComponent("Tests/LungfishWorkflowTests/Resources/primerschemes/mt192765-integration.lungfishprimers")
        guard FileManager.default.fileExists(atPath: schemeSource.path) else { return }

        let schemesDir = projectURL.appendingPathComponent("Primer Schemes", isDirectory: true)
        let dest = schemesDir.appendingPathComponent("mt192765-integration.lungfishprimers")
        try FileManager.default.copyItem(at: schemeSource, to: dest)
    }

    private static func writeStubPrimerTrimSidecar(projectURL: URL) throws {
        let sidecarURL = projectURL
            .appendingPathComponent("Sample.lungfishref/alignments/source.sorted.primer-trim-provenance.json")
        let sidecarJSON: [String: Any] = [
            "operation": "primer-trim",
            "primer_scheme": [
                "bundle_name": "mt192765-integration",
                "bundle_source": "test-fixture",
                "bundle_version": "0.1.0",
                "canonical_accession": "MT192765.1"
            ],
            "source_bam": "alignments/source.sorted.bam",
            "ivar_version": "1.4.4",
            "ivar_trim_args": [
                "trim", "-b", "primers.bed", "-i", "input.bam", "-p", "out",
                "-q", "20", "-m", "30", "-s", "4", "-x", "0", "-e"
            ],
            "timestamp": "2026-04-25T00:00:00Z"
        ]
        let data = try JSONSerialization.data(
            withJSONObject: sidecarJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: sidecarURL)
    }
}
