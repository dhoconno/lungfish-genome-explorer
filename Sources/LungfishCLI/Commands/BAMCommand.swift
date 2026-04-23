import ArgumentParser
import Foundation
import LungfishWorkflow

struct BAMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bam",
        abstract: "Operate on bundle-owned BAM alignment tracks",
        subcommands: [FilterSubcommand.self]
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
}

extension BAMCommand {
    struct FilterSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "filter",
            abstract: "Derive a filtered BAM alignment track from a bundle or mapping result"
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

        @Option(name: .customLong("mapping-result"), help: "Path to a mapping-result.json file")
        var mappingResultPath: String?

        @Option(name: .customLong("alignment-track"), help: "Bundle alignment track identifier")
        var alignmentTrackID: String

        @Option(name: [.customLong("name"), .customLong("output-track-name")], help: "Display name for the derived alignment track")
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

        @OptionGroup var globalOptions: GlobalOptions

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
            let emitLine: (String) -> Void = { line in
                if globalOptions.outputFormat == .text && globalOptions.quiet {
                    return
                }
                print(line)
            }

            _ = try await executeForCurrentFormat(runtime: .live(), emit: emitLine)
        }

        func executeForTesting(
            runtime: Runtime = .live(),
            emit: @escaping (String) -> Void
        ) async throws -> BundleAlignmentFilterResult {
            try await executeForCurrentFormat(runtime: runtime, emit: emit)
        }

        private func executeForCurrentFormat(
            runtime: Runtime,
            emit: @escaping (String) -> Void
        ) async throws -> BundleAlignmentFilterResult {
            if globalOptions.outputFormat == .json {
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
                return .bundle(URL(fileURLWithPath: bundlePath))
            }
            if let mappingResultPath {
                return .mappingResult(URL(fileURLWithPath: mappingResultPath))
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
            outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
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
