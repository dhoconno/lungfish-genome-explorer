import Foundation
import LungfishCore
import LungfishWorkflow
import LungfishKit

/// Runs `lungfish-cli align mafft` through `CLISubprocessTransport`, decoding
/// the shared `CLIEvent` schema instead of the private `msaAlignment*` JSON
/// shape this runner used to hand-parse (ARC-02, SIMP-04). The only fields a
/// caller reads from a successful run are the bundle URL, row count and
/// aligned length, none of which fit `CLIEvent.complete`'s plain
/// `outputs`/`message` shape, so `AlignCommand` encodes them into the
/// completion message as `"rows=<n> alignedLength=<n>"` and this runner
/// parses them back out.
struct CLIMSAAlignmentRunner {
    enum RunError: Error, LocalizedError, Equatable {
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case let .underlying(message): return message
            }
        }
    }

    struct Result: Sendable, Equatable {
        let bundleURL: URL
        let rowCount: Int
        let alignedLength: Int
    }

    private let transport: CLISubprocessTransport

    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    static func buildArguments(
        inputURLs: [URL],
        projectURL: URL,
        outputURL: URL?,
        name: String?,
        strategy: String,
        outputOrder: String,
        threads: Int?,
        sequenceType: String = "auto",
        adjustDirection: String = "off",
        symbols: String = "strict",
        allowNondeterministicThreads: Bool = false,
        allowFASTQAssemblyInputs: Bool = false,
        extraArguments: [String],
        includedSequenceNames: [String]? = nil
    ) -> [String] {
        var args = ["align", "mafft"] + inputURLs.map(\.path)
        args += ["--project", projectURL.path]
        if let outputURL {
            args += ["--output", outputURL.path]
        }
        if let name {
            args += ["--name", name]
        }
        args += ["--strategy", strategy]
        args += ["--output-order", outputOrder]
        if sequenceType != "auto" {
            args += ["--sequence-type", sequenceType]
        }
        if adjustDirection != "off" {
            args += ["--adjust-direction", adjustDirection]
        }
        if symbols != "strict" {
            args += ["--symbols", symbols]
        }
        if allowNondeterministicThreads {
            args += ["--allow-nondeterministic-threads"]
        }
        if allowFASTQAssemblyInputs {
            args += ["--allow-fastq-assembly-inputs"]
        }
        if let threads {
            args += ["--threads", "\(threads)"]
        }
        if !extraArguments.isEmpty {
            args += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
        }
        for name in includedSequenceNames ?? [] {
            args += ["--sequence", name]
        }
        args += ["--format", "json"]
        return args
    }

    func run(arguments: [String], operationID: UUID) async throws -> Result {
        do {
            let result = try await transport.run(
                arguments: arguments,
                isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
            )
            guard let bundlePath = result.outputs.first,
                  !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunError.underlying("lungfish-cli finished without reporting an alignment bundle.")
            }
            let (rowCount, alignedLength) = Self.parseCounts(from: result.message)
            return Result(
                bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
                rowCount: rowCount,
                alignedLength: alignedLength
            )
        } catch let error as CLISubprocessTransport.RunError {
            throw RunError.underlying(error.errorDescription ?? "MAFFT alignment failed")
        }
    }

    func cancel() {
        transport.cancel()
    }

    private static func parseCounts(from message: String?) -> (rowCount: Int, alignedLength: Int) {
        guard let message else { return (0, 0) }
        var rowCount = 0
        var alignedLength = 0
        for token in message.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            switch parts[0] {
            case "rows": rowCount = value
            case "alignedLength": alignedLength = value
            default: break
            }
        }
        return (rowCount, alignedLength)
    }
}
