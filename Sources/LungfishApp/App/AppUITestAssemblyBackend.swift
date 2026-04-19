import Foundation
import LungfishIO
import LungfishWorkflow

enum AppUITestAssemblyBackend {
    static func writeResult(for request: AssemblyRunRequest) throws {
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )

        let contigsURL = request.outputDirectory.appendingPathComponent("contigs.fasta")
        try synthesizedContigs(for: request).write(to: contigsURL, atomically: true, encoding: .utf8)

        let result = AssemblyResult(
            tool: request.tool,
            readType: request.readType,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "ui-test",
            commandLine: "ui-test \(request.tool.rawValue)",
            outputDirectory: request.outputDirectory,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 0.5
        )
        try result.save(to: request.outputDirectory)
    }

    private static func synthesizedContigs(for request: AssemblyRunRequest) -> String {
        let sequences: [String]
        switch request.readType {
        case .illuminaShortReads:
            sequences = [
                String(repeating: "ACGT", count: 8),
                String(repeating: "TTGC", count: 6),
            ]
        case .ontReads:
            sequences = [
                String(repeating: "GATTACA", count: 6),
                String(repeating: "CCGGTTAA", count: 4),
            ]
        case .pacBioHiFi:
            sequences = [
                String(repeating: "AACCGGTT", count: 5),
                String(repeating: "TTAACCGG", count: 4),
            ]
        }

        return sequences.enumerated().map { index, sequence in
            ">\(request.tool.rawValue)_contig_\(index + 1)\n\(sequence)"
        }.joined(separator: "\n") + "\n"
    }
}

extension AssemblyRunRequest {
    func replacingOutputDirectory(with outputDirectory: URL) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: threads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments
        )
    }
}
