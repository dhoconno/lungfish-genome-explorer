import Foundation

struct FullLengthONTMHCSavontRunPlan: Sendable, Equatable {
    let attempt: Int
    let scratchRootDirectory: URL
    let scratchRawOutputDirectory: URL
    let finalRawOutputDirectory: URL

    var scratchFinalASVFASTAURL: URL {
        scratchRawOutputDirectory.appendingPathComponent("final_asvs.fasta")
    }

    var finalASVFASTAURL: URL {
        finalRawOutputDirectory.appendingPathComponent("final_asvs.fasta")
    }
}

enum FullLengthONTMHCSavontRetryDecision: Sendable, Equatable {
    case none
    case singleThread
    case singleStrand
    case emptyClusters
}

enum FullLengthONTMHCSavontRunSupport {
    static func makePlan(
        sample: String,
        finalRawOutputDirectory: URL,
        attempt: Int,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> FullLengthONTMHCSavontRunPlan {
        let safeSample = safePathComponent(sample)
        let scratchRoot = temporaryDirectory.appendingPathComponent(
            "lungfish-savont-\(safeSample)-attempt-\(attempt)-\(UUID().uuidString)",
            isDirectory: true
        )
        return FullLengthONTMHCSavontRunPlan(
            attempt: attempt,
            scratchRootDirectory: scratchRoot,
            scratchRawOutputDirectory: scratchRoot.appendingPathComponent("raw", isDirectory: true),
            finalRawOutputDirectory: finalRawOutputDirectory
        )
    }

    static func shouldRetry(exitCode: Int32, attemptedThreads: Int) -> Bool {
        retryDecision(
            exitCode: exitCode,
            attemptedThreads: attemptedThreads,
            attemptedSingleStrand: false,
            stderr: ""
        ) == .singleThread
    }

    static func retryDecision(
        exitCode: Int32,
        attemptedThreads: Int,
        attemptedSingleStrand: Bool,
        stderr: String
    ) -> FullLengthONTMHCSavontRetryDecision {
        if isLowBidirectionalSNPmerFailure(exitCode: exitCode, stderr: stderr) {
            return attemptedSingleStrand ? .emptyClusters : .singleStrand
        }
        let retryableCrashStatuses: Set<Int32> = [
            -11,
            11,
            134,
            136,
            137,
            138,
            139,
        ]
        if attemptedThreads > 1 && retryableCrashStatuses.contains(exitCode) {
            return .singleThread
        }
        return .none
    }

    static func materializeCompletedRawOutput(from scratchRawOutputDirectory: URL, to finalRawOutputDirectory: URL) throws {
        let fileManager = FileManager.default
        let scratchFinalASV = scratchRawOutputDirectory.appendingPathComponent("final_asvs.fasta")
        guard fileManager.fileExists(atPath: scratchFinalASV.path) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Savont did not write final_asvs.fasta in \(scratchRawOutputDirectory.path)."
            )
        }
        try fileManager.createDirectory(
            at: finalRawOutputDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: finalRawOutputDirectory.path) {
            try fileManager.removeItem(at: finalRawOutputDirectory)
        }
        try fileManager.copyItem(at: scratchRawOutputDirectory, to: finalRawOutputDirectory)
    }

    private static func safePathComponent(_ sample: String) -> String {
        let sanitized = sample.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        }
        let value = String(sanitized)
        return value.isEmpty ? "sample" : value
    }

    static func isLowCoverageNoClusterFailure(
        exitCode: Int32,
        attemptedSingleStrand: Bool,
        stderr: String
    ) -> Bool {
        attemptedSingleStrand && isLowBidirectionalSNPmerFailure(exitCode: exitCode, stderr: stderr)
    }

    private static func isLowBidirectionalSNPmerFailure(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode != 0 else { return false }
        let normalized = stderr.lowercased()
        return normalized.contains("less than 0.1% of snpmers")
            && normalized.contains("--single-strand")
    }
}
