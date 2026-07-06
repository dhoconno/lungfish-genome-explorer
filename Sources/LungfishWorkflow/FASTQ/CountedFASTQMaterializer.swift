import Foundation
import LungfishIO

public enum CountedFASTQSequenceNormalization: Sendable, Equatable {
    case none
    case uppercase
}

public struct CountedFASTQCompressionProvenance: Sendable, Equatable {
    public let command: [String]
    public let input: FileRecord
    public let output: FileRecord
    public let exitCode: Int32
    public let wallTime: TimeInterval
    public let stderr: String?

    public init(
        command: [String],
        input: FileRecord,
        output: FileRecord,
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) {
        self.command = command
        self.input = input
        self.output = output
        self.exitCode = exitCode
        self.wallTime = wallTime
        self.stderr = stderr
    }
}

public struct CountedFASTQMaterializationResult: Sendable, Equatable {
    public let outputURL: URL
    public let inputRecordCount: Int
    public let totalReadCount: Int
    public let uniqueSequenceCount: Int
    public let uniqueBaseCount: Int
    public let weightedBaseCount: Int
    public let materializedOutput: FileRecord
    public let compression: CountedFASTQCompressionProvenance?
}

public enum CountedFASTQMaterializerError: LocalizedError, Sendable {
    case noInputs
    case missingInput(URL)
    case compressionFailed(URL, Int32)

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "At least one FASTQ input is required."
        case .missingInput(let url):
            return "FASTQ input does not exist: \(url.path)"
        case .compressionFailed(let url, let status):
            return "Failed to gzip counted FASTQ \(url.path) (exit \(status))."
        }
    }
}

public struct CountedFASTQMaterializer: Sendable {
    public init() {}

    public func materialize(
        inputs: [URL],
        outputURL: URL,
        compress: Bool = false,
        normalization: CountedFASTQSequenceNormalization = .uppercase
    ) async throws -> CountedFASTQMaterializationResult {
        guard !inputs.isEmpty else {
            throw CountedFASTQMaterializerError.noInputs
        }
        for input in inputs where !FileManager.default.fileExists(atPath: input.path) {
            throw CountedFASTQMaterializerError.missingInput(input)
        }

        var counts: [String: Int] = [:]
        var inputRecordCount = 0
        var totalReadCount = 0
        let reader = FASTQReader(validateSequence: false)
        for input in inputs {
            for try await record in reader.records(from: input) {
                inputRecordCount += 1
                let weight = Self.readCountWeight(
                    identifier: record.identifier,
                    description: record.description
                )
                let sequence = Self.normalized(record.sequence, normalization: normalization)
                counts[sequence, default: 0] += weight
                totalReadCount += weight
            }
        }

        return try write(
            counts: counts,
            outputURL: outputURL,
            compress: compress,
            inputRecordCount: inputRecordCount,
            totalReadCount: totalReadCount
        )
    }

    public func write(
        counts: [String: Int],
        outputURL: URL,
        compress: Bool = false,
        inputRecordCount: Int? = nil,
        totalReadCount: Int? = nil
    ) throws -> CountedFASTQMaterializationResult {
        let shouldCompress = compress || outputURL.pathExtension.lowercased() == "gz"
        let rawOutputURL: URL
        if shouldCompress {
            let tempName = ".\(outputURL.lastPathComponent).\(UUID().uuidString).fastq"
            rawOutputURL = outputURL.deletingLastPathComponent().appendingPathComponent(tempName)
        } else {
            rawOutputURL = outputURL
        }

        try FileManager.default.createDirectory(
            at: rawOutputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: rawOutputURL.path) {
            try FileManager.default.removeItem(at: rawOutputURL)
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let ordered = counts
            .filter { $0.value > 0 }
            .map { (sequence: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.sequence.localizedStandardCompare($1.sequence) == .orderedAscending
            }

        var uniqueBaseCount = 0
        var weightedBaseCount = 0
        let writer = FASTQWriter(url: rawOutputURL)
        try writer.open()
        do {
            for (index, item) in ordered.enumerated() {
                uniqueBaseCount += item.sequence.count
                weightedBaseCount += item.sequence.count * item.count
                let record = FASTQRecord(
                    identifier: "u\(String(format: "%06d", index + 1));size=\(item.count)",
                    sequence: item.sequence,
                    qualityString: String(repeating: "I", count: item.sequence.count)
                )
                try writer.write(record)
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }

        let materializedOutput = ProvenanceRecorder.fileRecord(url: rawOutputURL, format: .fastq, role: .output)
        let finalURL: URL
        let compression: CountedFASTQCompressionProvenance?
        if shouldCompress {
            let gzipResult = try Self.gzipCompress(
                rawOutputURL,
                to: outputURL,
                inputRecord: materializedOutput
            )
            finalURL = gzipResult.outputURL
            compression = gzipResult.provenance
        } else {
            finalURL = outputURL
            compression = nil
        }

        return CountedFASTQMaterializationResult(
            outputURL: finalURL.standardizedFileURL,
            inputRecordCount: inputRecordCount ?? ordered.reduce(0) { $0 + $1.count },
            totalReadCount: totalReadCount ?? ordered.reduce(0) { $0 + $1.count },
            uniqueSequenceCount: ordered.count,
            uniqueBaseCount: uniqueBaseCount,
            weightedBaseCount: weightedBaseCount,
            materializedOutput: materializedOutput,
            compression: compression
        )
    }

    public static func readCountWeight(identifier: String, description: String? = nil) -> Int {
        for text in [identifier, description].compactMap({ $0 }) {
            for token in text.split(whereSeparator: { $0.isWhitespace || $0 == ";" }) {
                guard token.hasPrefix("size="),
                      let value = Int(token.dropFirst("size=".count)),
                      value > 0
                else {
                    continue
                }
                return value
            }
        }
        return 1
    }

    public static func normalized(
        _ sequence: String,
        normalization: CountedFASTQSequenceNormalization
    ) -> String {
        switch normalization {
        case .none:
            return sequence
        case .uppercase:
            return sequence.uppercased()
        }
    }

    private struct GzipCompressionResult {
        let outputURL: URL
        let provenance: CountedFASTQCompressionProvenance
    }

    private static func gzipCompress(
        _ rawURL: URL,
        to outputURL: URL,
        inputRecord: FileRecord
    ) throws -> GzipCompressionResult {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        var shouldCloseOutputHandle = true
        defer {
            if shouldCloseOutputHandle {
                try? outputHandle.close()
            }
        }

        let process = Process()
        let stderrPipe = Pipe()
        let command = ["/usr/bin/gzip", "-1", "-c", rawURL.path]
        let startedAt = Date()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-1", "-c", rawURL.path]
        process.standardOutput = outputHandle
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let wallTime = Date().timeIntervalSince(startedAt)
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        try outputHandle.close()
        shouldCloseOutputHandle = false
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw CountedFASTQMaterializerError.compressionFailed(rawURL, process.terminationStatus)
        }
        let outputRecord = ProvenanceRecorder.fileRecord(url: outputURL, format: .fastq, role: .output)
        try? FileManager.default.removeItem(at: rawURL)
        return GzipCompressionResult(
            outputURL: outputURL.standardizedFileURL,
            provenance: CountedFASTQCompressionProvenance(
                command: command,
                input: inputRecord,
                output: outputRecord,
                exitCode: process.terminationStatus,
                wallTime: wallTime,
                stderr: stderr
            )
        )
    }
}
