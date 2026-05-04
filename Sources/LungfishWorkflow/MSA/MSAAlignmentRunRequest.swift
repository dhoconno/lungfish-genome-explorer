import Foundation

public enum MSAAlignmentTool: String, Codable, Sendable, Equatable {
    case mafft

    public var displayName: String {
        switch self {
        case .mafft: return "MAFFT"
        }
    }

    public var environmentName: String { rawValue }
    public var executableName: String { rawValue }
}

public enum MAFFTAlignmentStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    case auto
    case linsi
    case ginsi
    case einsi
    case fftns2
    case parttree

    var arguments: [String] {
        switch self {
        case .auto:
            return ["--auto"]
        case .linsi:
            return ["--localpair", "--maxiterate", "1000"]
        case .ginsi:
            return ["--globalpair", "--maxiterate", "1000"]
        case .einsi:
            return ["--genafpair", "--ep", "0", "--maxiterate", "1000"]
        case .fftns2:
            return ["--retree", "2", "--maxiterate", "0"]
        case .parttree:
            return ["--retree", "1", "--maxiterate", "0", "--nofft", "--parttree"]
        }
    }
}

public enum MSAAlignmentOutputOrder: String, Codable, Sendable, Equatable, CaseIterable {
    case input
    case aligned

    var argument: String {
        switch self {
        case .input: return "--inputorder"
        case .aligned: return "--reorder"
        }
    }
}

public enum MSASequenceType: String, Codable, Sendable, Equatable, CaseIterable {
    case auto
    case nucleotide
    case protein

    var argument: String? {
        switch self {
        case .auto: return nil
        case .nucleotide: return "--nuc"
        case .protein: return "--amino"
        }
    }
}

public enum MAFFTDirectionAdjustment: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case fast
    case accurate

    var argument: String? {
        switch self {
        case .off: return nil
        case .fast: return "--adjustdirection"
        case .accurate: return "--adjustdirectionaccurately"
        }
    }
}

public enum MSASymbolPolicy: String, Codable, Sendable, Equatable, CaseIterable {
    case strict
    case any

    var argument: String? {
        switch self {
        case .strict: return nil
        case .any: return "--anysymbol"
        }
    }
}

public struct MSAAlignmentRunRequest: Codable, Sendable, Equatable {
    public let tool: MSAAlignmentTool
    public let inputSequenceURLs: [URL]
    public let projectURL: URL
    public let outputBundleURL: URL?
    public let name: String
    public let threads: Int?
    public let strategy: MAFFTAlignmentStrategy
    public let outputOrder: MSAAlignmentOutputOrder
    public let sequenceType: MSASequenceType
    public let directionAdjustment: MAFFTDirectionAdjustment
    public let symbolPolicy: MSASymbolPolicy
    public let deterministicThreads: Bool
    public let extraArguments: [String]
    public let wrapperArgv: [String]
    public let allowFASTQAssemblyInputs: Bool

    public init(
        tool: MSAAlignmentTool,
        inputSequenceURLs: [URL],
        projectURL: URL,
        outputBundleURL: URL?,
        name: String,
        threads: Int?,
        strategy: MAFFTAlignmentStrategy = .auto,
        outputOrder: MSAAlignmentOutputOrder = .input,
        sequenceType: MSASequenceType = .auto,
        directionAdjustment: MAFFTDirectionAdjustment = .off,
        symbolPolicy: MSASymbolPolicy = .strict,
        deterministicThreads: Bool = true,
        extraArguments: [String] = [],
        wrapperArgv: [String] = [],
        allowFASTQAssemblyInputs: Bool = false
    ) {
        self.tool = tool
        self.inputSequenceURLs = inputSequenceURLs
        self.projectURL = projectURL
        self.outputBundleURL = outputBundleURL
        self.name = name
        self.threads = threads
        self.strategy = strategy
        self.outputOrder = outputOrder
        self.sequenceType = sequenceType
        self.directionAdjustment = directionAdjustment
        self.symbolPolicy = symbolPolicy
        self.deterministicThreads = deterministicThreads
        self.extraArguments = extraArguments
        self.wrapperArgv = wrapperArgv
        self.allowFASTQAssemblyInputs = allowFASTQAssemblyInputs
    }

    public var resolvedOutputBundleURL: URL {
        outputBundleURL ?? Self.uniqueDefaultOutputBundleURL(projectURL: projectURL, name: name)
    }

    public static func defaultOutputDirectory(projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
    }

    public static func uniqueDefaultOutputBundleURL(projectURL: URL, name: String) -> URL {
        let outputDirectory = defaultOutputDirectory(projectURL: projectURL)
        let baseStem = sanitizedBundleStem(name)
        let fm = FileManager.default

        func candidate(_ suffix: Int?) -> URL {
            let stem = suffix.map { "\(baseStem)-\($0)" } ?? baseStem
            return outputDirectory.appendingPathComponent("\(stem).lungfishmsa", isDirectory: true)
        }

        let first = candidate(nil)
        if !fm.fileExists(atPath: first.path) {
            return first
        }

        var index = 2
        while true {
            let url = candidate(index)
            if !fm.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }
    }

    public static func sanitizedBundleStem(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "mafft-alignment" : trimmed
    }
}

public struct MSAAlignmentRunResult: Sendable, Equatable {
    public let bundleURL: URL
    public let rowCount: Int
    public let alignedLength: Int
    public let warnings: [String]
    public let wallTimeSeconds: Double

    public init(
        bundleURL: URL,
        rowCount: Int,
        alignedLength: Int,
        warnings: [String],
        wallTimeSeconds: Double
    ) {
        self.bundleURL = bundleURL
        self.rowCount = rowCount
        self.alignedLength = alignedLength
        self.warnings = warnings
        self.wallTimeSeconds = wallTimeSeconds
    }
}
