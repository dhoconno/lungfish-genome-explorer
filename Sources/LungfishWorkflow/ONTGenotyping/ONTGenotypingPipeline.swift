import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingRunRequest: Sendable, Codable, Equatable {
    public let inputFASTQURLs: [URL]
    public let referenceSourceURL: URL
    public let outputDirectory: URL
    public let outputName: String
    public let projectURL: URL?
    public let threads: Int
    public let minSupport: Int
    public let extraArguments: [String]

    public init(
        inputFASTQURLs: [URL],
        referenceSourceURL: URL,
        outputDirectory: URL,
        outputName: String = "ont-genotyping-report",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minSupport: Int = 1,
        extraArguments: [String] = []
    ) {
        self.inputFASTQURLs = inputFASTQURLs.map(\.standardizedFileURL)
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = Self.sanitizedOutputName(outputName)
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.minSupport = max(1, minSupport)
        self.extraArguments = extraArguments
    }

    public var reportCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).csv")
    }

    public var argv: [String] {
        var values = [CLICommandIdentity.executableName, "fastq", "ont-genotype"]
        values.append(contentsOf: inputFASTQURLs.map(\.path))
        values += [
            "--reference", referenceSourceURL.path,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--min-support", String(minSupport),
        ]
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        if !extraArguments.isEmpty {
            values += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
        }
        return values
    }

    private static func sanitizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "ont-genotyping-report" : collapsed
    }
}

public struct ONTGenotypingGenotypeCount: Sendable, Codable, Equatable {
    public let genotype: String
    public let filteredIndelOnlyMappedReads: Int

    public init(genotype: String, filteredIndelOnlyMappedReads: Int) {
        self.genotype = genotype
        self.filteredIndelOnlyMappedReads = filteredIndelOnlyMappedReads
    }
}

public struct ONTGenotypingFilterRequest: Sendable, Codable, Equatable {
    public let sampleName: String
    public let inputBAMURL: URL
    public let referenceFASTAURL: URL
    public let outputBAMURL: URL
    public let scriptURL: URL
    public let extraArguments: [String]

    public init(
        sampleName: String,
        inputBAMURL: URL,
        referenceFASTAURL: URL,
        outputBAMURL: URL,
        scriptURL: URL,
        extraArguments: [String] = []
    ) {
        self.sampleName = sampleName
        self.inputBAMURL = inputBAMURL.standardizedFileURL
        self.referenceFASTAURL = referenceFASTAURL.standardizedFileURL
        self.outputBAMURL = outputBAMURL.standardizedFileURL
        self.scriptURL = scriptURL.standardizedFileURL
        self.extraArguments = extraArguments
    }

    public var outputBAIURL: URL {
        outputBAMURL.appendingPathExtension("bai")
    }

    public var pythonArguments: [String] {
        [
            scriptURL.path,
            "--sample-name", sampleName,
            "--input-bam", inputBAMURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--output-bam", outputBAMURL.path,
            "--require-both-end-softclips",
            "--require-full-reference-span",
            "--allow-indels",
            "--max-mismatches", "0",
        ] + extraArguments
    }
}

public struct ONTGenotypingFilterResult: Sendable, Codable, Equatable {
    public let inputBAMURL: URL
    public let outputBAMURL: URL
    public let outputBAIURL: URL
    public let totalAlignments: Int
    public let passedAlignments: Int
    public let genotypeCounts: [ONTGenotypingGenotypeCount]
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let wallClockSeconds: TimeInterval

    public init(
        inputBAMURL: URL,
        outputBAMURL: URL,
        outputBAIURL: URL,
        totalAlignments: Int,
        passedAlignments: Int,
        genotypeCounts: [ONTGenotypingGenotypeCount],
        stdout: String,
        stderr: String,
        exitCode: Int32,
        wallClockSeconds: TimeInterval
    ) {
        self.inputBAMURL = inputBAMURL.standardizedFileURL
        self.outputBAMURL = outputBAMURL.standardizedFileURL
        self.outputBAIURL = outputBAIURL.standardizedFileURL
        self.totalAlignments = totalAlignments
        self.passedAlignments = passedAlignments
        self.genotypeCounts = genotypeCounts
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.wallClockSeconds = wallClockSeconds
    }
}

