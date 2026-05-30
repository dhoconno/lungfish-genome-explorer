import Foundation
import LungfishIO

public struct TwelveSChimeraReviewResult: Equatable, Sendable {
    public let statusesBySequenceID: [String: TwelveSChimeraStatus]
    public let stderr: String
    public let exitStatus: Int32
    public let argv: [String]
    public let startedAt: Date?
    public let completedAt: Date?
    public let inputs: [URL]
    public let outputs: [URL]
    public let toolVersion: String?

    public init(
        statusesBySequenceID: [String: TwelveSChimeraStatus],
        stderr: String = "",
        exitStatus: Int32 = 0,
        argv: [String] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        inputs: [URL] = [],
        outputs: [URL] = [],
        toolVersion: String? = nil
    ) {
        self.statusesBySequenceID = statusesBySequenceID
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.argv = argv
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.inputs = inputs
        self.outputs = outputs
        self.toolVersion = toolVersion
    }
}

public protocol TwelveSChimeraReviewing: Sendable {
    func review(
        unresolvedSequences: [TwelveSUnresolvedSequence],
        outputDirectory: URL,
        threads: Int
    ) async throws -> TwelveSChimeraReviewResult
}

public enum TwelveSChimeraReviewError: Error, LocalizedError, Equatable {
    case vsearchFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .vsearchFailed(exitCode, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "vsearch chimera review failed with exit code \(exitCode)."
            }
            return "vsearch chimera review failed with exit code \(exitCode): \(detail)"
        }
    }
}

public struct TwelveSNoOpChimeraReviewer: TwelveSChimeraReviewing {
    public init() {}

    public func review(
        unresolvedSequences: [TwelveSUnresolvedSequence],
        outputDirectory: URL,
        threads: Int
    ) async throws -> TwelveSChimeraReviewResult {
        TwelveSChimeraReviewResult(
            statusesBySequenceID: Dictionary(uniqueKeysWithValues: unresolvedSequences.map {
                ($0.sequenceID, TwelveSChimeraStatus.notReviewed)
            })
        )
    }
}

public struct TwelveSVSearchChimeraReviewer: TwelveSChimeraReviewing {
    private let runVSearch: @Sendable ([String]) async throws -> NativeToolResult

    public init(
        runVSearch: (@Sendable ([String]) async throws -> NativeToolResult)? = nil
    ) {
        if let runVSearch {
            self.runVSearch = runVSearch
        } else {
            self.runVSearch = { arguments in
                try await NativeToolRunner.shared.run(.vsearch, arguments: arguments)
            }
        }
    }

    public func review(
        unresolvedSequences: [TwelveSUnresolvedSequence],
        outputDirectory: URL,
        threads: Int
    ) async throws -> TwelveSChimeraReviewResult {
        guard !unresolvedSequences.isEmpty else {
            return TwelveSChimeraReviewResult(statusesBySequenceID: [:])
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let inputURL = outputDirectory.appendingPathComponent("unresolved-for-vsearch.fasta")
        let uchimeURL = outputDirectory.appendingPathComponent("uchime-denovo.tsv")
        let chimerasURL = outputDirectory.appendingPathComponent("chimeras.fasta")
        let nonChimerasURL = outputDirectory.appendingPathComponent("nonchimeras.fasta")
        try Self.writeVSearchInput(unresolvedSequences, to: inputURL)

        let arguments = [
            "--uchime_denovo", inputURL.path,
            "--uchimeout", uchimeURL.path,
            "--chimeras", chimerasURL.path,
            "--nonchimeras", nonChimerasURL.path,
            "--threads", String(max(1, threads)),
        ]
        let started = Date()
        let result = try await runVSearch(arguments)
        let completed = Date()
        guard result.exitCode == 0 else {
            throw TwelveSChimeraReviewError.vsearchFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        var statuses = Dictionary(uniqueKeysWithValues: unresolvedSequences.map {
            ($0.sequenceID, TwelveSChimeraStatus.notDetected)
        })
        if FileManager.default.fileExists(atPath: uchimeURL.path) {
            for (sequenceID, status) in try parseUCHIMEOutput(at: uchimeURL) {
                statuses[sequenceID] = status
            }
        }
        return TwelveSChimeraReviewResult(
            statusesBySequenceID: statuses,
            stderr: result.stderr,
            exitStatus: result.exitCode,
            argv: result.arguments.isEmpty ? [NativeTool.vsearch.executableName] + arguments : result.arguments,
            startedAt: started,
            completedAt: completed,
            inputs: [inputURL],
            outputs: [uchimeURL, chimerasURL, nonChimerasURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            },
            toolVersion: Self.parseVSearchVersion(from: result.stderr)
        )
    }

    private static func writeVSearchInput(_ sequences: [TwelveSUnresolvedSequence], to url: URL) throws {
        var text = ""
        for unresolved in sequences {
            let size = max(1, unresolved.readCount)
            text += ">\(unresolved.sequenceID);size=\(size);\n"
            text += "\(unresolved.sequence)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func parseUCHIMEOutput(at url: URL) throws -> [String: TwelveSChimeraStatus] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var statuses: [String: TwelveSChimeraStatus] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let sequenceID = fields.first?.split(separator: ";").first.map(String.init) else {
                continue
            }
            let lowercasedFields = fields.map { $0.lowercased() }
            if lowercasedFields.contains("y") || lowercasedFields.contains("chimera") {
                statuses[sequenceID] = .candidate
            } else if lowercasedFields.contains("n") || lowercasedFields.contains("no") {
                statuses[sequenceID] = .notDetected
            }
        }
        return statuses
    }

    private static func parseVSearchVersion(from stderr: String) -> String? {
        for line in stderr.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let range = text.range(of: #"vsearch\s+([^\s,]+)"#, options: .regularExpression) else {
                continue
            }
            return String(text[range]).replacingOccurrences(of: "vsearch", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
