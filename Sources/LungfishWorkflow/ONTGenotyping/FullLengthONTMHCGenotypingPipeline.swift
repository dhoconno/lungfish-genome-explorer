import Foundation
import LungfishCore
import LungfishIO

public struct FullLengthONTMHCGenotypingRunRequest: Sendable, Codable, Equatable {
    public static let defaultPBAAExtraArgumentsText = "--min-cluster-read-count 3 --min-cluster-frequency 0.01"

    public let inputFASTQURLs: [URL]
    public let referenceSourceURL: URL
    public let guideSourceURL: URL
    public let orientReferenceURL: URL?
    public let forwardPrimerURL: URL?
    public let reversePrimerURL: URL?
    public let outputDirectory: URL
    public let outputName: String
    public let projectURL: URL?
    public let threads: Int
    public let minimumLength: Int
    public let maximumLength: Int
    public let pbaaSeed: Int
    public let pbaaExtraArgumentsText: String
    public let minUnmatchedReads: Int
    public let cdnaThreshold: Int

    public init(
        inputFASTQURLs: [URL],
        referenceSourceURL: URL,
        guideSourceURL: URL,
        orientReferenceURL: URL? = nil,
        forwardPrimerURL: URL? = nil,
        reversePrimerURL: URL? = nil,
        outputDirectory: URL,
        outputName: String = "full-length-ont-mhc-genotyping",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minimumLength: Int = 2_000,
        maximumLength: Int = 4_000,
        pbaaSeed: Int = 1984,
        pbaaExtraArgumentsText: String = Self.defaultPBAAExtraArgumentsText,
        minUnmatchedReads: Int = 5,
        cdnaThreshold: Int = 2_000
    ) {
        let normalizedOutputName = Self.sanitizedOutputName(outputName)
        self.inputFASTQURLs = inputFASTQURLs.map(\.standardizedFileURL)
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        self.guideSourceURL = guideSourceURL.standardizedFileURL
        self.orientReferenceURL = orientReferenceURL?.standardizedFileURL
        self.forwardPrimerURL = forwardPrimerURL?.standardizedFileURL
        self.reversePrimerURL = reversePrimerURL?.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = normalizedOutputName
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.minimumLength = max(1, minimumLength)
        self.maximumLength = max(self.minimumLength, maximumLength)
        self.pbaaSeed = pbaaSeed
        self.pbaaExtraArgumentsText = pbaaExtraArgumentsText
        self.minUnmatchedReads = max(1, minUnmatchedReads)
        self.cdnaThreshold = max(1, cdnaThreshold)
    }

    public var reportCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.csv")
    }

    public var sampleSummaryCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-samples.csv")
    }

    public var statsJSONURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-stats.json")
    }

    public var workbookURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.xlsx")
    }

    public var unmatchedClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("unmatched_clusters.fasta")
    }

    public var cdnaClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("cdna_clusters.fasta")
    }

    public var provenanceURL: URL {
        outputDirectory.appendingPathComponent("full-length-ont-mhc-genotyping-provenance.json")
    }

    public var manifestURL: URL {
        ONTGenotypeResultBundle.manifestURL(in: outputDirectory)
    }

    public var argv: [String] {
        var values = [
            "lungfish",
            "fastq",
            "full-length-ont-mhc-genotype",
        ] + inputFASTQURLs.map(\.path) + [
            "--reference", referenceSourceURL.path,
            "--guide", guideSourceURL.path,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--min-length", String(minimumLength),
            "--max-length", String(maximumLength),
            "--pbaa-seed", String(pbaaSeed),
            "--pbaa-extra-args", pbaaExtraArgumentsText,
            "--min-unmatched-reads", String(minUnmatchedReads),
            "--cdna-threshold", String(cdnaThreshold),
        ]
        if let orientReferenceURL {
            values += ["--orient-reference", orientReferenceURL.path]
        }
        if let forwardPrimerURL {
            values += ["--forward-primer", forwardPrimerURL.path]
        }
        if let reversePrimerURL {
            values += ["--reverse-primer", reversePrimerURL.path]
        }
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        return values
    }

    public func replacingOutput(outputDirectory: URL, outputName: String) -> FullLengthONTMHCGenotypingRunRequest {
        FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: inputFASTQURLs,
            referenceSourceURL: referenceSourceURL,
            guideSourceURL: guideSourceURL,
            orientReferenceURL: orientReferenceURL,
            forwardPrimerURL: forwardPrimerURL,
            reversePrimerURL: reversePrimerURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            projectURL: projectURL,
            threads: threads,
            minimumLength: minimumLength,
            maximumLength: maximumLength,
            pbaaSeed: pbaaSeed,
            pbaaExtraArgumentsText: pbaaExtraArgumentsText,
            minUnmatchedReads: minUnmatchedReads,
            cdnaThreshold: cdnaThreshold
        )
    }

    private static func sanitizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "full-length-ont-mhc-genotyping" : collapsed
    }
}

