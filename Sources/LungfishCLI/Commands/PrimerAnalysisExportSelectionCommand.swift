import ArgumentParser
import Foundation
import LungfishWorkflow

/// `lungfish-cli primers analysis export-selection`, the command behind "Save Primer FASTA Bundle" and
/// "Extract Reference Amplicon" in the saved primer analysis view (Phase 2.12 lane 12.15, A67-M3).
///
/// It calls the `PrimerAnalysisSelectionExportService` the app calls, so the command and the app write the
/// same `.lungfishref` folder for the same selection. The service resolves the selection again from the
/// saved analysis and verifies every stored file, and it publishes by an exclusive rename, so an existing
/// `--output` is never replaced.
struct PrimerAnalysisExportSelectionCommand: AsyncParsableCommand {
    enum Kind: String, ExpressibleByArgument, CaseIterable {
        case primerFASTA = "primer-fasta"
        case referenceAmplicon = "reference-amplicon"

        var exportKind: PrimerAnalysisExportKind {
            switch self {
            case .primerFASTA: .primerFASTA
            case .referenceAmplicon: .referenceAmplicon
            }
        }

        var outputTitle: String {
            switch self {
            case .primerFASTA: "Primer FASTA bundle"
            case .referenceAmplicon: "Reference amplicon"
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "export-selection",
        abstract: "Export a primer FASTA bundle or a reference amplicon for one saved selection",
        discussion: """
            Writes the same new .lungfishref bundle that the saved primer analysis view writes for \
            Save Primer FASTA Bundle and Extract Reference Amplicon, with its provenance and a copy \
            of the evidence it came from. Name exactly one selection, which is one primer (--target-id and \
            --primer-id), one amplicon (--target-id and --amplicon-id), one numbered pool \
            (--source-result-id and --pool) or one native pool (--source-result-id and --native-pool). \
            --kind primer-fasta saves the selected primers as primers.fasta, in the 5' to 3' \
            orientation they were stored in, and for an amplicon it saves the primers of that amplicon. \
            --kind reference-amplicon extracts the saved reference span of one amplicon, with its \
            primer sites as an annotation track, so it needs an amplicon. \
            The IDs are the ones the saved analysis stores, and Copy CLI Command on an export made in \
            the app records them. The saved analysis is never changed, and an existing --output is \
            never replaced.
            """
    )

    @Argument(help: "Path to the saved .lungfishprimeranalysis bundle.") var bundlePath: String
    @Option(help: "What to write. The value primer-fasta saves the selected primers and reference-amplicon extracts one amplicon's reference span.")
    var kind: Kind
    @Option(name: .customLong("target-id"), help: "Target ID of the primer or amplicon, with --primer-id or --amplicon-id.")
    var targetID: String?
    @Option(name: .customLong("primer-id"), help: "Primer ID, with --target-id.")
    var primerID: String?
    @Option(name: .customLong("amplicon-id"), help: "Amplicon ID, with --target-id.")
    var ampliconID: String?
    @Option(name: .customLong("source-result-id"), help: "ID of the saved result a pool belongs to, with --pool or --native-pool.")
    var sourceResultID: String?
    @Option(help: "Numbered pool to export, 1 or higher, with --source-result-id.")
    var pool: Int?
    @Option(name: .customLong("native-pool"), help: "Pool name exactly as the design tool saved it, with --source-result-id.")
    var nativePool: String?
    @Option(name: .customLong("output"), help: "New .lungfishref bundle to write. It must not exist, and its parent folder must.")
    var outputPath: String

    /// The selection the options name. Exactly one of the four forms must be present.
    func selection() throws -> PrimerAnalysisExportSelection {
        switch (targetID, primerID, ampliconID, sourceResultID, pool, nativePool) {
        case (let target?, let primer?, nil, nil, nil, nil):
            return .primer(targetID: target, primerID: primer)
        case (let target?, nil, let amplicon?, nil, nil, nil):
            return .amplicon(targetID: target, ampliconID: amplicon)
        case (nil, nil, nil, let result?, let number?, nil):
            return .pool(sourceResultID: result, pool: number)
        case (nil, nil, nil, let result?, nil, let name?):
            return .nativePool(sourceResultID: result, pool: name)
        default:
            throw ValidationError("""
                Name exactly one selection, which is --target-id with --primer-id (one primer), --target-id with \
                --amplicon-id (one amplicon), --source-result-id with --pool (a numbered pool) or \
                --source-result-id with --native-pool (a native pool).
                """)
        }
    }

    func validate() throws {
        let selection = try selection()
        if let pool, pool < 1 {
            throw ValidationError("--pool must be 1 or higher. Use --native-pool for a pool the design tool named.")
        }
        if let nativePool, nativePool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--native-pool must not be empty.")
        }
        if kind == .referenceAmplicon {
            guard case .amplicon = selection else {
                throw ValidationError("--kind reference-amplicon extracts the span of one amplicon, so it needs --target-id and --amplicon-id.")
            }
        }
        guard URL(fileURLWithPath: outputPath).pathExtension == "lungfishref" else {
            throw ValidationError("--output must name a new bundle that ends in .lungfishref.")
        }
    }

    func run() async throws {
        let analysisURL = try PrimerAnalysisExportOrderCommand.realURL(bundlePath, label: "The analysis bundle")
        let destination = try PrimerAnalysisExportOrderCommand.resolvedDestination(outputPath)
        let output = try await PrimerAnalysisSelectionExportService().export(
            analysisURL: analysisURL, selection: try selection(), kind: kind.exportKind,
            destinationURL: destination, invocationArgv: CommandLine.arguments)
        print("\(kind.outputTitle) written to \(output.path)")
    }
}
