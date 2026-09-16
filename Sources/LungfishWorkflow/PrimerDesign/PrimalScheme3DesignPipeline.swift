import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum PrimalScheme3TerminalGapPolicy: String, Codable, CaseIterable, Sendable {
    case legacy
    case observedOnly = "observed-only"

    public var discoveryBackend: String {
        self == .legacy ? "rust-legacy" : "python-observed-only"
    }
}

public enum PrimalScheme3PanelMode: String, Codable, CaseIterable, Sendable {
    case equal, entropy
}

public enum PrimalScheme3SelectionAlgorithm: String, Codable, CaseIterable, Sendable {
    case legacy, coverage
    case alleleCoverage = "allele-coverage"
}

public enum PrimalScheme3CoverageMetric: String, Codable, CaseIterable, Sendable {
    case fullSpan = "full-span"
    case primerTrimmed = "primer-trimmed"
    case observedAllelePrimerTrimmed = "observed-allele-primer-trimmed"
}

public struct PrimalScheme3DesignOptions: Codable, Equatable, Sendable {
    public static var defaultCoreCount: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)) }
    public let requestedAmpliconSizeMinimum: Int?
    public let requestedAmpliconSizeMaximum: Int?
    public var ampliconSizeMinimum: Int { requestedAmpliconSizeMinimum ?? ((100...2000).contains(ampliconSize) ? Int(Double(ampliconSize) * 0.9) : 0) }
    public var ampliconSizeMaximum: Int { requestedAmpliconSizeMaximum ?? ((100...2000).contains(ampliconSize) ? Int(Double(ampliconSize) * 1.1) : 0) }
    public var ampliconSizeMetric: String {
        requestedAmpliconSizeMinimum != nil || requestedAmpliconSizeMaximum != nil ? "reference-span" : "legacy-pairing"
    }
    public let dimerScore: Double
    public let useMatchDB: Bool
    public let backtrack: Bool
    public let ignoreN: Bool
    public let panelMode: PrimalScheme3PanelMode
    public let maxAmplicons: Int?
    public let maxAmpliconsPerMSA: Int?
    public let ampliconSize: Int
    public let poolCount: Int
    public let minOverlap: Int
    public let minimumBaseFrequency: Double
    public let highGC: Bool
    public let coreCount: Int
    public let terminalGapPolicy: PrimalScheme3TerminalGapPolicy
    public let selectionAlgorithm: PrimalScheme3SelectionAlgorithm
    public let coverageMetric: PrimalScheme3CoverageMetric
    public let coverageTarget: Double
    public let optimizerSeed: Int
    public let optimizerStarts: Int
    public let optimizerRepairRounds: Int
    public let optimizerTimeLimit: Double
    public let alleleOptions: PrimalScheme3AlleleOptions
    public let requestedMisprimingProductSize: Int?
    public var misprimingProductSize: Int {
        requestedMisprimingProductSize ?? (selectionAlgorithm == .legacy ? 0 : 2_000)
    }
    public init(ampliconSize: Int, poolCount: Int, minOverlap: Int = 10,
                minimumBaseFrequency: Double = 0, highGC: Bool = false, coreCount: Int = PrimalScheme3DesignOptions.defaultCoreCount,
                terminalGapPolicy: PrimalScheme3TerminalGapPolicy = .observedOnly,
                dimerScore: Double = -26, useMatchDB: Bool = true,
                backtrack: Bool = false, ignoreN: Bool = false,
                panelMode: PrimalScheme3PanelMode = .equal,
                maxAmplicons: Int? = nil, maxAmpliconsPerMSA: Int? = nil,
                ampliconSizeMinimum: Int? = nil, ampliconSizeMaximum: Int? = nil,
                selectionAlgorithm: PrimalScheme3SelectionAlgorithm = .legacy,
                coverageMetric: PrimalScheme3CoverageMetric? = nil,
                coverageTarget: Double? = nil, optimizerSeed: Int = 0,
                optimizerStarts: Int = 4, optimizerRepairRounds: Int = 2,
                optimizerTimeLimit: Double = 120,
                misprimingProductSize: Int? = nil,
                alleleOptions: PrimalScheme3AlleleOptions = .init()) {
        self.requestedAmpliconSizeMinimum = ampliconSizeMinimum
        self.requestedAmpliconSizeMaximum = ampliconSizeMaximum
        self.dimerScore = dimerScore
        self.useMatchDB = useMatchDB
        self.backtrack = backtrack
        self.ignoreN = ignoreN
        self.panelMode = panelMode
        self.maxAmplicons = maxAmplicons
        self.maxAmpliconsPerMSA = maxAmpliconsPerMSA
        self.ampliconSize = ampliconSize
        self.poolCount = poolCount
        self.minOverlap = minOverlap
        self.minimumBaseFrequency = minimumBaseFrequency
        self.highGC = highGC
        self.coreCount = coreCount
        self.terminalGapPolicy = terminalGapPolicy
        self.selectionAlgorithm = selectionAlgorithm
        self.coverageMetric = coverageMetric ?? (selectionAlgorithm == .alleleCoverage ? .observedAllelePrimerTrimmed : .fullSpan)
        self.coverageTarget = coverageTarget ?? (selectionAlgorithm == .alleleCoverage ? 0.95 : 0.90)
        self.optimizerSeed = optimizerSeed
        self.optimizerStarts = optimizerStarts
        self.optimizerRepairRounds = optimizerRepairRounds
        self.optimizerTimeLimit = optimizerTimeLimit
        self.requestedMisprimingProductSize = misprimingProductSize
        self.alleleOptions = alleleOptions
    }

    private enum CodingKeys: String, CodingKey {
        case requestedAmpliconSizeMinimum, requestedAmpliconSizeMaximum, dimerScore, useMatchDB
        case backtrack, ignoreN, panelMode, maxAmplicons, maxAmpliconsPerMSA, ampliconSize
        case poolCount, minOverlap, minimumBaseFrequency, highGC, coreCount, terminalGapPolicy
        case selectionAlgorithm, coverageMetric, coverageTarget, optimizerSeed, optimizerStarts
        case optimizerRepairRounds, optimizerTimeLimit, requestedMisprimingProductSize
        case alleleOptions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ampliconSize: try values.decode(Int.self, forKey: .ampliconSize),
            poolCount: try values.decode(Int.self, forKey: .poolCount),
            minOverlap: try values.decode(Int.self, forKey: .minOverlap),
            minimumBaseFrequency: try values.decode(Double.self, forKey: .minimumBaseFrequency),
            highGC: try values.decode(Bool.self, forKey: .highGC),
            coreCount: try values.decode(Int.self, forKey: .coreCount),
            terminalGapPolicy: try values.decode(PrimalScheme3TerminalGapPolicy.self, forKey: .terminalGapPolicy),
            dimerScore: try values.decode(Double.self, forKey: .dimerScore),
            useMatchDB: try values.decode(Bool.self, forKey: .useMatchDB),
            backtrack: try values.decode(Bool.self, forKey: .backtrack),
            ignoreN: try values.decode(Bool.self, forKey: .ignoreN),
            panelMode: try values.decode(PrimalScheme3PanelMode.self, forKey: .panelMode),
            maxAmplicons: try values.decodeIfPresent(Int.self, forKey: .maxAmplicons),
            maxAmpliconsPerMSA: try values.decodeIfPresent(Int.self, forKey: .maxAmpliconsPerMSA),
            ampliconSizeMinimum: try values.decodeIfPresent(Int.self, forKey: .requestedAmpliconSizeMinimum),
            ampliconSizeMaximum: try values.decodeIfPresent(Int.self, forKey: .requestedAmpliconSizeMaximum),
            selectionAlgorithm: try values.decodeIfPresent(PrimalScheme3SelectionAlgorithm.self, forKey: .selectionAlgorithm) ?? .legacy,
            coverageMetric: try values.decodeIfPresent(PrimalScheme3CoverageMetric.self, forKey: .coverageMetric),
            coverageTarget: try values.decodeIfPresent(Double.self, forKey: .coverageTarget),
            optimizerSeed: try values.decodeIfPresent(Int.self, forKey: .optimizerSeed) ?? 0,
            optimizerStarts: try values.decodeIfPresent(Int.self, forKey: .optimizerStarts) ?? 4,
            optimizerRepairRounds: try values.decodeIfPresent(Int.self, forKey: .optimizerRepairRounds) ?? 2,
            optimizerTimeLimit: try values.decodeIfPresent(Double.self, forKey: .optimizerTimeLimit) ?? 120,
            misprimingProductSize: try values.decodeIfPresent(Int.self, forKey: .requestedMisprimingProductSize),
            alleleOptions: try values.decodeIfPresent(PrimalScheme3AlleleOptions.self, forKey: .alleleOptions) ?? .init())
    }

    public var provenanceOptions: [String: ParameterValue] {
        ["ampliconSize": .integer(ampliconSize), "ampliconSizeMinimum": .integer(ampliconSizeMinimum),
         "ampliconSizeMaximum": .integer(ampliconSizeMaximum), "ampliconSizeMetric": .string(ampliconSizeMetric),
         "requestedAmpliconSizeMinimum": requestedAmpliconSizeMinimum.map(ParameterValue.integer) ?? .null,
         "requestedAmpliconSizeMaximum": requestedAmpliconSizeMaximum.map(ParameterValue.integer) ?? .null,
         "poolCount": .integer(poolCount),
         "minOverlap": .integer(minOverlap), "minimumBaseFrequency": .number(minimumBaseFrequency),
         "highGC": .boolean(highGC), "coreCount": .integer(coreCount),
         "terminalGapPolicy": .string(terminalGapPolicy.rawValue), "dimerScore": .number(dimerScore),
         "useMatchDB": .boolean(useMatchDB), "backtrack": .boolean(backtrack), "ignoreN": .boolean(ignoreN),
         "panelMode": .string(panelMode.rawValue),
         "maxAmplicons": maxAmplicons.map(ParameterValue.integer) ?? .string("unlimited"),
         "maxAmpliconsPerMSA": maxAmpliconsPerMSA.map(ParameterValue.integer) ?? .string("unlimited"),
         "selectionAlgorithm": .string(selectionAlgorithm.rawValue),
         "coverageMetric": .string(coverageMetric.rawValue), "coverageTarget": .number(coverageTarget),
         "optimizerSeed": .integer(optimizerSeed), "optimizerStarts": .integer(optimizerStarts),
         "optimizerRepairRounds": .integer(optimizerRepairRounds),
         "optimizerTimeLimit": .number(optimizerTimeLimit),
         "requestedMisprimingProductSize": requestedMisprimingProductSize.map(ParameterValue.integer) ?? .null,
         "misprimingProductSize": .integer(misprimingProductSize),
         "alleleOptions": .dictionary(alleleOptions.resolvedProvenanceOptions),
         "alleleRequestedOptions": .dictionary(alleleOptions.requestedProvenanceOptions)]
    }
}