public struct FullLengthONTMHCGenotypingResult: Sendable, Codable, Equatable {
    public let outputDirectory: URL
    public let reportCSVURL: URL
    public let sampleSummaryCSVURL: URL
    public let statsJSONURL: URL
    public let workbookURL: URL
    public let unmatchedClustersFASTAURL: URL
    public let cdnaClustersFASTAURL: URL
    public let provenanceURL: URL
    public let referenceFASTAURL: URL
    public let guideFASTAURL: URL
}

public enum FullLengthONTMHCGenotypingError: Error, LocalizedError, Sendable, Equatable {
    case missingInput(String)
    case invalidReference(String)
    case invalidGuide(String)
    case invalidFASTQ(String)
    case processFailed(tool: String, status: Int32, stderr: String)
    case reportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let path):
            return "Input does not exist: \(path)"
        case .invalidReference(let path):
            return "Could not resolve an MHC reference FASTA from \(path)."
        case .invalidGuide(let path):
            return "Could not resolve a guide FASTA from \(path)."
        case .invalidFASTQ(let path):
            return "Could not resolve a FASTQ payload from \(path)."
        case .processFailed(let tool, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(tool) failed with exit status \(status)."
                : "\(tool) failed with exit status \(status): \(detail)"
        case .reportFailed(let reason):
            return "Could not write full-length ONT MHC genotyping report: \(reason)"
        }
    }
}

public struct FullLengthONTMHCGenotypingPipeline: Sendable {
    private let nativeToolRunner: NativeToolRunner
    private let condaManager: CondaManager
    private let pbaaPipeline: PBAAClusteringPipeline

    public init(
        nativeToolRunner: NativeToolRunner = .shared,
        condaManager: CondaManager = .shared,
        pbaaPipeline: PBAAClusteringPipeline = PBAAClusteringPipeline()
    ) {
        self.nativeToolRunner = nativeToolRunner
        self.condaManager = condaManager
        self.pbaaPipeline = pbaaPipeline
    }

