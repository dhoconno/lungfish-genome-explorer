public enum SavontRetryDecision: Sendable, Equatable {
    case none
    case singleThread
    case singleStrand
    case emptyClusters
}

public enum SavontRetryPolicy {
    public static func decision(
        exitCode: Int32,
        attemptedThreads: Int,
        attemptedSingleStrand: Bool,
        stderr: String
    ) -> SavontRetryDecision {
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

    private static func isLowBidirectionalSNPmerFailure(
        exitCode: Int32,
        stderr: String
    ) -> Bool {
        guard exitCode != 0 else { return false }
        let normalized = stderr.lowercased()
        return normalized.contains("less than 0.1% of snpmers")
            && normalized.contains("--single-strand")
    }
}
