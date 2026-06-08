import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqUpdateCurrentWorkbookSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-current-workbook",
        abstract: "Apply genotype haplotype review edits to a .lungfishgenotype current.xlsx workbook",
        discussion: """
            Updates artifacts/workbooks/current.xlsx inside a .lungfishgenotype bundle
            from a displayed/effective haplotype-call JSON snapshot and the bundle's
            annotations.json audit sidecar.
            """
    )

    @Argument(help: "Input .lungfishgenotype bundle")
    var bundle: String

    @Option(name: .customLong("calls-json"), help: "JSON array of displayed/effective haplotype calls")
    var callsJSON: String

    @Option(name: .customLong("annotations"), help: "Annotation sidecar to write Overrides and Audit Log worksheets; defaults to bundle annotations.json when present")
    var annotations: String?

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
        guard ONTGenotypeResultBundle.isBundleURL(bundleURL) else {
            throw ValidationError("Expected a .lungfishgenotype bundle: \(bundle)")
        }
        let callsURL = URL(fileURLWithPath: callsJSON).standardizedFileURL
        guard FileManager.default.fileExists(atPath: callsURL.path) else {
            throw ValidationError("--calls-json does not exist: \(callsURL.path)")
        }
        let annotationURL = resolvedAnnotationURL(bundleURL: bundleURL)
        if let annotationURL, !FileManager.default.fileExists(atPath: annotationURL.path) {
            throw ValidationError("--annotations does not exist: \(annotationURL.path)")
        }

        FileHandle.standardError.write(Data("[ 10%] Resolving managed openpyxl runtime.\n".utf8))
        let pythonURL = try await CondaManager.shared.toolPath(name: "python", environment: "openpyxl")
        FileHandle.standardError.write(Data("[ 35%] Loading displayed haplotype call snapshot.\n".utf8))
        let calls = try JSONDecoder().decode(
            [GenotypeWorkbookHaplotypeCall].self,
            from: Data(contentsOf: callsURL)
        )
        let arguments = cliArguments(
            bundleURL: bundleURL,
            callsURL: callsURL,
            annotationURL: annotationURL
        )
        FileHandle.standardError.write(Data("[ 55%] Applying haplotype edits to current.xlsx.\n".utf8))
        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: pythonURL)
            .applyHaplotypeOverrides(
                calls,
                annotationSidecarURL: annotationURL,
                into: bundleURL,
                provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                    toolName: "lungfish-cli fastq update-current-workbook",
                    toolKind: "cli",
                    argv: ["lungfish-cli", "fastq"] + arguments
                )
            )
        FileHandle.standardError.write(Data("[100%] Updated current.xlsx\n".utf8))

        let payload = FastqUpdateCurrentWorkbookPayload(
            bundlePath: bundleURL.path,
            currentWorkbookPath: try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL).path,
            manifestPath: ONTGenotypeResultBundle.manifestURL(in: bundleURL).path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(payload))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func resolvedAnnotationURL(bundleURL: URL) -> URL? {
        if let annotations {
            return URL(fileURLWithPath: annotations).standardizedFileURL
        }
        let defaultURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        return FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    private func cliArguments(bundleURL: URL, callsURL: URL, annotationURL: URL?) -> [String] {
        var arguments = [
            "update-current-workbook",
            bundleURL.path,
            "--calls-json",
            callsURL.path,
        ]
        if let annotationURL {
            arguments += ["--annotations", annotationURL.path]
        }
        return arguments
    }
}

private struct FastqUpdateCurrentWorkbookPayload: Encodable {
    let bundlePath: String
    let currentWorkbookPath: String
    let manifestPath: String
}
