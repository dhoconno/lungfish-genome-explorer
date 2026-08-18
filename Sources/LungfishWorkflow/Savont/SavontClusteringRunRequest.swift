import Foundation

public enum SavontClusteringRunRequestError: Error, LocalizedError, Equatable {
    case invalidThreads(Int)
    case invalidQualityValueCutoff(Int)
    case invalidMinimumClusterSize(Int)
    case invalidMinimumReadLength(Int)
    case invalidMaximumReadLength(Int)
    case invalidReadLengthRange(minimum: Int, maximum: Int)
    case invalidOutputFASTA(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidThreads(let value):
            "Savont thread count must be positive; received \(value)."
        case .invalidQualityValueCutoff(let value):
            "Savont quality-value cutoff must be between 0 and 100; received \(value)."
        case .invalidMinimumClusterSize(let value):
            "Savont minimum cluster size must be positive; received \(value)."
        case .invalidMinimumReadLength(let value):
            "Savont minimum read length must be positive when set; received \(value)."
        case .invalidMaximumReadLength(let value):
            "Savont maximum read length must be positive when set; received \(value)."
        case .invalidReadLengthRange(let minimum, let maximum):
            "Savont minimum read length \(minimum) cannot exceed maximum read length \(maximum)."
        case .invalidOutputFASTA(let url):
            "Savont output must be a FASTA file; received \(url.path)."
        }
    }
}

public struct SavontClusteringRunRequest: Sendable, Codable, Equatable {
    public static let workflowVersion = "1"
    public static var toolVersion: String { FullLengthONTMHCGenotypingRunRequest.savontToolVersion }
    public static let condaEnvironment = "savont"

    public let inputFASTQURL: URL
    public let outputFASTAURL: URL
    public let threads: Int
    public let qualityValueCutoff: Int
    public let minimumClusterSize: Int
    public let minimumReadLength: Int?
    public let maximumReadLength: Int?
    public let singleStrand: Bool

    private enum CodingKeys: String, CodingKey {
        case inputFASTQURL
        case outputFASTAURL
        case threads
        case qualityValueCutoff
        case minimumClusterSize
        case minimumReadLength
        case maximumReadLength
        case singleStrand
    }

    public init(
        inputFASTQURL: URL,
        outputFASTAURL: URL,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        qualityValueCutoff: Int = 90,
        minimumClusterSize: Int = 3,
        minimumReadLength: Int? = nil,
        maximumReadLength: Int? = nil,
        singleStrand: Bool = false
    ) throws {
        guard threads > 0 else {
            throw SavontClusteringRunRequestError.invalidThreads(threads)
        }
        guard (0...100).contains(qualityValueCutoff) else {
            throw SavontClusteringRunRequestError.invalidQualityValueCutoff(qualityValueCutoff)
        }
        guard minimumClusterSize > 0 else {
            throw SavontClusteringRunRequestError.invalidMinimumClusterSize(minimumClusterSize)
        }
        if let minimumReadLength, minimumReadLength <= 0 {
            throw SavontClusteringRunRequestError.invalidMinimumReadLength(minimumReadLength)
        }
        if let maximumReadLength, maximumReadLength <= 0 {
            throw SavontClusteringRunRequestError.invalidMaximumReadLength(maximumReadLength)
        }
        if let minimumReadLength, let maximumReadLength, minimumReadLength > maximumReadLength {
            throw SavontClusteringRunRequestError.invalidReadLengthRange(
                minimum: minimumReadLength,
                maximum: maximumReadLength
            )
        }
        let fastaExtensions: Set<String> = ["fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn"]
        guard fastaExtensions.contains(outputFASTAURL.pathExtension.lowercased()) else {
            throw SavontClusteringRunRequestError.invalidOutputFASTA(outputFASTAURL)
        }

        self.inputFASTQURL = inputFASTQURL.standardizedFileURL
        self.outputFASTAURL = outputFASTAURL.standardizedFileURL
        self.threads = threads
        self.qualityValueCutoff = qualityValueCutoff
        self.minimumClusterSize = minimumClusterSize
        self.minimumReadLength = minimumReadLength
        self.maximumReadLength = maximumReadLength
        self.singleStrand = singleStrand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            inputFASTQURL: container.decode(URL.self, forKey: .inputFASTQURL),
            outputFASTAURL: container.decode(URL.self, forKey: .outputFASTAURL),
            threads: container.decode(Int.self, forKey: .threads),
            qualityValueCutoff: container.decode(Int.self, forKey: .qualityValueCutoff),
            minimumClusterSize: container.decode(Int.self, forKey: .minimumClusterSize),
            minimumReadLength: container.decodeIfPresent(Int.self, forKey: .minimumReadLength),
            maximumReadLength: container.decodeIfPresent(Int.self, forKey: .maximumReadLength),
            singleStrand: container.decode(Bool.self, forKey: .singleStrand)
        )
    }

    public static func defaultOutputBaseName(for inputURL: URL) -> String {
        var name = inputURL.lastPathComponent
        let lowercasedName = name.lowercased()
        if lowercasedName.hasSuffix(".fastq.gz") {
            name.removeLast(9)
        } else if lowercasedName.hasSuffix(".fq.gz") {
            name.removeLast(6)
        } else if lowercasedName.hasSuffix(".fastq") {
            name.removeLast(6)
        } else if lowercasedName.hasSuffix(".fq") {
            name.removeLast(3)
        }
        return "\(name)-savont-clusters"
    }

    public func arguments(
        outputDirectory: URL,
        threads: Int? = nil,
        singleStrand: Bool? = nil
    ) throws -> [String] {
        let effectiveThreads = threads ?? self.threads
        guard effectiveThreads > 0 else {
            throw SavontClusteringRunRequestError.invalidThreads(effectiveThreads)
        }
        var arguments = [
            "asv", inputFASTQURL.path,
            "-o", outputDirectory.standardizedFileURL.path,
            "-t", String(effectiveThreads),
            "--quality-value-cutoff", String(qualityValueCutoff),
            "--min-cluster-size", String(minimumClusterSize),
        ]
        if let minimumReadLength {
            arguments.append(contentsOf: ["--min-read-length", String(minimumReadLength)])
        }
        if let maximumReadLength {
            arguments.append(contentsOf: ["--max-read-length", String(maximumReadLength)])
        }
        if singleStrand ?? self.singleStrand {
            arguments.append("--single-strand")
        }
        return arguments
    }
}
