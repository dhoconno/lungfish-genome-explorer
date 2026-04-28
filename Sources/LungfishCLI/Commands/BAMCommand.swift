import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct BAMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bam",
        abstract: "Operate on bundle-owned BAM alignment tracks",
        discussion: """
            Use `lungfish bam filter` to derive filtered alignment tracks and
            `lungfish bam annotate` to convert mapped reads into annotation tracks.
            Use `lungfish bam markdup` to mark duplicates in BAM workflows.
            """,
        subcommands: [FilterSubcommand.self, AnnotateSubcommand.self, AnnotateBestSubcommand.self, AnnotateCDSBestSubcommand.self, MarkdupSubcommand.self, PrimerTrimSubcommand.self]
    )

    struct FilterEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String
        let bundlePath: String?
        let mappingResultPath: String?
        let sourceAlignmentTrackID: String?
        let outputAlignmentTrackID: String?
        let outputAlignmentTrackName: String?
        let bamPath: String?
        let baiPath: String?
        let metadataDBPath: String?
    }

    struct AnnotateEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String
        let bundlePath: String?
        let sourceAlignmentTrackID: String?
        let sourceAlignmentTrackName: String?
        let outputAnnotationTrackID: String?
        let outputAnnotationTrackName: String?
        let databasePath: String?
        let convertedRecordCount: Int?
        let skippedUnmappedCount: Int?
        let skippedSecondarySupplementaryCount: Int?
        let includedSequence: Bool?
        let includedQualities: Bool?
    }

    struct AnnotateBestEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String
        let sourceBundlePath: String?
        let mappingResultPath: String?
        let outputBundlePath: String?
        let outputAnnotationTrackID: String?
        let outputAnnotationTrackName: String?
        let databasePath: String?
        let convertedRecordCount: Int?
        let candidateRecordCount: Int?
        let selectedRecordCount: Int?
        let skippedUnmappedCount: Int?
        let skippedSecondarySupplementaryCount: Int?
    }

    struct AnnotateCDSBestEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String
        let sourceBundlePath: String?
        let mappingResultPath: String?
        let outputBundlePath: String?
        let outputAnnotationTrackID: String?
        let outputAnnotationTrackName: String?
        let databasePath: String?
        let geneCount: Int?
        let cdsCount: Int?
        let candidateRecordCount: Int?
        let selectedLocusCount: Int?
        let skippedUnmappedCount: Int?
        let skippedSecondaryCount: Int?
        let skippedSupplementaryCount: Int?
    }
}

