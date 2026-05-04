import ArgumentParser
import Foundation
import LungfishWorkflow

struct AlignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "align",
        abstract: "Create native multiple sequence alignment bundles",
        subcommands: [MAFFTSubcommand.self]
    )

    struct MAFFTEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String?
        let tool: String?
        let sourceCount: Int?
        let bundle: String?
        let rowCount: Int?
        let alignedLength: Int?
        let warningCount: Int?
    }
}

extension AlignCommand {
    struct MAFFTSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mafft",
            abstract: "Align FASTA sequences with MAFFT and create a .lungfishmsa bundle"
        )

        struct Runtime {
            typealias Runner = (
                MSAAlignmentRunRequest,
                @escaping @Sendable (Double, String) -> Void
            ) async throws -> MSAAlignmentRunResult

            let runMAFFT: Runner

            static func live() -> Runtime {
                Runtime(runMAFFT: { request, progress in
                    try await MAFFTAlignmentPipeline().run(request: request, progress: progress)
                })
            }
        }

        @Argument(help: "Input FASTA file(s) containing unaligned sequences")
        var inputFiles: [String]

        @Option(name: .customLong("project"), help: "Lungfish project directory that will receive the .lungfishmsa bundle")
        var projectPath: String

        @Option(name: .customLong("output"), help: "Explicit output .lungfishmsa bundle path")
        var outputPath: String?

        @Option(name: .customLong("name"), help: "Display name for the alignment bundle")
        var name: String?

        @Option(name: .customLong("strategy"), help: "MAFFT strategy: auto, linsi, ginsi, einsi, fftns2, parttree")
        var strategy: String = MAFFTAlignmentStrategy.auto.rawValue

        @Option(name: .customLong("output-order"), help: "Output order: input or aligned")
        var outputOrder: String = MSAAlignmentOutputOrder.input.rawValue

        @Option(name: .customLong("sequence-type"), help: "Sequence type: auto, nucleotide, protein")
        var sequenceType: String = MSASequenceType.auto.rawValue

        @Option(name: .customLong("adjust-direction"), help: "Direction adjustment: off, fast, accurate")
        var adjustDirection: String = MAFFTDirectionAdjustment.off.rawValue

        @Option(name: .customLong("symbols"), help: "Symbol policy: strict or any")
        var symbols: String = MSASymbolPolicy.strict.rawValue

        @Flag(name: .customLong("allow-nondeterministic-threads"), help: "Allow MAFFT iterative refinement to use multithreaded nondeterministic behavior")
        var allowNondeterministicThreads: Bool = false

        @Flag(name: .customLong("allow-fastq-assembly-inputs"), help: "Allow FASTQ records to be treated as assembled/consensus sequences and converted to FASTA before MAFFT")
        var allowFASTQAssemblyInputs: Bool = false

        @Option(
            name: .customLong("extra-mafft-options"),
            parsing: .unconditional,
            help: "Additional MAFFT options, written exactly as they should be passed to MAFFT"
        )
        var extraMAFFTOptions: String = ""

        @OptionGroup var globalOptions: GlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse align mafft arguments.")
            }
            return parsed
        }

        func validate() throws {
            if inputFiles.isEmpty {
                throw ValidationError("At least one input FASTA file is required.")
            }
            if projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--project must not be empty.")
            }
            _ = try parsedStrategy()
            _ = try parsedOutputOrder()
            _ = try parsedSequenceType()
            _ = try parsedDirectionAdjustment()
            _ = try parsedSymbolPolicy()
        }

        func run() async throws {
            let quiet = globalOptions.quiet
            let outputFormat = globalOptions.outputFormat
            let emit: @Sendable (String) -> Void = { line in
                if outputFormat == .text && quiet {
                    return
                }
                print(line)
                fflush(stdout)
            }
            _ = try await executeForCurrentFormat(runtime: .live(), emit: emit)
        }

        func executeForTesting(
            runtime: Runtime,
            emit: @escaping @Sendable (String) -> Void
        ) async throws -> MSAAlignmentRunResult {
            try await executeForCurrentFormat(runtime: runtime, emit: emit)
        }

        func makeRequestForTesting() throws -> MSAAlignmentRunRequest {
            try makeRequest()
        }

        private func executeForCurrentFormat(
            runtime: Runtime,
            emit: @escaping @Sendable (String) -> Void
        ) async throws -> MSAAlignmentRunResult {
            let request = try makeRequest()
            let outputFormat = globalOptions.outputFormat
            let quiet = globalOptions.quiet
            if outputFormat == .json {
                emitJSON(
                    AlignCommand.MAFFTEvent(
                        event: "msaAlignmentStart",
                        progress: 0.0,
                        message: "Starting MAFFT alignment.",
                        tool: "mafft",
                        sourceCount: request.inputSequenceURLs.count,
                        bundle: nil,
                        rowCount: nil,
                        alignedLength: nil,
                        warningCount: nil
                    ),
                    emit: emit
                )
            } else if !quiet {
                emit("Running MAFFT alignment for \(request.inputSequenceURLs.count) input file(s).")
            }

            do {
                let result = try await runtime.runMAFFT(request) { progress, message in
                    if outputFormat == .json {
                        emitJSON(
                            AlignCommand.MAFFTEvent(
                                event: "msaAlignmentProgress",
                                progress: progress,
                                message: message,
                                tool: "mafft",
                                sourceCount: nil,
                                bundle: nil,
                                rowCount: nil,
                                alignedLength: nil,
                                warningCount: nil
                            ),
                            emit: emit
                        )
                    } else if !quiet {
                        emit(message)
                    }
                }
                for warning in result.warnings {
                    if outputFormat == .json {
                        emitJSON(
                            AlignCommand.MAFFTEvent(
                                event: "msaAlignmentWarning",
                                progress: nil,
                                message: warning,
                                tool: "mafft",
                                sourceCount: nil,
                                bundle: nil,
                                rowCount: nil,
                                alignedLength: nil,
                                warningCount: nil
                            ),
                            emit: emit
                        )
                    } else if !quiet {
                        emit("Warning: \(warning)")
                    }
                }
                if outputFormat == .json {
                    emitJSON(
                        AlignCommand.MAFFTEvent(
                            event: "msaAlignmentComplete",
                            progress: 1.0,
                            message: "MAFFT alignment complete.",
                            tool: "mafft",
                            sourceCount: nil,
                            bundle: result.bundleURL.path,
                            rowCount: result.rowCount,
                            alignedLength: result.alignedLength,
                            warningCount: result.warnings.count
                        ),
                        emit: emit
                    )
                } else if !quiet {
                    emit("Created \(result.bundleURL.path)")
                    emit("Rows: \(result.rowCount)")
                    emit("Columns: \(result.alignedLength)")
                }
                return result
            } catch {
                if outputFormat == .json {
                    emitJSON(
                        AlignCommand.MAFFTEvent(
                            event: "msaAlignmentFailed",
                            progress: nil,
                            message: error.localizedDescription,
                            tool: "mafft",
                            sourceCount: nil,
                            bundle: nil,
                            rowCount: nil,
                            alignedLength: nil,
                            warningCount: nil
                        ),
                        emit: emit
                    )
                }
                throw error
            }
        }

        private func makeRequest() throws -> MSAAlignmentRunRequest {
            let inputURLs = inputFiles.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
            let outputURL = outputPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            let displayName = name ?? outputURL?.deletingPathExtension().lastPathComponent
                ?? inputURLs.first?.deletingPathExtension().lastPathComponent
                ?? "MAFFT Alignment"
            let extraArguments = try AdvancedCommandLineOptions.parse(extraMAFFTOptions)
            let wrapperArgv = canonicalArgv(
                inputURLs: inputURLs,
                projectURL: projectURL,
                outputURL: outputURL,
                displayName: displayName
            )
            return MSAAlignmentRunRequest(
                tool: .mafft,
                inputSequenceURLs: inputURLs,
                projectURL: projectURL,
                outputBundleURL: outputURL,
                name: displayName,
                threads: globalOptions.threads,
                strategy: try parsedStrategy(),
                outputOrder: try parsedOutputOrder(),
                sequenceType: try parsedSequenceType(),
                directionAdjustment: try parsedDirectionAdjustment(),
                symbolPolicy: try parsedSymbolPolicy(),
                deterministicThreads: !allowNondeterministicThreads,
                extraArguments: extraArguments,
                wrapperArgv: wrapperArgv,
                allowFASTQAssemblyInputs: allowFASTQAssemblyInputs
            )
        }

        private func parsedStrategy() throws -> MAFFTAlignmentStrategy {
            guard let value = MAFFTAlignmentStrategy(rawValue: strategy.lowercased()) else {
                throw ValidationError("Unsupported MAFFT strategy '\(strategy)'.")
            }
            return value
        }

        private func parsedOutputOrder() throws -> MSAAlignmentOutputOrder {
            guard let value = MSAAlignmentOutputOrder(rawValue: outputOrder.lowercased()) else {
                throw ValidationError("Unsupported output order '\(outputOrder)'.")
            }
            return value
        }

        private func parsedSequenceType() throws -> MSASequenceType {
            guard let value = MSASequenceType(rawValue: sequenceType.lowercased()) else {
                throw ValidationError("Unsupported sequence type '\(sequenceType)'.")
            }
            return value
        }

        private func parsedDirectionAdjustment() throws -> MAFFTDirectionAdjustment {
            guard let value = MAFFTDirectionAdjustment(rawValue: adjustDirection.lowercased()) else {
                throw ValidationError("Unsupported direction adjustment '\(adjustDirection)'.")
            }
            return value
        }

        private func parsedSymbolPolicy() throws -> MSASymbolPolicy {
            guard let value = MSASymbolPolicy(rawValue: symbols.lowercased()) else {
                throw ValidationError("Unsupported symbol policy '\(symbols)'.")
            }
            return value
        }

        private func canonicalArgv(
            inputURLs: [URL],
            projectURL: URL,
            outputURL: URL?,
            displayName: String
        ) -> [String] {
            var argv = ["lungfish", "align", "mafft"] + inputURLs.map(\.path)
            argv += ["--project", projectURL.path]
            if let outputURL {
                argv += ["--output", outputURL.path]
            }
            argv += [
                "--name", displayName,
                "--strategy", strategy.lowercased(),
                "--output-order", outputOrder.lowercased(),
                "--sequence-type", sequenceType.lowercased(),
                "--adjust-direction", adjustDirection.lowercased(),
                "--symbols", symbols.lowercased(),
            ]
            if let threads = globalOptions.threads {
                argv += ["--threads", "\(threads)"]
            }
            let trimmedExtraOptions = extraMAFFTOptions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedExtraOptions.isEmpty {
                argv += ["--extra-mafft-options", trimmedExtraOptions]
            }
            if allowFASTQAssemblyInputs {
                argv += ["--allow-fastq-assembly-inputs"]
            }
            if allowNondeterministicThreads {
                argv += ["--allow-nondeterministic-threads"]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }

        private func emitJSON(_ event: AlignCommand.MAFFTEvent, emit: @Sendable (String) -> Void) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(event),
               let line = String(data: data, encoding: .utf8) {
                emit(line)
            }
        }
    }
}
