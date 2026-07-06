import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct FastqTwelveSReferenceMetadataSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "12s-reference-metadata",
        abstract: "Prepare structured taxonomy metadata for a deduplicated 12S reference FASTA"
    )

    @Option(name: .customLong("dedup-fasta"), help: "Deduplicated 12S amplicon reference FASTA")
    var deduplicatedFASTA: String

    @Option(name: .customLong("midori-metadata"), help: "MIDORI-derived metadata TSV with seq_id, latin_name, group, taxid, and taxonomy")
    var midoriMetadataTSV: String

    @Option(name: .customLong("output"), help: "Output 12S target metadata TSV")
    var output: String

    @Flag(name: .customLong("force"), help: "Replace an existing metadata TSV")
    var force: Bool = false

    func run() async throws {
        let result = try await TwelveSReferenceMetadataBuilder().build(configurationForTesting())
        FileHandle.standardError.write(Data("12S target metadata written to \(result.metadataURL.path)\n".utf8))
    }

    func configurationForTesting() -> TwelveSReferenceMetadataBuildConfiguration {
        TwelveSReferenceMetadataBuildConfiguration(
            deduplicatedFASTA: URL(fileURLWithPath: deduplicatedFASTA),
            midoriMetadataTSV: URL(fileURLWithPath: midoriMetadataTSV),
            outputURL: URL(fileURLWithPath: output),
            forceOverwrite: force,
            argv: replayArgv()
        )
    }

    private func replayArgv() -> [String] {
        var argv = [
            CLICommandIdentity.executableName, "fastq", "12s-reference-metadata",
            "--dedup-fasta", deduplicatedFASTA,
            "--midori-metadata", midoriMetadataTSV,
            "--output", output,
        ]
        if force {
            argv.append("--force")
        }
        return argv
    }
}