public struct ONTGenotypingSampleResult: Sendable, Codable, Equatable {
    public let inputFASTQURL: URL
    public let sampleName: String
    public let mappingResult: MappingResult
    public let filteredMappingResult: MappingResult
    public let filterResult: ONTGenotypingFilterResult
    public let reportRows: [ONTGenotypingReportRow]
}

public struct ONTGenotypingReportRow: Sendable, Codable, Equatable {
    public let inputBundleName: String
    public let genotype: String
    public let filteredIndelOnlyMappedReads: Int
    public let totalReads: Int
}

public struct ONTGenotypingResult: Sendable, Codable, Equatable {
    public let reportCSVURL: URL
    public let outputDirectory: URL
    public let referenceFASTAURL: URL
    public let sourceReferenceBundleURL: URL?
    public let sampleResults: [ONTGenotypingSampleResult]
}

public protocol ONTGenotypingMappingRunning: Sendable {
    func runMapping(
        request: MappingRunRequest,
        progressHandler: ManagedMappingPipeline.ProgressHandler?
    ) async throws -> MappingResult
}

extension ManagedMappingPipeline: ONTGenotypingMappingRunning {
    public func runMapping(
        request: MappingRunRequest,
        progressHandler: ManagedMappingPipeline.ProgressHandler?
    ) async throws -> MappingResult {
        try await run(request: request, progress: progressHandler)
    }
}

public protocol ONTGenotypingPysamFiltering: Sendable {
    func filter(_ request: ONTGenotypingFilterRequest) async throws -> ONTGenotypingFilterResult
}

public enum ONTGenotypingError: Error, LocalizedError, Sendable, Equatable {
    case noInputs
    case missingInput(URL)
    case invalidReference(URL)
    case mappingFailed(String)
    case filteringFailed(sampleName: String, status: Int32, stderr: String)
    case reportWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "ONT genotyping requires at least one FASTQ input bundle or file."
        case .missingInput(let url):
            return "Input FASTQ does not exist: \(url.path)"
        case .invalidReference(let url):
            return "Reference source does not contain a readable FASTA payload: \(url.path)"
        case .mappingFailed(let message):
            return "ONT genotyping mapping failed: \(message)"
        case .filteringFailed(let sampleName, let status, let stderr):
            return "ONT genotyping filter failed for \(sampleName) with status \(status): \(stderr)"
        case .reportWriteFailed(let message):
            return "Failed to write ONT genotyping report: \(message)"
        }
    }
}

public struct ONTGenotypingPipeline: Sendable {
    private let mappingRunner: any ONTGenotypingMappingRunning
    private let filterRunner: any ONTGenotypingPysamFiltering
    private let referenceImporter: ReferenceBundleImportService

    public init(
        mappingRunner: any ONTGenotypingMappingRunning = ManagedMappingPipeline(),
        filterRunner: any ONTGenotypingPysamFiltering = ProcessONTGenotypingPysamFilterRunner(),
        referenceImporter: ReferenceBundleImportService = .shared
    ) {
        self.mappingRunner = mappingRunner
        self.filterRunner = filterRunner
        self.referenceImporter = referenceImporter
    }

    public func run(
        _ request: ONTGenotypingRunRequest,
        progress: ManagedMappingPipeline.ProgressHandler? = nil
    ) async throws -> ONTGenotypingResult {
        guard !request.inputFASTQURLs.isEmpty else {
            throw ONTGenotypingError.noInputs
        }
        for inputURL in request.inputFASTQURLs {
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                throw ONTGenotypingError.missingInput(inputURL)
            }
        }

        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let startedAt = Date()
        let reference = try await resolveReference(for: request)
        let referenceLengths = try await Self.loadReferenceLengths(from: reference.referenceFASTAURL)
        let scriptURL = request.outputDirectory
            .appendingPathComponent(".ont-genotyping", isDirectory: true)
            .appendingPathComponent("pysam-filter.py")
        try ProcessONTGenotypingPysamFilterRunner.writeScript(to: scriptURL)

        var sampleResults: [ONTGenotypingSampleResult] = []
        sampleResults.reserveCapacity(request.inputFASTQURLs.count)

        for (index, inputURL) in request.inputFASTQURLs.enumerated() {
            let sampleName = Self.sampleName(for: inputURL, fallback: "sample-\(index + 1)")
            let sampleDirectory = request.outputDirectory.appendingPathComponent(Self.sanitizeFileStem(sampleName), isDirectory: true)
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)