public struct PrimalScheme3DesignRequest: Sendable {
    public let inputURLs: [URL]
    public let destinationURL: URL
    public let options: PrimalScheme3DesignOptions
    public let grouping: PrimerAnalysisGrouping
    public let invocation: PrimerAnalysisWrapperInvocation
    public let executableURL: URL?
    public let expectedInputChecksums: [URL: String]

    public init(inputURLs: [URL], destinationURL: URL, options: PrimalScheme3DesignOptions,
                grouping: PrimerAnalysisGrouping, invocation: PrimerAnalysisWrapperInvocation,
                executableURL: URL? = nil, expectedInputChecksums: [URL: String] = [:]) {
        self.inputURLs = inputURLs
        self.destinationURL = destinationURL
        self.options = options
        self.grouping = grouping
        self.invocation = invocation
        self.executableURL = executableURL
        self.expectedInputChecksums = expectedInputChecksums
    }
}

public enum PrimalScheme3DesignError: Error, LocalizedError, Sendable {
    case invalidRequest(String)
    case executionFailed(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return "PrimalScheme: \(reason)"
        case .executionFailed(let code, let detail): return "PrimalScheme exited with status \(code): \(detail)"
        }
    }
}

struct PrimalScheme3Command: Sendable {
    let executableOverride: URL?
    let arguments: [String]
    let workingDirectory: URL
    let selectionAlgorithm: PrimalScheme3SelectionAlgorithm
    let terminalGapPolicy: PrimalScheme3TerminalGapPolicy
    var managedEnvironmentURL: URL? = nil
}

struct PrimalScheme3Execution: Sendable {
    let argv: [String]
    let stdout: String
    let stderr: String
    let exitStatus: Int32
    let version: String
    let runtime: ProvenanceRuntimeIdentity
    let startedAt: Date
    let endedAt: Date
    var executableSHA256: String? = nil
    var runtimeEvidence: [String: Data] = [:]
    var capabilitiesJSON: Data? = nil
    var auditValidationJSON: Data? = nil
    var auditProvenanceJSON: Data? = nil
    var auditArgv: [String]? = nil
    var auditExitStatus: Int32? = nil
}

public struct PrimalScheme3DesignPipeline: Sendable {
    public static let toolVersion = "3.3.0+lge.2"
    public static let coverageToolVersion = "3.3.0+lge.3"
    public static let alleleToolVersion = "3.3.0+lge.4"
    public static let toolDisplayName = "PrimalScheme3-LGE (custom fork)"
    public static let sourceRepository = "https://github.com/dhoconno/primalscheme3-lge"
    /// Raw nucleotide FASTA suffixes accepted as one-row or already-aligned inputs.
    /// Protein FASTA and compressed FASTA are intentionally excluded because the
    /// custom fork consumes an uncompressed DNA alignment.
    public static let supportedRawFASTAExtensions: Set<String> = ["fa", "fasta", "fna", "ffn", "frn", "fas"]

    public static func supportsInput(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == MultipleSequenceAlignmentBundle.directoryExtension || ext == "lungfishref"
            || supportedRawFASTAExtensions.contains(ext)
    }

    typealias Runner = @Sendable (PrimalScheme3Command) async throws -> PrimalScheme3Execution
    private let runner: Runner
    private let writer: PrimerAnalysisBundleWriter
    private let runtimePreparer: PrimerDesignManagedRuntime.Preparer?

    public init() {
        runner = Self.execute
        writer = PrimerAnalysisBundleWriter()
        runtimePreparer = { try await PrimerDesignManagedRuntime.prepareAndAcquire(toolID: "primalscheme3", progress: $0) }
    }

    init(runner: @escaping Runner, writer: PrimerAnalysisBundleWriter = PrimerAnalysisBundleWriter(), runtimePreparer: PrimerDesignManagedRuntime.Preparer? = nil) {
        self.runner = runner
        self.writer = writer
        self.runtimePreparer = runtimePreparer
    }

