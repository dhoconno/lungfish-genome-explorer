import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct VariantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract: "Call viral variants from a bundle-owned alignment track",
        subcommands: [CallSubcommand.self]
    )

    struct Runtime {
        typealias Preflight = (BundleVariantCallingRequest) async throws -> BAMVariantCallingPreflightResult
        typealias PipelineRunner = (
            BundleVariantCallingRequest,
            BAMVariantCallingPreflightResult,
            CallContext
        ) async throws -> ViralVariantCallingPipelineResult
        typealias SQLiteImporter = (
            VariantSQLiteImportRequest,
            CallContext
        ) async throws -> VariantSQLiteImportResult
        typealias TrackAttacher = (
            BundleVariantTrackAttachmentRequest
        ) async throws -> BundleVariantTrackAttachmentResult

        let preflight: Preflight
        let runPipeline: PipelineRunner
        let importSQLite: SQLiteImporter
        let attachTrack: TrackAttacher

        static func live() -> Runtime {
            Runtime(
                preflight: { request in
                    for tool in requiredTools(for: request.caller) {
                        do {
                            _ = try await NativeToolRunner.shared.findTool(tool)
                        } catch {
                            throw CLIError.workflowFailed(reason: "Required managed tool is not available: \(tool.executableName)")
                        }
                    }
                    return try await BAMVariantCallingPreflight().validate(request)
                },
                runPipeline: { request, preflight, context in
                    let pipeline = ViralVariantCallingPipeline(
                        request: request,
                        preflight: preflight,
                        stagingRoot: context.stagingRoot
                    )
                    return try await pipeline.run(progress: context.emitStageProgress)
                },
                importSQLite: { request, context in
                    try await VariantSQLiteImportCoordinator().importNormalizedVCF(
                        request: request,
                        progressHandler: context.emitStageProgress,
                        shouldCancel: context.shouldCancel
                    )
                },
                attachTrack: { request in
                    try await BundleVariantTrackAttachmentService().attach(request: request)
                }
            )
        }
    }

    struct CallContext {
        let stagingRoot: URL
        let emitStageProgress: @Sendable (Double, String) -> Void
        let shouldCancel: @Sendable () -> Bool
    }

    struct VariantCallingEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String
        let bundlePath: String?
        let variantTrackID: String?
        let variantTrackName: String?
        let caller: String?
        let vcfPath: String?
        let tbiPath: String?
        let databasePath: String?
        let importedVariantCount: Int?
    }

    private static func requiredTools(for caller: ViralVariantCaller) -> [NativeTool] {
        [
            .samtools,
            .bcftools,
            .bgzip,
            .tabix,
            nativeTool(for: caller),
        ]
    }

    private static func nativeTool(for caller: ViralVariantCaller) -> NativeTool {
        switch caller {
        case .lofreq:
            return .lofreq
        case .ivar:
            return .ivar
        case .medaka:
            return .medaka
        }
    }
}

