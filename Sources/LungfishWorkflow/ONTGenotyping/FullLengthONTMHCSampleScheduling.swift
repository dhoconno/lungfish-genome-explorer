import Foundation

struct FullLengthONTMHCSampleExecutionPlan: Sendable, Equatable {
    let totalThreads: Int
    let sampleCount: Int
    let sampleJobs: Int
    let savontThreadsPerSample: Int
    let workerThreadsPerSample: Int

    static func automatic(
        totalThreads: Int,
        sampleCount: Int,
        requestedSampleJobs: Int?,
        requestedSavontThreadsPerSample: Int?
    ) -> FullLengthONTMHCSampleExecutionPlan {
        let normalizedThreads = max(1, totalThreads)
        let normalizedSampleCount = max(1, sampleCount)
        let automaticJobs = automaticSampleJobs(
            totalThreads: normalizedThreads,
            sampleCount: normalizedSampleCount
        )
        let requestedJobs = requestedSampleJobs.map { max(1, $0) } ?? automaticJobs
        let jobs = min(normalizedSampleCount, requestedJobs)
        let defaultSavontThreads = jobs == 1 ? normalizedThreads : max(1, normalizedThreads / (jobs + 1))
        let savontThreads = max(1, requestedSavontThreadsPerSample ?? defaultSavontThreads)
        let workerThreads = jobs == 1 ? normalizedThreads : max(1, normalizedThreads / jobs)
        return FullLengthONTMHCSampleExecutionPlan(
            totalThreads: normalizedThreads,
            sampleCount: normalizedSampleCount,
            sampleJobs: jobs,
            savontThreadsPerSample: savontThreads,
            workerThreadsPerSample: workerThreads
        )
    }

    private static func automaticSampleJobs(totalThreads: Int, sampleCount: Int) -> Int {
        guard sampleCount > 1 else { return 1 }
        switch totalThreads {
        case 16...:
            return min(sampleCount, 4)
        case 10...:
            return min(sampleCount, 3)
        case 4...:
            return min(sampleCount, 2)
        default:
            return 1
        }
    }
}

struct FullLengthONTMHCScheduledSample: Sendable, Equatable {
    let originalIndex: Int
    let inputURL: URL
    let sample: String
    let sampleDirectory: URL
    let materializedFASTQURL: URL
    let readCount: Int
    let materializationStep: ProvenanceStep?

    init(
        originalIndex: Int,
        inputURL: URL,
        sample: String,
        sampleDirectory: URL,
        materializedFASTQURL: URL,
        readCount: Int,
        materializationStep: ProvenanceStep? = nil
    ) {
        self.originalIndex = originalIndex
        self.inputURL = inputURL
        self.sample = sample
        self.sampleDirectory = sampleDirectory
        self.materializedFASTQURL = materializedFASTQURL
        self.readCount = readCount
        self.materializationStep = materializationStep
    }
}

enum FullLengthONTMHCSampleScheduler {
    static let stagingStartProgress = 0.03
    static let stagingEndProgress = 0.15
    static let processingStartProgress = 0.15
    static let processingEndProgress = 0.86

    static func processingOrder(
        for samples: [FullLengthONTMHCScheduledSample]
    ) -> [FullLengthONTMHCScheduledSample] {
        samples.sorted { lhs, rhs in
            if lhs.readCount != rhs.readCount {
                return lhs.readCount > rhs.readCount
            }
            return lhs.originalIndex < rhs.originalIndex
        }
    }

    static func stagingProgress(stagedSampleCount: Int, totalSampleCount: Int) -> Double {
        fractionalProgress(
            completed: stagedSampleCount,
            total: totalSampleCount,
            start: stagingStartProgress,
            end: stagingEndProgress
        )
    }

    static func processingProgress(completedReadCount: Int, totalReadCount: Int) -> Double {
        fractionalProgress(
            completed: completedReadCount,
            total: max(1, totalReadCount),
            start: processingStartProgress,
            end: processingEndProgress
        )
    }

    private static func fractionalProgress(
        completed: Int,
        total: Int,
        start: Double,
        end: Double
    ) -> Double {
        let fraction = Double(max(0, min(completed, max(1, total)))) / Double(max(1, total))
        return start + (end - start) * fraction
    }
}
