import Foundation
import LungfishWorkflow

/// Lossless conversion into the existing imported-package controls only.
enum WorkflowRunAgainPresentation {
    static func parameters(
        package: WorkflowPackageManifest, referenceURL: URL, readURL: URL, outputDirectory: URL
    ) -> [String: String] {
        var values: [String: String] = [:]
        for input in package.inputs {
            if input.bundleTypes.contains(.lungfishref) {
                values[input.id] = referenceURL.path
                values["reference_bundle"] = referenceURL.path
            }
            if input.bundleTypes.contains(.lungfishfastq) {
                values[input.id] = readURL.path
                values["reads_bundle"] = readURL.path
            }
        }
        values["outdir"] = outputDirectory.path
        return values
    }

    static func render(_ template: String, outputName: String) -> String {
        template.replacingOccurrences(of: "{{outputName}}", with: outputName)
            .replacingOccurrences(of: "{outputName}", with: outputName)
    }

    static func outputName(for configuration: LocalWorkflowReplayConfiguration) throws -> String {
        let request = configuration.request
        let package = configuration.identity.packageManifest
        let validation = WorkflowPackageValidationResult(packageURL: configuration.identity.packageURL,
            manifestURL: configuration.identity.packageURL.appendingPathComponent("manifest.json"), manifest: package)
        guard validation.supportsWorkflowLibraryExecution, !request.resume, request.workDirectory == nil,
              request.memory == nil, let cpus = request.cpus, cpus > 0,
              request.inputURLs.count == 2,
              request.inputURLs[0].pathExtension.lowercased() == "lungfishref",
              request.inputURLs[1].pathExtension.lowercased() == "lungfishfastq",
              (package.runner.kind == .nextflow && request.engine == .nextflow
                || package.runner.kind == .snakemake && request.engine == .snakemake),
              request.params == parameters(package: package, referenceURL: request.inputURLs[0],
                  readURL: request.inputURLs[1], outputDirectory: request.outputDirectory),
              request.expectedOutputURLs.count == package.outputs.count else {
            throw unsupportedSettings()
        }
        var outputName: String?
        for (definition, output) in zip(package.outputs, request.expectedOutputURLs) {
            let prefix = request.outputDirectory.pathComponents
            let path = output.standardizedFileURL.pathComponents
            guard path.count > prefix.count, path.starts(with: prefix) else { throw unsupportedSettings() }
            let relativePath = path.dropFirst(prefix.count).joined(separator: "/")
            let pattern = "^" + NSRegularExpression.escapedPattern(for: definition.pathTemplate.replacingOccurrences(of: "{{outputName}}", with: "{outputName}"))
                .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{outputName}"), with: "(.+?)") + "$"
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: relativePath, range: NSRange(relativePath.startIndex..., in: relativePath)) else {
                throw unsupportedSettings()
            }
            for index in 1..<match.numberOfRanges {
                let candidate = (relativePath as NSString).substring(with: match.range(at: index))
                if let outputName, outputName != candidate { throw unsupportedSettings() }
                outputName = candidate
            }
        }
        // A name unused by every declared output has no effect on the typed request.
        let name = outputName ?? request.workflowName
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              zip(package.outputs, request.expectedOutputURLs).allSatisfy({ pair in
                  request.outputDirectory.appendingPathComponent(render(pair.0.pathTemplate, outputName: name))
                      .standardizedFileURL.pathComponents == pair.1.standardizedFileURL.pathComponents
              }) else { throw unsupportedSettings() }
        return name
    }

    static func freshOutput(in parent: URL, originalName: String) -> URL {
        parent.appendingPathComponent("\(originalName)-again-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .standardizedFileURL
    }

    private static func unsupportedSettings() -> LocalWorkflowReplayError {
        .unavailable("The retained settings cannot be represented by this configuration window. Start a new configuration; no stored options were reset or executed.")
    }
}
