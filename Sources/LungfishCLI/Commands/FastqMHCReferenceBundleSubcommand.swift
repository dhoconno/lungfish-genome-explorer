import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct FastqMHCReferenceBundleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mhc-reference-bundle",
        abstract: "Create a .lungfishmhcref bundle for MHC amplicon genotyping"
    )

    @Option(name: .customLong("reference-fasta"), help: "MHC amplicon reference FASTA")
    var referenceFASTA: String

    @Option(name: .customLong("haplotype-definition"), help: "Haplotype definition JSON file to embed in the bundle")
    var haplotypeDefinitions: [String] = []

    @Option(name: .customLong("default-haplotype-definition"), help: "Default embedded haplotype definition set ID")
    var defaultHaplotypeDefinition: String?

    @Option(name: .customLong("output"), help: "Output .lungfishmhcref bundle")
    var output: String

    @Option(name: .customLong("name"), help: "Display name stored in the bundle manifest")
    var name: String?

    @Option(name: .customLong("source-file"), help: "Additional source file to copy into the bundle")
    var sourceFiles: [String] = []

    @Option(name: .customLong("source-directory"), help: "Additional source directory to copy into the bundle")
    var sourceDirectories: [String] = []

    @Flag(name: .customLong("force"), help: "Replace an existing .lungfishmhcref bundle")
    var force: Bool = false

    func run() async throws {
        let result = try await MHCAmpliconReferenceBundleBuilder().build(
            configurationForTesting(),
            progressHandler: { fraction, message in
                FileHandle.standardError.write(Data(Self.progressLine(fraction: fraction, message: message).utf8))
            }
        )
        FileHandle.standardError.write(Data("MHC reference bundle written to \(result.bundleURL.path)\n".utf8))
    }

    func configurationForTesting() -> MHCAmpliconReferenceBundleBuildConfiguration {
        MHCAmpliconReferenceBundleBuildConfiguration(
            referenceFASTA: URL(fileURLWithPath: referenceFASTA),
            haplotypeDefinitionURLs: haplotypeDefinitions.map { URL(fileURLWithPath: $0) },
            outputURL: URL(fileURLWithPath: output),
            name: name,
            defaultHaplotypeDefinitionID: defaultHaplotypeDefinition,
            sourceFiles: sourceFiles.map { URL(fileURLWithPath: $0) },
            sourceDirectories: sourceDirectories.map { URL(fileURLWithPath: $0) },
            forceOverwrite: force,
            argv: replayArgv()
        )
    }

    private func replayArgv() -> [String] {
        var argv = [
            CLICommandIdentity.executableName, "fastq", "mhc-reference-bundle",
            "--reference-fasta", referenceFASTA,
            "--output", output,
        ]
        for haplotypeDefinition in haplotypeDefinitions {
            argv += ["--haplotype-definition", haplotypeDefinition]
        }
        if let defaultHaplotypeDefinition {
            argv += ["--default-haplotype-definition", defaultHaplotypeDefinition]
        }
        if let name {
            argv += ["--name", name]
        }
        for sourceFile in sourceFiles {
            argv += ["--source-file", sourceFile]
        }
        for sourceDirectory in sourceDirectories {
            argv += ["--source-directory", sourceDirectory]
        }
        if force {
            argv.append("--force")
        }
        return argv
    }

    static func progressLine(fraction: Double, message: String) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        return String(format: "[%3d%%] %@\n", percent, message)
    }
}