    public func run(
        _ request: FullLengthONTMHCGenotypingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> FullLengthONTMHCGenotypingResult {
        let startedAt = Date()
        progressHandler?(0.01, "Validating full-length ONT MHC genotyping inputs.")
        try validateInputs(request)
        let referenceFASTAURL = try resolveMHCReferenceFASTA(request.referenceSourceURL)
        let guideFASTAURL = try resolveGuideFASTA(request.guideSourceURL)

        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let workDirectory = request.outputDirectory.appendingPathComponent("workflow", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: request.outputDirectory.appendingPathComponent("samples", isDirectory: true),
            withIntermediateDirectories: true
        )

        var allGenotypeRows: [FullLengthONTMHCClusterGenotypeRow] = []
        var sampleCounts: [String: Int] = [:]
        var sampleSummaries: [FullLengthONTMHCSampleSummary] = []
        var pipelineSteps: [FullLengthONTMHCProvenanceStep] = []
        var sampleNameCounts: [String: Int] = [:]
        try Data().write(to: request.unmatchedClustersFASTAURL, options: .atomic)
        try Data().write(to: request.cdnaClustersFASTAURL, options: .atomic)

        for (index, inputURL) in request.inputFASTQURLs.enumerated() {
            let sampleBaseName = sampleName(for: inputURL, fallbackIndex: index)
            let sampleOccurrence = (sampleNameCounts[sampleBaseName] ?? 0) + 1
            sampleNameCounts[sampleBaseName] = sampleOccurrence
            let sample = sampleOccurrence == 1 ? sampleBaseName : "\(sampleBaseName)-\(sampleOccurrence)"
            progressHandler?(0.05 + Double(index) / max(1.0, Double(request.inputFASTQURLs.count)) * 0.72, "Processing \(sample).")
            let sampleDirectory = workDirectory.appendingPathComponent(sample, isDirectory: true)
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)

            let materializedFASTQ = try materializeFASTQ(
                inputURL: inputURL,
                sample: sample,
                sampleDirectory: sampleDirectory
            )
            sampleCounts[sample] = fastqReadCount(materializedFASTQ)

            let preparedFASTA = try await prepareReadsForPBAA(
                inputFASTQ: materializedFASTQ,
                sample: sample,
                sampleDirectory: sampleDirectory,
                request: request,
                steps: &pipelineSteps
            )

            let pbaaRequest = try PBAAClusteringRunRequest(
                inputFASTQURL: preparedFASTA,
                guideSourceURL: guideFASTAURL,
                outputDirectory: request.outputDirectory
                    .appendingPathComponent("samples", isDirectory: true)
                    .appendingPathComponent(sample, isDirectory: true)
                    .appendingPathComponent("pbaa", isDirectory: true),
                outputName: sample,
                threads: request.threads,
                seed: request.pbaaSeed,
                inputFormat: .fasta,
                extraArgumentsText: request.pbaaExtraArgumentsText
            )
            let pbaaStartedAt = Date()
            let pbaaResult = try await pbaaPipeline.run(pbaaRequest)
            let pbaaCompletedAt = Date()
            pipelineSteps.append(FullLengthONTMHCProvenanceStep(
                toolName: "pbaa",
                toolVersion: pbaaRequest.containerPins.pbaa.toolVersion,
                argv: [
                    "pbaa", "cluster",
                    "-j", String(pbaaRequest.threads),
                    "--seed", String(pbaaRequest.seed),
                ] + pbaaRequest.extraArguments + ["guide.fasta", "reads.fasta", pbaaRequest.prefix],
                inputs: [preparedFASTA, guideFASTAURL],
                outputs: [pbaaResult.rawOutputDirectory, pbaaResult.passedConsensusFASTAURL],
                exitStatus: 0,
                stderr: nil,
                startedAt: pbaaStartedAt,
                completedAt: pbaaCompletedAt
            ))

            let genotyped = try await genotypeClusters(
                sample: sample,
                clustersFASTAURL: pbaaResult.passedConsensusFASTAURL,
                referenceFASTAURL: referenceFASTAURL,
                sampleDirectory: sampleDirectory,
                request: request,
                steps: &pipelineSteps
            )
            allGenotypeRows += genotyped.rows
            let clusterRecords = try FullLengthONTMHCClusterGenotyper.readFASTARecords(
                from: pbaaResult.passedConsensusFASTAURL
            )
            sampleSummaries.append(FullLengthONTMHCSampleSummary(
                sample: sample,
                totalInputReads: sampleCounts[sample] ?? 0,
                clusterCount: clusterRecords.count,
                clusteredReads: clusterRecords.reduce(0) { $0 + $1.readCount },
                assignedReads: genotyped.rows.reduce(0) { $0 + $1.clusterReads },
                unmatchedClusters: genotyped.unmatchedClusters.count,
                cdnaClusters: genotyped.cdnaMatchedClusters.count
            ))
            try append(records: genotyped.unmatchedClusters, sample: sample, to: request.unmatchedClustersFASTAURL)
            try append(records: genotyped.cdnaMatchedClusters, sample: sample, to: request.cdnaClustersFASTAURL)
        }

        progressHandler?(0.86, "Writing full-length ONT MHC genotype reports.")
        let reportRows = FullLengthONTMHCClusterReportBuilder.reportRows(
            genotypeRows: allGenotypeRows,
            sampleReadCounts: sampleCounts
        )
        try writeReportCSV(reportRows, to: request.reportCSVURL)
        try writeSampleSummaryCSV(sampleSummaries, to: request.sampleSummaryCSVURL)
        try writeStatsJSON(
            sampleSummaries: sampleSummaries,
            genotypeRows: allGenotypeRows,
            to: request.statsJSONURL
        )
        try writeWorkbook(
            reportRows: reportRows,
            sampleSummaries: sampleSummaries,
            genotypeRows: allGenotypeRows,
            to: request.workbookURL
        )
        try writeManifest(request: request, createdAt: Date())
        try writeProvenance(
            request: request,
            referenceFASTAURL: referenceFASTAURL,
            guideFASTAURL: guideFASTAURL,
            steps: pipelineSteps,
            startedAt: startedAt,
            completedAt: Date()
        )

        progressHandler?(1.0, "Full-length ONT MHC genotyping complete.")
        return FullLengthONTMHCGenotypingResult(
            outputDirectory: request.outputDirectory,
            reportCSVURL: request.reportCSVURL,
            sampleSummaryCSVURL: request.sampleSummaryCSVURL,
            statsJSONURL: request.statsJSONURL,
            workbookURL: request.workbookURL,
            unmatchedClustersFASTAURL: request.unmatchedClustersFASTAURL,
            cdnaClustersFASTAURL: request.cdnaClustersFASTAURL,
            provenanceURL: request.provenanceURL,
            referenceFASTAURL: referenceFASTAURL,
            guideFASTAURL: guideFASTAURL
        )
    }

