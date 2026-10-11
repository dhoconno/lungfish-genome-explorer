import ArgumentParser
import Foundation
import LungfishWorkflow

extension ImportCommand {
    struct GeneiousSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "geneious",
            abstract: "Import a Geneious export into native Lungfish project collections"
        )

        @Argument(help: "Path to a .geneious archive, Geneious export folder, or exported file")
        var sourcePath: String

        @Option(name: .customLong("project"), help: "Lungfish project directory to import into")
        var projectPath: String

        @Option(name: .customLong("collection-name"), help: "Optional collection base name")
        var collectionName: String?

        @Flag(name: .customLong("preserve-raw-source"), help: "Copy the original export into the collection")
        var preserveRawSource = false

        @Flag(name: .customLong("no-preserve-raw-source"), help: .hidden)
        var noPreserveRawSource = false

        @Flag(name: .customLong("no-import-references"), help: "Preserve standalone references instead of converting them to .lungfishref bundles")
        var noImportReferences = false

        @Flag(name: .customLong("preserve-unsupported"), help: "Copy unsupported artifacts into Binary Artifacts")
        var preserveUnsupported = false

        @Flag(name: .customLong("no-preserve-unsupported"), help: .hidden)
        var noPreserveUnsupported = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let projectURL = URL(fileURLWithPath: projectPath)
            let eventsOn = globalOptions.outputFormat == .json
            let emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
            emitter.emitStart(kind: "geneious-export")

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                emitter.emitFailed("Input file not found: \(sourceURL.path)")
                throw CLIExitCode.inputError.exitCode
            }

            let options = GeneiousImportOptions(
                collectionName: collectionName,
                preserveRawSource: preserveRawSource && !noPreserveRawSource,
                importStandaloneReferences: !noImportReferences,
                preserveUnsupportedArtifacts: preserveUnsupported && !noPreserveUnsupported
            )

            do {
                let service = GeneiousImportCollectionService(
                    referenceImporter: Self.importReferenceViaSharedService
                )
                let result = try await service.importGeneiousExport(
                    sourceURL: sourceURL,
                    projectURL: projectURL,
                    options: options
                ) { progress, message in
                    emitter.emitProgress(progress, message: message)
                }

                for warning in result.warnings {
                    emitter.emitWarning(warning)
                }
                emitter.emitComplete(collection: result.collectionURL, provenanceURL: result.provenanceURL)
                if !globalOptions.quiet {
                    printHumanLine("Imported \(result.collectionURL.path)", eventsOn: eventsOn)
                }
            } catch {
                emitter.emitFailed(error.localizedDescription)
                throw CLIExitCode.workflowError.exitCode
            }
        }

        private static func importReferenceViaSharedService(
            sourceURL: URL,
            outputDirectory: URL,
            preferredName: String
        ) async throws -> ReferenceBundleImportResult {
            try await ReferenceBundleImportService.shared.importAsReferenceBundle(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                preferredBundleName: preferredName
            )
        }
    }

    struct ApplicationExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "application-export",
            abstract: "Import an external application export into native Lungfish project collections",
            discussion: "Kinds: \(ApplicationExportKind.allCases.map(\.cliArgument).joined(separator: ", "))"
        )

        @Argument(help: "Application export kind")
        var kind: String

        @Argument(help: "Path to an application export archive, folder, or file")
        var sourcePath: String

        @Option(name: .customLong("project"), help: "Lungfish project directory to import into")
        var projectPath: String

        @Option(name: .customLong("collection-name"), help: "Optional collection base name")
        var collectionName: String?

        @Flag(name: .customLong("no-preserve-raw-source"), help: "Do not copy the original export into the collection")
        var noPreserveRawSource = false

        @Flag(name: .customLong("no-import-references"), help: "Preserve standalone references instead of converting them to .lungfishref bundles")
        var noImportReferences = false

        @Flag(name: .customLong("no-preserve-unsupported"), help: "Skip unsupported artifacts instead of preserving them as binary files")
        var noPreserveUnsupported = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            guard let applicationKind = ApplicationExportKind(cliArgument: kind) else {
                throw ValidationError("Unknown application export kind '\(kind)'. Expected one of: \(ApplicationExportKind.allCases.map(\.cliArgument).joined(separator: ", "))")
            }

            let sourceURL = URL(fileURLWithPath: sourcePath)
            let projectURL = URL(fileURLWithPath: projectPath)
            let eventsOn = globalOptions.outputFormat == .json
            let emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
            emitter.emitStart(kind: applicationKind.cliArgument)

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                emitter.emitFailed("Input file not found: \(sourceURL.path)")
                throw CLIExitCode.inputError.exitCode
            }

            let options = ApplicationExportImportOptions(
                collectionName: collectionName,
                preserveRawSource: !noPreserveRawSource,
                importStandaloneReferences: !noImportReferences,
                preserveUnsupportedArtifacts: !noPreserveUnsupported
            )

            do {
                let service = ApplicationExportImportCollectionService(
                    referenceImporter: Self.importReferenceViaSharedService
                )
                let result = try await service.importApplicationExport(
                    sourceURL: sourceURL,
                    projectURL: projectURL,
                    kind: applicationKind,
                    options: options
                ) { progress, message in
                    emitter.emitProgress(progress, message: message)
                }

                for warning in result.warnings {
                    emitter.emitWarning(warning)
                }
                emitter.emitComplete(collection: result.collectionURL, provenanceURL: result.provenanceURL)
                if !globalOptions.quiet {
                    printHumanLine("Imported \(result.collectionURL.path)", eventsOn: eventsOn)
                }
            } catch {
                emitter.emitFailed(error.localizedDescription)
                throw CLIExitCode.workflowError.exitCode
            }
        }

        private static func importReferenceViaSharedService(
            sourceURL: URL,
            outputDirectory: URL,
            preferredName: String
        ) async throws -> ReferenceBundleImportResult {
            try await ReferenceBundleImportService.shared.importAsReferenceBundle(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                preferredBundleName: preferredName
            )
        }
    }
}

private extension ApplicationExportKind {
    init?(cliArgument: String) {
        if let value = Self(rawValue: cliArgument) ?? Self.allCases.first(where: { $0.cliArgument == cliArgument }) {
            self = value
        } else {
            return nil
        }
    }
}