            let executionInputURL = try resolveInputFASTQ(inputURL)
            let readGroup = MappingReadGroup.resolved(
                sampleName: sampleName,
                defaultPlatform: "ILLUMINA"
            )
            let mappingRequest = MappingRunRequest(
                tool: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [executionInputURL],
                originalInputFASTQURLs: [inputURL.standardizedFileURL],
                referenceFASTAURL: reference.referenceFASTAURL,
                sourceReferenceBundleURL: reference.sourceReferenceBundleURL,
                projectURL: request.projectURL,
                outputDirectory: sampleDirectory,
                sampleName: sampleName,
                readGroup: readGroup,
                pairedEnd: false,
                threads: request.threads,
                includeSecondary: true,
                includeSupplementary: true,
                minimumMappingQuality: 0,
                advancedArguments: request.extraArguments,
                compatibilityReadClassOverride: .illuminaShortReads
            )

            let mappingResult: MappingResult
            do {
                mappingResult = try await mappingRunner.runMapping(
                    request: mappingRequest,
                    progressHandler: progress
                )
            } catch {
                throw ONTGenotypingError.mappingFailed(error.localizedDescription)
            }
            try mappingResult.save(to: sampleDirectory)
            try preserveRawMappingSidecars(in: sampleDirectory)

            let filteredBAM = sampleDirectory.appendingPathComponent("\(Self.sanitizeFileStem(sampleName)).ont-genotyping.filtered.bam")
            let filterRequest = ONTGenotypingFilterRequest(
                sampleName: sampleName,
                inputBAMURL: mappingResult.bamURL,
                referenceFASTAURL: reference.referenceFASTAURL,
                outputBAMURL: filteredBAM,
                scriptURL: scriptURL
            )
            let filterResult = try await filterRunner.filter(filterRequest)
            guard filterResult.exitCode == 0 else {
                throw ONTGenotypingError.filteringFailed(
                    sampleName: sampleName,
                    status: filterResult.exitCode,
                    stderr: filterResult.stderr
                )
            }

            let filteredMappingResult = MappingResult(
                mapper: mappingResult.mapper,
                modeID: mappingResult.modeID,
                sourceReferenceBundleURL: mappingResult.sourceReferenceBundleURL,
                viewerBundleURL: mappingResult.viewerBundleURL,
                bamURL: filterResult.outputBAMURL,
                baiURL: filterResult.outputBAIURL,
                totalReads: mappingResult.totalReads,
                mappedReads: filterResult.passedAlignments,
                unmappedReads: max(0, mappingResult.totalReads - filterResult.passedAlignments),
                wallClockSeconds: mappingResult.wallClockSeconds + filterResult.wallClockSeconds,
                contigs: Self.filteredContigSummaries(
                    from: filterResult.genotypeCounts,
                    referenceLengths: referenceLengths,
                    totalReads: mappingResult.totalReads
                )
            )
            try filteredMappingResult.save(to: sampleDirectory)
            try writeFilteredMappingProvenance(
                runRequest: request,
                request: mappingRequest,
                rawMappingResult: mappingResult,
                filteredMappingResult: filteredMappingResult,
                filterRequest: filterRequest,
                filterResult: filterResult,
                sampleDirectory: sampleDirectory
            )

