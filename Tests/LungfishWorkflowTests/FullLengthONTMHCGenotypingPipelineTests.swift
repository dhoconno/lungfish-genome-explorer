import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCGenotypingPipelineTests: XCTestCase {
    func testBatchSchedulerUsesThreeSampleJobsAndThreePBAAThreadsOnFourteenCoreBatch() {
        let plan = FullLengthONTMHCSampleExecutionPlan.automatic(
            totalThreads: 14,
            sampleCount: 48,
            requestedSampleJobs: nil,
            requestedPBAAThreadsPerSample: nil
        )

        XCTAssertEqual(plan.sampleJobs, 3)
        XCTAssertEqual(plan.pbaaThreadsPerSample, 3)
        XCTAssertEqual(plan.workerThreadsPerSample, 4)
    }

    func testSingleSampleSchedulerKeepsAllThreadsForPBAA() {
        let plan = FullLengthONTMHCSampleExecutionPlan.automatic(
            totalThreads: 14,
            sampleCount: 1,
            requestedSampleJobs: nil,
            requestedPBAAThreadsPerSample: nil
        )

        XCTAssertEqual(plan.sampleJobs, 1)
        XCTAssertEqual(plan.pbaaThreadsPerSample, 14)
        XCTAssertEqual(plan.workerThreadsPerSample, 14)
    }

    func testSchedulerOrdersLargestSamplesFirstUsingReadCounts() {
        let root = URL(fileURLWithPath: "/tmp/full-length-ont-mhc-scheduler", isDirectory: true)
        let samples = [
            FullLengthONTMHCScheduledSample(
                originalIndex: 0,
                inputURL: root.appendingPathComponent("small.fastq"),
                sample: "small",
                sampleDirectory: root.appendingPathComponent("small", isDirectory: true),
                materializedFASTQURL: root.appendingPathComponent("small.fastq"),
                readCount: 100
            ),
            FullLengthONTMHCScheduledSample(
                originalIndex: 1,
                inputURL: root.appendingPathComponent("large.fastq"),
                sample: "large",
                sampleDirectory: root.appendingPathComponent("large", isDirectory: true),
                materializedFASTQURL: root.appendingPathComponent("large.fastq"),
                readCount: 500
            ),
            FullLengthONTMHCScheduledSample(
                originalIndex: 2,
                inputURL: root.appendingPathComponent("medium.fastq"),
                sample: "medium",
                sampleDirectory: root.appendingPathComponent("medium", isDirectory: true),
                materializedFASTQURL: root.appendingPathComponent("medium.fastq"),
                readCount: 250
            ),
        ]

        XCTAssertEqual(
            FullLengthONTMHCSampleScheduler.processingOrder(for: samples).map(\.sample),
            ["large", "medium", "small"]
        )
    }

    func testSchedulerUsesReadWeightedProcessingProgress() {
        let progress = FullLengthONTMHCSampleScheduler.processingProgress(
            completedReadCount: 100,
            totalReadCount: 1_000
        )

        XCTAssertEqual(progress, 0.221, accuracy: 0.000_1)
    }

    func testPBAAArtifactPlannerBuildsStrictSignatureFromWorkflowInputsAndContainerPins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-pbaa-signature-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("DL46.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("DL46.fastq")
        let preparedURL = root.appendingPathComponent("prepared.fastq")
        let guideURL = root.appendingPathComponent("guide.fasta")
        let orientURL = root.appendingPathComponent("orient.fasta")
        let forwardURL = root.appendingPathComponent("forward.fasta")
        let reverseURL = root.appendingPathComponent("reverse.fasta")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: preparedURL, atomically: true, encoding: .utf8)
        for url in [guideURL, orientURL, forwardURL, reverseURL] {
            try ">x\nACGT\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let runRequest = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [bundleURL],
            referenceSourceURL: root.appendingPathComponent("ref.fasta"),
            guideSourceURL: guideURL,
            orientReferenceURL: orientURL,
            forwardPrimerURL: forwardURL,
            reversePrimerURL: reverseURL,
            outputDirectory: root.appendingPathComponent("out.lungfishgenotype", isDirectory: true),
            minimumLength: 2_100,
            maximumLength: 3_900,
            pbaaSeed: 7,
            pbaaExtraArgumentsText: "--min-cluster-read-count 2"
        )
        let pbaaRequest = try PBAAClusteringRunRequest(
            inputFASTQURL: preparedURL,
            guideSourceURL: guideURL,
            outputDirectory: root.appendingPathComponent("pbaa", isDirectory: true),
            outputName: "DL46",
            seed: 7,
            extraArgumentsText: "--min-cluster-read-count 2"
        )

        let signature = try FullLengthONTPBAAArtifactPlanner.signature(
            inputURL: bundleURL,
            preparedFASTQURL: preparedURL,
            guideFASTAURL: guideURL,
            request: runRequest,
            pbaaRequest: pbaaRequest
        )

        XCTAssertEqual(signature.preprocessing.minimumLength, 2_100)
        XCTAssertEqual(signature.preprocessing.maximumLength, 3_900)
        XCTAssertNotNil(signature.preprocessing.orientReference)
        XCTAssertNotNil(signature.preprocessing.forwardPrimer)
        XCTAssertNotNil(signature.preprocessing.reversePrimer)
        XCTAssertEqual(signature.clustering.pbaaToolVersion, PBAAContainerPins.pbaa.toolVersion)
        XCTAssertEqual(signature.clustering.workflowSchemaVersion, PBAAContainerPins.workflowSchemaVersion)
        XCTAssertEqual(signature.clustering.seed, 7)
        XCTAssertEqual(signature.clustering.extraArguments, ["--min-cluster-read-count", "2"])
        XCTAssertEqual(signature.clustering.pbaaContainerReference, PBAAContainerPins.pbaa.reference)
        XCTAssertEqual(signature.clustering.samtoolsContainerReference, PBAAContainerPins.samtools.reference)
    }

    func testPBAAArtifactPlannerDecidesReuseRunOrRequireExistingFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-pbaa-decision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("DL46.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("DL46.fastq")
        let preparedURL = root.appendingPathComponent("prepared.fastq")
        let guideURL = root.appendingPathComponent("guide.fasta")
        let passedURL = root.appendingPathComponent("passed.fasta")
        let provenanceURL = root.appendingPathComponent("provenance.json")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: preparedURL, atomically: true, encoding: .utf8)
        try ">guide\nACGT\n".write(to: guideURL, atomically: true, encoding: .utf8)
        try ">Cluster1_ReadCount-5\nACGT\n".write(to: passedURL, atomically: true, encoding: .utf8)
        try "{\"workflow\":\"pbaa\"}\n".write(to: provenanceURL, atomically: true, encoding: .utf8)
        let signature = try FASTQPBAAArtifactSignature(
            sourceFASTQ: .fingerprint(url: bundleURL, displayPath: bundleURL.path),
            preparedReads: .fingerprint(url: preparedURL, displayPath: preparedURL.path),
            guide: .fingerprint(url: guideURL, displayPath: guideURL.path),
            preprocessing: FASTQPBAAPreprocessingSignature(
                orientReference: nil,
                forwardPrimer: nil,
                reversePrimer: nil,
                minimumLength: 2_000,
                maximumLength: 4_000
            ),
            clustering: FASTQPBAAClusteringSignature(
                pbaaToolVersion: "1.2.0",
                workflowSchemaVersion: "pbaa-cluster/1",
                seed: 1984,
                extraArguments: [],
                extraArgumentsText: "",
                pbaaContainerReference: "pbaa",
                pbaaContainerExpectedDigest: "sha256:pbaa",
                samtoolsContainerReference: "samtools",
                samtoolsContainerExpectedDigest: "sha256:samtools"
            )
        )
        let stored = try FASTQPBAAArtifactStore.saveArtifact(
            FASTQPBAAArtifactWriteRequest(
                bundleURL: bundleURL,
                id: "compatible",
                displayName: "DL46 pbAA",
                sampleName: "DL46",
                signature: signature,
                passedConsensusFASTAURL: passedURL,
                rawOutputDirectoryURL: nil,
                provenanceURL: provenanceURL,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )

        XCTAssertEqual(
            try FullLengthONTPBAAArtifactPlanner.decision(
                inputURL: bundleURL,
                signature: signature,
                mode: .useCompatible
            ),
            .reuse(stored)
        )
        XCTAssertEqual(
            try FullLengthONTPBAAArtifactPlanner.decision(
                inputURL: bundleURL,
                signature: signature,
                mode: .rerunAll
            ),
            .runAndSave
        )

        let emptyBundleURL = root.appendingPathComponent("empty.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundleURL, withIntermediateDirectories: true)
        do {
            _ = try FullLengthONTPBAAArtifactPlanner.decision(
                inputURL: emptyBundleURL,
                signature: signature,
                mode: .requireExisting
            )
            XCTFail("Expected require-existing to fail when no compatible artifact exists")
        } catch FullLengthONTPBAAArtifactPlanner.Error.missingCompatibleArtifact(let path) {
            XCTAssertEqual(path, emptyBundleURL.standardizedFileURL.path)
        }
    }

    func testMaterializingGzippedFASTQBundleWritesPlainFASTQ() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-gzip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let gzipURL = bundle.appendingPathComponent("sample.fastq.gz")
        let outputURL = root.appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.writeGzip(
            """
            @r1
            ACGT
            +
            IIII
            @r2
            TGCA
            +
            JJJJ

            """,
            to: gzipURL
        )

        try FullLengthONTMHCFASTQMaterializer.materializePlainFASTQ(
            inputURL: bundle,
            outputURL: outputURL
        )

        let materialized = try Data(contentsOf: outputURL)
        XCTAssertFalse(
            materialized.starts(with: Data([0x1f, 0x8b])),
            "The workflow must hand BBTools plain FASTQ, not gzip bytes."
        )
        XCTAssertEqual(
            String(data: materialized, encoding: .utf8),
            """
            @r1
            ACGT
            +
            IIII
            @r2
            TGCA
            +
            JJJJ

            """
        )
    }

    func testClusterGenotyperKeepsBestZeroSNPAllelesAndCarriesPBAAReadCounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try """
        >Cluster1_ReadCount-12
        ACGT
        >Cluster2_ReadCount-6
        TTTT
        """.write(to: clusters, atomically: true, encoding: .utf8)
        try """
        >Mamu-A1*001
        ACGT
        >Mamu-A1*002
        ACGT
        >Mamu-B*001
        TTTT
        """.write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        @SQ\tSN:Cluster1_ReadCount-12\tLN:4
        @SQ\tSN:Cluster2_ReadCount-6\tLN:4
        Mamu-A1*001\t0\tCluster1_ReadCount-12\t1\t60\t4=\t*\t0\t0\tACGT\t*
        Mamu-A1*002\t0\tCluster1_ReadCount-12\t1\t60\t3=1I\t*\t0\t0\tACGT\t*
        Mamu-B*001\t0\tCluster2_ReadCount-6\t1\t60\t3=1X\t*\t0\t0\tTTTT\t*
        """

        let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
            sampleID: "NB13",
            clustersFASTAURL: clusters,
            referenceFASTAURL: reference,
            samText: sam,
            cdnaThreshold: 2_000,
            minUnmatchedReads: 5
        )

        XCTAssertEqual(summary.rows, [
            FullLengthONTMHCClusterGenotypeRow(
                sample: "NB13",
                cluster: "Cluster1_ReadCount-12",
                clusterReads: 12,
                allele: "Mamu-A1*001",
                alleleLength: 4,
                alignedBases: 4,
                score: 4
            ),
        ])
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["Cluster2_ReadCount-6"])
        XCTAssertEqual(summary.unmatchedClusters.map(\.readCount), [6])

        let reportRows = FullLengthONTMHCClusterReportBuilder.reportRows(
            genotypeRows: summary.rows,
            sampleReadCounts: ["NB13": 100]
        )
        XCTAssertEqual(reportRows.map(\.sample), ["NB13"])
        XCTAssertEqual(reportRows.map(\.genotype), ["Mamu-A1*001"])
        XCTAssertEqual(reportRows.map(\.passedUniqueReads), [12])
        XCTAssertEqual(reportRows.map(\.passedAlignments), [12])
    }

    func testReportRowsConsolidateMultipleClustersMatchingSameAllele() {
        let genotypeRows = [
            FullLengthONTMHCClusterGenotypeRow(
                sample: "32286-002_DL47",
                cluster: "Cluster0_ReadCount-26",
                clusterReads: 26,
                allele: "Mamu-A1*004:01:01:01",
                alleleLength: 3_092,
                alignedBases: 3_092,
                score: 3_092
            ),
            FullLengthONTMHCClusterGenotypeRow(
                sample: "32286-002_DL47",
                cluster: "Cluster1_ReadCount-8",
                clusterReads: 8,
                allele: "Mamu-A1*004:01:01:01",
                alleleLength: 3_092,
                alignedBases: 3_092,
                score: 3_092
            ),
        ]

        let reportRows = FullLengthONTMHCClusterReportBuilder.reportRows(
            genotypeRows: genotypeRows,
            sampleReadCounts: ["32286-002_DL47": 1_966]
        )

        XCTAssertEqual(reportRows.count, 1)
        XCTAssertEqual(reportRows[0].sample, "32286-002_DL47")
        XCTAssertEqual(reportRows[0].genotype, "Mamu-A1*004:01:01:01")
        XCTAssertEqual(reportRows[0].passedAlignments, 34)
        XCTAssertEqual(reportRows[0].passedUniqueReads, 34)
    }

    func testXLSXPackageWriterDoesNotIncludeTempMetadataAndWritesUnmatchedSheet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workbookURL = root.appendingPathComponent("genotypes.xlsx")

        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: [
                .init(name: "Genotypes", rows: [["sample", "genotype"], ["DL47", "Mamu-A1*004:01:01:01"]]),
                .init(name: "Samples", rows: [["sample", "total_input_reads"], ["DL47", "1966"]]),
                .init(name: "Cluster Alignments", rows: [["sample", "cluster"], ["DL47", "Cluster0"]]),
                .init(name: "Unmatched Clusters", rows: [["sample", "cluster", "sequence"], ["DL47", "Cluster9", "ACGT"]]),
            ],
            to: workbookURL
        )

        let entries = try Self.zipEntries(workbookURL)
        XCTAssertFalse(entries.contains(".lungfish-temp-origin.json"))
        XCTAssertTrue(entries.contains("[Content_Types].xml"))
        XCTAssertTrue(entries.contains("xl/worksheets/sheet4.xml"))

        let workbookXML = try Self.unzippedText(path: "xl/workbook.xml", from: workbookURL)
        XCTAssertTrue(workbookXML.contains("Unmatched Clusters"))
        XCTAssertTrue(workbookXML.contains("Cluster Alignments"))
    }

    func testClusterGenotyperReadsGzippedFASTARecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-reference-gzip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reference = root.appendingPathComponent("sequence.fa.gz")
        try Self.writeGzip(
            """
            >Mamu-A1*001 description
            ACGT
            TGCA
            >Mamu-B*007
            TTTT

            """,
            to: reference
        )

        let records = try FullLengthONTMHCClusterGenotyper.readFASTARecords(from: reference)

        XCTAssertEqual(records.map(\.name), ["Mamu-A1*001", "Mamu-B*007"])
        XCTAssertEqual(records.map(\.sequence), ["ACGTTGCA", "TTTT"])
    }

    private static func writeGzip(_ content: String, to gzipURL: URL) throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gzip-source-\(UUID().uuidString).fastq")
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", sourceURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let compressed = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "gzip failed"
            throw NSError(
                domain: "FullLengthONTMHCGenotypingPipelineTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        try compressed.write(to: gzipURL)
    }

    private static func zipEntries(_ url: URL) throws -> [String] {
        let output = try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", url.path]
        )
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func unzippedText(path: String, from url: URL) throws -> String {
        try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-p", url.path, path]
        )
    }

    private static func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "\(executable) failed"
            throw NSError(
                domain: "FullLengthONTMHCGenotypingPipelineTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