    private func validateInputs(_ request: FullLengthONTMHCGenotypingRunRequest) throws {
        let paths = request.inputFASTQURLs + [
            request.referenceSourceURL,
            request.guideSourceURL,
        ] + [
            request.orientReferenceURL,
            request.forwardPrimerURL,
            request.reversePrimerURL,
        ].compactMap { $0 }
        for url in paths {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FullLengthONTMHCGenotypingError.missingInput(url.path)
            }
        }
        guard !request.inputFASTQURLs.isEmpty else {
            throw FullLengthONTMHCGenotypingError.invalidFASTQ("No FASTQ bundles selected")
        }
    }

    private func resolveMHCReferenceFASTA(_ sourceURL: URL) throws -> URL {
        if MHCAmpliconReferenceBundle.isBundleURL(sourceURL),
           let fastaURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: sourceURL) {
            return fastaURL.standardizedFileURL
        }
        guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
              (SequenceInputResolver.inputSequenceFormat(for: sourceURL) ?? SequenceFormat.from(url: fastaURL)) == .fasta else {
            throw FullLengthONTMHCGenotypingError.invalidReference(sourceURL.path)
        }
        return fastaURL.standardizedFileURL
    }

    private func resolveGuideFASTA(_ sourceURL: URL) throws -> URL {
        guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
              (SequenceInputResolver.inputSequenceFormat(for: sourceURL) ?? SequenceFormat.from(url: fastaURL)) == .fasta else {
            throw FullLengthONTMHCGenotypingError.invalidGuide(sourceURL.path)
        }
        return fastaURL.standardizedFileURL
    }

    private func materializeFASTQ(
        inputURL: URL,
        sample: String,
        sampleDirectory: URL
    ) throws -> URL {
        let outputURL = sampleDirectory.appendingPathComponent("00-input.fastq")
        if let allURLs = FASTQBundle.resolveAllFASTQURLs(for: inputURL), !allURLs.isEmpty {
            try concatenate(files: allURLs, to: outputURL)
            return outputURL
        }
        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: inputURL) {
            try copyOrLink(source: fastqURL, destination: outputURL)
            return outputURL
        }
        guard SequenceInputResolver.inputSequenceFormat(for: inputURL) == .fastq,
              let fastqURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
            throw FullLengthONTMHCGenotypingError.invalidFASTQ(inputURL.path)
        }
        try copyOrLink(source: fastqURL, destination: outputURL)
        _ = sample
        return outputURL
    }

    private func prepareReadsForPBAA(
        inputFASTQ: URL,
        sample: String,
        sampleDirectory: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> URL {
        var currentFASTQ = inputFASTQ
        if let orientReferenceURL = request.orientReferenceURL {
            let output = sampleDirectory.appendingPathComponent("01-oriented.fastq")
            let args = [
                "--orient", currentFASTQ.path,
                "--db", orientReferenceURL.path,
                "--fastqout", output.path,
                "--threads", String(request.threads),
            ]
            try await runNativeTool(
                .vsearch,
                arguments: args,
                inputs: [currentFASTQ, orientReferenceURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                steps: &steps
            )
            currentFASTQ = output
        }

        if let forwardPrimerURL = request.forwardPrimerURL {
            let output = sampleDirectory.appendingPathComponent("02-forward-trimmed.fastq")
            let args = [
                "in=\(currentFASTQ.path)",
                "out=\(output.path)",
                "ref=\(forwardPrimerURL.path)",
                "k=15",
                "mink=11",
                "hdist=1",
                "ktrim=l",
                "rcomp=t",
                "threads=1",
            ]
            try await runNativeTool(
                .bbduk,
                arguments: args,
                inputs: [currentFASTQ, forwardPrimerURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                steps: &steps
            )
            currentFASTQ = output
        }

        if let reversePrimerURL = request.reversePrimerURL {
            let output = sampleDirectory.appendingPathComponent("03-reverse-trimmed.fastq")
            let args = [
                "in=\(currentFASTQ.path)",
                "out=\(output.path)",
                "ref=\(reversePrimerURL.path)",
                "k=15",
                "mink=11",
                "hdist=1",
                "ktrim=r",
                "rcomp=t",
                "threads=1",
            ]
            try await runNativeTool(
                .bbduk,
                arguments: args,
                inputs: [currentFASTQ, reversePrimerURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                steps: &steps
            )
            currentFASTQ = output
        }

        let filtered = sampleDirectory.appendingPathComponent("04-length-filtered.fastq")
        try await runNativeTool(
            .reformat,
            arguments: [
                "in=\(currentFASTQ.path)",
                "out=\(filtered.path)",
                "minlength=\(request.minimumLength)",
                "maxlength=\(request.maximumLength)",
                "threads=1",
            ],
            inputs: [currentFASTQ],
            outputs: [filtered],
            workingDirectory: sampleDirectory,
            steps: &steps
        )

        let fasta = sampleDirectory.appendingPathComponent("\(sample).reads.fasta")
        try await runNativeTool(
            .reformat,
            arguments: [
                "in=\(filtered.path)",
                "out=\(fasta.path)",
                "fastawrap=0",
                "threads=1",
            ],
            inputs: [filtered],
            outputs: [fasta],
            workingDirectory: sampleDirectory,
            steps: &steps
        )
        return fasta
    }

    private func runNativeTool(
        _ tool: NativeTool,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        workingDirectory: URL,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws {
        let startedAt = Date()
        let result = try await nativeToolRunner.run(
            tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: 3_600
        )
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: tool.executableName,
            toolVersion: await nativeToolRunner.getToolVersion(tool) ?? "unknown",
            argv: result.arguments.isEmpty ? [tool.executableName] + arguments : result.arguments,
            inputs: inputs,
            outputs: outputs,
            exitStatus: result.exitCode,
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        guard result.isSuccess else {
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: tool.executableName,
                status: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    private func genotypeClusters(
        sample: String,
        clustersFASTAURL: URL,
        referenceFASTAURL: URL,
        sampleDirectory: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> FullLengthONTMHCClusterGenotypingSummary {
        let samURL = sampleDirectory.appendingPathComponent("\(sample).genotypes.sam")
        let startedAt = Date()
        let arguments = [
            "-a",
            "-x", "splice",
            "--eqx",
            "-t", String(max(1, request.threads)),
            "-N", "100",
            "--secondary=yes",
            clustersFASTAURL.path,
            referenceFASTAURL.path,
        ]
        let result = try await condaManager.runTool(
            name: "minimap2",
            arguments: arguments,
            environment: "minimap2",
            workingDirectory: sampleDirectory,
            timeout: 3_600
        )
        try result.stdout.write(to: samURL, atomically: true, encoding: .utf8)
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "minimap2",
            toolVersion: "unknown",
            argv: ["minimap2"] + arguments,
            inputs: [clustersFASTAURL, referenceFASTAURL],
            outputs: [samURL],
            exitStatus: result.exitCode,
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        guard result.exitCode == 0 else {
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: "minimap2",
                status: result.exitCode,
                stderr: result.stderr
            )
        }
        let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
            sampleID: sample,
            clustersFASTAURL: clustersFASTAURL,
            referenceFASTAURL: referenceFASTAURL,
            samText: result.stdout,
            cdnaThreshold: request.cdnaThreshold,
            minUnmatchedReads: request.minUnmatchedReads
        )
        try writeClusterGenotypeTSV(
            summary.rows,
            to: sampleDirectory.appendingPathComponent("\(sample).genotypes.tsv")
        )
        return summary
    }

    private func writeClusterGenotypeTSV(
        _ rows: [FullLengthONTMHCClusterGenotypeRow],
        to url: URL
    ) throws {
        var lines = ["sample\tcluster\tcluster_reads\tallele\tallele_length\taligned_bases\tscore"]
        lines += rows.map {
            [
                $0.sample,
                $0.cluster,
                String($0.clusterReads),
                $0.allele,
                String($0.alleleLength),
                String($0.alignedBases),
                String($0.score),
            ].joined(separator: "\t")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeReportCSV(
        _ rows: [FullLengthONTMHCReportRow],
        to url: URL
    ) throws {
        var lines = [
            [
                "sample",
                "genotype",
                "passed_alignments",
                "passed_unique_reads",
                "sample_total_reads",
                "sample_unique_retained_reads",
                "sample_unique_retained_percent",
                "overall_input_reads",
                "overall_unique_retained_reads",
                "overall_unique_retained_percent",
            ].joined(separator: ","),
        ]
        lines += rows.map {
            [
                csvEscape($0.sample),
                csvEscape($0.genotype),
                String($0.passedAlignments),
                String($0.passedUniqueReads),
                optionalString($0.sampleTotalReads),
                String($0.sampleUniqueRetainedReads),
                optionalString($0.sampleUniqueRetainedPercent),
                String($0.overallInputReads),
                String($0.overallUniqueRetainedReads),
                optionalString($0.overallUniqueRetainedPercent),
            ].joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeSampleSummaryCSV(
        _ rows: [FullLengthONTMHCSampleSummary],
        to url: URL
    ) throws {
        let header = [
            "sample",
            "passed_alignments",
            "passed_unique_reads",
            "sample_total_reads",
            "sample_unique_retained_reads",
            "sample_unique_retained_percent",
            "cluster_count",
            "clustered_reads",
            "unmatched_clusters",
            "cdna_clusters",
        ].joined(separator: ",")
        var lines = [header]
        lines += rows.sorted { $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }.map { row in
            let percent = row.totalInputReads > 0
                ? Double(row.assignedReads) / Double(row.totalInputReads) * 100.0
                : nil
            return [
                csvEscape(row.sample),
                String(row.assignedReads),
                String(row.assignedReads),
                String(row.totalInputReads),
                String(row.assignedReads),
                optionalString(percent),
                String(row.clusterCount),
                String(row.clusteredReads),
                String(row.unmatchedClusters),
                String(row.cdnaClusters),
            ].joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeStatsJSON(
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        genotypeRows: [FullLengthONTMHCClusterGenotypeRow],
        to url: URL
    ) throws {
        let totalInput = sampleSummaries.reduce(0) { $0 + $1.totalInputReads }
        let assigned = genotypeRows.reduce(0) { $0 + $1.clusterReads }
        let clustered = sampleSummaries.reduce(0) { $0 + $1.clusteredReads }
        let object: [String: Any] = [
            "totalInputReads": totalInput,
            "totalAlignments": assigned,
            "passedAlignments": assigned,
            "retainedUniqueReads": assigned,
            "retainedUniquePercentOfTotalReads": totalInput > 0 ? Double(assigned) / Double(totalInput) * 100.0 : 0.0,
            "assignedUniqueRetainedReads": assigned,
            "unassignedUniqueRetainedReads": max(0, clustered - assigned),
            "clusteredReads": clustered,
            "clusterCount": sampleSummaries.reduce(0) { $0 + $1.clusterCount },
            "unmatchedClusters": sampleSummaries.reduce(0) { $0 + $1.unmatchedClusters },
            "cdnaClusters": sampleSummaries.reduce(0) { $0 + $1.cdnaClusters },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeWorkbook(
        reportRows: [FullLengthONTMHCReportRow],
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        genotypeRows: [FullLengthONTMHCClusterGenotypeRow],
        to url: URL
    ) throws {
        let temp = try ProjectTempDirectory.create(
            prefix: "lungfish-full-length-mhc-xlsx-",
            contextURL: url,
            policy: .systemOnly
        )
        defer { try? FileManager.default.removeItem(at: temp) }
        let rels = temp.appendingPathComponent("_rels", isDirectory: true)
        let xl = temp.appendingPathComponent("xl", isDirectory: true)
        let xlRels = xl.appendingPathComponent("_rels", isDirectory: true)
        let worksheets = xl.appendingPathComponent("worksheets", isDirectory: true)
        for directory in [rels, xlRels, worksheets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try contentTypesXML(sheetCount: 3).write(
            to: temp.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )
        try rootRelsXML.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try workbookXML(sheetNames: ["Genotypes", "Samples", "Clusters"]).write(
            to: xl.appendingPathComponent("workbook.xml"),
            atomically: true,
            encoding: .utf8
        )
        try workbookRelsXML(sheetCount: 3).write(
            to: xlRels.appendingPathComponent("workbook.xml.rels"),
            atomically: true,
            encoding: .utf8
        )
        try worksheetXML(rows: genotypeWorkbookRows(reportRows)).write(
            to: worksheets.appendingPathComponent("sheet1.xml"),
            atomically: true,
            encoding: .utf8
        )
        try worksheetXML(rows: sampleWorkbookRows(sampleSummaries)).write(
            to: worksheets.appendingPathComponent("sheet2.xml"),
            atomically: true,
            encoding: .utf8
        )
        try worksheetXML(rows: clusterWorkbookRows(genotypeRows)).write(
            to: worksheets.appendingPathComponent("sheet3.xml"),
            atomically: true,
            encoding: .utf8
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", url.path, "."]
        process.currentDirectoryURL = temp
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FullLengthONTMHCGenotypingError.reportFailed("zip exited with \(process.terminationStatus)")
        }
    }

    private func writeManifest(
        request: FullLengthONTMHCGenotypingRunRequest,
        createdAt: Date
    ) throws {
        let manifest = ONTGenotypeResultBundleManifest(
            kind: "full-length-ont-mhc-genotype",
            outputName: request.outputName,
            analysisName: request.outputName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            createdAt: ISO8601DateFormatter().string(from: createdAt)
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: request.outputDirectory)
    }

    private func writeProvenance(
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        guideFASTAURL: URL,
        steps: [FullLengthONTMHCProvenanceStep],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let defaults: [String: ParameterValue] = [
            "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            "minimumLength": .integer(2_000),
            "maximumLength": .integer(4_000),
            "pbaaSeed": .integer(1984),
            "pbaaExtraArguments": .string(FullLengthONTMHCGenotypingRunRequest.defaultPBAAExtraArgumentsText),
            "minUnmatchedReads": .integer(5),
            "cdnaThreshold": .integer(2_000),
        ]
        let resolved: [String: ParameterValue] = [
            "threads": .integer(request.threads),
            "minimumLength": .integer(request.minimumLength),
            "maximumLength": .integer(request.maximumLength),
            "pbaaSeed": .integer(request.pbaaSeed),
            "pbaaExtraArguments": .string(request.pbaaExtraArgumentsText),
            "minUnmatchedReads": .integer(request.minUnmatchedReads),
            "cdnaThreshold": .integer(request.cdnaThreshold),
        ]
        var explicit = resolved
        explicit["inputFASTQs"] = .array(request.inputFASTQURLs.map(ParameterValue.file))
        explicit["reference"] = .file(request.referenceSourceURL)
        explicit["resolvedReferenceFASTA"] = .file(referenceFASTAURL)
        explicit["guide"] = .file(request.guideSourceURL)
        explicit["resolvedGuideFASTA"] = .file(guideFASTAURL)
        explicit["outputDirectory"] = .file(request.outputDirectory)
        explicit["outputName"] = .string(request.outputName)
        if let orientReferenceURL = request.orientReferenceURL {
            explicit["orientReference"] = .file(orientReferenceURL)
        }
        if let forwardPrimerURL = request.forwardPrimerURL {
            explicit["forwardPrimer"] = .file(forwardPrimerURL)
        }
        if let reversePrimerURL = request.reversePrimerURL {
            explicit["reversePrimer"] = .file(reversePrimerURL)
        }
        if let projectURL = request.projectURL {
            explicit["project"] = .file(projectURL)
        }

        var builder = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(request.argv)
        .durableReplayArgv(request.argv)
        .reproducibleCommand(request.argv.map(shellEscape).joined(separator: " "))
        .options(explicit: explicit, defaults: defaults, resolved: resolved)
        .runtime(ProvenanceRuntimeIdentity())
        .input(referenceFASTAURL, format: .fasta, role: .reference)
        .input(guideFASTAURL, format: .fasta, role: .reference)
        .output(request.reportCSVURL, format: .text, role: .report)
        .output(request.sampleSummaryCSVURL, format: .text, role: .report)
        .output(request.statsJSONURL, format: .json, role: .report)
        .output(request.workbookURL, format: .unknown, role: .report)
        .output(request.manifestURL, format: .json, role: .output)
        .output(request.unmatchedClustersFASTAURL, format: .fasta, role: .output)
        .output(request.cdnaClustersFASTAURL, format: .fasta, role: .output)

        for input in request.inputFASTQURLs where !isDirectory(input) {
            builder = try builder.input(input, format: .fastq, role: .input)
        }
        for primer in [request.orientReferenceURL, request.forwardPrimerURL, request.reversePrimerURL].compactMap({ $0 }) {
            builder = try builder.input(primer, format: .fasta, role: .reference)
        }
        for step in steps {
            builder = try builder.step(step.provenanceStep())
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: completedAt
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: request.provenanceURL)
    }

    private func append(
        records: [FullLengthONTMHCClusterFASTARecord],
        sample: String,
        to url: URL
    ) throws {
        guard !records.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for record in records {
            let text = ">\(sample)_\(record.name)\n\(record.sequence)\n"
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }
    }

    private func concatenate(files: [URL], to outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        for file in files {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while autoreleasepool(invoking: {
                let data = input.readData(ofLength: 1024 * 1024)
                guard !data.isEmpty else { return false }
                output.write(data)
                return true
            }) {}
        }
    }

    private func copyOrLink(source: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func fastqReadCount(_ url: URL) -> Int {
        guard url.pathExtension.lowercased() != "gz",
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        return text.split(whereSeparator: \.isNewline).count / 4
    }

    private func sampleName(for url: URL, fallbackIndex: Int) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "sample-\(fallbackIndex + 1)" : sanitizedSampleName(trimmed)
    }

    private func sanitizedSampleName(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "sample" : collapsed
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func optionalString<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? ""
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath.hasPrefix(normalizedBase) else { return targetPath }
        return String(targetPath.dropFirst(normalizedBase.count))
    }

    private func genotypeWorkbookRows(_ rows: [FullLengthONTMHCReportRow]) -> [[String]] {
        var result = [["sample", "genotype", "passed_alignments", "passed_unique_reads"]]
        result += rows.map {
            [$0.sample, $0.genotype, String($0.passedAlignments), String($0.passedUniqueReads)]
        }
        return result
    }

    private func sampleWorkbookRows(_ rows: [FullLengthONTMHCSampleSummary]) -> [[String]] {
        var result = [["sample", "total_input_reads", "cluster_count", "clustered_reads", "assigned_reads", "unmatched_clusters", "cdna_clusters"]]
        result += rows.map {
            [
                $0.sample,
                String($0.totalInputReads),
                String($0.clusterCount),
                String($0.clusteredReads),
                String($0.assignedReads),
                String($0.unmatchedClusters),
                String($0.cdnaClusters),
            ]
        }
        return result
    }

    private func clusterWorkbookRows(_ rows: [FullLengthONTMHCClusterGenotypeRow]) -> [[String]] {
        var result = [["sample", "cluster", "cluster_reads", "allele", "allele_length", "aligned_bases", "score"]]
        result += rows.map {
            [
                $0.sample,
                $0.cluster,
                String($0.clusterReads),
                $0.allele,
                String($0.alleleLength),
                String($0.alignedBases),
                String($0.score),
            ]
        }
        return result
    }
}

private struct FullLengthONTMHCSampleSummary: Sendable, Codable, Equatable {
    let sample: String
    let totalInputReads: Int
    let clusterCount: Int
    let clusteredReads: Int
    let assignedReads: Int
    let unmatchedClusters: Int
    let cdnaClusters: Int
}

private struct FullLengthONTMHCProvenanceStep: Sendable {
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let inputs: [URL]
    let outputs: [URL]
    let exitStatus: Int32
    let stderr: String?
    let startedAt: Date
    let completedAt: Date

    func provenanceStep() throws -> ProvenanceStep {
        try ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            inputs: inputs.map {
                try ProvenanceFileDescriptor.file(
                    url: $0,
                    format: SequenceFormat.from(url: $0) == .fasta ? .fasta : .fastq,
                    role: .input
                )
            },
            outputs: outputs.map {
                try fileDescriptor(url: $0, format: outputFormat(for: $0), role: .output)
            },
            exitStatus: Int(exitStatus),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func outputFormat(for url: URL) -> FileFormat {
        if SequenceFormat.from(url: url) == .fasta {
            return .fasta
        }
        if SequenceFormat.from(url: url) == .fastq {
            return .fastq
        }
        switch url.pathExtension.lowercased() {
        case "sam":
            return .sam
        case "json":
            return .json
        case "csv", "tsv", "txt", "log":
            return .text
        default:
            return .unknown
        }
    }

    private func fileDescriptor(url: URL, format: FileFormat?, role: FileRole) throws -> ProvenanceFileDescriptor {
        if isDirectory(url) {
            return ProvenanceFileDescriptor(path: url.path, format: format, role: role)
        }
        return try ProvenanceFileDescriptor.file(url: url, format: format, role: role)
    }
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

private let rootRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
"""

private func contentTypesXML(sheetCount: Int) -> String {
    let sheets = (1...sheetCount).map {
        "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    \(sheets)
    </Types>
    """
}

private func workbookXML(sheetNames: [String]) -> String {
    let sheets = sheetNames.enumerated().map { index, name in
        "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
    \(sheets)
      </sheets>
    </workbook>
    """
}

private func workbookRelsXML(sheetCount: Int) -> String {
    let rels = (1...sheetCount).map {
        "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \(rels)
    </Relationships>
    """
}

private func worksheetXML(rows: [[String]]) -> String {
    let body = rows.enumerated().map { rowIndex, row in
        let cells = row.enumerated().map { columnIndex, value in
            let ref = "\(xlsxColumn(columnIndex + 1))\(rowIndex + 1)"
            return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>"
        }.joined()
        return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
    \(body)
      </sheetData>
    </worksheet>
    """
}

private func xlsxColumn(_ oneBasedIndex: Int) -> String {
    var value = oneBasedIndex
    var result = ""
    while value > 0 {
        value -= 1
        let scalar = UnicodeScalar(65 + (value % 26))!
        result.insert(Character(scalar), at: result.startIndex)
        value /= 26
    }
    return result
}

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