            let rows = filterResult.genotypeCounts
                .filter { $0.filteredIndelOnlyMappedReads >= request.minSupport }
                .map {
                    ONTGenotypingReportRow(
                        inputBundleName: sampleName,
                        genotype: $0.genotype,
                        filteredIndelOnlyMappedReads: $0.filteredIndelOnlyMappedReads,
                        totalReads: mappingResult.totalReads
                    )
                }
            sampleResults.append(
                ONTGenotypingSampleResult(
                    inputFASTQURL: executionInputURL,
                    sampleName: sampleName,
                    mappingResult: mappingResult,
                    filteredMappingResult: filteredMappingResult,
                    filterResult: filterResult,
                    reportRows: rows
                )
            )
        }

        let reportRows = sampleResults.flatMap(\.reportRows)
        do {
            try writeReport(rows: reportRows, to: request.reportCSVURL)
        } catch {
            throw ONTGenotypingError.reportWriteFailed(error.localizedDescription)
        }

        let completedAt = Date()
        let result = ONTGenotypingResult(
            reportCSVURL: request.reportCSVURL,
            outputDirectory: request.outputDirectory,
            referenceFASTAURL: reference.referenceFASTAURL,
            sourceReferenceBundleURL: reference.sourceReferenceBundleURL,
            sampleResults: sampleResults
        )
        try writeProvenance(
            request: request,
            result: result,
            scriptURL: scriptURL,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return result
    }

    private struct ReferenceResolution {
        let referenceFASTAURL: URL
        let sourceReferenceBundleURL: URL?
    }

    private func resolveReference(for request: ONTGenotypingRunRequest) async throws -> ReferenceResolution {
        let sourceURL = request.referenceSourceURL
        if sourceURL.pathExtension.lowercased() == "lungfishref" {
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
                  SequenceInputResolver.inputSequenceFormat(for: sourceURL) == .fasta else {
                throw ONTGenotypingError.invalidReference(sourceURL)
            }
            return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: sourceURL)
        }

        if let projectURL = request.projectURL,
           ReferenceBundleImportService.isStandaloneReferenceSource(sourceURL),
           !Self.url(sourceURL, isContainedIn: projectURL) {
            let referenceDirectory = projectURL.appendingPathComponent("Reference Sequences", isDirectory: true)
            let importResult = try await referenceImporter.importAsReferenceBundle(
                sourceURL: sourceURL,
                outputDirectory: referenceDirectory,
                preferredBundleName: sourceURL.deletingPathExtension().lastPathComponent
            )
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: importResult.bundleURL) else {
                throw ONTGenotypingError.invalidReference(importResult.bundleURL)
            }
            return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: importResult.bundleURL)
        }

        guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
              (SequenceInputResolver.inputSequenceFormat(for: sourceURL) ?? SequenceFormat.from(url: fastaURL)) == .fasta else {
            throw ONTGenotypingError.invalidReference(sourceURL)
        }
        let sourceBundle = MappingReferenceStager.enclosingReferenceBundleURL(for: sourceURL)
        return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: sourceBundle)
    }

    private func resolveInputFASTQ(_ inputURL: URL) throws -> URL {
        guard let resolved = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL),
              (SequenceInputResolver.inputSequenceFormat(for: inputURL) ?? SequenceFormat.from(url: resolved)) == .fastq else {
            throw ONTGenotypingError.missingInput(inputURL)
        }
        return resolved.standardizedFileURL
    }

    private func writeReport(rows: [ONTGenotypingReportRow], to reportURL: URL) throws {
        var lines = ["input_bundle_name,genotype,filtered_indel_only_mapped_reads,total_reads"]
        lines += rows.map { row in
            [
                Self.csvEscape(row.inputBundleName),
                Self.csvEscape(row.genotype),
                String(row.filteredIndelOnlyMappedReads),
                String(row.totalReads),
            ].joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private static func loadReferenceLengths(from fastaURL: URL) async throws -> [String: Int] {
        let text: String
        if fastaURL.isGzipCompressed {
            text = try await GzipInputStream(url: fastaURL).readAll()
        } else {
            text = try String(contentsOf: fastaURL, encoding: .utf8)
        }

        var lengths: [String: Int] = [:]
        var currentName: String?
        var currentLength = 0

        func finishCurrent() {
            guard let currentName else { return }
            lengths[currentName] = currentLength
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(">") {
                finishCurrent()
                currentName = String(line.dropFirst()).split(separator: " ", maxSplits: 1).first.map(String.init)
                currentLength = 0
            } else {
                currentLength += line.count
            }
        }
        finishCurrent()
        return lengths
    }

    private static func filteredContigSummaries(
        from genotypeCounts: [ONTGenotypingGenotypeCount],
        referenceLengths: [String: Int],
        totalReads: Int
    ) -> [MappingContigSummary] {
        genotypeCounts
            .filter { $0.filteredIndelOnlyMappedReads > 0 }
            .map { count in
                let readCount = count.filteredIndelOnlyMappedReads
                return MappingContigSummary(
                    contigName: count.genotype,
                    contigLength: referenceLengths[count.genotype, default: 0],
                    mappedReads: readCount,
                    mappedReadPercent: totalReads > 0
                        ? Double(readCount) / Double(totalReads) * 100
                        : 0,
                    meanDepth: Double(readCount),
                    coverageBreadth: 1,
                    medianMAPQ: 0,
                    meanIdentity: 1
                )
            }
    }

    private func preserveRawMappingSidecars(in sampleDirectory: URL) throws {
        let copies = [
            ("mapping-result.json", "raw-mapping-result.json"),
            (MappingProvenance.filename, "raw-\(MappingProvenance.filename)"),
            (ProvenanceWriter.provenanceFilename, "raw-mapping-\(ProvenanceWriter.provenanceFilename)"),
        ]
        for (sourceName, destinationName) in copies {
            let source = sampleDirectory.appendingPathComponent(sourceName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = sampleDirectory.appendingPathComponent(destinationName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func writeFilteredMappingProvenance(
        runRequest: ONTGenotypingRunRequest,
        request: MappingRunRequest,
        rawMappingResult: MappingResult,
        filteredMappingResult: MappingResult,
        filterRequest: ONTGenotypingFilterRequest,
        filterResult: ONTGenotypingFilterResult,
        sampleDirectory: URL
    ) throws {
        let rawProvenance = MappingProvenance.load(from: sampleDirectory)
        let lockTool = try? ManagedToolLock.loadFromBundle().tool(named: "pysam")
        let pysamVersion = lockTool?.version ?? "unknown"
        let mappingResultURL = sampleDirectory.appendingPathComponent("mapping-result.json")
        let filterInputs = [
            ProvenanceRecorder.fileRecord(url: rawMappingResult.bamURL, format: .bam, role: .input),
            ProvenanceRecorder.fileRecord(url: request.referenceFASTAURL, format: .fasta, role: .reference),
            ProvenanceRecorder.fileRecord(url: filterRequest.scriptURL, format: .text, role: .input),
        ]
        let filterOutputs = [
            ProvenanceRecorder.fileRecord(url: filteredMappingResult.bamURL, format: .bam, role: .output),
            ProvenanceRecorder.fileRecord(url: filteredMappingResult.baiURL, role: .index),
            ProvenanceRecorder.fileRecord(url: mappingResultURL, format: .json, role: .output),
        ]
        let filterStep = StepExecution(
            toolName: "pysam",
            toolVersion: pysamVersion,
            command: ["python"] + filterRequest.pythonArguments,
            inputs: filterInputs,
            outputs: filterOutputs,
            exitCode: filterResult.exitCode,
            wallTime: filterResult.wallClockSeconds,
            stderr: filterResult.stderr.isEmpty ? nil : filterResult.stderr
        )
        let mapperInvocation = MappingCommandInvocation(
            label: "lungfish fastq ont-genotype",
            argv: runRequest.argv,
            durableReplayArgv: runRequest.argv
        )
        let provenance = MappingProvenance(
            schemaVersion: 4,
            workflowName: "ONT Genotyping",
            mapper: filteredMappingResult.mapper,
            modeID: filteredMappingResult.modeID,
            sampleName: request.sampleName,
            readGroup: request.resolvedReadGroup(),
            pairedEnd: request.pairedEnd,
            threads: request.threads,
            minimumMappingQuality: request.minimumMappingQuality,
            includeSecondary: request.includeSecondary,
            includeSupplementary: request.includeSupplementary,
            advancedArguments: request.advancedArguments,
            inputFASTQURLs: request.inputFASTQURLs,
            referenceFASTAURL: request.referenceFASTAURL,
            sourceReferenceBundleURL: filteredMappingResult.sourceReferenceBundleURL ?? request.sourceReferenceBundleURL,
            viewerBundleURL: filteredMappingResult.viewerBundleURL,
            mapperInvocation: mapperInvocation,
            normalizationInvocations: rawProvenance?.normalizationInvocations ?? [],
            mapperVersion: rawProvenance?.mapperVersion ?? "unknown",
            samtoolsVersion: rawProvenance?.samtoolsVersion ?? "unknown",
            wallClockSeconds: filteredMappingResult.wallClockSeconds,
            readClassHints: rawProvenance?.readClassHints ?? [],
            inputFiles: rawProvenance?.inputFiles ?? [],
            outputFiles: filterOutputs,
            runtimeIdentity: rawProvenance?.runtimeIdentity ?? [:],
            steps: (rawProvenance?.steps ?? []) + [filterStep],
            exitStatus: filterResult.exitCode,
            stderr: filterResult.stderr.isEmpty ? nil : filterResult.stderr
        )
        try provenance.save(to: sampleDirectory)
        try provenance.saveCanonicalEnvelope(to: sampleDirectory)
    }

    private func writeProvenance(
        request: ONTGenotypingRunRequest,
        result: ONTGenotypingResult,
        scriptURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let lockTool = try? ManagedToolLock.loadFromBundle().tool(named: "pysam")
        let pysamVersion = lockTool?.version ?? "unknown"
        let pysamPackageSpec = lockTool?.packageSpec ?? ManagedToolLock.bundled.packageSpec(forEnvironment: "pysam") ?? "bioconda::pysam"
        let minimap2Requirement = PluginPack.builtInPack(id: "read-mapping")?
            .toolRequirements
            .first { $0.id == "minimap2" }
        let minimap2Version = minimap2Requirement?.version ?? "unknown"
        let minimap2PackageSpec = minimap2Requirement?.installPackages.joined(separator: " ")
            ?? ManagedToolLock.bundled.packageSpec(forEnvironment: "minimap2") ?? "bioconda::minimap2"
        let runtime = ProvenanceRuntimeIdentity(
            condaEnvironment: "pysam (\(pysamPackageSpec))",
            condaPrefix: CondaManager.shared.rootPrefix.appendingPathComponent("envs/pysam", isDirectory: true).path,
            pluginPack: "lungfish-tools"
        )
        let allInputs = result.sampleResults.map(\.inputFASTQURL) + [result.referenceFASTAURL]
        let filterOutputs = result.sampleResults.flatMap {
            [$0.filterResult.outputBAMURL, $0.filterResult.outputBAIURL]
        }
        let outputURLs = [result.reportCSVURL] + filterOutputs
        let rawMappingOutputs = result.sampleResults.flatMap {
            [$0.mappingResult.bamURL, $0.mappingResult.baiURL]
        }
        let filteredMappingSidecars = result.sampleResults.map {
            $0.filterResult.outputBAMURL
                .deletingLastPathComponent()
                .appendingPathComponent("mapping-result.json")
        }

        var builder = ProvenanceRunBuilder(
            workflowName: "ONT Genotyping",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "pysam",
            toolVersion: pysamVersion
        )
        .argv(request.argv)
        .durableReplayArgv(request.argv)
        .reproducibleCommand(request.argv.map(shellEscape).joined(separator: " "))
        .options(
            explicit: [
                "inputCount": .integer(request.inputFASTQURLs.count),
                "reference": .file(request.referenceSourceURL),
                "outputDirectory": .file(request.outputDirectory),
                "outputName": .string(request.outputName),
                "threads": .integer(request.threads),
                "minSupport": .integer(request.minSupport),
                "mappingPreset": .string("sr"),
                "mappingTool": .string("minimap2"),
                "mappingToolVersion": .string(minimap2Version),
                "mappingPackage": .string(minimap2PackageSpec),
                "mappingReadClassOverride": .string(MappingReadClass.illuminaShortReads.rawValue),
                "extraArguments": .array(request.extraArguments.map(ParameterValue.string)),
            ],
            defaults: [
                "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
                "minSupport": .integer(1),
                "mappingPreset": .string("sr"),
                "mappingTool": .string("minimap2"),
                "mappingToolVersion": .string(minimap2Version),
                "mappingPackage": .string(minimap2PackageSpec),
                "mappingReadClassOverride": .string(MappingReadClass.illuminaShortReads.rawValue),
                "extraArguments": .array([]),
            ],
            resolved: [
                "threads": .integer(request.threads),
                "minSupport": .integer(request.minSupport),
                "mappingPreset": .string("sr"),
                "mappingTool": .string("minimap2"),
                "mappingToolVersion": .string(minimap2Version),
                "mappingPackage": .string(minimap2PackageSpec),
                "mappingReadClassOverride": .string(MappingReadClass.illuminaShortReads.rawValue),
                "extraArguments": .array(request.extraArguments.map(ParameterValue.string)),
            ]
        )
        .runtime(runtime)

        for inputURL in allInputs {
            builder = try builder.input(inputURL, format: fileFormat(for: inputURL), role: .input)
        }
        builder = try builder.input(scriptURL, format: .text, role: .input)
        for outputURL in outputURLs + rawMappingOutputs + filteredMappingSidecars {
            let role: FileRole
            if outputURL == result.reportCSVURL {
                role = .report
            } else if outputURL.pathExtension.lowercased() == "bai" {
                role = .index
            } else {
                role = .output
            }
            builder = try builder.output(outputURL, format: fileFormat(for: outputURL), role: role)
        }

        for sampleResult in result.sampleResults {
            let mappingArgv = [
                CLICommandIdentity.executableName, "map",
                sampleResult.inputFASTQURL.path,
                "--reference", result.referenceFASTAURL.path,
                "--mapper", "minimap2",
                "--preset", "sr",
                "--secondary",
                "--sample-name", sampleResult.sampleName,
                "--threads", String(request.threads),
            ] + (request.extraArguments.isEmpty ? [] : ["--extra-args", AdvancedCommandLineOptions.join(request.extraArguments)])
            let mappingInputs = [
                try ProvenanceFileDescriptor.file(url: sampleResult.inputFASTQURL, format: .fastq, role: .input),
                try ProvenanceFileDescriptor.file(url: result.referenceFASTAURL, format: .fasta, role: .reference),
            ]
            let mappingOutputs = [
                try ProvenanceFileDescriptor.file(url: sampleResult.mappingResult.bamURL, format: .bam, role: .output),
                try ProvenanceFileDescriptor.file(url: sampleResult.mappingResult.baiURL, format: .unknown, role: .index),
            ]
            builder = builder.step(ProvenanceStep(
                toolName: "minimap2",
                toolVersion: minimap2Version,
                argv: mappingArgv,
                inputs: mappingInputs,
                outputs: mappingOutputs,
                exitStatus: 0,
                wallTimeSeconds: sampleResult.mappingResult.wallClockSeconds,
                startedAt: startedAt,
                completedAt: completedAt
            ))
            let filterInputs = [
                try ProvenanceFileDescriptor.file(url: sampleResult.mappingResult.bamURL, format: .bam, role: .input),
                try ProvenanceFileDescriptor.file(url: result.referenceFASTAURL, format: .fasta, role: .reference),
                try ProvenanceFileDescriptor.file(url: scriptURL, format: .text, role: .input),
            ]
            let filterOutputs = [
                try ProvenanceFileDescriptor.file(url: sampleResult.filterResult.outputBAMURL, format: .bam, role: .output),
                try ProvenanceFileDescriptor.file(url: sampleResult.filterResult.outputBAIURL, format: .unknown, role: .index),
            ]
            builder = builder.step(ProvenanceStep(
                toolName: "pysam",
                toolVersion: pysamVersion,
                argv: ["python"] + ONTGenotypingFilterRequest(
                    sampleName: sampleResult.sampleName,
                    inputBAMURL: sampleResult.mappingResult.bamURL,
                    referenceFASTAURL: result.referenceFASTAURL,
                    outputBAMURL: sampleResult.filterResult.outputBAMURL,
                    scriptURL: scriptURL
                ).pythonArguments,
                inputs: filterInputs,
                outputs: filterOutputs,
                exitStatus: Int(sampleResult.filterResult.exitCode),
                wallTimeSeconds: sampleResult.filterResult.wallClockSeconds,
                stderr: sampleResult.filterResult.stderr.isEmpty ? nil : sampleResult.filterResult.stderr,
                startedAt: startedAt,
                completedAt: completedAt
            ))
        }

        let envelope = try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: request.outputDirectory)
    }

    private func fileFormat(for url: URL) -> FileFormat {
        let lowerName = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "fa", "fasta", "fna", "fas":
            return .fasta
        case "fastq", "fq":
            return .fastq
        case "bam":
            return .bam
        case "bai":
            return .unknown
        case "json":
            return .json
        case "csv", "tsv", "txt", "py":
            return .text
        default:
            if lowerName.hasSuffix(".fastq.gz") || lowerName.hasSuffix(".fq.gz") {
                return .fastq
            }
            if lowerName.hasSuffix(".fasta.gz") || lowerName.hasSuffix(".fa.gz") {
                return .fasta
            }
            return .unknown
        }
    }

    public static func sampleName(for inputURL: URL, fallback: String) -> String {
        if FASTQBundle.isBundleURL(inputURL) {
            return inputURL.deletingPathExtension().lastPathComponent
        }
        if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) {
            return bundleURL.deletingPathExtension().lastPathComponent
        }
        let stem = inputURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? fallback : stem
    }

    private static func sanitizeFileStem(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "sample" : collapsed
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func url(_ child: URL, isContainedIn parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath == parentPath || childPath.hasPrefix(prefix)
    }
}