extension BAMCommand {
    struct AnnotateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotate",
            abstract: "Convert mapped reads to annotations in a reference bundle"
        )

        struct Runtime {
            typealias AnnotateRunner = (MappedReadsAnnotationRequest) async throws -> MappedReadsAnnotationResult

            let runAnnotate: AnnotateRunner

            static func live() -> Runtime {
                Runtime(
                    runAnnotate: { request in
                        try await MappedReadsAnnotationService().convertMappedReads(request: request)
                    }
                )
            }
        }

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory")
        var bundlePath: String

        @Option(name: .customLong("alignment-track"), help: "Bundle alignment track identifier")
        var alignmentTrackID: String

        @Option(name: .customLong("output-track-name"), help: "Display name for the annotation track")
        var outputTrackName: String

        @Flag(name: .customLong("primary-only"), help: "Skip secondary and supplementary alignments")
        var primaryOnly: Bool = false

        @Flag(name: .customLong("include-sequence"), help: "Include SAM SEQ in annotation attributes")
        var includeSequence: Bool = false

        @Flag(name: .customLong("include-qualities"), help: "Include SAM QUAL in annotation attributes")
        var includeQualities: Bool = false

        @Flag(name: .customLong("replace"), help: "Replace an existing annotation track with the same generated ID or name")
        var replaceExisting: Bool = false

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse bam annotate arguments.")
            }
            return parsed
        }

        func validate() throws {
            if trimmedValue(bundlePath).isEmpty {
                throw ValidationError("--bundle must not be empty.")
            }
            if trimmedValue(alignmentTrackID).isEmpty {
                throw ValidationError("--alignment-track must not be empty.")
            }
            if trimmedValue(outputTrackName).isEmpty {
                throw ValidationError("--output-track-name must not be empty.")
            }
        }

        func run() async throws {
            let resolvedGlobalOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
            let emitLine: (String) -> Void = { line in
                if resolvedGlobalOptions.outputFormat == .text && resolvedGlobalOptions.quiet {
                    return
                }
                print(line)
            }

            _ = try await executeForCurrentFormat(
                runtime: .live(),
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emitLine
            )
        }

        func executeForTesting(
            runtime: Runtime = .live(),
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> MappedReadsAnnotationResult {
            try await executeForCurrentFormat(
                runtime: runtime,
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emit
            )
        }

        private func executeForCurrentFormat(
            runtime: Runtime,
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> MappedReadsAnnotationResult {
            let resolvedGlobalOptions = resolvedGlobalOptions
                ?? (try? globalOptions.resolved())
                ?? ResolvedTextAndJSONGlobalOptions(
                    outputFormat: globalOptions.outputFormat,
                    quiet: globalOptions.quiet
                )

            if resolvedGlobalOptions.outputFormat == .json {
                return try await execute(runtime: runtime) { event in
                    if let line = encode(event: event) {
                        emit(line)
                    }
                }
            }

            return try await execute(runtime: runtime) { event in
                for line in textLines(for: event) {
                    emit(line)
                }
            }
        }

        private func execute(
            runtime: Runtime,
            emitEvent: @escaping (BAMCommand.AnnotateEvent) -> Void
        ) async throws -> MappedReadsAnnotationResult {
            let request = makeRequest()
            emitEvent(
                BAMCommand.AnnotateEvent(
                    event: "runStart",
                    progress: 0.0,
                    message: "Converting mapped reads from '\(alignmentTrackID)' into '\(normalizedOutputTrackName())'.",
                    bundlePath: request.bundleURL.path,
                    sourceAlignmentTrackID: alignmentTrackID,
                    sourceAlignmentTrackName: nil,
                    outputAnnotationTrackID: nil,
                    outputAnnotationTrackName: normalizedOutputTrackName(),
                    databasePath: nil,
                    convertedRecordCount: nil,
                    skippedUnmappedCount: nil,
                    skippedSecondarySupplementaryCount: nil,
                    includedSequence: includeSequence,
                    includedQualities: includeQualities
                )
            )

            do {
                let result = try await runtime.runAnnotate(request)
                emitEvent(makeRunCompleteEvent(from: result))
                return result
            } catch {
                emitEvent(
                    BAMCommand.AnnotateEvent(
                        event: "runFailed",
                        progress: nil,
                        message: error.localizedDescription,
                        bundlePath: request.bundleURL.path,
                        sourceAlignmentTrackID: alignmentTrackID,
                        sourceAlignmentTrackName: nil,
                        outputAnnotationTrackID: nil,
                        outputAnnotationTrackName: normalizedOutputTrackName(),
                        databasePath: nil,
                        convertedRecordCount: nil,
                        skippedUnmappedCount: nil,
                        skippedSecondarySupplementaryCount: nil,
                        includedSequence: includeSequence,
                        includedQualities: includeQualities
                    )
                )
                throw error
            }
        }

        private func makeRequest() -> MappedReadsAnnotationRequest {
            MappedReadsAnnotationRequest(
                bundleURL: URL(fileURLWithPath: trimmedValue(bundlePath)),
                sourceTrackID: trimmedValue(alignmentTrackID),
                outputTrackName: normalizedOutputTrackName(),
                primaryOnly: primaryOnly,
                includeSequence: includeSequence,
                includeQualities: includeQualities,
                replaceExisting: replaceExisting
            )
        }

        private func normalizedOutputTrackName() -> String {
            trimmedValue(outputTrackName)
        }

        private func trimmedValue(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func makeRunCompleteEvent(
            from result: MappedReadsAnnotationResult
        ) -> BAMCommand.AnnotateEvent {
            BAMCommand.AnnotateEvent(
                event: "runComplete",
                progress: 1.0,
                message: "Created annotation track '\(result.annotationTrackInfo.name)' (\(result.annotationTrackInfo.id)) from mapped reads.",
                bundlePath: result.bundleURL.path,
                sourceAlignmentTrackID: result.sourceAlignmentTrackID,
                sourceAlignmentTrackName: result.sourceAlignmentTrackName,
                outputAnnotationTrackID: result.annotationTrackInfo.id,
                outputAnnotationTrackName: result.annotationTrackInfo.name,
                databasePath: absolutePath(for: result.databasePath, within: result.bundleURL),
                convertedRecordCount: result.convertedRecordCount,
                skippedUnmappedCount: result.skippedUnmappedCount,
                skippedSecondarySupplementaryCount: result.skippedSecondarySupplementaryCount,
                includedSequence: result.includedSequence,
                includedQualities: result.includedQualities
            )
        }

        private func absolutePath(for path: String, within bundleURL: URL) -> String {
            let candidate = URL(fileURLWithPath: path)
            if candidate.isFileURL && path.hasPrefix("/") {
                return candidate.path
            }
            return bundleURL.appendingPathComponent(path).path
        }

        private func textLines(for event: BAMCommand.AnnotateEvent) -> [String] {
            switch event.event {
            case "runComplete":
                var lines = [event.message]
                if let bundlePath = event.bundlePath {
                    lines.append("Bundle: \(bundlePath)")
                }
                if let id = event.sourceAlignmentTrackID {
                    if let name = event.sourceAlignmentTrackName {
                        lines.append("Source alignment track: \(id) (\(name))")
                    } else {
                        lines.append("Source alignment track: \(id)")
                    }
                }
                if let databasePath = event.databasePath {
                    lines.append("Database: \(databasePath)")
                }
                if let convertedRecordCount = event.convertedRecordCount {
                    lines.append("Converted reads: \(convertedRecordCount)")
                }
                if let skippedUnmappedCount = event.skippedUnmappedCount {
                    lines.append("Skipped unmapped reads: \(skippedUnmappedCount)")
                }
                if let skippedSecondarySupplementaryCount = event.skippedSecondarySupplementaryCount {
                    lines.append("Skipped secondary/supplementary reads: \(skippedSecondarySupplementaryCount)")
                }
                return lines
            default:
                return [event.message]
            }
        }

        private func encode(event: BAMCommand.AnnotateEvent) -> String? {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(event) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    struct AnnotateBestSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotate-best",
            abstract: "Create a new bundle with the best mapped read per overlapping genomic interval"
        )

        struct Runtime {
            typealias AnnotateBestRunner = (BestMappedReadsAnnotationRequest) async throws -> BestMappedReadsAnnotationResult

            let runAnnotateBest: AnnotateBestRunner

            static func live() -> Runtime {
                Runtime(
                    runAnnotateBest: { request in
                        try await BestMappedReadsAnnotationService().convertBestMappedReads(request: request)
                    }
                )
            }
        }

        @Option(name: .customLong("bundle"), help: "Path to the source reference bundle directory")
        var bundlePath: String

        @Option(name: .customLong("mapping-result"), help: "Path to the mapping analysis directory")
        var mappingResultPath: String

        @Option(name: .customLong("output-bundle"), help: "Path for the new output reference bundle")
        var outputBundlePath: String

        @Option(name: .customLong("output-track-name"), help: "Display name for the annotation track")
        var outputTrackName: String

        @Flag(name: .customLong("primary-only"), help: "Skip secondary and supplementary alignments")
        var primaryOnly: Bool = false

        @Flag(name: .customLong("replace"), help: "Replace an existing output bundle or track with the same name")
        var replaceExisting: Bool = false

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse bam annotate-best arguments.")
            }
            return parsed
        }

        func validate() throws {
            if trimmedValue(bundlePath).isEmpty {
                throw ValidationError("--bundle must not be empty.")
            }
            if trimmedValue(mappingResultPath).isEmpty {
                throw ValidationError("--mapping-result must not be empty.")
            }
            if trimmedValue(outputBundlePath).isEmpty {
                throw ValidationError("--output-bundle must not be empty.")
            }
            if trimmedValue(outputTrackName).isEmpty {
                throw ValidationError("--output-track-name must not be empty.")
            }
        }

        func run() async throws {
            let resolvedGlobalOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
            let emitLine: (String) -> Void = { line in
                if resolvedGlobalOptions.outputFormat == .text && resolvedGlobalOptions.quiet {
                    return
                }
                print(line)
            }

            _ = try await executeForCurrentFormat(
                runtime: .live(),
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emitLine
            )
        }

        func executeForTesting(
            runtime: Runtime = .live(),
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> BestMappedReadsAnnotationResult {
            try await executeForCurrentFormat(
                runtime: runtime,
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emit
            )
        }

        private func executeForCurrentFormat(
            runtime: Runtime,
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> BestMappedReadsAnnotationResult {
            let resolvedGlobalOptions = resolvedGlobalOptions
                ?? (try? globalOptions.resolved())
                ?? ResolvedTextAndJSONGlobalOptions(
                    outputFormat: globalOptions.outputFormat,
                    quiet: globalOptions.quiet
                )

            if resolvedGlobalOptions.outputFormat == .json {
                return try await execute(runtime: runtime) { event in
                    if let line = encode(event: event) {
                        emit(line)
                    }
                }
            }

            return try await execute(runtime: runtime) { event in
                for line in textLines(for: event) {
                    emit(line)
                }
            }
        }

        private func execute(
            runtime: Runtime,
            emitEvent: @escaping (BAMCommand.AnnotateBestEvent) -> Void
        ) async throws -> BestMappedReadsAnnotationResult {
            let request = makeRequest()
            emitEvent(
                BAMCommand.AnnotateBestEvent(
                    event: "runStart",
                    progress: 0.0,
                    message: "Selecting best mapped reads from '\(mappingResultPath)' into '\(normalizedOutputTrackName())'.",
                    sourceBundlePath: request.sourceBundleURL.path,
                    mappingResultPath: request.mappingResultURL.path,
                    outputBundlePath: request.outputBundleURL.path,
                    outputAnnotationTrackID: nil,
                    outputAnnotationTrackName: normalizedOutputTrackName(),
                    databasePath: nil,
                    convertedRecordCount: nil,
                    candidateRecordCount: nil,
                    selectedRecordCount: nil,
                    skippedUnmappedCount: nil,
                    skippedSecondarySupplementaryCount: nil
                )
            )

            do {
                let result = try await runtime.runAnnotateBest(request)
                emitEvent(makeRunCompleteEvent(from: result))
                return result
            } catch {
                emitEvent(
                    BAMCommand.AnnotateBestEvent(
                        event: "runFailed",
                        progress: nil,
                        message: error.localizedDescription,
                        sourceBundlePath: request.sourceBundleURL.path,
                        mappingResultPath: request.mappingResultURL.path,
                        outputBundlePath: request.outputBundleURL.path,
                        outputAnnotationTrackID: nil,
                        outputAnnotationTrackName: normalizedOutputTrackName(),
                        databasePath: nil,
                        convertedRecordCount: nil,
                        candidateRecordCount: nil,
                        selectedRecordCount: nil,
                        skippedUnmappedCount: nil,
                        skippedSecondarySupplementaryCount: nil
                    )
                )
                throw error
            }
        }

        private func makeRequest() -> BestMappedReadsAnnotationRequest {
            BestMappedReadsAnnotationRequest(
                sourceBundleURL: URL(fileURLWithPath: trimmedValue(bundlePath)),
                mappingResultURL: URL(fileURLWithPath: trimmedValue(mappingResultPath)),
                outputBundleURL: URL(fileURLWithPath: trimmedValue(outputBundlePath)),
                outputTrackName: normalizedOutputTrackName(),
                primaryOnly: primaryOnly,
                replaceExisting: replaceExisting
            )
        }

        private func normalizedOutputTrackName() -> String {
            trimmedValue(outputTrackName)
        }

        private func trimmedValue(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func makeRunCompleteEvent(
            from result: BestMappedReadsAnnotationResult
        ) -> BAMCommand.AnnotateBestEvent {
            BAMCommand.AnnotateBestEvent(
                event: "runComplete",
                progress: 1.0,
                message: "Created annotation track '\(result.annotationTrackInfo.name)' (\(result.annotationTrackInfo.id)) in output bundle.",
                sourceBundlePath: result.sourceBundleURL.path,
                mappingResultPath: result.mappingResultURL.path,
                outputBundlePath: result.outputBundleURL.path,
                outputAnnotationTrackID: result.annotationTrackInfo.id,
                outputAnnotationTrackName: result.annotationTrackInfo.name,
                databasePath: absolutePath(for: result.databasePath, within: result.outputBundleURL),
                convertedRecordCount: result.convertedRecordCount,
                candidateRecordCount: result.candidateRecordCount,
                selectedRecordCount: result.selectedRecordCount,
                skippedUnmappedCount: result.skippedUnmappedCount,
                skippedSecondarySupplementaryCount: result.skippedSecondarySupplementaryCount
            )
        }

        private func absolutePath(for path: String, within bundleURL: URL) -> String {
            let candidate = URL(fileURLWithPath: path)
            if candidate.isFileURL && path.hasPrefix("/") {
                return candidate.path
            }
            return bundleURL.appendingPathComponent(path).path
        }

        private func textLines(for event: BAMCommand.AnnotateBestEvent) -> [String] {
            switch event.event {
            case "runComplete":
                var lines = [event.message]
                if let outputBundlePath = event.outputBundlePath {
                    lines.append("Output bundle: \(outputBundlePath)")
                }
                if let sourceBundlePath = event.sourceBundlePath {
                    lines.append("Source bundle: \(sourceBundlePath)")
                }
                if let mappingResultPath = event.mappingResultPath {
                    lines.append("Mapping result: \(mappingResultPath)")
                }
                if let databasePath = event.databasePath {
                    lines.append("Database: \(databasePath)")
                }
                if let convertedRecordCount = event.convertedRecordCount {
                    lines.append("Converted reads: \(convertedRecordCount)")
                }
                if let candidateRecordCount = event.candidateRecordCount {
                    lines.append("Candidate reads: \(candidateRecordCount)")
                }
                if let skippedSecondarySupplementaryCount = event.skippedSecondarySupplementaryCount {
                    lines.append("Skipped secondary/supplementary reads: \(skippedSecondarySupplementaryCount)")
                }
                return lines
            default:
                return [event.message]
            }
        }

        private func encode(event: BAMCommand.AnnotateBestEvent) -> String? {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(event) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    struct AnnotateCDSBestSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotate-cds-best",
            abstract: "Create a new bundle with best CDS query gene and CDS annotations"
        )

        struct Runtime {
            typealias AnnotateCDSBestRunner = (CDSBestAnnotationRequest) async throws -> CDSBestAnnotationResult

            let runAnnotateCDSBest: AnnotateCDSBestRunner

            static func live() -> Runtime {
                Runtime(
                    runAnnotateCDSBest: { request in
                        try await CDSBestAnnotationService().convertBestCDS(request: request)
                    }
                )
            }
        }

        @Option(name: .customLong("bundle"), help: "Path to the source reference bundle directory")
        var bundlePath: String

        @Option(name: .customLong("mapping-result"), help: "Path to the mapping analysis directory")
        var mappingResultPath: String

        @Option(name: .customLong("output-bundle"), help: "Path for the new output reference bundle")
        var outputBundlePath: String

        @Option(name: .customLong("output-track-name"), help: "Display name for the annotation track")
        var outputTrackName: String

        @Flag(name: .customLong("include-secondary"), help: "Use secondary alignments as candidate duplicated loci")
        var includeSecondary: Bool = false

        @Flag(name: .customLong("include-supplementary"), help: "Use supplementary alignments as candidate CDS models")
        var includeSupplementary: Bool = false

        @Option(name: .customLong("min-query-cover"), help: "Minimum fraction of the CDS query covered by aligned components")
        var minimumQueryCoverage: Double = 0.5

        @Flag(name: .customLong("replace"), help: "Replace an existing output bundle or track with the same name")
        var replaceExisting: Bool = false

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse bam annotate-cds-best arguments.")
            }
            return parsed
        }

        func validate() throws {
            if trimmedValue(bundlePath).isEmpty {
                throw ValidationError("--bundle must not be empty.")
            }
            if trimmedValue(mappingResultPath).isEmpty {
                throw ValidationError("--mapping-result must not be empty.")
            }
            if trimmedValue(outputBundlePath).isEmpty {
                throw ValidationError("--output-bundle must not be empty.")
            }
            if trimmedValue(outputTrackName).isEmpty {
                throw ValidationError("--output-track-name must not be empty.")
            }
            if !(0...1).contains(minimumQueryCoverage) {
                throw ValidationError("--min-query-cover must be between 0 and 1.")
            }
        }

        func run() async throws {
            let resolvedGlobalOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
            let emitLine: (String) -> Void = { line in
                if resolvedGlobalOptions.outputFormat == .text && resolvedGlobalOptions.quiet {
                    return
                }
                print(line)
            }

            _ = try await executeForCurrentFormat(
                runtime: .live(),
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emitLine
            )
        }

        func executeForTesting(
            runtime: Runtime = .live(),
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> CDSBestAnnotationResult {
            try await executeForCurrentFormat(
                runtime: runtime,
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emit
            )
        }

        private func executeForCurrentFormat(
            runtime: Runtime,
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> CDSBestAnnotationResult {
            let resolvedGlobalOptions = resolvedGlobalOptions
                ?? (try? globalOptions.resolved())
                ?? ResolvedTextAndJSONGlobalOptions(
                    outputFormat: globalOptions.outputFormat,
                    quiet: globalOptions.quiet
                )

            if resolvedGlobalOptions.outputFormat == .json {
                return try await execute(runtime: runtime) { event in
                    if let line = encode(event: event) {
                        emit(line)
                    }
                }
            }

            return try await execute(runtime: runtime) { event in
                for line in textLines(for: event) {
                    emit(line)
                }
            }
        }

        private func execute(
            runtime: Runtime,
            emitEvent: @escaping (BAMCommand.AnnotateCDSBestEvent) -> Void
        ) async throws -> CDSBestAnnotationResult {
            let request = makeRequest()
            emitEvent(
                BAMCommand.AnnotateCDSBestEvent(
                    event: "runStart",
                    progress: 0.0,
                    message: "Selecting best CDS models from '\(mappingResultPath)' into '\(normalizedOutputTrackName())'.",
                    sourceBundlePath: request.sourceBundleURL.path,
                    mappingResultPath: request.mappingResultURL.path,
                    outputBundlePath: request.outputBundleURL.path,
                    outputAnnotationTrackID: nil,
                    outputAnnotationTrackName: normalizedOutputTrackName(),
                    databasePath: nil,
                    geneCount: nil,
                    cdsCount: nil,
                    candidateRecordCount: nil,
                    selectedLocusCount: nil,
                    skippedUnmappedCount: nil,
                    skippedSecondaryCount: nil,
                    skippedSupplementaryCount: nil
                )
            )

            do {
                let result = try await runtime.runAnnotateCDSBest(request)
                emitEvent(makeRunCompleteEvent(from: result))
                return result
            } catch {
                emitEvent(
                    BAMCommand.AnnotateCDSBestEvent(
                        event: "runFailed",
                        progress: nil,
                        message: error.localizedDescription,
                        sourceBundlePath: request.sourceBundleURL.path,
                        mappingResultPath: request.mappingResultURL.path,
                        outputBundlePath: request.outputBundleURL.path,
                        outputAnnotationTrackID: nil,
                        outputAnnotationTrackName: normalizedOutputTrackName(),
                        databasePath: nil,
                        geneCount: nil,
                        cdsCount: nil,
                        candidateRecordCount: nil,
                        selectedLocusCount: nil,
                        skippedUnmappedCount: nil,
                        skippedSecondaryCount: nil,
                        skippedSupplementaryCount: nil
                    )
                )
                throw error
            }
        }

        private func makeRequest() -> CDSBestAnnotationRequest {
            CDSBestAnnotationRequest(
                sourceBundleURL: URL(fileURLWithPath: trimmedValue(bundlePath)),
                mappingResultURL: URL(fileURLWithPath: trimmedValue(mappingResultPath)),
                outputBundleURL: URL(fileURLWithPath: trimmedValue(outputBundlePath)),
                outputTrackName: normalizedOutputTrackName(),
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary,
                minimumQueryCoverage: minimumQueryCoverage,
                replaceExisting: replaceExisting
            )
        }

        private func normalizedOutputTrackName() -> String {
            trimmedValue(outputTrackName)
        }

        private func trimmedValue(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func makeRunCompleteEvent(
            from result: CDSBestAnnotationResult
        ) -> BAMCommand.AnnotateCDSBestEvent {
            BAMCommand.AnnotateCDSBestEvent(
                event: "runComplete",
                progress: 1.0,
                message: "Created CDS annotation track '\(result.annotationTrackInfo.name)' (\(result.annotationTrackInfo.id)) in output bundle.",
                sourceBundlePath: result.sourceBundleURL.path,
                mappingResultPath: result.mappingResultURL.path,
                outputBundlePath: result.outputBundleURL.path,
                outputAnnotationTrackID: result.annotationTrackInfo.id,
                outputAnnotationTrackName: result.annotationTrackInfo.name,
                databasePath: absolutePath(for: result.databasePath, within: result.outputBundleURL),
                geneCount: result.geneCount,
                cdsCount: result.cdsCount,
                candidateRecordCount: result.candidateRecordCount,
                selectedLocusCount: result.selectedLocusCount,
                skippedUnmappedCount: result.skippedUnmappedCount,
                skippedSecondaryCount: result.skippedSecondaryCount,
                skippedSupplementaryCount: result.skippedSupplementaryCount
            )
        }

        private func absolutePath(for path: String, within bundleURL: URL) -> String {
            let candidate = URL(fileURLWithPath: path)
            if candidate.isFileURL && path.hasPrefix("/") {
                return candidate.path
            }
            return bundleURL.appendingPathComponent(path).path
        }

        private func textLines(for event: BAMCommand.AnnotateCDSBestEvent) -> [String] {
            switch event.event {
            case "runComplete":
                var lines = [event.message]
                if let outputBundlePath = event.outputBundlePath {
                    lines.append("Output bundle: \(outputBundlePath)")
                }
                if let sourceBundlePath = event.sourceBundlePath {
                    lines.append("Source bundle: \(sourceBundlePath)")
                }
                if let mappingResultPath = event.mappingResultPath {
                    lines.append("Mapping result: \(mappingResultPath)")
                }
                if let databasePath = event.databasePath {
                    lines.append("Database: \(databasePath)")
                }
                if let geneCount = event.geneCount {
                    lines.append("Genes: \(geneCount)")
                }
                if let cdsCount = event.cdsCount {
                    lines.append("CDS features: \(cdsCount)")
                }
                if let candidateRecordCount = event.candidateRecordCount {
                    lines.append("Candidate CDS records: \(candidateRecordCount)")
                }
                return lines
            default:
                return [event.message]
            }
        }

        private func encode(event: BAMCommand.AnnotateCDSBestEvent) -> String? {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(event) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    struct MarkdupSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "markdup",
            abstract: "Mark PCR duplicates in BAM files using samtools markdup"
        )

        @Argument(help: "Path to a BAM file or a directory containing BAMs")
        var path: String

        @Flag(name: .long, help: "Re-run markdup even if already marked")
        var force: Bool = false

        @Option(name: .customLong("sort-threads"), help: "Threads for samtools sort (default 4)")
        var sortThreads: Int = 4

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse bam markdup arguments.")
            }
            return parsed
        }

        func run() async throws {
            let resolvedGlobalOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
            _ = try await executeForTesting(
                runtime: .live(),
                resolvedGlobalOptions: resolvedGlobalOptions
            ) { print($0) }
        }

        func executeForTesting(
            runtime: MarkdupCommand.Runtime = .live(),
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> [MarkdupResult] {
            let resolvedGlobalOptions = resolvedGlobalOptions
                ?? (try? globalOptions.resolved())
                ?? ResolvedTextAndJSONGlobalOptions(
                    outputFormat: globalOptions.outputFormat,
                    quiet: globalOptions.quiet
                )
            return try await MarkdupCommand.execute(
                input: MarkdupCommand.ExecutionInput(
                    path: path,
                    force: force,
                    sortThreads: sortThreads,
                    quiet: resolvedGlobalOptions.quiet,
                    outputFormat: resolvedGlobalOptions.outputFormat
                ),
                runtime: runtime,
                emit: emit
            )
        }
    }

    struct FilterSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "filter",
            abstract: "Derive a filtered BAM alignment track from a bundle or mapping analysis directory"
        )

        struct Runtime {
            typealias FilterRunner = (
                AlignmentFilterTarget,
                String,
                String,
                AlignmentFilterRequest
            ) async throws -> BundleAlignmentFilterResult

            let runFilter: FilterRunner

            static func live() -> Runtime {
                Runtime(
                    runFilter: { target, sourceTrackID, outputTrackName, request in
                        try await BundleAlignmentFilterService().deriveFilteredAlignment(
                            target: target,
                            sourceTrackID: sourceTrackID,
                            outputTrackName: outputTrackName,
                            filterRequest: request
                        )
                    }
                )
            }
        }

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory")
        var bundlePath: String?

        @Option(name: .customLong("mapping-result"), help: "Path to the mapping analysis directory")
        var mappingResultPath: String?

        @Option(name: .customLong("alignment-track"), help: "Bundle alignment track identifier")
        var alignmentTrackID: String

        @Option(name: .customLong("output-track-name"), help: "Display name for the derived alignment track")
        var outputTrackName: String

        @Flag(name: .customLong("mapped-only"), help: "Exclude unmapped reads from the derived BAM")
        var mappedOnly: Bool = false

        @Flag(name: .customLong("primary-only"), help: "Keep only primary alignments")
        var primaryOnly: Bool = false

        @Option(name: .customLong("min-mapq"), help: "Minimum MAPQ score to retain")
        var minimumMAPQ: Int?

        @Flag(name: .customLong("exclude-marked-duplicates"), help: "Exclude reads already marked as duplicates")
        var excludeMarkedDuplicates: Bool = false

        @Flag(name: .customLong("remove-duplicates"), help: "Mark duplicates first, then exclude them from the derived BAM")
        var removeDuplicates: Bool = false

        @Flag(name: .customLong("exact-match"), help: "Keep only exact matches (NM == 0)")
        var exactMatch: Bool = false

        @Option(name: .customLong("min-percent-identity"), help: "Minimum percent identity threshold")
        var minimumPercentIdentity: Double?

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse bam filter arguments.")
            }
            return parsed
        }

        func validate() throws {
            if let bundlePath, trimmedValue(bundlePath).isEmpty {
                throw ValidationError("--bundle must not be empty.")
            }

            if let mappingResultPath, trimmedValue(mappingResultPath).isEmpty {
                throw ValidationError("--mapping-result must not be empty.")
            }

            if trimmedValue(outputTrackName).isEmpty {
                throw ValidationError("--output-track-name must not be empty.")
            }

            let targetCount = [bundlePath, mappingResultPath].compactMap { $0 }.count
            guard targetCount == 1 else {
                throw ValidationError("Specify exactly one of --bundle or --mapping-result.")
            }

            if excludeMarkedDuplicates && removeDuplicates {
                throw ValidationError("--exclude-marked-duplicates and --remove-duplicates are mutually exclusive.")
            }

            if exactMatch && minimumPercentIdentity != nil {
                throw ValidationError("--exact-match and --min-percent-identity are mutually exclusive.")
            }

            if let minimumMAPQ, minimumMAPQ < 0 {
                throw ValidationError("Invalid minimum MAPQ: \(minimumMAPQ)")
            }

            if let minimumPercentIdentity, !(0...100).contains(minimumPercentIdentity) {
                throw ValidationError("Invalid minimum percent identity: \(minimumPercentIdentity)")
            }
        }

        func run() async throws {
            let resolvedGlobalOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
            let emitLine: (String) -> Void = { line in
                if resolvedGlobalOptions.outputFormat == .text && resolvedGlobalOptions.quiet {
                    return
                }
                print(line)
            }

            _ = try await executeForCurrentFormat(
                runtime: .live(),
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emitLine
            )
        }

        func executeForTesting(
            runtime: Runtime = .live(),
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> BundleAlignmentFilterResult {
            try await executeForCurrentFormat(
                runtime: runtime,
                resolvedGlobalOptions: resolvedGlobalOptions,
                emit: emit
            )
        }

        private func executeForCurrentFormat(
            runtime: Runtime,
            resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
            emit: @escaping (String) -> Void
        ) async throws -> BundleAlignmentFilterResult {
            let resolvedGlobalOptions = resolvedGlobalOptions
                ?? (try? globalOptions.resolved())
                ?? ResolvedTextAndJSONGlobalOptions(
                    outputFormat: globalOptions.outputFormat,
                    quiet: globalOptions.quiet
                )

            if resolvedGlobalOptions.outputFormat == .json {
                return try await execute(runtime: runtime) { event in
                    if let line = encode(event: event) {
                        emit(line)
                    }
                }
            }

            return try await execute(runtime: runtime) { event in
                for line in textLines(for: event) {
                    emit(line)
                }
            }
        }

        private func execute(
            runtime: Runtime,
            emitEvent: @escaping (BAMCommand.FilterEvent) -> Void
        ) async throws -> BundleAlignmentFilterResult {
            let target = try resolvedTarget()
            let request = makeFilterRequest()

            emitEvent(
                BAMCommand.FilterEvent(
                    event: "runStart",
                    progress: 0.0,
                    message: "Filtering alignment track '\(alignmentTrackID)' into '\(normalizedOutputTrackName())'.",
                    bundlePath: bundlePath,
                    mappingResultPath: mappingResultPath,
                    sourceAlignmentTrackID: alignmentTrackID,
                    outputAlignmentTrackID: nil,
                    outputAlignmentTrackName: normalizedOutputTrackName(),
                    bamPath: nil,
                    baiPath: nil,
                    metadataDBPath: nil
                )
            )

            do {
                let result = try await runtime.runFilter(
                    target,
                    alignmentTrackID,
                    normalizedOutputTrackName(),
                    request
                )
                emitEvent(makeRunCompleteEvent(from: result))
                return result
            } catch {
                emitEvent(
                    BAMCommand.FilterEvent(
                        event: "runFailed",
                        progress: nil,
                        message: error.localizedDescription,
                        bundlePath: bundlePath,
                        mappingResultPath: mappingResultPath,
                        sourceAlignmentTrackID: alignmentTrackID,
                        outputAlignmentTrackID: nil,
                        outputAlignmentTrackName: normalizedOutputTrackName(),
                        bamPath: nil,
                        baiPath: nil,
                        metadataDBPath: nil
                    )
                )
                throw error
            }
        }

        private func resolvedTarget() throws -> AlignmentFilterTarget {
            if let bundlePath {
                return .bundle(URL(fileURLWithPath: trimmedValue(bundlePath)))
            }
            if let mappingResultPath {
                return .mappingResult(URL(fileURLWithPath: trimmedValue(mappingResultPath)))
            }
            throw ValidationError("Specify exactly one of --bundle or --mapping-result.")
        }

        private func makeFilterRequest() -> AlignmentFilterRequest {
            AlignmentFilterRequest(
                mappedOnly: mappedOnly,
                primaryOnly: primaryOnly,
                minimumMAPQ: minimumMAPQ,
                duplicateMode: duplicateMode(),
                identityFilter: identityFilter(),
                region: nil
            )
        }

        private func duplicateMode() -> AlignmentFilterDuplicateMode? {
            if removeDuplicates {
                return .remove
            }
            if excludeMarkedDuplicates {
                return .exclude
            }
            return nil
        }

        private func identityFilter() -> AlignmentFilterIdentityFilter? {
            if exactMatch {
                return .exactMatch
            }
            if let minimumPercentIdentity {
                return .minimumPercentIdentity(minimumPercentIdentity)
            }
            return nil
        }

        private func normalizedOutputTrackName() -> String {
            trimmedValue(outputTrackName)
        }

        private func trimmedValue(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func makeRunCompleteEvent(
            from result: BundleAlignmentFilterResult
        ) -> BAMCommand.FilterEvent {
            BAMCommand.FilterEvent(
                event: "runComplete",
                progress: 1.0,
                message: "Created filtered BAM track '\(result.trackInfo.name)' (\(result.trackInfo.id)).",
                bundlePath: result.bundleURL.path,
                mappingResultPath: result.mappingResultURL?.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: result.trackInfo.id,
                outputAlignmentTrackName: result.trackInfo.name,
                bamPath: absolutePath(for: result.trackInfo.sourcePath, within: result.bundleURL),
                baiPath: absolutePath(for: result.trackInfo.indexPath, within: result.bundleURL),
                metadataDBPath: result.trackInfo.metadataDBPath.map { absolutePath(for: $0, within: result.bundleURL) }
            )
        }

        private func absolutePath(for path: String, within bundleURL: URL) -> String {
            let candidate = URL(fileURLWithPath: path)
            if candidate.isFileURL && path.hasPrefix("/") {
                return candidate.path
            }
            return bundleURL.appendingPathComponent(path).path
        }

        private func textLines(for event: BAMCommand.FilterEvent) -> [String] {
            switch event.event {
            case "runComplete":
                var lines = [event.message]
                if let bundlePath = event.bundlePath {
                    lines.append("Bundle: \(bundlePath)")
                }
                if let mappingResultPath = event.mappingResultPath {
                    lines.append("Mapping result: \(mappingResultPath)")
                }
                if let sourceAlignmentTrackID = event.sourceAlignmentTrackID {
                    lines.append("Source alignment track: \(sourceAlignmentTrackID)")
                }
                if let bamPath = event.bamPath {
                    lines.append("BAM: \(bamPath)")
                }
                if let baiPath = event.baiPath {
                    lines.append("BAI: \(baiPath)")
                }
                if let metadataDBPath = event.metadataDBPath {
                    lines.append("Metadata DB: \(metadataDBPath)")
                }
                return lines
            default:
                return [event.message]
            }
        }

        private func encode(event: BAMCommand.FilterEvent) -> String? {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(event) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }
}
