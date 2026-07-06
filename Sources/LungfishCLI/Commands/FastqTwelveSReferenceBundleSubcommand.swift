import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct FastqTwelveSReferenceBundleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "12s-reference-bundle",
        abstract: "Create a .lungfish12sref bundle for 12S amplicon matching"
    )

    @Option(name: .customLong("dedup-fasta"), help: "Deduplicated 12S amplicon reference FASTA")
    var deduplicatedFASTA: String

    @Option(name: .customLong("midori-metadata"), help: "MIDORI-derived metadata TSV with seq_id, latin_name, group, taxid, and taxonomy")
    var midoriMetadataTSV: String

    @Option(name: .customLong("output"), help: "Output .lungfish12sref bundle")
    var output: String

    @Option(name: .customLong("name"), help: "Display name stored in the bundle manifest")
    var name: String?

    @Option(name: .customLong("source-file"), help: "Additional source file to copy into the bundle")
    var sourceFiles: [String] = []

    @Option(name: .customLong("source-directory"), help: "Additional source directory to copy into the bundle")
    var sourceDirectories: [String] = []

    @Flag(name: .customLong("force"), help: "Replace an existing .lungfish12sref bundle")
    var force: Bool = false

    func run() async throws {
        let result = try await TwelveSReferenceBundleBuilder().build(
            configurationForTesting(),
            progressHandler: { fraction, message in
                FileHandle.standardError.write(Data(Self.progressLine(fraction: fraction, message: message).utf8))
            }
        )
        FileHandle.standardError.write(Data("12S reference bundle written to \(result.bundleURL.path)\n".utf8))
    }

    func configurationForTesting() -> TwelveSReferenceBundleBuildConfiguration {
        TwelveSReferenceBundleBuildConfiguration(
            deduplicatedFASTA: URL(fileURLWithPath: deduplicatedFASTA),
            midoriMetadataTSV: URL(fileURLWithPath: midoriMetadataTSV),
            outputURL: URL(fileURLWithPath: output),
            name: name,
            sourceFiles: sourceFiles.map { URL(fileURLWithPath: $0) },
            sourceDirectories: sourceDirectories.map { URL(fileURLWithPath: $0) },
            forceOverwrite: force,
            argv: replayArgv()
        )
    }

    private func replayArgv() -> [String] {
        var argv = [
            CLICommandIdentity.executableName, "fastq", "12s-reference-bundle",
            "--dedup-fasta", deduplicatedFASTA,
            "--midori-metadata", midoriMetadataTSV,
            "--output", output,
        ]
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