extension VariantsCommand {
    struct CallSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "call",
            abstract: "Call viral variants from a bundle-owned alignment track"
        )

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory")
        var bundlePath: String

        @Option(name: .customLong("alignment-track"), help: "Bundle alignment track identifier")
        var alignmentTrackID: String

        @Option(name: .customLong("caller"), help: "Variant caller: lofreq, ivar, medaka")
        var caller: String

        @Option(name: [.customLong("name"), .customLong("output-track-name")], help: "Display name for the created variant track")
        var outputTrackName: String?

        @Option(name: .customLong("min-af"), help: "Minimum allele frequency threshold")
        var minimumAlleleFrequency: Double?

        @Option(name: .customLong("min-depth"), help: "Minimum depth threshold")
        var minimumDepth: Int?

        @Flag(name: .customLong("ivar-primer-trimmed"), help: "Confirm the BAM was primer-trimmed before iVar calling")
        var ivarPrimerTrimConfirmed: Bool = false

        @Option(name: .customLong("medaka-model"), help: "Required ONT/basecaller model identifier for Medaka")
        var medakaModel: String?

        @OptionGroup var globalOptions: GlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse variants call arguments.")
            }
            return parsed
        }

        func run() async throws {
            let emitter: (VariantsCommand.VariantCallingEvent) -> Void
            if globalOptions.outputFormat == .json {
                emitter = { event in
                    if let line = encode(event: event) {
                        print(line)
                    }
                }
            } else {
                emitter = { event in
                    guard !globalOptions.quiet else { return }
                    print(event.message)
                }
            }

            _ = try await execute(runtime: .live(), emitEvent: emitter)
        }

        func executeForTesting(
            runtime: VariantsCommand.Runtime = .live(),
            emit: @escaping (String) -> Void
        ) async throws -> BundleVariantTrackAttachmentResult {
            try await execute(runtime: runtime) { event in
                if let line = encode(event: event) {
                    emit(line)
                }
            }
        }

        private func execute(
            runtime: VariantsCommand.Runtime,
            emitEvent: @escaping (VariantsCommand.VariantCallingEvent) -> Void
        ) async throws -> BundleVariantTrackAttachmentResult {
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let resolvedCaller = try parseCaller()
            let initialTrackName = normalizedOutputTrackName(fallback: resolvedCaller.displayName)
            let initialRequest = BundleVariantCallingRequest(
                bundleURL: bundleURL,
                alignmentTrackID: alignmentTrackID,
                caller: resolvedCaller,
                outputTrackName: initialTrackName,
                threads: globalOptions.effectiveThreads,
                minimumAlleleFrequency: minimumAlleleFrequency,
                minimumDepth: minimumDepth,
                ivarPrimerTrimConfirmed: ivarPrimerTrimConfirmed,
                medakaModel: medakaModel
            )

            emitSimpleEvent(event: "runStart", progress: 0.0, message: "Starting \(resolvedCaller.displayName) variant calling", caller: resolvedCaller.rawValue, emit: emitEvent)
            emitSimpleEvent(event: "preflightStart", progress: 0.02, message: "Checking bundle and alignment inputs", caller: resolvedCaller.rawValue, emit: emitEvent)

            do {
                let preflight = try await runtime.preflight(initialRequest)
                let finalTrackName = normalizedOutputTrackName(
                    fallback: "\(preflight.alignmentTrack.name) • \(resolvedCaller.displayName)"
                )
                let request = BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: alignmentTrackID,
                    caller: resolvedCaller,
                    outputTrackName: finalTrackName,
                    threads: globalOptions.effectiveThreads,
                    minimumAlleleFrequency: minimumAlleleFrequency,
                    minimumDepth: minimumDepth,
                    ivarPrimerTrimConfirmed: ivarPrimerTrimConfirmed,
                    medakaModel: medakaModel
                )
                emitSimpleEvent(event: "preflightComplete", progress: 0.08, message: "Preflight checks passed", caller: resolvedCaller.rawValue, emit: emitEvent)

                let stagingRoot = try ProjectTempDirectory.create(
                    prefix: "variants-",
                    contextURL: bundleURL,
                    policy: .systemOnly
                )
                defer { try? FileManager.default.removeItem(at: stagingRoot) }
                let emitterBox = VariantCallingEventEmitter(emitEvent)

                let context = VariantsCommand.CallContext(
                    stagingRoot: stagingRoot,
                    emitStageProgress: { progress, message in
                        emitterBox.emit(
                            VariantsCommand.VariantCallingEvent(
                                event: "stageProgress",
                                progress: progress,
                                message: message,
                                bundlePath: bundleURL.path,
                                variantTrackID: nil,
                                variantTrackName: nil,
                                caller: resolvedCaller.rawValue,
                                vcfPath: nil,
                                tbiPath: nil,
                                databasePath: nil,
                                importedVariantCount: nil
                            )
                        )
                    },
                    shouldCancel: { Task.isCancelled }
                )

                emitSimpleEvent(event: "stageStart", progress: 0.10, message: "Running caller workflow", caller: resolvedCaller.rawValue, emit: emitEvent)
                let pipelineResult = try await runtime.runPipeline(request, preflight, context)
                emitSimpleEvent(event: "stageComplete", progress: 0.70, message: "Caller workflow completed", caller: resolvedCaller.rawValue, emit: emitEvent)

                emitSimpleEvent(event: "importStart", progress: 0.74, message: "Importing normalized variants into SQLite", caller: resolvedCaller.rawValue, emit: emitEvent)
                let importRequest = VariantSQLiteImportRequest(
                    normalizedVCFURL: pipelineResult.normalizedVCFURL,
                    outputDatabaseURL: stagingRoot.appendingPathComponent("variants.sqlite.db"),
                    sourceFile: pipelineResult.stagedVCFGZURL.lastPathComponent,
                    importProfile: .ultraLowMemory,
                    importSemantics: .viralFrequency,
                    materializeVariantInfo: true
                )
                let importResult = try await runtime.importSQLite(importRequest, context)
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "importComplete",
                        progress: 0.88,
                        message: "Imported \(importResult.variantCount) variants into SQLite",
                        bundlePath: bundleURL.path,
                        variantTrackID: nil,
                        variantTrackName: finalTrackName,
                        caller: resolvedCaller.rawValue,
                        vcfPath: pipelineResult.stagedVCFGZURL.path,
                        tbiPath: pipelineResult.stagedTabixURL.path,
                        databasePath: nil,
                        importedVariantCount: importResult.variantCount
                    )
                )

                emitSimpleEvent(event: "attachStart", progress: 0.90, message: "Attaching variant track to bundle", caller: resolvedCaller.rawValue, emit: emitEvent)
                let attachmentRequest = BundleVariantTrackAttachmentRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: alignmentTrackID,
                    caller: resolvedCaller,
                    outputTrackID: Self.makeTrackID(),
                    outputTrackName: finalTrackName,
                    stagedVCFGZURL: pipelineResult.stagedVCFGZURL,
                    stagedTabixURL: pipelineResult.stagedTabixURL,
                    stagedDatabaseURL: importResult.databaseURL,
                    variantCount: importResult.variantCount,
                    variantCallerVersion: pipelineResult.callerVersion,
                    variantCallerParametersJSON: pipelineResult.callerParametersJSON,
                    referenceStagedFASTASHA256: pipelineResult.referenceFASTASHA256
                )
                let attachmentResult = try await runtime.attachTrack(attachmentRequest)
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "attachComplete",
                        progress: 0.97,
                        message: "Attached variant track \(attachmentResult.trackInfo.name)",
                        bundlePath: bundleURL.path,
                        variantTrackID: attachmentResult.trackInfo.id,
                        variantTrackName: attachmentResult.trackInfo.name,
                        caller: resolvedCaller.rawValue,
                        vcfPath: attachmentResult.finalVCFGZURL.path,
                        tbiPath: attachmentResult.finalTabixURL.path,
                        databasePath: attachmentResult.finalDatabaseURL.path,
                        importedVariantCount: attachmentResult.trackInfo.variantCount
                    )
                )
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "runComplete",
                        progress: 1.0,
                        message: "Variant calling complete",
                        bundlePath: bundleURL.path,
                        variantTrackID: attachmentResult.trackInfo.id,
                        variantTrackName: attachmentResult.trackInfo.name,
                        caller: resolvedCaller.rawValue,
                        vcfPath: attachmentResult.finalVCFGZURL.path,
                        tbiPath: attachmentResult.finalTabixURL.path,
                        databasePath: attachmentResult.finalDatabaseURL.path,
                        importedVariantCount: attachmentResult.trackInfo.variantCount
                    )
                )
                return attachmentResult
            } catch {
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "runFailed",
                        progress: nil,
                        message: error.localizedDescription,
                        bundlePath: bundleURL.path,
                        variantTrackID: nil,
                        variantTrackName: nil,
                        caller: resolvedCaller.rawValue,
                        vcfPath: nil,
                        tbiPath: nil,
                        databasePath: nil,
                        importedVariantCount: nil
                    )
                )
                throw error
            }
        }

        private static func makeTrackID() -> String {
            "vc-\(UUID().uuidString.lowercased())"
        }

        private func parseCaller() throws -> ViralVariantCaller {
            guard let value = ViralVariantCaller(rawValue: caller.lowercased()) else {
                throw ValidationError("Unknown caller: \(caller)")
            }
            return value
        }

        private func normalizedOutputTrackName(fallback: String) -> String {
            let trimmed = outputTrackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? fallback : trimmed
        }

        private func emitSimpleEvent(
            event: String,
            progress: Double?,
            message: String,
            caller: String,
            emit: (VariantsCommand.VariantCallingEvent) -> Void
        ) {
            emit(
                VariantsCommand.VariantCallingEvent(
                    event: event,
                    progress: progress,
                    message: message,
                    bundlePath: bundlePath,
                    variantTrackID: nil,
                    variantTrackName: nil,
                    caller: caller,
                    vcfPath: nil,
                    tbiPath: nil,
                    databasePath: nil,
                    importedVariantCount: nil
                )
            )
        }

        private func encode(event: VariantsCommand.VariantCallingEvent) -> String? {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(event) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }
}

private final class VariantCallingEventEmitter: @unchecked Sendable {
    let emit: (VariantsCommand.VariantCallingEvent) -> Void

    init(_ emit: @escaping (VariantsCommand.VariantCallingEvent) -> Void) {
        self.emit = emit
    }
}
