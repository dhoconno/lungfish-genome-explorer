import Foundation
import Darwin
import SQLite3
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCGenotypingPipelineTests: XCTestCase {
    func testLungfishReferenceRecordStoreImportHasActualInputsCommandAndTiming() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-record-store-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("annotated.lungfishref", isDirectory: true)
        let genomeDirectory = bundle.appendingPathComponent("genome", isDirectory: true)
        let metadataDirectory = bundle.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let fastaURL = genomeDirectory.appendingPathComponent("reference.fasta")
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let databaseURL = metadataDirectory.appendingPathComponent("records.sqlite")
        try ">record-1 fallback-description\nACGTACGT\n".write(
            to: fastaURL, atomically: true, encoding: .utf8
        )
        let manifest = BundleManifest(
            name: "Annotated MHC Reference",
            identifier: "org.lungfish.tests.annotated-mhc",
            source: SourceInfo(organism: "Macaca fascicularis", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/reference.fasta",
                indexPath: "genome/reference.fasta.fai",
                totalLength: 8,
                chromosomes: [
                    ChromosomeInfo(name: "record-1", length: 8, offset: 10, lineBases: 8, lineWidth: 9)
                ]
            )
        )
        try manifest.save(to: bundle)
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifestObject["record_store"] = ["database_path": "metadata/records.sqlite"]
        try JSONSerialization.data(withJSONObject: manifestObject, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("Could not create SQLite record store") }
        let schemaAndRows = """
        CREATE TABLE records (id INTEGER PRIMARY KEY, sequence_name TEXT NOT NULL UNIQUE, sequence_length INTEGER NOT NULL, source_ordinal INTEGER NOT NULL);
        CREATE TABLE field_values (record_id INTEGER NOT NULL, field_key TEXT NOT NULL, value_ordinal INTEGER NOT NULL, value TEXT NOT NULL, PRIMARY KEY (record_id, field_key, value_ordinal));
        INSERT INTO records VALUES (1, 'record-1', 8, 0);
        INSERT INTO field_values VALUES (1, 'feature.allele', 0, 'Mafa-A1*018:01:01:01');
        INSERT INTO field_values VALUES (1, 'feature.gene', 0, 'A1');
        INSERT INTO field_values VALUES (1, 'feature.mol_type', 0, 'genomic DNA');
        """
        var sqliteError: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(database, schemaAndRows, nil, nil, &sqliteError), SQLITE_OK)
        if let sqliteError {
            defer { sqlite3_free(sqliteError) }
            XCTFail(String(cString: sqliteError))
        }
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            referenceSourceURL: bundle
        )
        _ = try await pipeline.run(request)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        let imports = envelope.steps.filter {
            $0.toolName == "lungfish-in-process:import-mhc-reference-catalog"
        }
        let step = try XCTUnwrap(imports.first)
        XCTAssertEqual(imports.count, 1, "The writer must not synthesize a second catalog import.")
        XCTAssertEqual(Set(step.inputs.map(\.path)), Set([
            fastaURL.path, manifestURL.path, databaseURL.path,
        ]))
        for input in step.inputs {
            XCTAssertNotNil(input.checksumSHA256)
            XCTAssertNotNil(input.fileSize)
        }
        XCTAssertEqual(value(after: "--reference-fasta", in: step.argv), fastaURL.path)
        XCTAssertEqual(value(after: "--reference-bundle-manifest", in: step.argv), manifestURL.path)
        XCTAssertEqual(value(after: "--record-store", in: step.argv), databaseURL.path)
        XCTAssertEqual(value(after: "--cdna-threshold", in: step.argv), "2000")
        XCTAssertNotNil(step.startedAt)
        XCTAssertNotNil(step.completedAt)
        XCTAssertGreaterThanOrEqual(step.wallTimeSeconds ?? -1, 0)
        let projectionURL = try XCTUnwrap(step.outputs.first).path
        XCTAssertTrue(projectionURL.hasPrefix(request.outputDirectory.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectionURL))
        XCTAssertNotNil(step.outputs.first?.checksumSHA256)
        let projection = try JSONDecoder().decode(
            FullLengthONTMHCReferenceCatalogProjection.self,
            from: Data(contentsOf: URL(fileURLWithPath: projectionURL))
        )
        XCTAssertEqual(projection.records.first?.alleleName, "Mafa-A1*018:01:01:01")
        XCTAssertEqual(projection.records.first?.classEvidence, .annotatedMetadata)
    }

    func testLungfishReferenceBundleUsesMHCMetadataCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-reference-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fasta = bundle.appendingPathComponent("genome.fasta")
        try ">record-1 Mafa-A1*018:01:01:01\nACGT\n".write(to: fasta, atomically: true, encoding: .utf8)
        try #"{"genome":{"path":"genome.fasta"}}"#.write(
            to: bundle.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let records = try FullLengthONTMHCGenotypingPipeline().mhcReferenceRecords(
            sourceURL: bundle,
            fastaURL: fasta,
            cdnaThreshold: 2_000
        )

        XCTAssertEqual(records.map(\.alleleName), ["Mafa-A1*018:01:01:01"])
        XCTAssertEqual(records.map(\.locus), ["Mafa-A1"])
        XCTAssertEqual(records.map(\.classEvidence), [.lengthThresholdFallback])
        XCTAssertEqual(
            try FullLengthONTMHCGenotypingPipeline().mhcReferenceCatalogInputURLs(
                sourceURL: bundle,
                fastaURL: fasta
            ),
            [fasta, bundle.appendingPathComponent("manifest.json")]
        )
    }

    func testGenotypingResultDecodesLegacyPayloadWithoutCohortEvidencePaths() throws {
        let data = Data(
            #"""
            {
              "outputDirectory": "file:///tmp/legacy.lungfishgenotype/",
              "reportCSVURL": "file:///tmp/legacy.csv",
              "sampleSummaryCSVURL": "file:///tmp/legacy-samples.csv",
              "statsJSONURL": "file:///tmp/legacy-stats.json",
              "workbookURL": "file:///tmp/current.xlsx",
              "primaryWorkbookURL": "file:///tmp/primary.xlsx",
              "unmatchedClustersFASTAURL": "file:///tmp/unmatched.fasta",
              "deduplicatedUnmatchedClustersFASTAURL": "file:///tmp/deduplicated.fasta",
              "cdnaClustersFASTAURL": "file:///tmp/cdna.fasta",
              "provenanceURL": "file:///tmp/provenance.json",
              "referenceFASTAURL": "file:///tmp/reference.fasta"
            }
            """#.utf8
        )

        let result = try JSONDecoder().decode(FullLengthONTMHCGenotypingResult.self, from: data)

        XCTAssertNil(result.genotypingEvidenceBAMURL)
        XCTAssertNil(result.genotypingEvidenceBAIURL)
        XCTAssertEqual(result.cleanupWarnings, [])
    }

    func testBatchSchedulerUsesThreeSampleJobsAndThreeSavontThreadsOnFourteenCoreBatch() {
        let plan = FullLengthONTMHCSampleExecutionPlan.automatic(
            totalThreads: 14,
            sampleCount: 48,
            requestedSampleJobs: nil,
            requestedSavontThreadsPerSample: nil
        )

        XCTAssertEqual(plan.sampleJobs, 3)
        XCTAssertEqual(plan.savontThreadsPerSample, 3)
        XCTAssertEqual(plan.workerThreadsPerSample, 4)
    }

    func testSingleSampleSchedulerKeepsAllThreadsForSavont() {
        let plan = FullLengthONTMHCSampleExecutionPlan.automatic(
            totalThreads: 14,
            sampleCount: 1,
            requestedSampleJobs: nil,
            requestedSavontThreadsPerSample: nil
        )

        XCTAssertEqual(plan.sampleJobs, 1)
        XCTAssertEqual(plan.savontThreadsPerSample, 14)
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
            orientReferenceURL: orientURL,
            forwardPrimerURL: forwardURL,
            reversePrimerURL: reverseURL,
            outputDirectory: root.appendingPathComponent("out.lungfishgenotype", isDirectory: true),
            minimumLength: 2_100,
            maximumLength: 3_900
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

    func testSavontClusterNormalizerAddsReadCountFromDepthHeaders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-savont-normalize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("final_asvs.fasta")
        let outputURL = root.appendingPathComponent("savont-clusters.fasta")
        try """
        >final_consensus_0_depth_71
        ACGT
        >already_ReadCount-12
        TGCA
        >no_depth_header
        CCCC

        """.write(to: inputURL, atomically: true, encoding: .utf8)

        try FullLengthONTMHCSavontClusterNormalizer.normalize(
            savontFinalASVFASTAURL: inputURL,
            outputFASTAURL: outputURL
        )

        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8),
            """
            >final_consensus_0_depth_71_ReadCount-71
            ACGT
            >already_ReadCount-12
            TGCA
            >no_depth_header_ReadCount-0
            CCCC

            """
        )
    }

    func testSavontRunSupportKeepsFinalASVAndLogsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-savont-scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratchRaw = root.appendingPathComponent("scratch/raw", isDirectory: true)
        let scratchTemp = scratchRaw.appendingPathComponent("temp", isDirectory: true)
        let finalRaw = root.appendingPathComponent("bundle/sample/savont/raw", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchTemp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finalRaw, withIntermediateDirectories: true)
        try ">final_consensus_0_depth_5\nACGT\n".write(
            to: scratchRaw.appendingPathComponent("final_asvs.fasta"),
            atomically: true,
            encoding: .utf8
        )
        try "temporary detail\n".write(
            to: scratchRaw.appendingPathComponent("savont.log"),
            atomically: true,
            encoding: .utf8
        )
        try "timestamped detail\n".write(
            to: scratchRaw.appendingPathComponent("savont_2026-06-10_05-09-37.log"),
            atomically: true,
            encoding: .utf8
        )
        try "regenerable table\n".write(
            to: scratchRaw.appendingPathComponent("feature-table.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try "regenerable temp\n".write(
            to: scratchTemp.appendingPathComponent("read_to_asv_mappings.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try "stale\n".write(
            to: finalRaw.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )

        try FullLengthONTMHCSavontRunSupport.materializeCompletedRawOutput(
            from: scratchRaw,
            to: finalRaw
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalRaw.appendingPathComponent("final_asvs.fasta").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalRaw.appendingPathComponent("savont.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalRaw.appendingPathComponent("savont_2026-06-10_05-09-37.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalRaw.appendingPathComponent("feature-table.tsv").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalRaw.appendingPathComponent("temp", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalRaw.appendingPathComponent("stale.txt").path))
    }

    func testRunRemovesRegenerableWorkflowIntermediatesButKeepsSavontLogs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let condaRoot = CoreToolLocator.condaRoot(homeDirectory: homeDirectory)
        let bundledMicromamba = try makeFakeFullLengthCondaRoot(at: condaRoot)
        let inputFASTQ = root.appendingPathComponent("DL46.fastq")
        let referenceFASTA = root.appendingPathComponent("reference.fasta")
        let outputDirectory = root.appendingPathComponent("full-length.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "@read-1\nACGTACGT\n+\nIIIIIIII\n".write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try ">allele1\nACGTACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)

        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [inputFASTQ],
            referenceSourceURL: referenceFASTA,
            outputDirectory: outputDirectory,
            outputName: "full-length",
            threads: 2,
            minimumLength: 4,
            maximumLength: 12
        )
        let pipeline = FullLengthONTMHCGenotypingPipeline(
            nativeToolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory),
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        )

        let result = try await pipeline.run(request)

        let evidenceBAMURL = outputDirectory
            .appendingPathComponent("artifacts/alignments/genotyping-evidence.bam")
        let evidenceBAIURL = outputDirectory
            .appendingPathComponent("artifacts/alignments/genotyping-evidence.bam.bai")
        XCTAssertEqual(result.genotypingEvidenceBAMURL, evidenceBAMURL)
        XCTAssertEqual(result.genotypingEvidenceBAIURL, evidenceBAIURL)
        XCTAssertEqual(result.cleanupWarnings, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceBAMURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceBAIURL.path))

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: outputDirectory)
        let evidence = try XCTUnwrap(manifest.mhcCandidateArtifacts?.genotypingEvidence)
        XCTAssertEqual(evidence.bam.path, "artifacts/alignments/genotyping-evidence.bam")
        XCTAssertEqual(evidence.bai.path, "artifacts/alignments/genotyping-evidence.bam.bai")
        XCTAssertEqual(evidence.bam.sha256, try ProvenanceFileHasher.sha256(of: evidenceBAMURL))
        XCTAssertEqual(evidence.bai.sha256, try ProvenanceFileHasher.sha256(of: evidenceBAIURL))
        XCTAssertEqual(evidence.bam.sizeBytes, Int64(try ProvenanceFileHasher.fileSize(of: evidenceBAMURL)))
        XCTAssertEqual(evidence.bai.sizeBytes, Int64(try ProvenanceFileHasher.fileSize(of: evidenceBAIURL)))
        let reciprocal = try XCTUnwrap(manifest.mhcCandidateArtifacts?.reciprocalEvidence)
        XCTAssertEqual(reciprocal.bam.path, "artifacts/alignments/unmatched-to-reference.bam")
        XCTAssertEqual(reciprocal.bai.path, "artifacts/alignments/unmatched-to-reference.bam.bai")
        let candidateJSON = try XCTUnwrap(manifest.mhcCandidateArtifacts?.candidateJSON)
        XCTAssertEqual(candidateJSON.path, "candidate-alleles.json")
        let candidateDocument = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: outputDirectory.appendingPathComponent(candidateJSON.path))
        )
        XCTAssertEqual(candidateDocument.inputs.map(\.path), [
            referenceFASTA.path,
            "deduplicated_unmatched_clusters.fasta",
        ])
        for reference in [
            reciprocal.bam, reciprocal.bai, candidateJSON,
            try XCTUnwrap(manifest.mhcCandidateArtifacts?.candidateFASTA),
            try XCTUnwrap(manifest.mhcCandidateArtifacts?.unnameableJSON),
            try XCTUnwrap(manifest.mhcCandidateArtifacts?.unnameableFASTA),
        ] {
            let url = outputDirectory.appendingPathComponent(reference.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(reference.sha256, try ProvenanceFileHasher.sha256(of: url))
            XCTAssertEqual(reference.sizeBytes, Int64(try ProvenanceFileHasher.fileSize(of: url)))
        }

        let report = try String(contentsOf: request.reportCSVURL, encoding: .utf8)
        XCTAssertTrue(report.contains("DL46,allele1,7,7,1,7"))

        let workflowDirectory = outputDirectory.appendingPathComponent("workflow", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workflowDirectory.path),
            "Regenerable full-length ONT MHC workflow intermediates should be removed after provenance is written."
        )
        let cohortWorkDirectory = outputDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputDirectory.lastPathComponent).cohort-alignment-work")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cohortWorkDirectory.path),
            "Regenerable cohort alignment intermediates should be removed after provenance is written."
        )
        let candidateWorkDirectory = outputDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputDirectory.lastPathComponent).candidate-artifact-work")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: candidateWorkDirectory.path),
            "Regenerable candidate alignment intermediates should be removed after provenance is written."
        )
        let savontDirectory = outputDirectory
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent("DL46", isDirectory: true)
            .appendingPathComponent("savont", isDirectory: true)
        let rawDirectory = savontDirectory.appendingPathComponent("raw", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savontDirectory.appendingPathComponent("DL46.savont-clusters.fasta").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawDirectory.appendingPathComponent("final_asvs.fasta").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawDirectory.appendingPathComponent("savont_2026-06-10_05-09-37.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawDirectory.appendingPathComponent("temp", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawDirectory.appendingPathComponent("feature-table.tsv").path))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        let mergeStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "samtools" && $0.argv.dropFirst().first == "merge"
        })
        XCTAssertTrue(mergeStep.argv.contains("-f"))
        let viewStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "samtools" && Array($0.argv.dropFirst().prefix(2)) == ["view", "-h"]
        })
        XCTAssertEqual(viewStep.inputs.map(\.path), [evidenceBAMURL.path])
        XCTAssertEqual(viewStep.argv.last, evidenceBAMURL.path)
        XCTAssertEqual(viewStep.toolVersion, "samtools 1.21-fake")
        let publicationStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "lungfish-internal publish-alignment-directory"
        })
        XCTAssertEqual(Array(publicationStep.argv.prefix(4)), [
            "lungfish-internal", "publish-alignment-directory", "--mode", "create",
        ])
        XCTAssertTrue(publicationStep.argv[4].contains(".alignments-replacement-"))
        XCTAssertEqual(publicationStep.argv[5], evidenceBAMURL.deletingLastPathComponent().path)
        XCTAssertEqual(publicationStep.exitStatus, 0)
        XCTAssertEqual(publicationStep.inputs.count, 2)
        XCTAssertEqual(publicationStep.outputs.map(\.path).sorted(), [
            evidenceBAIURL.path,
            evidenceBAMURL.path,
        ].sorted())
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(publicationStep.wallTimeSeconds), 0)
        XCTAssertNotNil(publicationStep.startedAt)
        XCTAssertNotNil(publicationStep.completedAt)
        XCTAssertFalse(publicationStep.argv.contains("--atomic-directory-exchange"))
        XCTAssertTrue(envelope.outputs.contains { $0.path == evidenceBAMURL.path })
        XCTAssertTrue(envelope.outputs.contains { $0.path == evidenceBAIURL.path })
        XCTAssertFalse(
            envelope.outputs.contains { $0.path.contains("/workflow/") },
            "Regenerable workflow intermediates must not be top-level durable provenance outputs."
        )
        let retainedLogSuffix = "/samples/DL46/savont/raw/savont_2026-06-10_05-09-37.log"
        XCTAssertTrue(
            envelope.outputs.contains { $0.path.hasSuffix(retainedLogSuffix) },
            "Expected retained Savont log in outputs. Outputs: \(envelope.outputs.map(\.path))"
        )
        XCTAssertTrue(
            envelope.outputs.contains { $0.path.hasSuffix("/deduplicated_unmatched_clusters.fasta") },
            "Expected deduplicated unmatched FASTA in provenance outputs. Outputs: \(envelope.outputs.map(\.path))"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.deduplicatedUnmatchedClustersFASTAURL.path))
        let durableEvidenceBAMs = Set([
            "artifacts/alignments/genotyping-evidence.bam",
            "artifacts/alignments/unmatched-to-reference.bam",
        ])
        let durablePerSampleBAMs = try FileManager.default.subpathsOfDirectory(atPath: outputDirectory.path)
            .filter { $0.hasSuffix(".bam") && !durableEvidenceBAMs.contains($0) }
        XCTAssertEqual(durablePerSampleBAMs, [])

        let workbookXML = try Self.unzippedText(path: "xl/workbook.xml", from: result.workbookURL)
        XCTAssertEqual(
            Self.sheetNames(in: workbookXML),
            [
                "Interpretation Guide",
                "Samples",
                "Genotypes",
                "Genotyping pivot",
                "Unmatched Clusters",
                "Unmatched Shared Pivot",
                "MHC-like Unmatched Clusters",
                "MHC-like Unmatched Pivot",
                "Unified Genotype Pivot",
                "Candidate Alleles",
                "Un-nameable Clusters",
            ]
        )
        XCTAssertFalse(workbookXML.contains("Cluster Alignments"))
        XCTAssertFalse(workbookXML.contains("Unmatched Closest Matches"))
        XCTAssertFalse(workbookXML.contains("Full Sequencing Results 1"))

        let guideSheetXML = try Self.unzippedText(path: "xl/worksheets/sheet1.xml", from: result.workbookURL)
        XCTAssertTrue(guideSheetXML.contains("Full-length ONT MHC genotyping"))
        XCTAssertTrue(guideSheetXML.contains("score = aligned_bases - (100 * snp_differences) - (10 * indel_bases)"))
        XCTAssertTrue(guideSheetXML.contains(
            "Known genotype calls require zero SNP differences. Indel-only genomic-reference alignments remain calls to the existing allele; true genomic extensions of cDNA references are classified separately with the _ext suffix."
        ))
        XCTAssertTrue(guideSheetXML.contains("Cluster-level known genotype evidence."))
        XCTAssertFalse(guideSheetXML.contains("zero SNP differences and zero indel bases"))
        XCTAssertTrue(guideSheetXML.contains("Blank closest-match fields mean the unmatched cluster had no mapped SAM hit."))
        XCTAssertTrue(guideSheetXML.contains("MHC-like unmatched rescue"))
        XCTAssertTrue(guideSheetXML.contains("local-blast-rescue"))

        let samplesSheetXML = try Self.unzippedText(path: "xl/worksheets/sheet2.xml", from: result.workbookURL)
        XCTAssertTrue(samplesSheetXML.contains("sample_unique_retained_percent"))
        XCTAssertTrue(samplesSheetXML.contains("overall_unique_retained_percent"))

        let genotypesSheetXML = try Self.unzippedText(path: "xl/worksheets/sheet3.xml", from: result.workbookURL)
        XCTAssertTrue(genotypesSheetXML.contains("genotype"))
        XCTAssertTrue(genotypesSheetXML.contains("cluster"))
        XCTAssertTrue(genotypesSheetXML.contains("allele_length"))
        XCTAssertTrue(genotypesSheetXML.contains("aligned_bases"))
        XCTAssertFalse(genotypesSheetXML.contains("overall_unique_retained_percent"))

        let pivotSheetXML = try Self.unzippedText(path: "xl/worksheets/sheet4.xml", from: result.workbookURL)
        XCTAssertTrue(pivotSheetXML.contains("Client ID"))
        for sheetNumber in 5...8 {
            let unmatchedXML = try Self.unzippedText(
                path: "xl/worksheets/sheet\(sheetNumber).xml",
                from: result.workbookURL
            )
            XCTAssertFalse(unmatchedXML.contains("_extension"), "Legacy extension label leaked into sheet \(sheetNumber)")
            XCTAssertNil(
                unmatchedXML.range(of: #"_[0-9]+SNP"#, options: .regularExpression),
                "Legacy SNP label leaked into sheet \(sheetNumber)"
            )
        }
        let candidateSheetXML = try Self.unzippedText(path: "xl/worksheets/sheet10.xml", from: result.workbookURL)
        XCTAssertTrue(candidateSheetXML.contains("Stable Cluster ID"))
        XCTAssertTrue(candidateSheetXML.contains("Provisional Name"))
        let unnameableSheetXML = try Self.unzippedText(path: "xl/worksheets/sheet11.xml", from: result.workbookURL)
        XCTAssertTrue(unnameableSheetXML.contains("Stable Cluster ID"))
        XCTAssertTrue(unnameableSheetXML.contains("Reason"))
        XCTAssertTrue(try Self.unzippedText(path: "xl/styles.xml", from: result.workbookURL).contains("FFFFE0B2"))
    }

    func testRunRetriesStrictNoClusterSampleWithHiddenQV90MinClusterOneFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-fallback-rescue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let savontScript = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "savont 0.5.0"
          exit 0
        fi
        shift
        input="$1"
        shift
        output=""
        qv=""
        min_cluster=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) output="$2"; shift 2 ;;
            --quality-value-cutoff) qv="$2"; shift 2 ;;
            --min-cluster-size) min_cluster="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        mkdir -p "$output"
        printf 'qv=%s min_cluster=%s input=%s\n' "$qv" "$min_cluster" "$input" > "$output/savont.log"
        if [ "$qv" = "90" ] && [ "$min_cluster" = "3" ]; then
          : > "$output/final_asvs.fasta"
          exit 0
        fi
        if [ "$qv" = "90" ] && [ "$min_cluster" = "1" ]; then
          cat > "$output/final_asvs.fasta" <<'EOF'
        >final_consensus_0_depth_7
        ACGTACGT
        EOF
          exit 0
        fi
        echo "unexpected Savont preset qv=$qv min_cluster=$min_cluster" >&2
        exit 2
        """#
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            savontScript: savontScript
        )

        _ = try await pipeline.run(request)

        let report = try String(contentsOf: request.reportCSVURL, encoding: .utf8)
        XCTAssertTrue(report.contains("DL46,allele1,7,7,1,7"))

        let sampleSummary = try String(contentsOf: request.sampleSummaryCSVURL, encoding: .utf8)
        XCTAssertTrue(sampleSummary.contains("savont_preset,savont_status,savont_fallback_reason"))
        XCTAssertTrue(sampleSummary.contains("fallback-qv90-min1,called,strict-no-clusters"))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        let savontSteps = envelope.steps.filter { $0.toolName == "savont" }
        XCTAssertEqual(savontSteps.count, 2)
        XCTAssertTrue(savontSteps.contains { value(after: "--min-cluster-size", in: $0.argv) == "3" })
        XCTAssertTrue(savontSteps.contains { value(after: "--min-cluster-size", in: $0.argv) == "1" })
        XCTAssertTrue(savontSteps.allSatisfy { value(after: "--quality-value-cutoff", in: $0.argv) == "90" })
        XCTAssertFalse(savontSteps.contains { value(after: "--quality-value-cutoff", in: $0.argv) == "0" })
    }

    func testRunReusesCompatibleSampleCheckpointWithoutRerunningSavont() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-checkpoint-reuse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (baseRequest, firstPipeline) = try makeFakeFullLengthRun(root: root)
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: baseRequest.inputFASTQURLs,
            referenceSourceURL: baseRequest.referenceSourceURL,
            outputDirectory: baseRequest.outputDirectory,
            outputName: baseRequest.outputName,
            threads: baseRequest.threads,
            minimumLength: baseRequest.minimumLength,
            maximumLength: baseRequest.maximumLength,
            reuseCompatibleCheckpoints: true
        )

        _ = try await firstPipeline.run(request)

        let checkpointURL = request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc/checkpoints/samples", isDirectory: true)
            .appendingPathComponent("DL46.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
        let checkpointObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
        )
        let checkpointResult = try XCTUnwrap(checkpointObject["result"] as? [String: Any])
        XCTAssertEqual((checkpointResult["genotypeRows"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(checkpointResult["clustersFASTAURL"])
        XCTAssertNotNil(checkpointResult["clusterRecords"])

        let failingSavontScript = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "savont 0.5.0"
          exit 0
        fi
        echo "SavONT should not run when the sample checkpoint is compatible" >&2
        exit 77
        """#
        let (_, secondPipeline) = try makeFakeFullLengthRun(
            root: root,
            savontScript: failingSavontScript
        )

        _ = try await secondPipeline.run(request)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        let savontSteps = envelope.steps.filter { $0.toolName == "savont" }
        XCTAssertEqual(savontSteps.count, 1)
        let minimapMappingSteps = envelope.steps.filter {
            $0.toolName == "minimap2" && $0.argv.contains("-a")
        }
        XCTAssertEqual(minimapMappingSteps.count, 2, "Checkpoint reuse must remap retained clusters and candidates.")
        XCTAssertEqual(minimapMappingSteps.filter { $0.argv.contains("splice") }.count, 1)
        XCTAssertEqual(minimapMappingSteps.filter { $0.argv.contains("asm20") }.count, 1)
        let reuseStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "lungfish full-length ONT MHC sample checkpoint reuse"
        })
        XCTAssertTrue(reuseStep.inputs.contains { $0.path == checkpointURL.path })
        XCTAssertTrue(reuseStep.outputs.contains {
            $0.path.hasSuffix("/samples/DL46/savont/DL46.savont-clusters.fasta")
        })
    }

    func testFinalBAMViewFailureLeavesNoSuccessfulMetadataAndRetainsDiagnosticBAMs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-final-view-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            failFinalBAMView: true
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected final BAM view failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("forced final BAM view failure"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path))
        let cohortWorkDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.contains(".run-staging-")
                    && $0.lastPathComponent.hasSuffix(".cohort-alignment-work")
            }
        )
        let retainedBAMs = try FileManager.default.subpathsOfDirectory(atPath: cohortWorkDirectory.path)
            .filter { $0.hasSuffix(".bam") }
        XCTAssertFalse(retainedBAMs.isEmpty, "Final-view failure must retain per-sample BAM diagnostics.")
    }

    func testInjectedFailureAfterProvenanceLeavesNoVisibleSuccessManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-manifest-crash-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let observation = MetadataPublicationObservation(failAfterProvenance: true)
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: observation.observe
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected injected metadata publication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected post-provenance failure"), error.localizedDescription)
        }

        XCTAssertTrue(observation.observedProvenanceBoundary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path))
        let stagedManifestURL = try XCTUnwrap(observation.stagedManifestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedManifestURL.path))
    }

    func testFailureAfterDirectorySwapRollsBackPriorBundleBeforeSuccessManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-post-swap-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (initialRequest, initialPipeline) = try makeFakeFullLengthRun(root: root)
        _ = try await initialPipeline.run(initialRequest)
        let priorSnapshot = try directoryFileSnapshot(initialRequest.outputDirectory)

        let (replacementRequest, replacementPipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: { event in
                guard case .resultBundlePublishedBeforeReceipt = event else { return }
                throw InjectedPostSwapFailure()
            }
        )
        do {
            _ = try await replacementPipeline.run(replacementRequest)
            XCTFail("Expected injected post-swap failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected post-swap failure"))
        }

        XCTAssertEqual(try directoryFileSnapshot(replacementRequest.outputDirectory), priorSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementRequest.manifestURL.path))
    }

    func testFailedReplacementAfterCandidateAndProvenanceWorkLeavesPriorBundleByteForByteUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-atomic-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, initialPipeline) = try makeFakeFullLengthRun(root: root)
        _ = try await initialPipeline.run(request)

        let bundleBefore = try directoryFileSnapshot(request.outputDirectory)

        let (_, failingPipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: { event in
                guard case .provenanceWrittenBeforeManifestPublication = event else { return }
                throw NSError(domain: "injected-replacement", code: 19)
            }
        )
        do {
            _ = try await failingPipeline.run(request)
            XCTFail("Expected injected replacement failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "injected-replacement")
        }

        XCTAssertEqual(try directoryFileSnapshot(request.outputDirectory), bundleBefore)
    }

    func testFailureImmediatelyAfterCandidateArtifactsLeavesNoVisibleResultBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-post-candidate-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: { event in
                guard case .candidateArtifactsStaged = event else { return }
                throw NSError(domain: "injected-post-candidate", code: 23)
            }
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected injected post-candidate failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "injected-post-candidate")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path))
    }

    func testResultPublicationRejectsSpecialFilesystemEntriesInsteadOfSkippingThem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-special-payload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: { event in
                guard case .candidateArtifactsStaged(let outputDirectoryURL) = event else { return }
                let fifoURL = outputDirectoryURL.appendingPathComponent("unsupported.fifo")
                guard Darwin.mkfifo(fifoURL.path, S_IRUSR | S_IWUSR) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected special staged payload rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsupported filesystem entry"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("unsupported.fifo"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path))
    }

    func testCancellationImmediatelyAfterCandidateArtifactsLeavesPriorBundleByteForByteUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-post-candidate-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, initialPipeline) = try makeFakeFullLengthRun(root: root)
        _ = try await initialPipeline.run(request)
        let bundleBefore = try directoryFileSnapshot(request.outputDirectory)
        let (_, cancellingPipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: { event in
                guard case .candidateArtifactsStaged = event else { return }
                throw CancellationError()
            }
        )

        do {
            _ = try await cancellingPipeline.run(request)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertEqual(try directoryFileSnapshot(request.outputDirectory), bundleBefore)
    }

    func testSuccessfulReplacementAtomicallyPublishesCompleteBundleAndRemovesRetiredGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-successful-atomic-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(root: root)
        _ = try await pipeline.run(request)
        let provenanceBefore = try Data(contentsOf: request.provenanceURL)
        let staleRootArtifact = request.outputDirectory.appendingPathComponent("stale-from-prior-run.txt")
        let removedSampleArtifact = request.outputDirectory
            .appendingPathComponent("samples/REMOVED", isDirectory: true)
            .appendingPathComponent("stale.txt")
        try FileManager.default.createDirectory(
            at: removedSampleArtifact.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale-root".utf8).write(to: staleRootArtifact)
        try Data("stale-sample".utf8).write(to: removedSampleArtifact)

        let result = try await pipeline.run(request)

        XCTAssertNotEqual(try Data(contentsOf: request.provenanceURL), provenanceBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRootArtifact.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedSampleArtifact.path))
        try assertSuccessfulPublishedEvidence(result: result, request: request)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: request.outputDirectory.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".run-staging-") })
    }

    func testCheckpointImportRejectsSymlinkInsteadOfCopyingPriorBundleContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-checkpoint-symlink-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (baseRequest, pipeline) = try makeFakeFullLengthRun(root: root)
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: baseRequest.inputFASTQURLs,
            referenceSourceURL: baseRequest.referenceSourceURL,
            outputDirectory: baseRequest.outputDirectory,
            outputName: baseRequest.outputName,
            threads: baseRequest.threads,
            minimumLength: baseRequest.minimumLength,
            maximumLength: baseRequest.maximumLength,
            reuseCompatibleCheckpoints: true
        )
        _ = try await pipeline.run(request)
        let checkpointURL = request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc/checkpoints/samples/DL46.json")
        let externalURL = root.appendingPathComponent("external-checkpoint.json")
        try FileManager.default.moveItem(at: checkpointURL, to: externalURL)
        try FileManager.default.createSymbolicLink(at: checkpointURL, withDestinationURL: externalURL)

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected unsafe checkpoint symlink rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checkpoint"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("regular file"), error.localizedDescription)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: request.manifestURL.path))
        XCTAssertEqual(try Data(contentsOf: externalURL), try Data(contentsOf: checkpointURL))
    }

    func testCheckpointImportRejectsFIFOWithoutOpeningIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-checkpoint-fifo-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (baseRequest, pipeline) = try makeFakeFullLengthRun(root: root)
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: baseRequest.inputFASTQURLs,
            referenceSourceURL: baseRequest.referenceSourceURL,
            outputDirectory: baseRequest.outputDirectory,
            outputName: baseRequest.outputName,
            threads: baseRequest.threads,
            minimumLength: baseRequest.minimumLength,
            maximumLength: baseRequest.maximumLength,
            reuseCompatibleCheckpoints: true
        )
        _ = try await pipeline.run(request)
        let checkpointURL = request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc/checkpoints/samples/DL46.json")
        try FileManager.default.removeItem(at: checkpointURL)
        XCTAssertEqual(Darwin.mkfifo(checkpointURL.path, S_IRUSR | S_IWUSR), 0)

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected FIFO checkpoint rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checkpoint"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("regular file"), error.localizedDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.manifestURL.path))
    }

    func testCheckpointImportRejectsIntermediateSampleDirectorySymlinkWithoutExternalMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-checkpoint-intermediate-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (baseRequest, pipeline) = try makeFakeFullLengthRun(root: root)
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: baseRequest.inputFASTQURLs,
            referenceSourceURL: baseRequest.referenceSourceURL,
            outputDirectory: baseRequest.outputDirectory,
            outputName: baseRequest.outputName,
            threads: baseRequest.threads,
            minimumLength: baseRequest.minimumLength,
            maximumLength: baseRequest.maximumLength,
            reuseCompatibleCheckpoints: true
        )
        _ = try await pipeline.run(request)
        let sampleDirectory = request.outputDirectory.appendingPathComponent("samples/DL46", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("external-sample", isDirectory: true)
        try FileManager.default.moveItem(at: sampleDirectory, to: externalDirectory)
        try FileManager.default.createSymbolicLink(at: sampleDirectory, withDestinationURL: externalDirectory)
        let externalBefore = try directoryFileSnapshot(externalDirectory)

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected intermediate sample symlink rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checkpoint"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("symlink"), error.localizedDescription)
        }
        XCTAssertEqual(try directoryFileSnapshot(externalDirectory), externalBefore)
        var info = stat()
        XCTAssertEqual(Darwin.lstat(sampleDirectory.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testRunRejectsExistingFinalOutputSymlinkWithoutExternalMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-final-symlink-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(root: root)
        let externalDirectory = root.appendingPathComponent("external-output", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let sentinel = externalDirectory.appendingPathComponent("sentinel.txt")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: request.outputDirectory,
            withDestinationURL: externalDirectory
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected final output symlink rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("final output"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("directory"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        var info = stat()
        XCTAssertEqual(Darwin.lstat(request.outputDirectory.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testRunRejectsExistingFinalOutputFileWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-final-file-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(root: root)
        let sentinel = Data("existing-file".utf8)
        try sentinel.write(to: request.outputDirectory)

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected final output file rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("final output"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("directory"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: request.outputDirectory), sentinel)
    }

    func testConcurrentSameOutputRunIsRejectedBeforeTouchingPriorResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-run-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RunLockBoundaryGate()
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: gate.observe
        )
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let priorManifest = Data("prior-manifest".utf8)
        let priorProvenance = Data("prior-provenance".utf8)
        let priorReport = Data("prior-report".utf8)
        try priorManifest.write(to: request.manifestURL)
        try priorProvenance.write(to: request.provenanceURL)
        try priorReport.write(to: request.reportCSVURL)

        let firstRun = Task {
            try await pipeline.run(request)
        }
        XCTAssertEqual(gate.waitUntilLockAcquired(), .success)

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected competing same-output run to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("run lock is already held"), error.localizedDescription)
        }

        XCTAssertEqual(try Data(contentsOf: request.manifestURL), priorManifest)
        XCTAssertEqual(try Data(contentsOf: request.provenanceURL), priorProvenance)
        XCTAssertEqual(try Data(contentsOf: request.reportCSVURL), priorReport)
        gate.releaseFirstRun()
        do {
            _ = try await firstRun.value
            XCTFail("Expected gated first run to stop before mutation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected stop after run lock"), error.localizedDescription)
        }
    }

    func testRunCreatesMissingMultiLevelOutputParentsBeforeAcquiringSiblingLock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-missing-output-parents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputDirectory = root
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        let observation = OutputParentPreparationObservation(outputDirectory: outputDirectory)
        let (baseRequest, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: observation.observe
        )
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: baseRequest.inputFASTQURLs,
            referenceSourceURL: baseRequest.referenceSourceURL,
            outputDirectory: outputDirectory,
            outputName: baseRequest.outputName,
            threads: baseRequest.threads,
            minimumLength: baseRequest.minimumLength,
            maximumLength: baseRequest.maximumLength
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.deletingLastPathComponent().path))

        let result = try await pipeline.run(request)

        XCTAssertEqual(result.outputDirectory, outputDirectory.standardizedFileURL)
        XCTAssertTrue(observation.observedLockBoundary)
        XCTAssertTrue(observation.parentExistedAtLockBoundary)
        XCTAssertTrue(observation.resultWasAbsentAtLockBoundary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DarwinFullLengthONTMHCRunLock.lockURL(for: outputDirectory).path
        ))
    }

    func testRunRejectsSymlinkedMissingOutputParentChainWithoutResultMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-unsafe-output-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (baseRequest, pipeline) = try makeFakeFullLengthRun(root: root)
        let safeParent = root.appendingPathComponent("new", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        let symlink = safeParent.appendingPathComponent("redirect", isDirectory: true)
        try FileManager.default.createDirectory(at: safeParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("sentinel.txt")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let outputDirectory = symlink
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: baseRequest.inputFASTQURLs,
            referenceSourceURL: baseRequest.referenceSourceURL,
            outputDirectory: outputDirectory,
            outputName: baseRequest.outputName,
            threads: baseRequest.threads,
            minimumLength: baseRequest.minimumLength,
            maximumLength: baseRequest.maximumLength
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected symlinked output parent chain rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("output parent"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("symlink"), error.localizedDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("missing").path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DarwinFullLengthONTMHCRunLock.lockURL(for: outputDirectory).path
        ))
    }

    func testManifestIsPublishedLastAndProvenanceMapsUniqueStagingDescriptorToFinalPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-manifest-last-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let observation = MetadataPublicationObservation(failAfterProvenance: false)
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: observation.observe
        )

        let result = try await pipeline.run(request)

        XCTAssertTrue(observation.observedProvenanceBoundary)
        XCTAssertTrue(observation.manifestWasAbsentAtProvenanceBoundary)
        XCTAssertTrue(observation.observedFinalProvenanceBoundary)
        XCTAssertTrue(observation.observedManifestPublication)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.provenanceURL.path))
        XCTAssertEqual(
            observation.finalizedProvenanceChecksum,
            try ProvenanceFileHasher.sha256(of: request.provenanceURL),
            "Provenance must not be mutated after the success manifest is published."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.genotypingEvidenceBAMURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.genotypingEvidenceBAIURL!.path))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcCandidateReciprocalMappingPreset"]?.stringValue, "asm20")
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcCandidateMinimumAlignedBases"]?.integerValue, 1_000)
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcCandidateMinimumIdentity"]?.numberValue, 0.75)
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcCandidateMinimumShorterCoverage"]?.numberValue, 0.70)
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcCandidateMinimumIntronGapBases"]?.integerValue, 20)
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcWorkbookSharedNovelTint"]?.stringValue, "FFFFE0B2")
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcWorkbookSingletonNovelTint"]?.stringValue, "FFFFCC80")
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcWorkbookSharedExtensionTint"]?.stringValue, "FFB2DFDB")
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcWorkbookSingletonExtensionTint"]?.stringValue, "FFBBDEFB")
        XCTAssertEqual(envelope.options.resolvedDefaults["mhcCandidateNovelDistanceMetric"]?.stringValue, "SNP-substitutions-only")
        XCTAssertEqual(
            envelope.options.resolvedDefaults["mhcResultBundleAtomicPublication"]?.stringValue,
            "adjacent-directory-renameatx_np"
        )
        let candidateProvenanceNames = Set(envelope.steps.map(\.toolName))
        XCTAssertTrue(candidateProvenanceNames.isSuperset(of: [
            "lungfish-in-process:import-mhc-reference-catalog",
            "lungfish-in-process:construct-stable-unmatched-cluster-fasta",
            "lungfish-in-process:parse-and-classify-reciprocal-mhc-alignments",
            "lungfish-in-process:render-mhc-candidate-fasta",
            "lungfish-in-process:render-mhc-unnameable-fasta",
            "lungfish-in-process:render-mhc-candidate-json",
            "lungfish-in-process:render-mhc-unnameable-json",
            "lungfish-in-process:capture-mhc-candidate-artifact-checksums",
            "lungfish-in-process:materialize-mhc-candidate-staging-generation",
            "lungfish-in-process:assemble-mhc-workbook-projection-input",
            "lungfish-internal mhc-candidate-workbook-project",
        ]))
        let auditedCandidateSteps = envelope.steps.filter { step in
            step.toolName.hasPrefix("lungfish-in-process:")
                || step.toolName == "lungfish-internal mhc-candidate-workbook-project"
                || step.toolName == "lungfish-internal publish-result-bundle"
                || (step.toolName == "minimap2" && step.argv.contains("asm20"))
                || (step.toolName == "samtools"
                    && (step.reproducibleCommand.contains("unmatched-to-reference.bam")
                        || step.reproducibleCommand.contains("reciprocal")))
        }
        for step in auditedCandidateSteps {
            XCTAssertFalse(step.toolName.isEmpty)
            XCTAssertFalse(step.toolVersion.isEmpty, step.toolName)
            XCTAssertNotEqual(step.toolVersion, "unknown", step.toolName)
            XCTAssertFalse(step.argv.isEmpty, step.toolName)
            XCTAssertFalse(step.reproducibleCommand.isEmpty, step.toolName)
            XCTAssertFalse(step.resolvedOptions.isEmpty, step.toolName)
            XCTAssertNotNil(step.runtimeIdentity, step.toolName)
            XCTAssertNotNil(step.exitStatus, step.toolName)
            XCTAssertGreaterThanOrEqual(step.wallTimeSeconds ?? -1, 0, step.toolName)
            XCTAssertNotNil(step.startedAt, step.toolName)
            XCTAssertNotNil(step.completedAt, step.toolName)
            XCTAssertFalse(step.inputs.isEmpty, "\(step.toolName) must identify its scientific inputs.")
            if step.outputs.isEmpty {
                XCTAssertNotNil(
                    step.resolvedOptions["provenanceOutputException"],
                    "\(step.toolName) must identify outputs or document its in-process sink."
                )
            }
            for descriptor in step.inputs + step.outputs {
                XCTAssertNotNil(descriptor.checksumSHA256, "\(step.toolName): \(descriptor.path)")
                XCTAssertNotNil(descriptor.fileSize, "\(step.toolName): \(descriptor.path)")
            }
        }
        XCTAssertFalse(envelope.runtimeIdentity.executablePath.isEmpty)
        XCTAssertFalse(envelope.runtimeIdentity.operatingSystemVersion.isEmpty)
        XCTAssertFalse(envelope.runtimeIdentity.architecture.isEmpty)
        XCTAssertTrue(envelope.outputs.allSatisfy {
            !$0.path.contains(".run-staging-") && !$0.path.contains(".candidate-artifact-work")
        }, envelope.outputs.map(\.path).joined(separator: "\n"))
        let workbookProjectionStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "lungfish-internal mhc-candidate-workbook-project"
        })
        XCTAssertEqual(Array(workbookProjectionStep.argv.prefix(2)), [
            "lungfish-internal", "mhc-candidate-workbook-project",
        ])
        XCTAssertEqual(workbookProjectionStep.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(workbookProjectionStep.exitStatus, 0)
        XCTAssertNotNil(workbookProjectionStep.startedAt)
        XCTAssertNotNil(workbookProjectionStep.completedAt)
        XCTAssertGreaterThanOrEqual(workbookProjectionStep.wallTimeSeconds ?? -1, 0)
        XCTAssertEqual(workbookProjectionStep.inputs.count, 1)
        let workbookProjectionInputURL = URL(
            fileURLWithPath: try XCTUnwrap(workbookProjectionStep.inputs.first).path
        )
        XCTAssertEqual(
            value(after: "--projection-input", in: workbookProjectionStep.argv),
            workbookProjectionInputURL.path
        )
        let workbookProjectionInput = try JSONDecoder().decode(
            FullLengthONTMHCWorkbookProjectionInputDocument.self,
            from: Data(contentsOf: workbookProjectionInputURL)
        )
        XCTAssertGreaterThan(workbookProjectionInput.sourceSummary.reportRowCount, 0)
        XCTAssertEqual(workbookProjectionInput.sourceSummary.sampleSummaryCount, 1)
        XCTAssertFalse(workbookProjectionInput.sheets.isEmpty)
        XCTAssertEqual(workbookProjectionStep.outputs.map(\.path), [result.primaryWorkbookURL.path])
        for descriptor in workbookProjectionStep.inputs + workbookProjectionStep.outputs {
            XCTAssertNotNil(descriptor.checksumSHA256)
            XCTAssertNotNil(descriptor.fileSize)
            XCTAssertFalse(descriptor.path.contains(".run-staging-"), descriptor.path)
            XCTAssertFalse(descriptor.path.contains(".candidate-artifact-work"), descriptor.path)
        }
        let workbookAssemblyStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "lungfish-in-process:assemble-mhc-workbook-projection-input"
        })
        XCTAssertTrue(Set(workbookAssemblyStep.inputs.map(\.path)).isSuperset(of: [
            try XCTUnwrap(result.candidateAllelesJSONURL).path,
            try XCTUnwrap(result.unnameableClustersJSONURL).path,
            result.reportCSVURL.path,
            result.sampleSummaryCSVURL.path,
            result.deduplicatedUnmatchedClustersFASTAURL.path,
            result.referenceFASTAURL.path,
        ]))
        XCTAssertEqual(workbookAssemblyStep.outputs.map(\.path), [workbookProjectionInputURL.path])
        XCTAssertNotNil(workbookAssemblyStep.resolvedOptions["genotypeRowCount"])
        XCTAssertNotNil(workbookAssemblyStep.resolvedOptions["orderedAlleleCount"])
        XCTAssertNotNil(workbookAssemblyStep.resolvedOptions["inProcessSourceException"])
        let candidatePublicationStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "lungfish-in-process:materialize-mhc-candidate-staging-generation"
        })
        XCTAssertTrue(candidatePublicationStep.outputs.allSatisfy {
            $0.path.hasPrefix(request.outputDirectory.path + "/")
        })
        let resultPublicationStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "lungfish-internal publish-result-bundle"
        })
        XCTAssertTrue(resultPublicationStep.argv.contains("renameatx_np"))
        XCTAssertTrue(resultPublicationStep.argv.contains("create"))
        XCTAssertEqual(resultPublicationStep.exitStatus, 0)
        XCTAssertNotNil(resultPublicationStep.startedAt)
        XCTAssertNotNil(resultPublicationStep.completedAt)
        XCTAssertGreaterThanOrEqual(resultPublicationStep.wallTimeSeconds ?? -1, 0)
        XCTAssertEqual(
            try XCTUnwrap(envelope.wallTimeSeconds),
            try XCTUnwrap(envelope.steps.compactMap(\.completedAt).max()).timeIntervalSince(envelope.createdAt),
            accuracy: 0.000_001
        )
        XCTAssertFalse(resultPublicationStep.inputs.isEmpty)
        XCTAssertEqual(resultPublicationStep.inputs.count, resultPublicationStep.outputs.count)
        for (stagedPayload, finalPayload) in zip(
            resultPublicationStep.inputs,
            resultPublicationStep.outputs
        ) {
            XCTAssertNotEqual(stagedPayload.path, finalPayload.path)
            XCTAssertEqual(stagedPayload.checksumSHA256, finalPayload.checksumSHA256)
            XCTAssertEqual(stagedPayload.fileSize, finalPayload.fileSize)
            XCTAssertEqual(finalPayload.originPath, stagedPayload.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: finalPayload.path))
            XCTAssertEqual(finalPayload.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: finalPayload.path)))
        }
        XCTAssertFalse(envelope.steps.contains {
            $0.toolName.contains("success-manifest")
        }, "Manifest publication cannot truthfully appear in provenance finalized before that operation.")

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: request.outputDirectory)
        for relativePath in [
            manifest.primaryWorkbookPath,
            manifest.currentWorkbookPath,
            manifest.longSummaryCSVPath,
            manifest.sampleSummaryCSVPath,
            manifest.statsJSONPath,
            manifest.provenancePath,
            manifest.mhcCandidateArtifacts?.genotypingEvidence?.bam.path,
            manifest.mhcCandidateArtifacts?.genotypingEvidence?.bai.path,
        ].compactMap({ $0 }) {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: request.outputDirectory.appendingPathComponent(relativePath).path
                ),
                "Manifest published before referenced output existed: \(relativePath)"
            )
        }
    }

    func testFailureAtFinalProvenanceBoundaryLeavesNoVisibleManifestOrBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-final-provenance-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: { event in
                guard case .provenanceFinalizedBeforeManifestPublication(
                    let finalManifestURL, let provenanceURL
                ) = event else { return }
                XCTAssertFalse(FileManager.default.fileExists(atPath: finalManifestURL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
                throw NSError(domain: "injected-final-provenance-boundary", code: 31)
            }
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected final provenance boundary failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "injected-final-provenance-boundary")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.manifestURL.path))
    }

    func testPostPublicationWorkflowCleanupFailureReturnsSuccessWithRetainedPathWarning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-workflow-cleanup-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            postPublicationWorkDirectoryCleaner: SelectiveFailingPostPublicationCleaner(
                target: .workflowIntermediates
            )
        )

        let result = try await pipeline.run(request)

        let workflowDirectory = request.outputDirectory.appendingPathComponent("workflow", isDirectory: true)
        let warning = try XCTUnwrap(result.cleanupWarnings.first)
        XCTAssertEqual(result.cleanupWarnings.count, 1)
        XCTAssertEqual(warning.kind, .workflowIntermediates)
        XCTAssertEqual(warning.path, workflowDirectory.standardizedFileURL.path)
        XCTAssertTrue(warning.error.contains("injected workflow intermediates cleanup failure"))
        XCTAssertTrue(warning.publishedArtifactsRemainValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: warning.path))

        let cohortWorkDirectory = request.outputDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(request.outputDirectory.lastPathComponent).cohort-alignment-work")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cohortWorkDirectory.path),
            "Cohort cleanup must still complete when workflow cleanup fails."
        )
        try assertSuccessfulPublishedEvidence(result: result, request: request)
    }

    func testAtomicPublicationFailureWritesCompleteCommandProvenanceReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-publication-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            metadataPublicationObserver: { event in
                guard case .provenanceWrittenBeforeManifestPublication(
                    _, let finalManifestURL, _
                ) = event else { return }
                try FileManager.default.createDirectory(
                    at: finalManifestURL.deletingLastPathComponent(),
                    withIntermediateDirectories: false
                )
            }
        )

        do {
            _ = try await pipeline.run(request)
            XCTFail("Expected atomic publication conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("atomically publish"), error.localizedDescription)
        }

        let receiptURL = root.appendingPathComponent(
            ".\(request.outputDirectory.lastPathComponent).publication-failure.json"
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: receiptURL)
        )
        XCTAssertEqual(envelope.workflowName, "lungfish fastq full-length-ont-mhc-genotype result-bundle-publication")
        XCTAssertEqual(envelope.workflowVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.toolName, "lungfish-internal publish-result-bundle")
        XCTAssertEqual(envelope.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.argv.first, "lungfish-internal")
        XCTAssertTrue(envelope.argv.contains("renameatx_np"))
        XCTAssertTrue(envelope.reproducibleCommand.contains("publish-result-bundle"))
        XCTAssertFalse(envelope.runtimeIdentity.executablePath.isEmpty)
        XCTAssertEqual(envelope.options.explicit["publicationStatus"]?.stringValue, "failed")
        XCTAssertFalse(envelope.files.isEmpty)
        XCTAssertFalse(envelope.outputs.isEmpty)
        XCTAssertTrue(envelope.files.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertNotEqual(envelope.exitStatus, 0)
        XCTAssertFalse((envelope.stderr ?? "").isEmpty)
        XCTAssertEqual(envelope.steps.count, 1)
        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(step.argv, envelope.argv)
        XCTAssertEqual(step.exitStatus, envelope.exitStatus)
        XCTAssertEqual(step.startedAt, envelope.createdAt)
        XCTAssertEqual(
            try XCTUnwrap(envelope.wallTimeSeconds),
            try XCTUnwrap(step.completedAt).timeIntervalSince(envelope.createdAt),
            accuracy: 0.000_001
        )
    }

    func testPostPublicationCohortCleanupFailureStillRemovesWorkflowIntermediates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-cohort-cleanup-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            postPublicationWorkDirectoryCleaner: SelectiveFailingPostPublicationCleaner(
                target: .cohortAlignmentTemporaryWorkDirectory
            )
        )

        let result = try await pipeline.run(request)

        let warning = try XCTUnwrap(result.cleanupWarnings.first)
        XCTAssertEqual(result.cleanupWarnings.count, 1)
        XCTAssertEqual(warning.kind, .cohortAlignmentTemporaryWorkDirectory)
        XCTAssertTrue(warning.path.contains("full-length-ont-mhc-cohort-alignment-"))
        XCTAssertTrue(warning.error.contains("injected cohort alignment temporary work directory cleanup failure"))
        XCTAssertTrue(warning.publishedArtifactsRemainValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: warning.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: request.outputDirectory.appendingPathComponent("workflow", isDirectory: true).path
            ),
            "Workflow cleanup must still complete when cohort cleanup fails."
        )
        try assertSuccessfulPublishedEvidence(result: result, request: request)
    }

    func testRunKeepsWorkflowIntermediatesAndRecordsCheckpointOptionsInProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-keep-intermediates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (baseRequest, pipeline) = try makeFakeFullLengthRun(root: root)
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: baseRequest.inputFASTQURLs,
            referenceSourceURL: baseRequest.referenceSourceURL,
            outputDirectory: baseRequest.outputDirectory,
            outputName: baseRequest.outputName,
            threads: baseRequest.threads,
            minimumLength: baseRequest.minimumLength,
            maximumLength: baseRequest.maximumLength,
            keepIntermediates: true,
            reuseCompatibleCheckpoints: true
        )

        _ = try await pipeline.run(request)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: request.outputDirectory.appendingPathComponent("workflow", isDirectory: true).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: request.outputDirectory
                    .appendingPathComponent(".full-length-ont-mhc/checkpoints/samples/DL46.json").path
            )
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        XCTAssertEqual(envelope.options.defaults["keepIntermediates"]?.booleanValue, false)
        XCTAssertEqual(envelope.options.defaults["reuseCompatibleCheckpoints"]?.booleanValue, false)
        XCTAssertEqual(envelope.options.resolvedDefaults["keepIntermediates"]?.booleanValue, true)
        XCTAssertEqual(envelope.options.resolvedDefaults["reuseCompatibleCheckpoints"]?.booleanValue, true)
        XCTAssertEqual(envelope.options.explicit["keepIntermediates"]?.booleanValue, true)
        XCTAssertEqual(envelope.options.explicit["reuseCompatibleCheckpoints"]?.booleanValue, true)
    }

    func testRunUsesManagedBlastForMhcLikeRescueWhenPathDoesNotContainBlastn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-managed-blast-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalPATH {
                setenv("PATH", originalPATH, 1)
            } else {
                unsetenv("PATH")
            }
        }
        let savontScript = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "savont 0.5.0"
          exit 0
        fi
        shift
        input="$1"
        shift
        output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) output="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        mkdir -p "$output"
        cat > "$output/final_asvs.fasta" <<'EOF'
        >final_consensus_0_depth_7
        TTTTTTTT
        EOF
        printf 'savont log for %s\n' "$input" > "$output/savont_2026-06-10_05-09-37.log"
        """#
        let minimap2Script = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "minimap2 2.28"
          exit 0
        fi
        previous=""
        current=""
        for arg in "$@"; do previous="$current"; current="$arg"; done
        target=$(awk '/^>/{sub(/^>/, ""); print $1; exit}' "$previous")
        printf '@SQ\tSN:%s\tLN:8\n' "$target"
        """#
        let blastnScript = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "-version" ]; then
          echo "blastn: 2.16.0+"
          exit 0
        fi
        outfmt=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -outfmt) outfmt="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -z "$outfmt" ]; then
          echo "missing -outfmt" >&2
          exit 2
        fi
        printf 'final_consensus_0_depth_7_ReadCount-7\tallele1\t100.0\t8\t0\t0\t1\t8\t1\t8\t1e-20\t60\t8\t8\n'
        """#
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            savontScript: savontScript,
            minimap2Script: minimap2Script,
            blastnScript: blastnScript
        )

        _ = try await pipeline.run(request)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        let blastStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "blastn" })
        XCTAssertEqual(blastStep.toolVersion, "2.16.0")
        XCTAssertEqual(blastStep.exitStatus, 0)
        XCTAssertTrue(blastStep.argv.first?.hasSuffix("blastn") == true)
    }

    func testRunHandlesSavontPanicDuringHiddenFallbackAsSampleNoCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-fallback-panic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let savontScript = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "savont 0.5.0"
          exit 0
        fi
        shift
        input="$1"
        shift
        output=""
        min_cluster=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) output="$2"; shift 2 ;;
            --min-cluster-size) min_cluster="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        mkdir -p "$output"
        printf 'input=%s min_cluster=%s\n' "$input" "$min_cluster" > "$output/savont.log"
        if [ "$min_cluster" = "3" ]; then
          : > "$output/final_asvs.fasta"
          exit 0
        fi
        echo "thread 'main' panicked at src/main.rs:518: called Option::unwrap()" >&2
        exit 101
        """#
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            savontScript: savontScript
        )

        _ = try await pipeline.run(request)

        let report = try String(contentsOf: request.reportCSVURL, encoding: .utf8)
        XCTAssertEqual(report.split(separator: "\n").count, 1)

        let sampleSummary = try String(contentsOf: request.sampleSummaryCSVURL, encoding: .utf8)
        XCTAssertTrue(sampleSummary.contains("DL46,0,0,1,0,0.0,0,0,0,0,fallback-qv90-min1,handled-savont-failure,strict-no-clusters"))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
        XCTAssertTrue(envelope.steps.contains {
            $0.toolName == "savont"
                && value(after: "--min-cluster-size", in: $0.argv) == "1"
                && $0.exitStatus == 101
                && ($0.stderr?.contains("panicked") == true)
        })
    }

    func testSavontRunSupportRetriesSignalCrashWithSingleThreadFallback() {
        XCTAssertTrue(FullLengthONTMHCSavontRunSupport.shouldRetry(exitCode: 139, attemptedThreads: 3))
        XCTAssertTrue(FullLengthONTMHCSavontRunSupport.shouldRetry(exitCode: 138, attemptedThreads: 3))
        XCTAssertFalse(FullLengthONTMHCSavontRunSupport.shouldRetry(exitCode: 139, attemptedThreads: 1))
        XCTAssertFalse(FullLengthONTMHCSavontRunSupport.shouldRetry(exitCode: 1, attemptedThreads: 3))
        XCTAssertFalse(FullLengthONTMHCSavontRunSupport.shouldRetry(exitCode: 143, attemptedThreads: 3))
        XCTAssertEqual(
            FullLengthONTMHCSavontRunSupport.retryDecision(
                exitCode: 139,
                attemptedThreads: 3,
                attemptedSingleStrand: false,
                stderr: ""
            ),
            .singleThread
        )
    }

    func testSavontRunSupportRetriesLowBidirectionalSNPmersWithSingleStrandFallback() {
        let stderr = """
        ERROR [savont::seq_parse] Less than 0.1% of SNPmers have counts > 1 in both strands and > 2 multiplicity. This may indicate a problem with the input data or very low coverage. Consider using --single-strand
        """

        XCTAssertEqual(
            FullLengthONTMHCSavontRunSupport.retryDecision(
                exitCode: 1,
                attemptedThreads: 3,
                attemptedSingleStrand: false,
                stderr: stderr
            ),
            .singleStrand
        )
        XCTAssertEqual(
            FullLengthONTMHCSavontRunSupport.retryDecision(
                exitCode: 1,
                attemptedThreads: 3,
                attemptedSingleStrand: true,
                stderr: stderr
            ),
            .emptyClusters
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
        XCTAssertEqual(summary.cdnaMatchedClusters.map(\.name), ["Cluster1_ReadCount-12"])

        let reportRows = FullLengthONTMHCClusterReportBuilder.reportRows(
            genotypeRows: summary.rows,
            sampleReadCounts: ["NB13": 100]
        )
        XCTAssertEqual(reportRows.map(\.sample), ["NB13"])
        XCTAssertEqual(reportRows.map(\.genotype), ["Mamu-A1*001"])
        XCTAssertEqual(reportRows.map(\.passedUniqueReads), [12])
        XCTAssertEqual(reportRows.map(\.passedAlignments), [12])
    }

    func testClusterGenotyperReportsSNPClosestMatchForUnmatchedCluster() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-closest-snp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try """
        >ClusterSNP_ReadCount-9
        ACGTACGT
        """.write(to: clusters, atomically: true, encoding: .utf8)
        try """
        >Mamu-A1*001
        ACGTACGT
        >Mamu-B*001
        ACGTACGT
        """.write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        @SQ\tSN:ClusterSNP_ReadCount-9\tLN:8
        Mamu-A1*001\t0\tClusterSNP_ReadCount-9\t1\t60\t6=2X\t*\t0\t0\tACGTACGT\t*
        Mamu-B*001\t0\tClusterSNP_ReadCount-9\t1\t60\t5=3X\t*\t0\t0\tACGTACGT\t*
        """

        let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
            sampleID: "DL47",
            clustersFASTAURL: clusters,
            referenceFASTAURL: reference,
            samText: sam,
            cdnaThreshold: 2_000,
            minUnmatchedReads: 5
        )

        XCTAssertEqual(summary.rows, [])
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["ClusterSNP_ReadCount-9"])
        XCTAssertEqual(summary.closestMatches, [
            FullLengthONTMHCClosestMatch(
                sample: "DL47",
                cluster: "ClusterSNP_ReadCount-9",
                clusterReads: 9,
                closestReference: "Mamu-A1*001",
                matchClass: .snpDifferent,
                closestMatchID: "Mamu-A1*001_2SNP",
                nucleotidesDifferent: 2,
                snpDifferences: 2,
                indelBases: 0,
                alignedBases: 6,
                score: -194,
                trimStart: 1,
                trimEnd: 8,
                isReverse: false
            ),
        ])
    }

    func testClusterGenotyperReportsTrimBoundsAndReverseStrandForClosestMatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-closest-reverse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try """
        >ClusterReverse_ReadCount-9
        TTAAGCATGG
        """.write(to: clusters, atomically: true, encoding: .utf8)
        try """
        >Mamu-A1*001
        ATGCTT
        """.write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        @SQ\tSN:ClusterReverse_ReadCount-9\tLN:10
        Mamu-A1*001\t16\tClusterReverse_ReadCount-9\t3\t60\t4=2X\t*\t0\t0\tATGCTT\t*
        """

        let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
            sampleID: "DL47",
            clustersFASTAURL: clusters,
            referenceFASTAURL: reference,
            samText: sam,
            cdnaThreshold: 2_000,
            minUnmatchedReads: 5
        )

        let closest = try XCTUnwrap(summary.closestMatches.first)
        XCTAssertEqual(closest.trimStart, 3)
        XCTAssertEqual(closest.trimEnd, 8)
        XCTAssertEqual(closest.isReverse, true)
    }

    func testClusterGenotyperTreatsZeroSNPIndelOnlyGenomicHitAsExistingGenotype() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-zero-snp-indel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try """
        >ClusterExisting_ReadCount-11
        ACGTACGTAA
        """.write(to: clusters, atomically: true, encoding: .utf8)
        try """
        >Mamu-A1*001
        ACGTACGT
        """.write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        @SQ\tSN:ClusterExisting_ReadCount-11\tLN:10
        Mamu-A1*001\t0\tClusterExisting_ReadCount-11\t1\t60\t4=2D4=\t*\t0\t0\tACGTACGT\t*
        """

        let metrics = try FullLengthONTMHCSAMMetrics(cigar: "4=2D4=", nm: nil)
        XCTAssertEqual(metrics.snps, 0)
        XCTAssertEqual(metrics.querySpan, 8)
        XCTAssertEqual(metrics.referenceSpan, 10)

        let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
            sampleID: "DL48",
            clustersFASTAURL: clusters,
            referenceFASTAURL: reference,
            samText: sam,
            cdnaThreshold: 8,
            minUnmatchedReads: 5
        )

        XCTAssertEqual(summary.rows, [
            FullLengthONTMHCClusterGenotypeRow(
                sample: "DL48",
                cluster: "ClusterExisting_ReadCount-11",
                clusterReads: 11,
                allele: "Mamu-A1*001",
                alleleLength: 8,
                alignedBases: 8,
                score: -12
            ),
        ])
        XCTAssertEqual(summary.unmatchedClusters, [])
        XCTAssertEqual(summary.cdnaMatchedClusters, [])
        XCTAssertEqual(summary.closestMatches, [])
        XCTAssertFalse(summary.rows.map(\.allele).contains { allele in
            allele.contains("_extension") || allele.contains("_ext") || allele.contains("_0nt_nov")
        })
    }

    func testClusterGenotyperLeavesZeroSNPIndelOnlyCDNAHitUnmatched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-cdna-indel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try """
        >ClusterCDNAExtension_ReadCount-11
        ACGTACGTAA
        """.write(to: clusters, atomically: true, encoding: .utf8)
        try """
        >Mamu-cDNA*001
        ACGTACGT
        """.write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        @SQ\tSN:ClusterCDNAExtension_ReadCount-11\tLN:10
        Mamu-cDNA*001\t0\tClusterCDNAExtension_ReadCount-11\t1\t60\t4=2D4=\t*\t0\t0\tACGTACGT\t*
        """

        let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
            sampleID: "DL48",
            clustersFASTAURL: clusters,
            referenceFASTAURL: reference,
            samText: sam,
            cdnaThreshold: 2_000,
            minUnmatchedReads: 5
        )

        XCTAssertEqual(summary.rows, [])
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["ClusterCDNAExtension_ReadCount-11"])
        XCTAssertEqual(summary.cdnaMatchedClusters, [])
    }

    func testClusterGenotyperReconcilesProductionShapedMAndNM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-m-nm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try ">ClusterM_ReadCount-11\nACGTACGTAA\n".write(to: clusters, atomically: true, encoding: .utf8)
        try ">Mamu-A1*001\nACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        @SQ\tSN:ClusterM_ReadCount-11\tLN:10
        Mamu-A1*001\t0\tClusterM_ReadCount-11\t1\t60\t8M2D\t*\t0\t0\tACGTACGT\t*\tNM:i:2
        """

        let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
            sampleID: "DL48",
            clustersFASTAURL: clusters,
            referenceFASTAURL: reference,
            samText: sam,
            cdnaThreshold: 8,
            minUnmatchedReads: 5
        )

        XCTAssertEqual(summary.rows.map(\.allele), ["Mamu-A1*001"])
        XCTAssertEqual(summary.rows.map(\.score), [-12])
        XCTAssertEqual(summary.unmatchedClusters, [])
    }

    func testClusterGenotyperRejectsMalformedNMTag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-invalid-nm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try ">ClusterM_ReadCount-11\nACGTACGTAA\n".write(to: clusters, atomically: true, encoding: .utf8)
        try ">Mamu-A1*001\nACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        Mamu-A1*001\t0\tClusterM_ReadCount-11\t1\t60\t8M2D\t*\t0\t0\tACGTACGT\t*\tNM:i:not-a-number
        """

        XCTAssertThrowsError(
            try FullLengthONTMHCClusterGenotyper.genotypeSummary(
                sampleID: "DL48",
                clustersFASTAURL: clusters,
                referenceFASTAURL: reference,
                samText: sam
            )
        ) { error in
            XCTAssertEqual(error as? FullLengthONTMHCSAMMetricsError, .invalidNM("not-a-number"))
        }
    }

    func testClusterGenotyperRejectsScoreAndTargetEndOverflow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try ">ClusterOverflow_ReadCount-11\nAC\n".write(to: clusters, atomically: true, encoding: .utf8)
        try ">Mamu-A1*001\nA\n".write(to: reference, atomically: true, encoding: .utf8)

        let scoreOverflowSAM = """
        Mamu-A1*001\t0\tClusterOverflow_ReadCount-11\t1\t60\t\(Int.max)X\t*\t0\t0\tA\t*
        """
        XCTAssertThrowsError(
            try FullLengthONTMHCClusterGenotyper.genotypeSummary(
                sampleID: "DL48",
                clustersFASTAURL: clusters,
                referenceFASTAURL: reference,
                samText: scoreOverflowSAM
            )
        ) { error in
            XCTAssertEqual(
                error as? FullLengthONTMHCSAMMetricsError,
                .arithmeticOverflow(metric: .alignmentScore, operation: .multiply(100))
            )
        }

        let targetEndOverflowSAM = """
        Mamu-A1*001\t0\tClusterOverflow_ReadCount-11\t\(Int.max)\t60\t2=\t*\t0\t0\tA\t*
        """
        XCTAssertThrowsError(
            try FullLengthONTMHCClusterGenotyper.genotypeSummary(
                sampleID: "DL48",
                clustersFASTAURL: clusters,
                referenceFASTAURL: reference,
                samText: targetEndOverflowSAM
            )
        ) { error in
            XCTAssertEqual(
                error as? FullLengthONTMHCSAMMetricsError,
                .arithmeticOverflow(metric: .targetEnd, operation: .add)
            )
        }
    }

    func testUnmatchedNormalizerTrimsAndReverseComplementsBeforeIDAssignment() {
        let record = FullLengthONTMHCClusterFASTARecord(
            name: "ClusterReverse_ReadCount-9",
            sequence: "TTAAGCATGG",
            readCount: 9
        )
        let closest = FullLengthONTMHCClosestMatch(
            sample: "DL47",
            cluster: "ClusterReverse_ReadCount-9",
            clusterReads: 9,
            closestReference: "Mamu-A1*001",
            matchClass: .snpDifferent,
            closestMatchID: "Mamu-A1*001_2SNP",
            nucleotidesDifferent: 2,
            snpDifferences: 2,
            indelBases: 0,
            alignedBases: 4,
            score: -196,
            trimStart: 3,
            trimEnd: 8,
            isReverse: true
        )

        let row = FullLengthONTMHCUnmatchedSequenceNormalizer.workbookRow(
            sample: "DL47",
            record: record,
            closestMatch: closest
        )

        XCTAssertEqual(row.rawSequence, "TTAAGCATGG")
        XCTAssertEqual(row.sequence, "ATGCTT")
        XCTAssertEqual(row.trimStart, 3)
        XCTAssertEqual(row.trimEnd, 8)
        XCTAssertEqual(row.trimSource, "minimap2-target-interval-reverse-complement")
        XCTAssertEqual(row.rawLength, 10)
        XCTAssertEqual(row.trimmedLength, 6)
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

    func testReciprocalKnownTiesCountSourceReadsOnceAndWorkbookPreservesReferenceIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-reciprocal-known-ties-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sequence = String(repeating: "A", count: 1_200)
        let savont = """
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then echo "savont 0.5.0"; exit 0; fi
        shift
        input="$1"
        shift
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
        done
        mkdir -p "$output/temp"
        cat > "$output/final_asvs.fasta" <<'EOF'
        >final_consensus_0_depth_7
        \(sequence)
        EOF
        printf 'savont log for %s\n' "$input" > "$output/savont.log"
        printf 'feature table\n' > "$output/feature-table.tsv"
        printf 'final clusters\n' > "$output/final_clusters.tsv"
        printf 'read mappings\n' > "$output/temp/read_to_asv_mappings.tsv"
        """
        let minimap2 = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "minimap2 2.28"
          exit 0
        fi
        previous=""
        current=""
        reciprocal="false"
        for arg in "$@"; do
          previous="$current"
          current="$arg"
          if [ "$arg" = "asm20" ]; then reciprocal="true"; fi
        done
        query=$(awk '/^>/{sub(/^>/, ""); print $1; exit}' "$current")
        if [ "$reciprocal" = "true" ]; then
          printf '@SQ\tSN:ref-a\tLN:1200\n@SQ\tSN:ref-b\tLN:1200\n'
          if [ -n "$query" ]; then
            printf '%s\t0\tref-a\t1\t60\t1200=\t*\t0\t0\t*\t*\tNM:i:0\tAS:i:1200\n' "$query"
            printf '%s\t0\tref-b\t1\t60\t1200=\t*\t0\t0\t*\t*\tNM:i:0\tAS:i:1200\n' "$query"
          fi
        else
          target=$(awk '/^>/{sub(/^>/, ""); print $1; exit}' "$previous")
          printf '@SQ\tSN:%s\tLN:1200\n' "$target"
        fi
        """#
        let (request, pipeline) = try makeFakeFullLengthRun(
            root: root,
            savontScript: savont,
            minimap2Script: minimap2
        )
        try Data(">ref-a\n\(sequence)\n>ref-b\n\(sequence)\n".utf8).write(to: request.referenceSourceURL)

        let result = try await pipeline.run(request)

        let stats = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: result.statsJSONURL)) as? [String: Any]
        )
        XCTAssertEqual(stats["passedAlignments"] as? Int, 7)
        XCTAssertEqual(stats["retainedUniqueReads"] as? Int, 7)
        XCTAssertEqual(stats["assignedUniqueRetainedReads"] as? Int, 7)

        let sampleSummary = try String(contentsOf: result.sampleSummaryCSVURL, encoding: .utf8)
        XCTAssertTrue(sampleSummary.contains("DL46,7,7,1,7,"), sampleSummary)
        let report = try String(contentsOf: result.reportCSVURL, encoding: .utf8)
        XCTAssertTrue(report.contains("DL46,ref-a,7,7,"), report)
        XCTAssertTrue(report.contains("DL46,ref-b,7,7,"), report)

        let genotypeSheet = try Self.unzippedText(
            path: "xl/worksheets/sheet3.xml",
            from: result.primaryWorkbookURL
        )
        XCTAssertTrue(genotypeSheet.contains("reference_sequence_id"), genotypeSheet)
        XCTAssertTrue(genotypeSheet.contains("ref-a"), genotypeSheet)
        XCTAssertTrue(genotypeSheet.contains("ref-b"), genotypeSheet)
        XCTAssertTrue(genotypeSheet.contains("cigar"), genotypeSheet)
        XCTAssertTrue(genotypeSheet.contains("evidence_bam_path"), genotypeSheet)
    }

    func testFullLengthPivotWorkbookRowsMatchMiSeqFullSequencingFormatAndSorting() {
        let rows = FullLengthONTMHCPivotWorkbookBuilder.buildRows(
            reportRows: [
                FullLengthONTMHCReportRow(
                    sample: "DL47",
                    genotype: "Mamu-B*007:01",
                    passedAlignments: 12,
                    passedUniqueReads: 12,
                    sampleTotalReads: 100,
                    sampleUniqueRetainedReads: 42,
                    sampleUniqueRetainedPercent: 42.25,
                    overallInputReads: 300,
                    overallUniqueRetainedReads: 82,
                    overallUniqueRetainedPercent: 27.333333
                ),
                FullLengthONTMHCReportRow(
                    sample: "DL47",
                    genotype: "Mamu-A1*004:01",
                    passedAlignments: 30,
                    passedUniqueReads: 30,
                    sampleTotalReads: 100,
                    sampleUniqueRetainedReads: 42,
                    sampleUniqueRetainedPercent: 42.25,
                    overallInputReads: 300,
                    overallUniqueRetainedReads: 82,
                    overallUniqueRetainedPercent: 27.333333
                ),
                FullLengthONTMHCReportRow(
                    sample: "DL48",
                    genotype: "Mamu-A1*004:01",
                    passedAlignments: 40,
                    passedUniqueReads: 40,
                    sampleTotalReads: 200,
                    sampleUniqueRetainedReads: 40,
                    sampleUniqueRetainedPercent: 20.0,
                    overallInputReads: 300,
                    overallUniqueRetainedReads: 82,
                    overallUniqueRetainedPercent: 27.333333
                ),
            ],
            samples: [
                FullLengthONTMHCPivotSample(
                    sample: "DL47",
                    mappedReadCount: 42,
                    totalReadCount: 100,
                    retainedPercent: 42.25
                ),
                FullLengthONTMHCPivotSample(
                    sample: "DL48",
                    mappedReadCount: 40,
                    totalReadCount: 200,
                    retainedPercent: 20.0
                ),
            ],
            orderedAlleles: [
                "Mamu-B*007:01",
                "Mamu-A1*004:01",
            ],
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "full-length-ont-mhc",
                definitionSetID: "mamu-test",
                definitionSetName: "Mamu test",
                speciesName: "Macaca mulatta",
                samples: [
                    GenotypeHaplotypeSampleAnalysis(
                        sample: "DL47",
                        calls: [
                            GenotypeHaplotypeLocusCall(
                                locus: "MHC-A",
                                sourceLocus: "Mamu-A",
                                haplotype1: "Mamu-A-H1",
                                haplotype2: "Mamu-A-H2",
                                status: .called,
                                matchedHaplotypes: [],
                                observedGenotypeCount: 1,
                                observedGenotypes: ["Mamu-A1*004:01"]
                            ),
                            GenotypeHaplotypeLocusCall(
                                locus: "MHC-B",
                                sourceLocus: "Mamu-B",
                                haplotype1: "ERR: NO HAP",
                                haplotype2: "ERR: NO HAP",
                                status: .noHaplotype,
                                matchedHaplotypes: [],
                                observedGenotypeCount: 1,
                                observedGenotypes: ["Mamu-B*007:01"]
                            ),
                        ]
                    ),
                ]
            )
        )

        XCTAssertEqual(rows[0], ["Client ID", "", "", "DL47", "DL48"])
        XCTAssertEqual(rows[1], ["GS ID", "Total", "Average", "DL47", "DL48"])
        XCTAssertEqual(rows[2], ["Mapped Read Count", "82", "41", "42", "40"])
        XCTAssertEqual(rows[3], ["total_read_count", "", "", "100", "200"])
        XCTAssertEqual(rows[4], ["percent_reads_unmapped", "", "", "57.8", "80"])
        XCTAssertEqual(rows[5], ["MHC-A Haplotype 1", "", "", "Mamu-A-H1", ""])
        XCTAssertEqual(rows[6], ["MHC-A Haplotype 2", "", "", "Mamu-A-H2", ""])
        XCTAssertEqual(rows[19], ["Comments", "Subtotal", "# Obs.", "MHC-B: ERR: NO HAP", ""])

        let aMajorHeader = try? XCTUnwrap(rows.firstIndex { $0.first == "Mamu-A major alleles" })
        let bHeader = try? XCTUnwrap(rows.firstIndex { $0.first == "Mamu-B alleles" })
        XCTAssertNotNil(aMajorHeader)
        XCTAssertNotNil(bHeader)
        XCTAssertLessThan(aMajorHeader ?? 0, bHeader ?? 0)
        XCTAssertEqual(rows[(aMajorHeader ?? 0) + 1], ["Mamu-A1*004:01", "70", "2", "30", "40"])
        XCTAssertEqual(rows[(bHeader ?? 0) + 1], ["Mamu-B*007:01", "12", "1", "12", ""])
    }

    func testUnmatchedWorkbookRowsBuildMergedDetailAndSequencePivot() {
        let rows = [
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL47",
                cluster: "ClusterA_ReadCount-9",
                clusterReads: 9,
                sequence: "ACGT",
                closestMatch: FullLengthONTMHCClosestMatch(
                    sample: "DL47",
                    cluster: "ClusterA_ReadCount-9",
                    clusterReads: 9,
                    closestReference: "Mamu-A1*001",
                    matchClass: .snpDifferent,
                    closestMatchID: "Mamu-A1*001_2SNP",
                    nucleotidesDifferent: 2,
                    snpDifferences: 2,
                    indelBases: 0,
                    alignedBases: 6,
                    score: -194
                )
            ),
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL48",
                cluster: "ClusterB_ReadCount-11",
                clusterReads: 11,
                sequence: "ACGT",
                closestMatch: FullLengthONTMHCClosestMatch(
                    sample: "DL48",
                    cluster: "ClusterB_ReadCount-11",
                    clusterReads: 11,
                    closestReference: "Mamu-A1*001",
                    matchClass: .snpDifferent,
                    closestMatchID: "Mamu-A1*001_2SNP",
                    nucleotidesDifferent: 2,
                    snpDifferences: 2,
                    indelBases: 0,
                    alignedBases: 6,
                    score: -194
                )
            ),
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL48",
                cluster: "ClusterC_ReadCount-5",
                clusterReads: 5,
                sequence: "TTTT",
                closestMatch: FullLengthONTMHCClosestMatch(
                    sample: "DL48",
                    cluster: "ClusterC_ReadCount-5",
                    clusterReads: 5,
                    closestReference: "Mamu-cDNA*001",
                    matchClass: .extension,
                    closestMatchID: "Mamu-cDNA*001_extension",
                    nucleotidesDifferent: 0,
                    snpDifferences: 0,
                    indelBases: 2,
                    alignedBases: 8,
                    score: -12
                )
            ),
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL49",
                cluster: "ClusterD_ReadCount-7",
                clusterReads: 7,
                sequence: "GGGG",
                closestMatch: nil
            ),
        ]

        XCTAssertEqual(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.detailRows(rows),
            [
                [
                    "unmatched_sequence_id",
                    "sample",
                    "cluster",
                    "cluster_reads",
                    "raw_length",
                    "trimmed_length",
                    "trim_start",
                    "trim_end",
                    "trim_source",
                    "closest_match_id",
                    "match_class",
                    "nucleotides_different",
                    "snp_differences",
                    "indel_bases",
                    "aligned_bases",
                    "score",
                    "sequence",
                ],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "DL47", "ClusterA_ReadCount-9", "9", "4", "4", "", "", "provided-sequence", "Mamu-A1*001_2SNP", "snp-different", "2", "2", "0", "6", "-194", "ACGT"],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "DL48", "ClusterB_ReadCount-11", "11", "4", "4", "", "", "provided-sequence", "Mamu-A1*001_2SNP", "snp-different", "2", "2", "0", "6", "-194", "ACGT"],
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "DL48", "ClusterC_ReadCount-5", "5", "4", "4", "", "", "provided-sequence", "Mamu-cDNA*001_extension", "extension", "0", "0", "2", "8", "-12", "TTTT"],
                ["93ccf25b-7870-5fdc-aa82-f98b6b7a1ca4", "DL49", "ClusterD_ReadCount-7", "7", "4", "4", "", "", "provided-sequence", "", "", "", "", "", "", "", "GGGG"],
            ]
        )
        XCTAssertEqual(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.pivotRows(rows, sampleOrder: ["DL47", "DL48"]),
            [
                [
                    "unmatched_sequence_id",
                    "occurrence_count",
                    "sample_count",
                    "total_cluster_reads",
                    "closest_match_id",
                    "match_class",
                    "nucleotides_different",
                    "snp_differences",
                    "indel_bases",
                    "aligned_bases",
                    "score",
                    "DL47",
                    "DL48",
                    "DL49",
                ],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "2", "2", "20", "Mamu-A1*001_2SNP", "snp-different", "2", "2", "0", "6", "-194", "9", "11", ""],
                ["93ccf25b-7870-5fdc-aa82-f98b6b7a1ca4", "1", "1", "7", "", "", "", "", "", "", "", "", "", "7"],
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "1", "1", "5", "Mamu-cDNA*001_extension", "extension", "0", "0", "2", "8", "-12", "", "5", ""],
            ]
        )
    }

    func testDeduplicatedUnmatchedFASTARecordsIncludeOccurrencesAndSamples() {
        let rows = [
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL47",
                cluster: "ClusterA_ReadCount-9",
                clusterReads: 9,
                sequence: "ACGT",
                closestMatch: nil
            ),
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL48",
                cluster: "ClusterB_ReadCount-11",
                clusterReads: 11,
                sequence: "ACGT",
                closestMatch: nil
            ),
        ]

        XCTAssertEqual(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.deduplicatedFASTARecords(rows),
            [
                FullLengthONTMHCClusterFASTARecord(
                    name: "1dff3e84-fe78-57e0-a73b-69bbddcf4012|occurrences=2|sample_count=2|samples=DL47;DL48|total_cluster_reads=20",
                    sequence: "ACGT",
                    readCount: 20
                ),
            ]
        )
    }

    func testUnifiedPivotPreservesKnownAllelesWhenCandidateProjectionIsEmpty() throws {
        let reportRows = [
            FullLengthONTMHCReportRow(
                sample: "DL47",
                genotype: "Mamu-A1*001",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: 100,
                sampleUniqueRetainedReads: 12,
                sampleUniqueRetainedPercent: 12,
                overallInputReads: 300,
                overallUniqueRetainedReads: 32,
                overallUniqueRetainedPercent: 10.7
            ),
            FullLengthONTMHCReportRow(
                sample: "DL48",
                genotype: "Mamu-A1*001",
                passedAlignments: 20,
                passedUniqueReads: 20,
                sampleTotalReads: 200,
                sampleUniqueRetainedReads: 20,
                sampleUniqueRetainedPercent: 10,
                overallInputReads: 300,
                overallUniqueRetainedReads: 32,
                overallUniqueRetainedPercent: 10.7
            ),
        ]
        let emptyFASTA = ONTMHCArtifactReference(path: "empty.fasta", sha256: String(repeating: "0", count: 64), sizeBytes: 0)
        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: ONTMHCCandidateAllelesDocument(
                schemaVersion: 1,
                createdAt: "2026-07-19T00:00:00Z",
                thresholds: .defaults,
                inputs: [],
                evidence: [],
                sequenceFASTA: emptyFASTA,
                candidates: [],
                observations: []
            ),
            unnameableDocument: ONTMHCUnnameableClustersDocument(
                schemaVersion: 1,
                createdAt: "2026-07-19T00:00:00Z",
                thresholds: .defaults,
                sequenceFASTA: emptyFASTA,
                clusters: [],
                observations: []
            ),
            sampleOrder: ["DL47", "DL48"]
        )

        XCTAssertEqual(
            FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildRows(
                reportRows: reportRows,
                projection: projection,
                sampleOrder: ["DL47", "DL48"]
            ),
            [
                [
                    "call_type",
                    "call_id",
                    "display_name",
                    "stable_cluster_id",
                    "locus",
                    "classification",
                    "support_class",
                    "closest_reference",
                    "match_class",
                    "occurrence_count",
                    "sample_count",
                    "total_cluster_reads",
                    "DL47",
                    "DL48",
                ],
                ["known-allele", "Mamu-A1*001", "Mamu-A1*001", "", "", "known", "", "Mamu-A1*001", "exact", "2", "2", "32", "12", "20"],
            ]
        )
    }

    func testMHCLikeWorkbookRowsIncludeOriginalAndBlastRescuedMatchesOnly() {
        let original = FullLengthONTMHCClosestMatch(
            sample: "DL47",
            cluster: "ClusterA_ReadCount-9",
            clusterReads: 9,
            closestReference: "Mamu-A1*001",
            matchClass: .snpDifferent,
            closestMatchID: "Mamu-A1*001_2SNP",
            nucleotidesDifferent: 2,
            snpDifferences: 2,
            indelBases: 0,
            alignedBases: 6,
            score: -194
        )
        let rescue = FullLengthONTMHCBlastRescueMatch(
            sample: "DL48",
            cluster: "ClusterB_ReadCount-11",
            clusterReads: 11,
            closestReference: "Mamu-G*02_nov01b",
            percentIdentity: 99.966,
            queryCoverage: 98.0,
            alignedBases: 2_892,
            mismatches: 1,
            gapOpens: 0,
            eValue: 0,
            bitScore: 5_341,
            closestMatchID: "Mamu-G*02_nov01b_blast-rescue"
        )
        let rows = [
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL47",
                cluster: "ClusterA_ReadCount-9",
                clusterReads: 9,
                sequence: "ACGT",
                closestMatch: original
            ),
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL48",
                cluster: "ClusterB_ReadCount-11",
                clusterReads: 11,
                sequence: "TTTT",
                closestMatch: nil,
                rescueMatch: rescue
            ),
            FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: "DL49",
                cluster: "ClusterC_ReadCount-7",
                clusterReads: 7,
                sequence: "GGGG",
                closestMatch: nil
            ),
        ]

        XCTAssertEqual(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.mhcLikeDetailRows(rows),
            [
                [
                    "unmatched_sequence_id",
                    "sample",
                    "cluster",
                    "cluster_reads",
                    "raw_length",
                    "trimmed_length",
                    "trim_start",
                    "trim_end",
                    "trim_source",
                    "match_source",
                    "closest_match_id",
                    "closest_reference",
                    "match_class",
                    "nucleotides_different",
                    "snp_differences",
                    "indel_bases",
                    "aligned_bases",
                    "score",
                    "percent_identity",
                    "query_coverage",
                    "evalue",
                    "bitscore",
                    "sequence",
                ],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "DL47", "ClusterA_ReadCount-9", "9", "4", "4", "", "", "provided-sequence", "genotyping-sam", "Mamu-A1*001_2SNP", "Mamu-A1*001", "snp-different", "2", "2", "0", "6", "-194", "", "", "", "", "ACGT"],
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "DL48", "ClusterB_ReadCount-11", "11", "4", "4", "", "", "provided-sequence", "local-blast-rescue", "Mamu-G*02_nov01b_blast-rescue", "Mamu-G*02_nov01b", "blast-rescue", "", "", "", "2892", "", "99.966", "98", "0", "5341", "TTTT"],
            ]
        )
        XCTAssertEqual(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.mhcLikePivotRows(rows, sampleOrder: ["DL47", "DL48"]),
            [
                [
                    "unmatched_sequence_id",
                    "occurrence_count",
                    "sample_count",
                    "total_cluster_reads",
                    "match_source",
                    "closest_match_id",
                    "closest_reference",
                    "match_class",
                    "nucleotides_different",
                    "percent_identity",
                    "query_coverage",
                    "evalue",
                    "bitscore",
                    "DL47",
                    "DL48",
                ],
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "1", "1", "11", "local-blast-rescue", "Mamu-G*02_nov01b_blast-rescue", "Mamu-G*02_nov01b", "blast-rescue", "", "99.966", "98", "0", "5341", "", "11"],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "1", "1", "9", "genotyping-sam", "Mamu-A1*001_2SNP", "Mamu-A1*001", "snp-different", "2", "", "", "", "", "9", ""],
            ]
        )
    }

    func testBlastRescueParserAppliesThresholdsAndChoosesBestHit() throws {
        let tsv = """
        ClusterA_ReadCount-9\tMamu-B*001\t80.0\t1200\t240\t2\t1\t1200\t1\t1200\t1e-40\t900\t1500\t1800
        ClusterA_ReadCount-9\tMamu-A*001\t80.0\t1200\t240\t2\t1\t1200\t1\t1200\t1e-50\t910\t1500\t1800
        ClusterB_ReadCount-7\tMamu-C*001\t90.0\t600\t60\t0\t1\t600\t1\t600\t1e-80\t700\t1500\t1800
        ClusterC_ReadCount-5\tMamu-D*001\t70.0\t1300\t390\t4\t1\t1300\t1\t1300\t1e-80\t700\t1500\t1800
        """
        let records = [
            FullLengthONTMHCClusterFASTARecord(name: "ClusterA_ReadCount-9", sequence: String(repeating: "A", count: 1_500), readCount: 9),
            FullLengthONTMHCClusterFASTARecord(name: "ClusterB_ReadCount-7", sequence: String(repeating: "C", count: 1_500), readCount: 7),
            FullLengthONTMHCClusterFASTARecord(name: "ClusterC_ReadCount-5", sequence: String(repeating: "G", count: 1_500), readCount: 5),
        ]

        let matches = try FullLengthONTMHCBlastRescueParser.acceptedMatches(
            sample: "DL47",
            recordsByCluster: Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) }),
            tsv: tsv
        )

        XCTAssertEqual(matches.map(\.cluster), ["ClusterA_ReadCount-9"])
        XCTAssertEqual(matches.first?.closestReference, "Mamu-A*001")
        XCTAssertEqual(matches.first?.queryCoverage, 80.0)
        XCTAssertEqual(matches.first?.closestMatchID, "Mamu-A*001_blast-rescue")
    }

    func testXLSXPackageWriterDoesNotIncludeTempMetadataAndWritesUnmatchedSheet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workbookURL = root.appendingPathComponent("genotypes.xlsx")

        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: [
                .init(name: "Interpretation Guide", rows: [["Field", "Interpretation"], ["Score formula", "score = aligned_bases - (100 * snp_differences) - (10 * indel_bases)"]]),
                .init(name: "Samples", rows: [["sample", "total_input_reads"], ["DL47", "1966"]]),
                .init(name: "Genotypes", rows: [["sample", "genotype", "cluster"], ["DL47", "Mamu-A1*004:01:01:01", "Cluster0"]]),
                .init(name: "Genotyping pivot", rows: [["Client ID", "", "", "DL47"]]),
                .init(name: "Unmatched Clusters", rows: [["sample", "cluster", "sequence"], ["DL47", "Cluster9", "ACGT"]]),
                .init(name: "Unmatched Shared Pivot", rows: [["unmatched_sequence_id", "DL47"], ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "8"]]),
            ],
            to: workbookURL
        )

        let entries = try Self.zipEntries(workbookURL)
        XCTAssertFalse(entries.contains(".lungfish-temp-origin.json"))
        XCTAssertTrue(entries.contains("[Content_Types].xml"))
        XCTAssertTrue(entries.contains("xl/worksheets/sheet6.xml"))
        XCTAssertFalse(entries.contains("xl/worksheets/sheet7.xml"))

        let workbookXML = try Self.unzippedText(path: "xl/workbook.xml", from: workbookURL)
        XCTAssertEqual(
            Self.sheetNames(in: workbookXML),
            [
                "Interpretation Guide",
                "Samples",
                "Genotypes",
                "Genotyping pivot",
                "Unmatched Clusters",
                "Unmatched Shared Pivot",
            ]
        )
        XCTAssertFalse(workbookXML.contains("Unmatched Closest Matches"))
        XCTAssertFalse(workbookXML.contains("Cluster Alignments"))
        XCTAssertFalse(workbookXML.contains("Full Sequencing Results 1"))
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

    private func directoryFileSnapshot(_ directoryURL: URL) throws -> [String: Data] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: directoryURL.path).sorted()
        var snapshot: [String: Data] = [:]
        for path in paths {
            let url = directoryURL.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            snapshot[path] = try Data(contentsOf: url)
        }
        return snapshot
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

    private func makeFakeFullLengthRun(
        root: URL,
        savontScript: String? = nil,
        minimap2Script: String? = nil,
        blastnScript: String? = nil,
        referenceSourceURL: URL? = nil,
        failFinalBAMView: Bool = false,
        postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner(),
        metadataPublicationObserver: @escaping @Sendable (FullLengthONTMHCMetadataPublicationEvent) throws -> Void = { _ in }
    ) throws -> (
        FullLengthONTMHCGenotypingRunRequest,
        FullLengthONTMHCGenotypingPipeline
    ) {
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let condaRoot = CoreToolLocator.condaRoot(homeDirectory: homeDirectory)
        let bundledMicromamba = try makeFakeFullLengthCondaRoot(
            at: condaRoot,
            savontScript: savontScript,
            minimap2Script: minimap2Script,
            blastnScript: blastnScript
        )
        if failFinalBAMView {
            try Data().write(
                to: condaRoot.appendingPathComponent("envs/samtools/bin/fail-final-view")
            )
        }
        let inputFASTQ = root.appendingPathComponent("DL46.fastq")
        let referenceFASTA = referenceSourceURL ?? root.appendingPathComponent("reference.fasta")
        let outputDirectory = root.appendingPathComponent("full-length.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "@read-1\nACGTACGT\n+\nIIIIIIII\n".write(to: inputFASTQ, atomically: true, encoding: .utf8)
        if referenceSourceURL == nil {
            try ">allele1\nACGTACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        }
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [inputFASTQ],
            referenceSourceURL: referenceFASTA,
            outputDirectory: outputDirectory,
            outputName: "full-length",
            threads: 2,
            minimumLength: 4,
            maximumLength: 12
        )
        let pipeline = FullLengthONTMHCGenotypingPipeline(
            nativeToolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory),
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            ),
            postPublicationWorkDirectoryCleaner: postPublicationWorkDirectoryCleaner,
            metadataPublicationObserver: metadataPublicationObserver
        )
        return (request, pipeline)
    }

    private func assertSuccessfulPublishedEvidence(
        result: FullLengthONTMHCGenotypingResult,
        request: FullLengthONTMHCGenotypingRunRequest
    ) throws {
        let bamURL = try XCTUnwrap(result.genotypingEvidenceBAMURL)
        let baiURL = try XCTUnwrap(result.genotypingEvidenceBAIURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: baiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.provenanceURL.path))
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: request.outputDirectory)
        let evidence = try XCTUnwrap(manifest.mhcCandidateArtifacts?.genotypingEvidence)
        XCTAssertEqual(evidence.bam.sha256, try ProvenanceFileHasher.sha256(of: bamURL))
        XCTAssertEqual(evidence.bai.sha256, try ProvenanceFileHasher.sha256(of: baiURL))
        XCTAssertNotNil(try ProvenanceEnvelopeReader.load(fromSidecar: request.provenanceURL))
    }

    private func makeFakeFullLengthCondaRoot(
        at root: URL,
        savontScript: String? = nil,
        minimap2Script: String? = nil,
        blastnScript: String? = nil,
        samtoolsScript: String? = nil
    ) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let micromambaScript = #"""
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
          echo "test-micromamba"
          exit 0
        fi
        if [ "${1:-}" != "run" ]; then
          echo "unsupported micromamba invocation: $*" >&2
          exit 2
        fi
        shift
        if [ "${1:-}" != "-n" ]; then
          echo "missing environment" >&2
          exit 2
        fi
        env_name="$2"
        shift 2
        tool="$1"
        shift
        exec "$MAMBA_ROOT_PREFIX/envs/$env_name/bin/$tool" "$@"
        """#
        let bundledMicromamba = root.deletingLastPathComponent().appendingPathComponent("bundled-micromamba")
        try writeExecutable(micromambaScript, to: bundledMicromamba)
        try writeExecutable(micromambaScript, to: bin.appendingPathComponent("micromamba"))

        let bbtoolsBin = root.appendingPathComponent("envs/bbtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bbtoolsBin, withIntermediateDirectories: true)
        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            if [ "${1:-}" = "--version" ]; then
              echo "reformat.sh 39.01"
              exit 0
            fi
            input=""
            output=""
            for arg in "$@"; do
              case "$arg" in
                in=*) input="${arg#in=}" ;;
                out=*) output="${arg#out=}" ;;
              esac
            done
            if [ -z "$input" ] || [ -z "$output" ]; then
              echo "missing in= or out=" >&2
              exit 2
            fi
            cp "$input" "$output"
            """#,
            to: bbtoolsBin.appendingPathComponent("reformat.sh")
        )

        let savontBin = root.appendingPathComponent("envs/savont/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: savontBin, withIntermediateDirectories: true)
        try writeExecutable(
            savontScript ?? #"""
            #!/bin/sh
            set -eu
            if [ "${1:-}" = "--version" ]; then
              echo "savont 0.5.0"
              exit 0
            fi
            if [ "${1:-}" != "asv" ]; then
              echo "unsupported savont invocation: $*" >&2
              exit 2
            fi
            shift
            input="$1"
            shift
            output=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o)
                  output="$2"
                  shift 2
                  ;;
                *)
                  shift
                  ;;
              esac
            done
            if [ -z "$output" ]; then
              echo "missing -o" >&2
              exit 2
            fi
            mkdir -p "$output/temp"
            cat > "$output/final_asvs.fasta" <<'EOF'
            >final_consensus_0_depth_7
            ACGTACGT
            EOF
            printf 'savont log for %s\n' "$input" > "$output/savont_2026-06-10_05-09-37.log"
            printf 'feature table\n' > "$output/feature-table.tsv"
            printf 'final clusters\n' > "$output/final_clusters.tsv"
            printf 'read mappings\n' > "$output/temp/read_to_asv_mappings.tsv"
            """#,
            to: savontBin.appendingPathComponent("savont")
        )

        let minimap2Bin = root.appendingPathComponent("envs/minimap2/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap2Bin, withIntermediateDirectories: true)
        try writeExecutable(
            minimap2Script ?? #"""
            #!/bin/sh
            set -eu
            if [ "${1:-}" = "--version" ]; then
              echo "minimap2 2.28"
              exit 0
            fi
            previous=""
            current=""
            for arg in "$@"; do previous="$current"; current="$arg"; done
            target_fasta="$previous"
            query_fasta="$current"
            query=$(awk '/^>/{sub(/^>/, ""); print $1; exit}' "$query_fasta")
            target=$(awk '/^>/{sub(/^>/, ""); print $1; exit}' "$target_fasta")
            printf '@SQ\tSN:%s\tLN:8\n' "$target"
            if [ -n "$query" ]; then
              printf '%s\t0\t%s\t1\t60\t8=\t*\t0\t0\tACGTACGT\t*\tNM:i:0\tAS:i:8\n' "$query" "$target"
            fi
            """#,
            to: minimap2Bin.appendingPathComponent("minimap2")
        )

        let samtoolsBin = root.appendingPathComponent("envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: samtoolsBin, withIntermediateDirectories: true)
        try writeExecutable(
            samtoolsScript ?? #"""
            #!/bin/sh
            set -eu
            if [ "${1:-}" = "--version" ]; then
              echo "samtools 1.21-fake"
              exit 0
            fi
            command="$1"
            shift
            case "$command" in
              view)
                if [ "${1:-}" = "-h" ]; then
                  if [ -f "$(dirname "$0")/fail-final-view" ]; then
                    echo "forced final BAM view failure" >&2
                    exit 42
                  fi
                  cat "$2"
                  exit 0
                fi
                [ "${1:-}" = "-b" ] && shift
                [ "${1:-}" = "-o" ] || exit 90
                output="$2"
                input="$3"
                cp "$input" "$output"
                ;;
              addreplacerg)
                [ "${1:-}" = "-r" ] || exit 91
                rg_id="${2#ID:}"
                shift 2
                [ "${1:-}" = "-r" ] || exit 92
                rg_sm="${2#SM:}"
                shift 2
                [ "${1:-}" = "-o" ] || exit 93
                output="$2"
                input="$3"
                awk -v id="$rg_id" -v sm="$rg_sm" 'BEGIN {printf "@RG\tID:%s\tSM:%s\n", id, sm} /^@/ {print; next} {print $0 "\tRG:Z:" id}' "$input" > "$output"
                ;;
              sort)
                [ "${1:-}" = "-o" ] || exit 94
                cp "$3" "$2"
                ;;
              merge)
                [ "${1:-}" = "-f" ] || exit 95
                shift
                [ "${1:-}" = "-o" ] || exit 96
                output="$2"
                shift 2
                : > "$output"
                for input in "$@"; do cat "$input" >> "$output"; done
                ;;
              index)
                printf 'index for %s\n' "$1" > "$2"
                ;;
              quickcheck)
                [ -f "$1" ] || exit 97
                ;;
              idxstats)
                [ -f "$1" ] || exit 98
                [ -f "$1.bai" ] || exit 99
                printf 'cohort-target\t8\t1\t0\n'
                ;;
              *)
                echo "unsupported samtools invocation: $command $*" >&2
                exit 100
                ;;
            esac
            """#,
            to: samtoolsBin.appendingPathComponent("samtools")
        )

        let blastBin = root.appendingPathComponent("envs/blast/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: blastBin, withIntermediateDirectories: true)
        try writeExecutable(
            blastnScript ?? #"""
            #!/bin/sh
            set -eu
            if [ "${1:-}" = "-version" ]; then
              echo "blastn: 2.16.0+"
              exit 0
            fi
            exit 0
            """#,
            to: blastBin.appendingPathComponent("blastn")
        )

        return bundledMicromamba
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

    private static func sheetNames(in workbookXML: String) -> [String] {
        let pattern = #"<sheet name="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(workbookXML.startIndex..<workbookXML.endIndex, in: workbookXML)
        return regex.matches(in: workbookXML, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: workbookXML) else { return nil }
            return String(workbookXML[nameRange])
        }
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

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct SelectiveFailingPostPublicationCleaner: FullLengthONTMHCWorkDirectoryCleaning {
    enum Target: Sendable {
        case workflowIntermediates
        case cohortAlignmentTemporaryWorkDirectory
    }

    let target: Target

    func removeWorkDirectory(at url: URL) throws {
        let shouldFail: Bool
        let label: String
        switch target {
        case .workflowIntermediates:
            shouldFail = url.lastPathComponent == "workflow"
            label = "workflow intermediates"
        case .cohortAlignmentTemporaryWorkDirectory:
            shouldFail = url.lastPathComponent.hasPrefix("full-length-ont-mhc-cohort-alignment-")
            label = "cohort alignment temporary work directory"
        }
        if shouldFail {
            throw InjectedPostPublicationCleanupFailure(label: label)
        }
        try DefaultFullLengthONTMHCWorkDirectoryCleaner().removeWorkDirectory(at: url)
    }

    private struct InjectedPostPublicationCleanupFailure: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "injected \(label) cleanup failure" }
    }
}

private struct InjectedPostSwapFailure: Error, LocalizedError {
    var errorDescription: String? { "injected post-swap failure" }
}

private final class MetadataPublicationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let failAfterProvenance: Bool
    private var didObserveProvenanceBoundary = false
    private var manifestAbsentAtBoundary = false
    private var capturedStagedManifestURL: URL?
    private var didObserveFinalProvenanceBoundary = false
    private var didObserveManifestPublication = false
    private var capturedFinalizedProvenanceChecksum: String?

    init(failAfterProvenance: Bool) {
        self.failAfterProvenance = failAfterProvenance
    }

    var observedProvenanceBoundary: Bool {
        lock.withLock { didObserveProvenanceBoundary }
    }

    var manifestWasAbsentAtProvenanceBoundary: Bool {
        lock.withLock { manifestAbsentAtBoundary }
    }

    var stagedManifestURL: URL? {
        lock.withLock { capturedStagedManifestURL }
    }

    var observedFinalProvenanceBoundary: Bool {
        lock.withLock { didObserveFinalProvenanceBoundary }
    }

    var observedManifestPublication: Bool {
        lock.withLock { didObserveManifestPublication }
    }

    var finalizedProvenanceChecksum: String? {
        lock.withLock { capturedFinalizedProvenanceChecksum }
    }

    func observe(_ event: FullLengthONTMHCMetadataPublicationEvent) throws {
        if case .provenanceFinalizedBeforeManifestPublication(_, let provenanceURL) = event {
            let checksum = try ProvenanceFileHasher.sha256(of: provenanceURL)
            lock.withLock {
                didObserveFinalProvenanceBoundary = true
                capturedFinalizedProvenanceChecksum = checksum
            }
            return
        }
        if case .successManifestPublished = event {
            lock.withLock { didObserveManifestPublication = true }
            return
        }
        guard case .provenanceWrittenBeforeManifestPublication(
            let stagedManifestURL,
            let finalManifestURL,
            let provenanceURL
        ) = event else { return }
        lock.withLock {
            didObserveProvenanceBoundary = true
            manifestAbsentAtBoundary = !FileManager.default.fileExists(atPath: finalManifestURL.path)
                && FileManager.default.fileExists(atPath: provenanceURL.path)
            capturedStagedManifestURL = stagedManifestURL
        }
        if failAfterProvenance {
            throw InjectedMetadataPublicationFailure()
        }
    }

    private struct InjectedMetadataPublicationFailure: Error, LocalizedError {
        var errorDescription: String? { "injected post-provenance failure" }
    }
}

private final class RunLockBoundaryGate: @unchecked Sendable {
    private let acquired = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func observe(_ event: FullLengthONTMHCMetadataPublicationEvent) throws {
        guard case .runLockAcquired = event else { return }
        acquired.signal()
        release.wait()
        throw InjectedRunLockStop()
    }

    func waitUntilLockAcquired() -> DispatchTimeoutResult {
        acquired.wait(timeout: .now() + 10)
    }

    func releaseFirstRun() {
        release.signal()
    }

    private struct InjectedRunLockStop: Error, LocalizedError {
        var errorDescription: String? { "injected stop after run lock" }
    }
}

private final class OutputParentPreparationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let outputDirectory: URL
    private var observed = false
    private var parentExisted = false
    private var resultWasAbsent = false

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory.standardizedFileURL
    }

    var observedLockBoundary: Bool {
        lock.withLock { observed }
    }

    var parentExistedAtLockBoundary: Bool {
        lock.withLock { parentExisted }
    }

    var resultWasAbsentAtLockBoundary: Bool {
        lock.withLock { resultWasAbsent }
    }

    func observe(_ event: FullLengthONTMHCMetadataPublicationEvent) {
        guard case .runLockAcquired = event else { return }
        lock.withLock {
            observed = true
            parentExisted = FileManager.default.fileExists(
                atPath: outputDirectory.deletingLastPathComponent().path
            )
            resultWasAbsent = !FileManager.default.fileExists(atPath: outputDirectory.path)
        }
    }
}