    public func run(request: PrimalScheme3DesignRequest,
                    progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> URL {
        let worker = Task.detached(priority: .userInitiated) {
            try await runOffMain(request: request, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    static func arguments(inputs: [URL], output: URL, grouping: PrimerAnalysisGrouping,
                          options: PrimalScheme3DesignOptions) throws -> [String] {
        guard !inputs.isEmpty, (100...2000).contains(options.ampliconSize), options.poolCount > 0,
              options.minOverlap >= 0, options.minimumBaseFrequency.isFinite,
              (0...1).contains(options.minimumBaseFrequency), options.coreCount > 0,
              grouping != .combined || options.minOverlap == 10,
              grouping == .combined || inputs.count == 1 else {
            throw PrimalScheme3DesignError.invalidRequest("Choose an amplicon size from 100 to 2000, positive pool/core counts, nonnegative overlap, base frequency from 0 to 1, and explicit alignment inputs. Custom overlap applies only to independent schemes.")
        }
        guard options.ampliconSizeMinimum > 0,
              options.ampliconSizeMinimum <= options.ampliconSize,
              options.ampliconSize <= options.ampliconSizeMaximum else {
            throw PrimalScheme3DesignError.invalidRequest("Amplicon bounds must be positive, with minimum ≤ target ≤ maximum.")
        }
        if options.selectionAlgorithm != .alleleCoverage,
           !options.alleleOptions.requestedOptionNames.isEmpty {
            throw PrimalScheme3DesignError.invalidRequest("Allele controls require --selection-algorithm allele-coverage.")
        }
        let validCap: (Int?) -> Bool = { value in
            value.map { options.selectionAlgorithm == .legacy ? $0 > 0 : $0 >= 0 } ?? true
        }
        guard options.dimerScore.isFinite, validCap(options.maxAmplicons), validCap(options.maxAmpliconsPerMSA),
              grouping != .combined || (!options.backtrack && !options.ignoreN),
              grouping != .independent || (options.panelMode == .equal && options.maxAmplicons == nil && options.maxAmpliconsPerMSA == nil) else {
            throw PrimalScheme3DesignError.invalidRequest("Dimer score must be finite and amplicon limits positive. Backtracking and unknown-base omission apply only to independent schemes; panel modes and limits apply only to combined panels.")
        }
        if options.selectionAlgorithm == .legacy {
            guard options.coverageMetric == .fullSpan, options.coverageTarget == 0.90,
                  options.optimizerSeed == 0, options.optimizerStarts == 4,
                  options.optimizerRepairRounds == 2, options.optimizerTimeLimit == 120,
                  options.misprimingProductSize == 0 else {
                throw PrimalScheme3DesignError.invalidRequest("Coverage optimizer settings require --selection-algorithm coverage.")
            }
        } else {
            guard grouping == .combined, options.panelMode == .equal, options.useMatchDB,
                  options.requestedAmpliconSizeMinimum != nil || options.requestedAmpliconSizeMaximum != nil,
                  options.coverageTarget.isFinite, (0...1).contains(options.coverageTarget),
                  options.optimizerStarts > 0, options.optimizerRepairRounds >= 0,
                  options.optimizerTimeLimit.isFinite, options.optimizerTimeLimit > 0,
                  options.misprimingProductSize > 0 else {
                throw PrimalScheme3DesignError.invalidRequest("Coverage selection requires a combined equal panel, supplied-MSA specificity, an explicit amplicon bound, finite selector settings, positive starts/time/product size, and nonnegative repair rounds.")
            }
            if options.selectionAlgorithm == .coverage {
                guard [.fullSpan, .primerTrimmed].contains(options.coverageMetric) else {
                    throw PrimalScheme3DesignError.invalidRequest("Historical coverage selection supports only full-span or primer-trimmed metrics.")
                }
            } else {
                try options.alleleOptions.validate()
                guard options.coverageMetric == .observedAllelePrimerTrimmed,
                      options.coverageTarget > 0,
                      options.terminalGapPolicy == .observedOnly, options.dimerScore == -26,
                      !options.highGC, !options.backtrack, !options.ignoreN,
                      options.requestedAmpliconSizeMinimum != nil,
                      options.requestedAmpliconSizeMaximum != nil else {
                    throw PrimalScheme3DesignError.invalidRequest("Allele coverage requires the observed-allele metric, observed-only linear combined/equal scope, strict -26 dimer cutoff, no legacy high-GC toggle, and both explicit size bounds.")
                }
            }
        }
        var args = [grouping == .combined ? "panel-create" : "scheme-create"]
        // Stock panel-create defaults to region-only, which requires a BED file.
        // This interface has whole-alignment inputs, so select equal explicitly.
        if grouping == .combined { args += ["--mode", options.panelMode.rawValue] }
        for input in inputs { args += ["--msa", input.path] }
        args += ["--output", output.path, "--amplicon-size", String(options.ampliconSize),
                 "--n-pools", String(options.poolCount),
                 "--min-base-freq", String(options.minimumBaseFrequency), "--mapping", "first",
                 options.highGC ? "--high-gc" : "--no-high-gc", "--ncores", String(options.coreCount),
                 "--terminal-gap-policy", options.terminalGapPolicy.rawValue]
        args += ["--dimer-score", String(options.dimerScore), options.useMatchDB ? "--use-matchdb" : "--no-use-matchdb", "--offline-plots"]
        if let minimum = options.requestedAmpliconSizeMinimum { args += ["--amplicon-size-min", String(minimum)] }
        if let maximum = options.requestedAmpliconSizeMaximum { args += ["--amplicon-size-max", String(maximum)] }
        if grouping == .independent {
            args += ["--min-overlap", String(options.minOverlap), options.backtrack ? "--backtrack" : "--no-backtrack",
                     options.ignoreN ? "--ignore-n" : "--no-ignore-n"]
        } else {
            if let count = options.maxAmplicons { args += ["--max-amplicons", String(count)] }
            if let count = options.maxAmpliconsPerMSA { args += ["--max-amplicons-msa", String(count)] }
        }
        if options.selectionAlgorithm != .legacy {
            args += ["--selection-algorithm", options.selectionAlgorithm.rawValue,
                     "--coverage-metric", options.coverageMetric.rawValue,
                     "--coverage-target", String(options.coverageTarget),
                     "--optimizer-seed", String(options.optimizerSeed),
                     "--optimizer-starts", String(options.optimizerStarts),
                     "--optimizer-repair-rounds", String(options.optimizerRepairRounds),
                     "--optimizer-time-limit", String(options.optimizerTimeLimit),
                     "--mispriming-product-size", String(options.misprimingProductSize)]
            if options.selectionAlgorithm == .coverage, options.requestedAmpliconSizeMinimum == nil {
                args += ["--amplicon-size-min", String(options.ampliconSizeMinimum)]
            }
            if options.selectionAlgorithm == .coverage, options.requestedAmpliconSizeMaximum == nil {
                args += ["--amplicon-size-max", String(options.ampliconSizeMaximum)]
            }
            if options.selectionAlgorithm == .alleleCoverage {
                options.alleleOptions.appendRequestedArguments(to: &args)
            }
        }
        return args
    }

    static func validateNativeAmpliconSpans(at output: URL, options: PrimalScheme3DesignOptions) throws {
        guard options.ampliconSizeMetric == "reference-span" else { return }
        let bed = output.appendingPathComponent("amplicon.bed")
        let text = try String(contentsOf: bed, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, !fields[0].isEmpty,
                  let start = Int(fields[1]), let end = Int(fields[2]), start >= 0, end > start else {
                throw PrimalScheme3DesignError.invalidRequest("The native amplicon BED contains an invalid reference interval.")
            }
            guard (options.ampliconSizeMinimum...options.ampliconSizeMaximum).contains(end - start) else {
                throw PrimalScheme3DesignError.invalidRequest("A native amplicon span falls outside the requested minimum and maximum sizes.")
            }
        }
    }

    static func validateReferenceBundleRows(_ rows: [Primer3AlignedRow]) throws {
        guard rows.count == 1 else {
            throw PrimalScheme3DesignError.invalidRequest(
                ".lungfishref input must contain exactly one sequence. Import multiple sequences as an explicit alignment first.")
        }
    }

    private struct Input: Sendable {
        let id: UUID
        let originalURL: URL
        let snapshotURL: URL
        let alignedURL: URL
        let paths: [String]
        let fingerprint: String
        let consumedFingerprint: String
        let uracilCount: Int
        let unknownBaseCount: Int
        let preprocessing: String
        let referenceName: String
        let rowMappingPath: String
    }

    private func runOffMain(request: PrimalScheme3DesignRequest,
                            progress: (@Sendable (Double, String) -> Void)?) async throws -> URL {
        try Task.checkCancellation()
        guard !request.inputURLs.isEmpty, Set(request.inputURLs).count == request.inputURLs.count else {
            throw PrimalScheme3DesignError.invalidRequest("Select distinct sequence or alignment inputs.")
        }
        guard request.destinationURL.pathExtension.lowercased() == "lungfishprimeranalysis" else {
            throw PrimalScheme3DesignError.invalidRequest("The destination must be a .lungfishprimeranalysis bundle.")
        }
        let destination = try Self.physicalParent(request.destinationURL)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw PrimalScheme3DesignError.invalidRequest("The destination already exists.")
        }
        _ = try Self.arguments(inputs: [request.inputURLs[0]], output: destination,
                               grouping: request.grouping, options: request.options)
        if request.options.selectionAlgorithm != .legacy, request.executableURL == nil {
            throw PrimalScheme3DesignError.invalidRequest(
                "Coverage selection requires an explicit verified native executable: --primalscheme3-path /path/to/primalscheme3")
        }
        let runtimeLease = request.executableURL == nil ? try await runtimePreparer?(progress) : nil
        defer { runtimeLease?.release() }
        progress?(0.05, "Validating sequence or alignment inputs")
        let workflowStartedAt = Date()
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(
            ".primalscheme3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
        var artifacts: [PrimerAnalysisSourceArtifact] = []
        var inputs: [Input] = []
        for (inputIndex, url) in request.inputURLs.enumerated() {
            try Task.checkCancellation()
            progress?(0.05 + 0.15 * Double(inputIndex) / Double(request.inputURLs.count), "Preparing input \(inputIndex + 1)/\(request.inputURLs.count)")
            guard let expected = request.expectedInputChecksums[url], expected.count == 64,
                  expected == (try Primer3InputLoader.fingerprint(url)) else {
                throw PrimalScheme3DesignError.invalidRequest("An input changed after inspection or has no inspection checksum: \(url.lastPathComponent)")
            }
            let id = UUID()
            let prefix = "source-inputs/\(id.uuidString)"
            let native = Primer3InputLoader.isAlignmentBundle(url)
            let referenceBundle = Primer3InputLoader.isReferenceBundle(url)
            let snapshot = scratch.appendingPathComponent(prefix).appendingPathComponent(
                native ? "source.lungfishmsa" : referenceBundle ? "source.lungfishref" : "source.fasta")
            try Self.copySource(url, to: snapshot)
            guard try Primer3InputLoader.fingerprint(snapshot) == expected else {
                throw PrimalScheme3DesignError.invalidRequest("An input changed while its snapshot was being captured.")
            }
            let sourceAligned: URL
            if native {
                sourceAligned = snapshot.appendingPathComponent("alignment/primary.aligned.fasta")
            } else if referenceBundle {
                guard let originalFASTA = SequenceInputResolver.resolvePrimarySequenceURL(for: url) else {
                    throw PrimalScheme3DesignError.invalidRequest("Reference bundle has no readable primary FASTA.")
                }
                guard Primer3InputLoader.isContained(originalFASTA.resolvingSymlinksInPath(),
                                                      in: url.resolvingSymlinksInPath()) else {
                    throw PrimalScheme3DesignError.invalidRequest(
                        "Reference bundle primary FASTA must be stored inside the bundle for primer design.")
                }
                sourceAligned = snapshot.appendingPathComponent(Self.relative(originalFASTA, to: url))
            } else {
                sourceAligned = snapshot
            }
            let rows = try Primer3InputLoader.readAlignedRows(at: sourceAligned, allowingRNAU: true)
            if native {
                try Primer3InputLoader.validateAlignedRows(rows, bundle: MultipleSequenceAlignmentBundle.load(from: snapshot))
            } else if referenceBundle {
                try Self.validateReferenceBundleRows(rows)
            }
            let preservesAmbiguity = request.options.selectionAlgorithm == .alleleCoverage
            let normalized = Primer3InputLoader.normalizeForPrimalScheme(
                rows, ambiguityPolicy: preservesAmbiguity ? .preserve : .missingCoverage)
            let normalizedRows = normalized.rows
            let uracilCount = normalized.uracilCount
            let unknownBaseCount = normalized.unknownBaseCount
            let lengths = Set(normalizedRows.map { $0.sequence.count })
            guard !normalizedRows.isEmpty, lengths.count == 1, lengths.first != 0,
                  Set(normalizedRows.map(\.title)).count == normalizedRows.count,
                  normalizedRows.allSatisfy({ $0.sequence.uppercased().allSatisfy { "ACGTRYSWKMBDHVN-".contains($0) } }) else {
                throw PrimalScheme3DesignError.invalidRequest("Each input must contain aligned, nonempty DNA rows with distinct FASTA identifiers. No alignment or record selection is inferred.")
            }
            let files = try Self.regularFiles(in: snapshot)
            let aligned = scratch.appendingPathComponent("inputs/\(id.uuidString).fasta")
            try FileManager.default.createDirectory(at: aligned.deletingLastPathComponent(), withIntermediateDirectories: true)
            let normalizedNames = normalizedRows.indices.map { "input_\(id.uuidString.replacingOccurrences(of: "-", with: ""))_row_\($0)" }
            let decompression = sourceAligned.pathExtension.lowercased() == "gz"
                ? "gzip-decompression-to-UTF8-FASTA; " : ""
            let ambiguityTransform = preservesAmbiguity
                ? "N/IUPAC ambiguity preserved for exact support and specificity"
                : "N-to-gap missing-coverage normalization"
            let preprocessing = decompression
                + "FASTA-header-normalization; U-to-T DNA normalization; \(ambiguityTransform); row-order-preserved"
            let consumedFASTA = normalizedRows.enumerated().map { index, row in
                ">\(normalizedNames[index])\n\(row.sequence)\n"
            }.joined()
            try Data(consumedFASTA.utf8).write(to: aligned, options: .withoutOverwriting)
            let mappingPath = "inputs/\(id.uuidString)-row-map.json"
            let mappingURL = scratch.appendingPathComponent(mappingPath)
            let mapping: [String: Any] = ["schemaVersion": 1, "inputID": id.uuidString,
                "transformation": (sourceAligned.pathExtension.lowercased() == "gz" ? "gzip decompressed to UTF-8 FASTA; " : "")
                    + "FASTA headers replaced; U/u normalized to T; "
                    + (preservesAmbiguity ? "N/IUPAC ambiguity preserved; " : "N/n treated as missing alignment gaps; ")
                    + "row order preserved",
                "uracilCount": uracilCount,
                "unknownBaseCount": unknownBaseCount,
                "rows": normalizedRows.enumerated().map { index, row in
                    ["rowIndex": index, "originalHeader": row.title, "normalizedHeader": normalizedNames[index]] as [String: Any]
                }]
            try JSONSerialization.data(withJSONObject: mapping, options: [.prettyPrinted, .sortedKeys])
                .write(to: mappingURL, options: .withoutOverwriting)
            let consumedFingerprint = try Primer3InputLoader.fingerprint(aligned)
            let paths = files.map { Self.relative($0, to: scratch) } + [Self.relative(aligned, to: scratch), mappingPath]
            for file in files {
                artifacts.append(.init(sourceURL: file, relativePath: Self.relative(file, to: scratch),
                                       role: "input", format: file.pathExtension.isEmpty ? "binary" : file.pathExtension))
            }
            artifacts.append(.init(sourceURL: aligned, relativePath: Self.relative(aligned, to: scratch), role: "input", format: "fasta"))
            artifacts.append(.init(sourceURL: mappingURL, relativePath: mappingPath, role: "input", format: "json"))
            inputs.append(Input(id: id, originalURL: url, snapshotURL: snapshot, alignedURL: aligned,
                                paths: paths, fingerprint: expected, consumedFingerprint: consumedFingerprint,
                                uracilCount: uracilCount, unknownBaseCount: unknownBaseCount,
                                preprocessing: preprocessing,
                                referenceName: normalizedNames[0],
                                rowMappingPath: mappingPath))
        }
        let analysisID = UUID(), runID = UUID()
        let groups = request.grouping == .combined ? [inputs] : inputs.map { [$0] }
        var results: [PrimerAnalysisResult] = []
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            progress?(0.2 + 0.7 * Double(index) / Double(groups.count), "Running PrimalScheme (\(index + 1)/\(groups.count))")
            let resultID = UUID()
            let output = scratch.appendingPathComponent("native/\(resultID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let args = try Self.arguments(inputs: group.map(\.alignedURL), output: output,
                                          grouping: request.grouping, options: request.options)
            let executionRequests = scratch.appendingPathComponent("execution-attempts", isDirectory: true)
            try FileManager.default.createDirectory(at: executionRequests, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "status": "started", "argv": [request.executableURL?.path ?? "managed:primalscheme3"] + args,
                "workingDirectory": scratch.path, "startedAt": ISO8601DateFormatter().string(from: Date())
            ], options: [.prettyPrinted, .sortedKeys]).write(
                to: executionRequests.appendingPathComponent("\(resultID.uuidString)-design-request.json"),
                options: .withoutOverwriting)
            let executed = try await runner(.init(executableOverride: request.executableURL,
                                                  arguments: args, workingDirectory: scratch,
                                                  selectionAlgorithm: request.options.selectionAlgorithm,
                                                  terminalGapPolicy: request.options.terminalGapPolicy,
                                                  managedEnvironmentURL: runtimeLease?.environmentURL))
            let attemptLogs = scratch.appendingPathComponent("logs/\(resultID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: attemptLogs, withIntermediateDirectories: true)
            let runtimeData = try JSONEncoder().encode(executed.runtime)
            let attempt: [String: Any] = [
                "argv": executed.argv, "stdout": executed.stdout, "stderr": executed.stderr,
                "exitStatus": executed.exitStatus, "toolVersion": executed.version,
                "startedAt": ISO8601DateFormatter().string(from: executed.startedAt),
                "endedAt": ISO8601DateFormatter().string(from: executed.endedAt),
                "runtime": try JSONSerialization.jsonObject(with: runtimeData)
            ]
            try JSONSerialization.data(withJSONObject: attempt, options: [.prettyPrinted, .sortedKeys])
                .write(to: attemptLogs.appendingPathComponent("native-execution-attempt.json"),
                       options: .withoutOverwriting)
            try Task.checkCancellation()
            guard executed.exitStatus == 0 else {
                throw PrimalScheme3DesignError.executionFailed(executed.exitStatus, executed.stderr)
            }
            let supportedVersion: Bool
            switch request.options.selectionAlgorithm {
            case .coverage: supportedVersion = executed.version == Self.coverageToolVersion
            case .alleleCoverage: supportedVersion = executed.version == Self.alleleToolVersion
            case .legacy: supportedVersion = [Self.toolVersion, Self.coverageToolVersion, Self.alleleToolVersion].contains(executed.version)
            }
            guard supportedVersion, !executed.argv.isEmpty else {
                throw PrimalScheme3DesignError.invalidRequest("The executed tool did not report the verified PrimalScheme3-LGE custom fork identity.")
            }
            let capabilityData = executed.capabilitiesJSON
            let coverageCapabilities = request.options.selectionAlgorithm == .coverage
                ? try PrimalScheme3CoverageContract.validateCapabilities(
                    capabilityData ?? { throw PrimalScheme3DesignError.invalidRequest("Coverage capability evidence is missing from the executable probe.") }(),
                    terminalPolicy: request.options.terminalGapPolicy) : nil
            let alleleCapabilities = request.options.selectionAlgorithm == .alleleCoverage
                ? try PrimalScheme3AlleleContract.validateCapabilities(
                    capabilityData ?? { throw PrimalScheme3DesignError.invalidRequest("Allele capability evidence is missing from the executable probe.") }()) : nil
            let configURL = output.appendingPathComponent("config.json")
            let configData = try Data(contentsOf: configURL)
            guard let configuration = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
                throw PrimalScheme3DesignError.invalidRequest("Native configuration is missing or malformed.")
            }
            guard configuration["version"] as? String == executed.version else {
                throw PrimalScheme3DesignError.invalidRequest("The native configuration version does not match the executed tool identity.")
            }
            guard configuration["terminal_gap_policy"] as? String == request.options.terminalGapPolicy.rawValue,
                  configuration["discovery_backend"] as? String == request.options.terminalGapPolicy.discoveryBackend else {
                throw PrimalScheme3DesignError.invalidRequest("The custom fork's native policy or discovery backend does not match the requested policy.")
            }
            guard configuration["amplicon_size"] as? Int == request.options.ampliconSize,
                  configuration["amplicon_size_min"] as? Int == request.options.ampliconSizeMinimum,
                  configuration["amplicon_size_max"] as? Int == request.options.ampliconSizeMaximum,
                  configuration["amplicon_size_metric"] as? String == request.options.ampliconSizeMetric else {
                throw PrimalScheme3DesignError.invalidRequest("The native amplicon size bounds or size interpretation do not match the request.")
            }
            try Self.validateNativeAmpliconSpans(at: output, options: request.options)
            let effectiveWorkers = try Self.validateEffectiveWorkers(configuration: configuration,
                                                                     options: request.options)
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent("primer.bed").path),
                  FileManager.default.fileExists(atPath: output.appendingPathComponent("reference.fasta").path) else {
                throw PrimalScheme3DesignError.invalidRequest("Native primer.bed or reference.fasta output is missing.")
            }
            if let capabilities = coverageCapabilities {
                try PrimalScheme3CoverageContract.validateNativeOutput(
                    at: output, configuration: configuration, capabilities: capabilities,
                    options: request.options, inputCount: group.count, executedArgv: executed.argv)
            }
            if let capabilities = alleleCapabilities {
                try PrimalScheme3AlleleContract.validateNativeOutput(
                    at: output, configuration: configuration, capabilities: capabilities,
                    options: request.options, inputCount: group.count, executedArgv: executed.argv,
                    auditValidation: executed.auditValidationJSON,
                    auditProvenance: executed.auditProvenanceJSON,
                    auditExecutedArgv: executed.auditArgv,
                    auditExitStatus: executed.auditExitStatus)
            }
            let files = try Self.regularFiles(in: output)
            var resultPaths: [String] = []
            let replayArgv = executed.argv.map {
                $0.replacingOccurrences(of: scratch.path + "/", with: destination.path + "/")
            }
            var builder = ProvenanceRunBuilder(workflowName: "lungfish.primalscheme3.design", workflowVersion: "1",
                                               toolName: Self.toolDisplayName, toolVersion: executed.version)
                .argv(executed.argv)
                .durableReplayArgv(replayArgv)
                .reproducibleCommand(replayArgv.map(shellEscape).joined(separator: " "))
                .runtime(executed.runtime)
                .options(explicit: request.options.provenanceOptions.merging(["grouping": .string(request.grouping.rawValue)]) { _, new in new },
                         defaults: [:], resolved: ["nativeConfiguration": Self.parameter(configuration),
                         "customFork": .boolean(true), "sourceRepository": .string(Self.sourceRepository),
                         "terminalGapPolicy": .string(request.options.terminalGapPolicy.rawValue),
                         "discoveryBackend": .string(request.options.terminalGapPolicy.discoveryBackend),
                         "effectiveCoreCount": .integer(effectiveWorkers),
                         "analysisID": .string(analysisID.uuidString), "runID": .string(runID.uuidString),
                         "resultID": .string(resultID.uuidString), "inputIDs": .array(group.map { .string($0.id.uuidString) }),
                         "panelMode": .string(request.grouping == .combined ? request.options.panelMode.rawValue : "not-applicable"),
                         "mapping": .string("first"),
                         "minOverlap": request.grouping == .combined ? .string("not-applicable") : .integer(request.options.minOverlap),
                         "executableSHA256": executed.executableSHA256.map(ParameterValue.string) ?? .string("injected-test-runner"),
                         "sourceInputs": .array(group.map { .dictionary([
                            "inputID": .string($0.id.uuidString), "sourcePath": .string($0.originalURL.path),
                            "sourceSnapshotRelativePath": .string(Self.relative($0.snapshotURL, to: scratch)),
                            "consumedRelativePath": .string(Self.relative($0.alignedURL, to: scratch)),
                            "inspectionSHA256": .string($0.fingerprint),
                            "consumedSHA256": .string($0.consumedFingerprint),
                            "uracilCount": .integer($0.uracilCount),
                            "unknownBaseCount": .integer($0.unknownBaseCount),
                            "preprocessing": .string($0.preprocessing),
                            "rowMappingRelativePath": .string($0.rowMappingPath),
                            "referenceName": .string($0.referenceName)
                         ]) })])
            for input in group {
                builder = try builder.consumedInputSnapshot(Self.descriptor(input.alignedURL,
                    path: destination.appendingPathComponent(Self.relative(input.alignedURL, to: scratch)).path,
                    role: .input, origin: input.alignedURL.path))
            }
            for file in files {
                let path = Self.relative(file, to: scratch)
                artifacts.append(.init(sourceURL: file, relativePath: path, role: "nativeOutput",
                                       format: file.pathExtension.isEmpty ? "binary" : file.pathExtension))
                resultPaths.append(path)
                builder = try builder.relocatedOutput(Self.descriptor(file, path: destination.appendingPathComponent(path).path,
                                                                      role: .output, origin: file.path))
            }
            let logs = scratch.appendingPathComponent("logs/\(resultID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            for (name, bytes) in executed.runtimeEvidence.sorted(by: { $0.key < $1.key }) {
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
                    throw PrimalScheme3DesignError.invalidRequest("Invalid runtime evidence filename.")
                }
                let file = logs.appendingPathComponent(name)
                try bytes.write(to: file, options: .withoutOverwriting)
                let path = Self.relative(file, to: scratch)
                artifacts.append(.init(sourceURL: file, relativePath: path, role: "runtime", format: file.pathExtension))
                resultPaths.append(path)
                builder = try builder.relocatedOutput(Self.descriptor(file,
                    path: destination.appendingPathComponent(path).path, role: .output, origin: file.path))
            }
            for (name, contents) in [("stdout.txt", executed.stdout), ("stderr.txt", executed.stderr)] {
                let file = logs.appendingPathComponent(name)
                try Data(contents.utf8).write(to: file, options: .withoutOverwriting)
                let path = Self.relative(file, to: scratch)
                artifacts.append(.init(sourceURL: file, relativePath: path, role: "log", format: "text"))
                resultPaths.append(path)
                builder = try builder.relocatedOutput(Self.descriptor(file, path: destination.appendingPathComponent(path).path,
                                                                      role: .output, origin: file.path))
            }
            let envelope = try builder.complete(exitStatus: 0, stderr: executed.stderr,
                                                startedAt: executed.startedAt, endedAt: executed.endedAt)
            let provenance = logs.appendingPathComponent("execution.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(envelope).write(to: provenance, options: .withoutOverwriting)
            let provenancePath = Self.relative(provenance, to: scratch)
            artifacts.append(.init(sourceURL: provenance, relativePath: provenancePath, role: "toolProvenance", format: "json"))
            resultPaths.append(provenancePath)
            // LGE derives the ordering worksheet; it is not an engine-native output.
            let orderStarted = Date()
            let bedURL = output.appendingPathComponent("primer.bed")
            let orderURL = request.options.selectionAlgorithm == .alleleCoverage
                ? scratch.appendingPathComponent("derived/\(resultID.uuidString)/\(PrimalSchemeOrderSheet.filename)")
                : output.appendingPathComponent(PrimalSchemeOrderSheet.filename)
            try FileManager.default.createDirectory(at: orderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrimalSchemeOrderSheet.csv(fromBED: Data(contentsOf: bedURL))
                .write(to: orderURL, options: .withoutOverwriting)
            let orderPath = Self.relative(orderURL, to: scratch)
            let bedPath = Self.relative(bedURL, to: scratch)
            artifacts.append(.init(sourceURL: orderURL, relativePath: orderPath, role: "derived-order-sheet", format: "csv"))
            resultPaths.append(orderPath)
            var orderBuilder = ProvenanceRunBuilder(workflowName: "lungfish.primalscheme3.order-sheet", workflowVersion: "1",
                toolName: "Lungfish Primer Order Sheet", toolVersion: request.invocation.callerVersion)
                .argv(request.invocation.argv)
                .options(explicit: ["schemaVersion": .integer(PrimalSchemeOrderSheet.schemaVersion)], defaults: [:],
                    resolved: ["ordering": .string("numeric-pool-then-native-row"),
                               "sequenceOrientation": .string("native-5-prime-to-3-prime"),
                               "spreadsheetFormulaEscaping": .boolean(true),
                               "transform": .string("PrimalSchemeOrderSheet.csv(fromBED:), schema 1, applied to the checksummed stored primer.bed"),
                               "argvMeaning": .string("Exact host-process invocation; GUI launch argv alone does not replay the transformation.")])
                .runtime(request.invocation.runtimeIdentity)
            orderBuilder = try orderBuilder.consumedInputSnapshot(Self.descriptor(bedURL,
                path: destination.appendingPathComponent(bedPath).path, role: .input, origin: bedURL.path))
            orderBuilder = try orderBuilder.relocatedOutput(Self.descriptor(orderURL,
                path: destination.appendingPathComponent(orderPath).path, role: .output, origin: orderURL.path))
            let orderEnvelope = try orderBuilder.complete(exitStatus: 0, stderr: "", startedAt: orderStarted, endedAt: Date())
            let orderProvenanceURL = logs.appendingPathComponent("order-sheet.json")
            try encoder.encode(orderEnvelope).write(to: orderProvenanceURL, options: .withoutOverwriting)
            let orderProvenancePath = Self.relative(orderProvenanceURL, to: scratch)
            artifacts.append(.init(sourceURL: orderProvenanceURL, relativePath: orderProvenancePath, role: "derivedProvenance", format: "json"))
            resultPaths.append(orderProvenancePath)
            results.append(.init(id: resultID, label: request.grouping == .combined ? "Combined panel" : group[0].originalURL.deletingPathExtension().lastPathComponent,
                                 inputIDs: group.map(\.id), artifactPaths: resultPaths))
        }
        try Task.checkCancellation()
        progress?(0.95, "Publishing primer analysis and ordering worksheets")
        let bundle = try writer.write(.init(analysisID: analysisID, runID: runID, grouping: request.grouping,
            inputs: inputs.map { .init(id: $0.id, label: $0.originalURL.lastPathComponent, artifactPaths: $0.paths) },
            results: results, artifacts: artifacts, destinationURL: destination, invocation: request.invocation))
        progress?(1, "Saved PrimalScheme analysis")
        return bundle.url
        } catch {
            do {
                try Self.retainFailureArtifact(scratch: scratch, destination: destination,
                    request: request, startedAt: workflowStartedAt, error: error)
                try? FileManager.default.removeItem(at: scratch)
            } catch let retentionError {
                throw PrimalScheme3DesignError.invalidRequest(
                    "\(error.localizedDescription) Failure evidence could not be retained: \(retentionError.localizedDescription)")
            }
            throw error
        }
    }

    private static func execute(_ command: PrimalScheme3Command) async throws -> PrimalScheme3Execution {
        let executable: URL
        let prefix: URL?
        if let override = command.executableOverride { executable = override; prefix = nil }
        else if let prepared = command.managedEnvironmentURL {
            prefix = prepared
            executable = prepared.appendingPathComponent("bin/primalscheme3")
        } else {
            throw PrimalScheme3DesignError.invalidRequest("The managed PrimalScheme3 runtime was not prepared before execution.")
        }
        let environment = prefix.map { ["PATH": $0.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                                        "CONDA_PREFIX": $0.path, "PYTHONNOUSERSITE": "1",
                                        "PYTHONPATH": "", "PYTHONHOME": ""] }
        var runtimeEvidence: [String: Data] = [:]
        if let environment {
            runtimeEvidence["execution-environment.json"] = try JSONSerialization.data(
                withJSONObject: environment, options: [.prettyPrinted, .sortedKeys])
        }
        if let prefix {
            guard let spec = ManagedToolLock.bundled.packTool(packID: "pcr-primer-design", id: "primalscheme3")?.pythonRuntime else {
                throw PrimalScheme3DesignError.invalidRequest("The managed PrimalScheme3 runtime specification is missing.")
            }
            let receiptURL = ManagedPythonRuntimeReceipt.receiptURL(for: spec, environmentURL: prefix)
            let data = try Data(contentsOf: receiptURL)
            let receipt = try JSONDecoder().decode(ManagedPythonRuntimeReceipt.self, from: data)
            guard receipt.validates(spec: spec, environmentURL: prefix) else {
                throw PrimalScheme3DesignError.invalidRequest("The managed PrimalScheme3 runtime needs repair in the plugin manager.")
            }
            runtimeEvidence["managed-runtime.json"] = data
        }
        let executableHash = try ProvenanceFileHasher.sha256(of: executable)
        let native = NativeToolRunner()
        let attemptDirectory = command.workingDirectory.appendingPathComponent("execution-attempts/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: true)
        func persist(_ name: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: attemptDirectory.appendingPathComponent(name), options: .withoutOverwriting)
        }
        let runtimeIdentity = ProvenanceRuntimeIdentity(executablePath: executable.path,
            condaEnvironment: prefix == nil ? nil : "primalscheme3", condaPrefix: prefix?.path,
            pluginPack: prefix == nil ? nil : "pcr-primer-design",
            dependencySet: prefix == nil ? nil : ManagedToolLock.bundled.resolvedDependencySet)
        let encodedRuntime = try JSONEncoder().encode(runtimeIdentity)
        var retainedRuntimeEvidence: [String: Any] = [:]
        for (name, data) in runtimeEvidence {
            retainedRuntimeEvidence[name] = (try? JSONSerialization.jsonObject(with: data))
                ?? ["sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "size": data.count]
        }
        try persist("00-runtime-identity.json", [
            "executablePath": executable.path, "executableSHA256": executableHash,
            "environment": environment ?? [:],
            "runtimeIdentity": try JSONSerialization.jsonObject(with: encodedRuntime),
            "runtimeEvidence": retainedRuntimeEvidence
        ])
        let probeArguments = command.selectionAlgorithm == .legacy ? ["--version"] : ["--capabilities-json"]
        try persist("01-probe-started.json", ["status": "started", "argv": [executable.path] + probeArguments,
            "workingDirectory": command.workingDirectory.path, "startedAt": ISO8601DateFormatter().string(from: Date())])
        let probe: NativeToolResult
        do {
            probe = try await native.runProcess(executableURL: executable, arguments: probeArguments,
                workingDirectory: command.workingDirectory, environment: environment, timeout: 30)
            try persist("02-probe-completed.json", ["status": "completed", "argv": probe.arguments,
                "stdout": probe.stdout, "stderr": probe.stderr, "exitStatus": probe.exitCode])
        } catch {
            try? persist("02-probe-failed.json", ["status": "failed", "argv": [executable.path] + probeArguments,
                "stderr": error.localizedDescription])
            throw error
        }
        let capabilitiesJSON: Data?
        let executedVersion: String
        if command.selectionAlgorithm != .legacy {
            guard probe.exitCode == 0, let data = probe.stdout.data(using: .utf8) else {
                throw PrimalScheme3DesignError.invalidRequest("Coverage selection requires a verified PrimalScheme3-LGE executable. Pass --primalscheme3-path /path/to/primalscheme3.")
            }
            if command.selectionAlgorithm == .coverage {
                _ = try PrimalScheme3CoverageContract.validateCapabilities(data, terminalPolicy: command.terminalGapPolicy)
                executedVersion = Self.coverageToolVersion
            } else {
                _ = try PrimalScheme3AlleleContract.validateCapabilities(data)
                executedVersion = Self.alleleToolVersion
            }
            capabilitiesJSON = data
        } else {
            let reported = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let accepted = [Self.toolVersion, Self.coverageToolVersion, Self.alleleToolVersion]
                .first { reported == "PrimalScheme3-LGE version: \($0)" }
            guard probe.exitCode == 0, let accepted else {
                throw PrimalScheme3DesignError.invalidRequest("This adapter requires the verified PrimalScheme3-LGE custom fork lge.2 or lge.3; stock PrimalScheme3 is not interchangeable with this fork.")
            }
            guard prefix == nil || accepted == Self.toolVersion else {
                throw PrimalScheme3DesignError.invalidRequest("The managed PrimalScheme3 runtime must remain at \(Self.toolVersion).")
            }
            capabilitiesJSON = nil
            executedVersion = accepted
        }
        runtimeEvidence[command.selectionAlgorithm == .legacy ? "version-probe.json" : "capabilities-probe.json"] = try JSONSerialization.data(withJSONObject: [
            "argv": probe.arguments, "stdout": probe.stdout, "stderr": probe.stderr, "exitStatus": probe.exitCode
        ], options: [.prettyPrinted, .sortedKeys])
        if let capabilitiesJSON { runtimeEvidence["capabilities.json"] = capabilitiesJSON }
        try Task.checkCancellation()
        let start = Date()
        try persist("03-design-started.json", ["status": "started", "argv": [executable.path] + command.arguments,
            "workingDirectory": command.workingDirectory.path, "startedAt": ISO8601DateFormatter().string(from: start)])
        let result: NativeToolResult
        do {
            result = try await native.runProcess(executableURL: executable, arguments: command.arguments,
                workingDirectory: command.workingDirectory, environment: environment, timeout: 86400,
                toolName: Self.toolDisplayName)
            try persist("04-design-completed.json", ["status": "completed", "argv": result.arguments,
                "stdout": result.stdout, "stderr": result.stderr, "exitStatus": result.exitCode])
        } catch {
            try? persist("04-design-failed.json", ["status": "failed", "argv": [executable.path] + command.arguments,
                "stderr": error.localizedDescription])
            throw error
        }
        var auditValidationJSON: Data?
        var auditProvenanceJSON: Data?
        var auditArgv: [String]?
        var auditExitStatus: Int32?
        if command.selectionAlgorithm == .alleleCoverage, result.exitCode == 0 {
            guard let outputIndex = command.arguments.firstIndex(of: "--output"), outputIndex + 1 < command.arguments.count else {
                throw PrimalScheme3DesignError.invalidRequest("The native allele command has no output path to audit.")
            }
            let nativeOutput = URL(fileURLWithPath: command.arguments[outputIndex + 1])
            let auditParent = command.workingDirectory.appendingPathComponent("native-audit", isDirectory: true)
            try FileManager.default.createDirectory(at: auditParent, withIntermediateDirectories: true)
            let auditOutput = auditParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let auditArguments = ["panel-audit", "--bundle", nativeOutput.path, "--output", auditOutput.path]
            try persist("05-audit-started.json", ["status": "started", "argv": [executable.path] + auditArguments,
                "workingDirectory": command.workingDirectory.path, "startedAt": ISO8601DateFormatter().string(from: Date())])
            let audit: NativeToolResult
            do {
                audit = try await native.runProcess(executableURL: executable, arguments: auditArguments,
                    workingDirectory: command.workingDirectory, environment: environment, timeout: 86400,
                    toolName: "\(Self.toolDisplayName) panel-audit")
                try persist("06-audit-completed.json", ["status": "completed", "argv": audit.arguments,
                    "stdout": audit.stdout, "stderr": audit.stderr, "exitStatus": audit.exitCode])
            } catch {
                try? persist("06-audit-failed.json", ["status": "failed", "argv": [executable.path] + auditArguments,
                    "stderr": error.localizedDescription])
                throw error
            }
            auditArgv = audit.arguments
            auditExitStatus = audit.exitCode
            guard audit.exitCode == 0 else {
                throw PrimalScheme3DesignError.executionFailed(audit.exitCode, audit.stderr)
            }
            auditValidationJSON = try Data(contentsOf: auditOutput.appendingPathComponent("validation.json"))
            auditProvenanceJSON = try Data(contentsOf: auditOutput.appendingPathComponent("provenance.json"))
            runtimeEvidence["panel-audit-validation.json"] = auditValidationJSON
            runtimeEvidence["panel-audit-provenance.json"] = auditProvenanceJSON
            runtimeEvidence["panel-audit-execution.json"] = try JSONSerialization.data(withJSONObject: [
                "argv": audit.arguments, "stdout": audit.stdout, "stderr": audit.stderr,
                "exitStatus": audit.exitCode
            ], options: [.prettyPrinted, .sortedKeys])
        }
        guard try ProvenanceFileHasher.sha256(of: executable) == executableHash else {
            throw PrimalScheme3DesignError.invalidRequest("The executable changed during the run.")
        }
        return .init(argv: result.arguments, stdout: result.stdout, stderr: result.stderr, exitStatus: result.exitCode,
                     version: executedVersion, runtime: runtimeIdentity,
                     startedAt: start, endedAt: Date(), executableSHA256: executableHash,
                     runtimeEvidence: runtimeEvidence, capabilitiesJSON: capabilitiesJSON,
                     auditValidationJSON: auditValidationJSON, auditProvenanceJSON: auditProvenanceJSON,
                     auditArgv: auditArgv, auditExitStatus: auditExitStatus)
    }

    static func validateEffectiveWorkers(configuration: [String: Any],
                                         options: PrimalScheme3DesignOptions) throws -> Int {
        guard let workers = configuration["discovery_core_count"] as? Int else {
            throw PrimalScheme3DesignError.invalidRequest("The custom fork did not report an effective discovery worker count.")
        }
        if options.selectionAlgorithm == .alleleCoverage, options.alleleOptions.reuseDiscovery != nil {
            guard workers == 0, configuration["discovery_reused"] as? Bool == true,
                  let byMSA = configuration["discovery_workers_by_msa"] as? [String: Any], !byMSA.isEmpty,
                  byMSA.values.allSatisfy({ ($0 as? NSNumber)?.intValue == 0 }),
                  let byProfile = configuration["discovery_workers_by_target_profile"] as? [String: Any], !byProfile.isEmpty,
                  byProfile.values.allSatisfy({ value in
                      guard let profiles = value as? [String: Any], !profiles.isEmpty else { return false }
                      return profiles.values.allSatisfy { ($0 as? NSNumber)?.intValue == 0 }
                  }) else {
                throw PrimalScheme3DesignError.invalidRequest("Reused allele discovery must report zero workers consistently.")
            }
            return workers
        }
        guard (1...options.coreCount).contains(workers), configuration["discovery_reused"] as? Bool != true else {
            throw PrimalScheme3DesignError.invalidRequest("The custom fork did not report a valid effective discovery worker count.")
        }
        return workers
    }

    private static func physicalParent(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.pathComponents.contains("..") else {
            throw PrimalScheme3DesignError.invalidRequest("Unsafe destination path.")
        }
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else {
            throw PrimalScheme3DesignError.invalidRequest("The destination parent must already exist.")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func regularFiles(in url: URL) throws -> [URL] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw PrimalScheme3DesignError.invalidRequest("Symbolic-link payloads are unsupported.") }
        if values.isRegularFile == true { return [url] }
        guard values.isDirectory == true else { throw PrimalScheme3DesignError.invalidRequest("Unsupported payload file type.") }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { try regularFiles(in: $0) }
    }

    private static func copySource(_ source: URL, to destination: URL) throws {
        let files = try regularFiles(in: source)
        let directory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if directory { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        for file in files {
            try Task.checkCancellation()
            let target = directory ? destination.appendingPathComponent(relative(file, to: source)) : destination
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: target)
        }
    }

    private static func retainFailureArtifact(scratch: URL, destination: URL,
                                              request: PrimalScheme3DesignRequest,
                                              startedAt: Date, error: Error) throws {
        guard FileManager.default.fileExists(atPath: scratch.path) else { return }
        let parent = destination.deletingLastPathComponent()
        var failure = parent.appendingPathComponent(destination.lastPathComponent + ".failure", isDirectory: true)
        if FileManager.default.fileExists(atPath: failure.path) {
            failure = parent.appendingPathComponent(destination.lastPathComponent + ".failure-" + UUID().uuidString,
                                                     isDirectory: true)
        }
        let staging = parent.appendingPathComponent("." + failure.lastPathComponent + ".staging-" + UUID().uuidString,
                                                   isDirectory: true)
        try FileManager.default.copyItem(at: scratch, to: staging)
        do {
            let finishedAt = Date()
            let files = try regularFiles(in: staging).map { file -> [String: Any] in
                ["path": relative(file, to: staging), "sha256": try ProvenanceFileHasher.sha256(of: file),
                 "size": try ProvenanceFileHasher.fileSize(of: file)]
            }
            let optionsData = try JSONEncoder().encode(request.options.provenanceOptions)
            let options = try JSONSerialization.jsonObject(with: optionsData)
            let runtimeData = try JSONEncoder().encode(request.invocation.runtimeIdentity)
            let runtime = try JSONSerialization.jsonObject(with: runtimeData)
            let record: [String: Any] = [
                "schemaVersion": 1, "workflow": "lungfish.primalscheme3.design",
                "workflowVersion": "1", "status": error is CancellationError ? "cancelled" : "failed",
                "exitStatus": NSNull(), "argv": request.invocation.argv,
                "reproducibleCommand": request.invocation.argv.map(shellEscape).joined(separator: " "),
                "startedAt": ISO8601DateFormatter().string(from: startedAt),
                "endedAt": ISO8601DateFormatter().string(from: finishedAt),
                "wallTimeSeconds": finishedAt.timeIntervalSince(startedAt),
                "stderr": error.localizedDescription, "runtime": runtime, "resolvedOptions": options,
                "requestedDestination": destination.path, "failureArtifact": failure.path,
                "retainedFiles": files
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent("failure-provenance.json"), options: .withoutOverwriting)
            try FileManager.default.moveItem(at: staging, to: failure)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func descriptor(_ source: URL, path: String, role: FileRole, origin: String? = nil) throws -> ProvenanceFileDescriptor {
        return .init(path: path, checksumSHA256: try ProvenanceFileHasher.sha256(of: source),
                     fileSize: try ProvenanceFileHasher.fileSize(of: source), role: role, originPath: origin)
    }

    private static func parameter(_ value: Any) -> ParameterValue {
        if let dictionary = value as? [String: Any] { return .dictionary(dictionary.mapValues(parameter)) }
        if let array = value as? [Any] { return .array(array.map(parameter)) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        return .string("null")
    }
}
