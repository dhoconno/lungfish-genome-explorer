import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCGenotypingPipelineTests: XCTestCase {
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

        let workflowDirectory = outputDirectory.appendingPathComponent("workflow", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workflowDirectory.path),
            "Regenerable full-length ONT MHC workflow intermediates should be removed after provenance is written."
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
        XCTAssertFalse(
            envelope.outputs.contains { $0.path.contains("/workflow/") },
            "Regenerable workflow intermediates must not be top-level durable provenance outputs."
        )
        let retainedLogSuffix = "/samples/DL46/savont/raw/savont_2026-06-10_05-09-37.log"
        XCTAssertTrue(
            envelope.outputs.contains { $0.path.hasSuffix(retainedLogSuffix) },
            "Expected retained Savont log in outputs. Outputs: \(envelope.outputs.map(\.path))"
        )

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
            ]
        )
        XCTAssertFalse(workbookXML.contains("Cluster Alignments"))
        XCTAssertFalse(workbookXML.contains("Unmatched Closest Matches"))
        XCTAssertFalse(workbookXML.contains("Full Sequencing Results 1"))

        let guideSheetXML = try Self.unzippedText(path: "xl/worksheets/sheet1.xml", from: result.workbookURL)
        XCTAssertTrue(guideSheetXML.contains("Full-length ONT MHC genotyping"))
        XCTAssertTrue(guideSheetXML.contains("score = aligned_bases - (100 * snp_differences) - (10 * indel_bases)"))
        XCTAssertTrue(guideSheetXML.contains("Exact genotype calls require zero SNP differences and zero indel bases."))
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
        let minimapSteps = envelope.steps.filter { $0.toolName == "minimap2" }
        XCTAssertEqual(minimapSteps.count, 1)
        let reuseStep = try XCTUnwrap(envelope.steps.first {
            $0.toolName == "lungfish full-length ONT MHC sample checkpoint reuse"
        })
        XCTAssertTrue(reuseStep.inputs.contains { $0.path == checkpointURL.path })
        XCTAssertTrue(reuseStep.outputs.contains {
            $0.path.hasSuffix("/samples/DL46/savont/DL46.savont-clusters.fasta")
        })
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
        printf '@SQ\tSN:final_consensus_0_depth_7_ReadCount-7\tLN:8\n'
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
                score: -194
            ),
        ])
    }

    func testClusterGenotyperTreatsZeroSNPIndelOnlyHitAsExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-closest-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusters = root.appendingPathComponent("clusters.fasta")
        let reference = root.appendingPathComponent("reference.fasta")
        try """
        >ClusterExtension_ReadCount-11
        ACGTACGTAA
        """.write(to: clusters, atomically: true, encoding: .utf8)
        try """
        >Mamu-cDNA*001
        ACGTACGT
        """.write(to: reference, atomically: true, encoding: .utf8)
        let sam = """
        @SQ\tSN:ClusterExtension_ReadCount-11\tLN:10
        Mamu-cDNA*001\t0\tClusterExtension_ReadCount-11\t1\t60\t8=2I\t*\t0\t0\tACGTACGTAA\t*
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
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["ClusterExtension_ReadCount-11"])
        XCTAssertEqual(summary.closestMatches, [
            FullLengthONTMHCClosestMatch(
                sample: "DL48",
                cluster: "ClusterExtension_ReadCount-11",
                clusterReads: 11,
                closestReference: "Mamu-cDNA*001",
                matchClass: .extension,
                closestMatchID: "Mamu-cDNA*001_extension",
                nucleotidesDifferent: 0,
                snpDifferences: 0,
                indelBases: 2,
                alignedBases: 8,
                score: -12
            ),
        ])
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
                    "closest_match_id",
                    "match_class",
                    "nucleotides_different",
                    "snp_differences",
                    "indel_bases",
                    "aligned_bases",
                    "score",
                    "sequence",
                ],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "DL47", "ClusterA_ReadCount-9", "9", "Mamu-A1*001_2SNP", "snp-different", "2", "2", "0", "6", "-194", "ACGT"],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "DL48", "ClusterB_ReadCount-11", "11", "Mamu-A1*001_2SNP", "snp-different", "2", "2", "0", "6", "-194", "ACGT"],
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "DL48", "ClusterC_ReadCount-5", "5", "Mamu-cDNA*001_extension", "extension", "0", "0", "2", "8", "-12", "TTTT"],
                ["93ccf25b-7870-5fdc-aa82-f98b6b7a1ca4", "DL49", "ClusterD_ReadCount-7", "7", "", "", "", "", "", "", "", "GGGG"],
            ]
        )
        XCTAssertEqual(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.pivotRows(rows, sampleOrder: ["DL47", "DL48"]),
            [
                [
                    "unmatched_sequence_id",
                    "occurrence_count",
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
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "2", "20", "Mamu-A1*001_2SNP", "snp-different", "2", "2", "0", "6", "-194", "9", "11", ""],
                ["93ccf25b-7870-5fdc-aa82-f98b6b7a1ca4", "1", "7", "", "", "", "", "", "", "", "", "", "7"],
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "1", "5", "Mamu-cDNA*001_extension", "extension", "0", "0", "2", "8", "-12", "", "5", ""],
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
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "DL47", "ClusterA_ReadCount-9", "9", "genotyping-sam", "Mamu-A1*001_2SNP", "Mamu-A1*001", "snp-different", "2", "2", "0", "6", "-194", "", "", "", "", "ACGT"],
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "DL48", "ClusterB_ReadCount-11", "11", "local-blast-rescue", "Mamu-G*02_nov01b_blast-rescue", "Mamu-G*02_nov01b", "blast-rescue", "", "", "", "2892", "", "99.966", "98", "0", "5341", "TTTT"],
            ]
        )
        XCTAssertEqual(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.mhcLikePivotRows(rows, sampleOrder: ["DL47", "DL48"]),
            [
                [
                    "unmatched_sequence_id",
                    "occurrence_count",
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
                ["3fd8b2c4-aea7-54d9-90ec-b00284070196", "1", "11", "local-blast-rescue", "Mamu-G*02_nov01b_blast-rescue", "Mamu-G*02_nov01b", "blast-rescue", "", "99.966", "98", "0", "5341", "", "11"],
                ["1dff3e84-fe78-57e0-a73b-69bbddcf4012", "1", "9", "genotyping-sam", "Mamu-A1*001_2SNP", "Mamu-A1*001", "snp-different", "2", "", "", "", "", "9", ""],
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
        blastnScript: String? = nil
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
        return (request, pipeline)
    }

    private func makeFakeFullLengthCondaRoot(
        at root: URL,
        savontScript: String? = nil,
        minimap2Script: String? = nil,
        blastnScript: String? = nil
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
            printf '@SQ\tSN:final_consensus_0_depth_7_ReadCount-7\tLN:8\n'
            printf 'allele1\t0\tfinal_consensus_0_depth_7_ReadCount-7\t1\t60\t8=\t*\t0\t0\tACGTACGT\t*\n'
            """#,
            to: minimap2Bin.appendingPathComponent("minimap2")
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
