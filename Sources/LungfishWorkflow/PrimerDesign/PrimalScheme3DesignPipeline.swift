import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct PrimalScheme3DesignPipeline: Sendable {
    public static let toolVersion = "3.3.0+lge.2"
    public static let coverageToolVersion = "3.3.0+lge.3"
    public static let alleleToolVersion = "3.3.0+lge.4"
    public static let managedToolVersion = "3.3.0+lge.5"
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
        let observer = NativeProcessObservation.onEvent
        let worker = Task.detached(priority: .userInitiated) {
            try await NativeProcessObservation.$onEvent.withValue(observer) {
                try await runOffMain(request: request, progress: progress)
            }
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
        try options.legacySalvageOptions.validate(selectionAlgorithm: options.selectionAlgorithm, grouping: grouping, panelMode: options.panelMode, strictCutoff: options.dimerScore)
        try options.gapExpansionOptions.validate(hasParent: options.gapCompletionParent != nil)
        if options.legacySalvageOptions.mode == .bounded && options.panelMode == .entropy {
            throw PrimalScheme3DesignError.invalidRequest("Legacy salvage requires an equal panel mode.")
        }
        if options.legacySalvageOptions.mode == .bounded && (options.maxAmplicons != nil || options.maxAmpliconsPerMSA != nil) {
            throw PrimalScheme3DesignError.invalidRequest("Legacy salvage requires an uncapped strict panel; max amplicon limits are incompatible.")
        }
        if options.gapCompletionParent != nil && options.legacySalvageOptions.mode == .bounded {
            throw PrimalScheme3DesignError.invalidRequest("Legacy salvage and gap completion parent are incompatible recovery modes.")
        }
        if options.gapCompletionParent != nil {
            guard options.selectionAlgorithm == .legacy, grouping == .combined,
                  options.panelMode == .equal, options.terminalGapPolicy == .legacy,
                  options.minOverlap == 10, !options.backtrack, !options.ignoreN,
                  options.maxAmplicons == nil, options.maxAmpliconsPerMSA == nil else {
                throw PrimalScheme3DesignError.invalidRequest("Gap completion requires legacy selection, a combined equal panel, first mapping, legacy terminal policy, and no imported or bounded legacy-only panel controls.")
            }
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
                     "--mispriming-product-size", String(options.misprimingProductSize)]
            if options.selectionAlgorithm == .coverage {
                args += ["--optimizer-starts", String(options.optimizerStarts),
                         "--optimizer-repair-rounds", String(options.optimizerRepairRounds),
                         "--optimizer-time-limit", String(options.optimizerTimeLimit)]
            } else {
                if let value = options.requestedOptimizerStarts {
                    args += ["--optimizer-starts", String(value)]
                }
                if let value = options.requestedOptimizerRepairRounds {
                    args += ["--optimizer-repair-rounds", String(value)]
                }
                if let value = options.requestedOptimizerTimeLimit {
                    args += ["--optimizer-time-limit", String(value)]
                }
            }
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
        if options.selectionAlgorithm == .legacy {
            options.legacySalvageOptions.appendRequestedArguments(to: &args)
            if let parent = options.gapCompletionParent {
                args += ["--gap-completion-parent", try PrimalScheme3ParentResolver.resolve(parent).path]
                options.gapExpansionOptions.appendRequestedArguments(to: &args)
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
        let workflowClock = ProvenanceRunClock()
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(
            ".primalscheme3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
        let effectiveParent: URL?
        let savedParentInputs: [PrimalScheme3ParentResolver.SavedInput]?
        if let parent = request.options.gapCompletionParent {
            let resolved = try PrimalScheme3ParentResolver.resolve(parent)
            savedParentInputs = try PrimalScheme3ParentResolver.savedInputs(parent: parent, native: resolved)
            let snapshot = scratch.appendingPathComponent("parent-input", isDirectory: true)
            try Self.copySource(resolved, to: snapshot)
            // Keep the identity evidence used to rehydrate saved GUI inputs.
            // Native files remain untouched; this wrapper-owned folder is not a pool.
            for saved in savedParentInputs ?? [] {
                for (path, source) in saved.evidenceFiles {
                    let target = snapshot.appendingPathComponent("analysis-evidence").appendingPathComponent(path)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: source, to: target)
                    }
                    guard try ProvenanceFileHasher.sha256(of: target) == ProvenanceFileHasher.sha256(of: source) else {
                        throw PrimalScheme3DesignError.invalidRequest("Parent identity evidence changed while being snapshotted.")
                    }
                }
            }
            effectiveParent = snapshot
        } else { effectiveParent = nil; savedParentInputs = nil }
        let executionOptions = request.options.replacingGapCompletionParent(effectiveParent)
        var artifacts: [PrimerAnalysisSourceArtifact] = []
        var inputs: [Input] = []
        var matchedParentInputs = Set<UUID>()
        var parentOrderByInput: [UUID: Int] = [:]
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
            let savedInput: PrimalScheme3ParentResolver.SavedInput?
            if let savedParentInputs {
                let matches = savedParentInputs.enumerated().filter { $0.element.matches(rows) }
                guard matches.count == 1, let match = matches.first,
                      matchedParentInputs.insert(match.element.id).inserted else {
                    throw PrimalScheme3DesignError.invalidRequest("Each selected MSA must uniquely match all source rows of one parent input, including non-reference alleles.")
                }
                savedInput = match.element
                parentOrderByInput[id] = match.offset
            } else { savedInput = nil }
            let preservesAmbiguity = savedInput?.preservesAmbiguity
                ?? (request.options.selectionAlgorithm == .alleleCoverage
                    || request.options.gapCompletionParent != nil
                    || request.options.legacySalvageOptions.mode == .bounded)
            let normalized = Primer3InputLoader.normalizeForPrimalScheme(
                rows, ambiguityPolicy: preservesAmbiguity ? .preserve : .missingCoverage)
            // Use the parent's exact consumed sequence bytes while retaining the
            // source titles for the new row map and viewer.
            let normalizedRows = savedInput.map { saved in
                zip(rows, saved.consumedRows).map { Primer3AlignedRow(title: $0.title, sequence: $1.sequence) }
            } ?? normalized.rows
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
            let normalizedNames = savedInput?.consumedRows.map(\.title)
                ?? (request.options.gapCompletionParent != nil
                    ? normalizedRows.map(\.title)
                    : normalizedRows.indices.map { "input_\(id.uuidString.replacingOccurrences(of: "-", with: ""))_row_\($0)" })
            guard normalizedNames.count == normalizedRows.count,
                  Set(normalizedNames).count == normalizedNames.count,
                  normalizedNames.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }) else {
                throw PrimalScheme3DesignError.invalidRequest("Gap-completion inputs must have unique nonempty FASTA titles matching the native parent targets.")
            }
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
        if let savedParentInputs {
            guard matchedParentInputs.count == savedParentInputs.count else {
                throw PrimalScheme3DesignError.invalidRequest("Select every MSA used by the chosen parent result.")
            }
            inputs.sort { parentOrderByInput[$0.id, default: 0] < parentOrderByInput[$1.id, default: 0] }
        }
        let analysisID = UUID(), runID = UUID()
        let groups = request.grouping == .combined ? [inputs] : inputs.map { [$0] }
        var results: [PrimerAnalysisResult] = []
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            let resultID = UUID()
            let output = scratch.appendingPathComponent("native/\(resultID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let args = try Self.arguments(inputs: group.map(\.alignedURL), output: output,
                                          grouping: request.grouping, options: executionOptions)
            let executionRequests = scratch.appendingPathComponent("execution-attempts", isDirectory: true)
            try FileManager.default.createDirectory(at: executionRequests, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "status": "started", "argv": [request.executableURL?.path ?? "managed:primalscheme3"] + args,
                "workingDirectory": scratch.path, "startedAt": ISO8601DateFormatter().string(from: Date())
            ], options: [.prettyPrinted, .sortedKeys]).write(
                to: executionRequests.appendingPathComponent("\(resultID.uuidString)-design-request.json"),
                options: .withoutOverwriting)
            let executed = try await PrimalScheme3NativeProgress.observing(run: index, of: groups.count, inputCount: group.count, progress: progress) {
                try await runner(.init(executableOverride: request.executableURL, arguments: args, workingDirectory: scratch,
                                       selectionAlgorithm: executionOptions.selectionAlgorithm,
                                       terminalGapPolicy: executionOptions.terminalGapPolicy,
                                       managedEnvironmentURL: runtimeLease?.environmentURL))
            }
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
            case .legacy: supportedVersion = [Self.toolVersion, Self.coverageToolVersion, Self.alleleToolVersion, Self.managedToolVersion].contains(executed.version)
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
                    capabilityData ?? { throw PrimalScheme3DesignError.invalidRequest("Allele capability evidence is missing from the executable probe.") }(),
                    requestedSearchEffort: request.options.alleleOptions.requestedSearchEffort,
                    requestedPhaseScheduling: request.options.alleleOptions.requestedPhaseScheduling,
                    requestedIntendedProductPolicy: request.options.alleleOptions.requestedIntendedProductPolicy,
                    requestedSecondaryProductPolicy: request.options.alleleOptions.requestedOptionNames.contains("secondaryProductPolicy")
                        ? request.options.alleleOptions.secondaryProductPolicy : nil) : nil
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
            try PrimalScheme3RecoveryContract.validate(at: output, options: request.options, configuration: configuration)
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
            if let effectiveParent {
                for file in try Self.regularFiles(in: effectiveParent) {
                    let path = Self.relative(file, to: scratch)
                    artifacts.append(.init(sourceURL: file, relativePath: path, role: "parentSnapshot",
                                           format: file.pathExtension.isEmpty ? "binary" : file.pathExtension))
                    resultPaths.append(path)
                    builder = try builder.relocatedOutput(Self.descriptor(file,
                        path: destination.appendingPathComponent(path).path, role: .output, origin: file.path))
                }
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
            if request.options.selectionAlgorithm == .alleleCoverage {
                let auditValidationURL = logs.appendingPathComponent("panel-audit-validation.json")
                let bridgeInputs = group.map { input -> PrimalScheme3AlleleLabelBridge.Input in
                    let metadata = input.snapshotURL.appendingPathComponent("metadata/source-row-map.json")
                    return .init(id: input.id,
                        rowMappingURL: scratch.appendingPathComponent(input.rowMappingPath),
                        sourceMetadataURL: FileManager.default.fileExists(atPath: metadata.path) ? metadata : nil)
                }
                if let publication = try PrimalScheme3AlleleLabelBridge.publishIfAdvertised(
                    nativeOutputURL: output, inputs: bridgeInputs, resultID: resultID,
                    scratchRootURL: scratch, publishedRootURL: destination,
                    invocation: request.invocation, auditValidation: executed.auditValidationJSON,
                    auditValidationURL: FileManager.default.fileExists(atPath: auditValidationURL.path)
                        ? auditValidationURL : nil) {
                    artifacts.append(contentsOf: publication.artifacts)
                    resultPaths.append(contentsOf: publication.resultArtifactPaths)
                }
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
            let orderClock = ProvenanceRunClock()
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
            let orderEnvelope = try orderBuilder.complete(exitStatus: 0, stderr: "", startedAt: orderClock.startedAt, endedAt: orderClock.now)
            let orderProvenanceURL = logs.appendingPathComponent("order-sheet.json")
            try encoder.encode(orderEnvelope).write(to: orderProvenanceURL, options: .withoutOverwriting)
            let orderProvenancePath = Self.relative(orderProvenanceURL, to: scratch)
            artifacts.append(.init(sourceURL: orderProvenanceURL, relativePath: orderProvenancePath, role: "derivedProvenance", format: "json"))
            resultPaths.append(orderProvenancePath)
            results.append(.init(id: resultID, label: request.options.gapCompletionParent != nil ? "Follow-up scheme (separate PCRs)" : (request.grouping == .combined ? "Combined panel" : group[0].originalURL.deletingPathExtension().lastPathComponent),
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
                    request: request, runClock: workflowClock, error: error)
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
                let requestedScheduling: PrimalScheme3PhaseScheduling?
                if let index = command.arguments.firstIndex(of: "--phase-scheduling"),
                   index + 1 < command.arguments.count {
                    guard let value = PrimalScheme3PhaseScheduling(rawValue: command.arguments[index + 1]) else {
                        throw PrimalScheme3DesignError.invalidRequest("Phase scheduling must be serial or reserved.")
                    }
                    requestedScheduling = value
                } else {
                    requestedScheduling = nil
                }
                let requestedIntendedPolicy: PrimalScheme3IntendedProductPolicy?
                if let index = command.arguments.firstIndex(of: "--intended-product-policy"),
                   index + 1 < command.arguments.count {
                    guard let value = PrimalScheme3IntendedProductPolicy(rawValue: command.arguments[index + 1]) else {
                        throw PrimalScheme3DesignError.invalidRequest(
                            "Intended product policy must be exact-supported or concrete-designated-sites.")
                    }
                    requestedIntendedPolicy = value
                } else {
                    requestedIntendedPolicy = nil
                }
                let requestedSecondaryPolicy: PrimalScheme3SecondaryProductPolicy?
                if let index = command.arguments.firstIndex(of: "--secondary-product-policy"),
                   index + 1 < command.arguments.count {
                    guard let value = PrimalScheme3SecondaryProductPolicy(rawValue: command.arguments[index + 1]) else {
                        throw PrimalScheme3DesignError.invalidRequest(
                            "Secondary product policy is outside the supported lge.4 contract.")
                    }
                    requestedSecondaryPolicy = value
                } else {
                    requestedSecondaryPolicy = nil
                }
                let requestedSearchEffort: PrimalScheme3SearchEffort?
                if let index = command.arguments.firstIndex(of: "--search-effort"),
                   index + 1 < command.arguments.count {
                    guard let value = PrimalScheme3SearchEffort(rawValue: command.arguments[index + 1]) else {
                        throw PrimalScheme3DesignError.invalidRequest(
                            "Search effort is outside the supported lge.4 contract.")
                    }
                    requestedSearchEffort = value
                } else {
                    requestedSearchEffort = nil
                }
                _ = try PrimalScheme3AlleleContract.validateCapabilities(
                    data, requestedSearchEffort: requestedSearchEffort,
                    requestedPhaseScheduling: requestedScheduling,
                    requestedIntendedProductPolicy: requestedIntendedPolicy,
                    requestedSecondaryProductPolicy: requestedSecondaryPolicy)
                executedVersion = Self.alleleToolVersion
            }
            capabilitiesJSON = data
        } else {
            let reported = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let accepted = [Self.toolVersion, Self.coverageToolVersion, Self.alleleToolVersion, Self.managedToolVersion]
                .first { reported == "PrimalScheme3-LGE version: \($0)" }
            guard probe.exitCode == 0, let accepted else {
                throw PrimalScheme3DesignError.invalidRequest("This adapter requires the verified PrimalScheme3-LGE custom fork lge.2, lge.3, lge.4, or lge.5; stock PrimalScheme3 is not interchangeable with this fork.")
            }
            guard prefix == nil || [Self.toolVersion, Self.managedToolVersion].contains(accepted) else {
                throw PrimalScheme3DesignError.invalidRequest("The managed PrimalScheme3 runtime must remain at \(Self.toolVersion) or \(Self.managedToolVersion).")
            }
            capabilitiesJSON = nil
            executedVersion = accepted
            let recoveryFlags = ["--legacy-salvage", "--legacy-salvage-threshold", "--legacy-salvage-floor",
                                 "--legacy-salvage-max-edges-per-pool", "--legacy-salvage-max-incident-species-per-pool",
                                 "--legacy-salvage-min-reference-gain", "--legacy-salvage-max-candidate-evaluations",
                                 "--gap-completion-parent", "--gap-expansion", "--gap-expansion-max-anchors-per-msa",
                                 "--gap-expansion-max-pairs-per-msa"]
            if command.arguments.contains(where: { recoveryFlags.contains($0) }) {
                let capabilities = try await native.runProcess(executableURL: executable, arguments: ["--capabilities-json"],
                    workingDirectory: command.workingDirectory, environment: environment, timeout: 30)
                let capabilityObject = (try? JSONSerialization.jsonObject(with: Data(capabilities.stdout.utf8))) as? [String: Any]
                let capabilityVersion = capabilityObject?["toolVersion"] as? String
                let source = capabilityObject?["source"] as? [String: Any]
                let runtime = capabilityObject?["runtime"] as? [String: Any]
                let digest = source?["sourceDigest"] as? String ?? ""
                let runtimeKeys = ["pythonVersion", "pythonExecutable", "pythonPrefix", "platform", "machine"]
                guard capabilities.exitCode == 0, capabilityVersion == accepted,
                      [Self.alleleToolVersion, Self.managedToolVersion].contains(capabilityVersion),
                      capabilityObject?["schemaVersion"] as? String == "primalscheme3.capabilities/v1",
                      capabilityObject?["tool"] as? String == "primalscheme3",
                      digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
                      source?["files"] is [[String: Any]],
                      runtimeKeys.allSatisfy({ (runtime?[$0] as? String)?.isEmpty == false }),
                      runtime?["declaredRuntimeDependencies"] is [[String: Any]],
                      runtime?["nativeKernels"] is [[String: Any]] else {
                    throw PrimalScheme3DesignError.invalidRequest("Recovery modes require a native lge.4 or lge.5 capabilities probe with source/runtime identity.")
                }
                runtimeEvidence["recovery-capabilities-probe.json"] = try JSONSerialization.data(withJSONObject: [
                    "argv": capabilities.arguments, "stdout": capabilities.stdout, "stderr": capabilities.stderr,
                    "exitStatus": capabilities.exitCode
                ], options: [.prettyPrinted, .sortedKeys])
                var helpEnvironment = environment ?? [:]
                helpEnvironment["COLUMNS"] = "240"; helpEnvironment["TERM"] = "dumb"; helpEnvironment["NO_COLOR"] = "1"
                let help = try await native.runProcess(executableURL: executable, arguments: ["panel-create", "--help"],
                    workingDirectory: command.workingDirectory, environment: helpEnvironment, timeout: 30)
                let missing = recoveryFlags.filter { command.arguments.contains($0) && !help.stdout.contains($0) }
                runtimeEvidence["recovery-help-probe.json"] = try JSONSerialization.data(withJSONObject: [
                    "argv": help.arguments, "stdout": help.stdout, "stderr": help.stderr, "exitStatus": help.exitCode,
                    "requiredFlags": command.arguments.filter { recoveryFlags.contains($0) }, "missingFlags": missing
                ], options: [.prettyPrinted, .sortedKeys])
                guard help.exitCode == 0, missing.isEmpty else {
                    throw PrimalScheme3DesignError.invalidRequest("The verified PrimalScheme3 executable is missing required lge.4/lge.5 recovery flags: " + missing.joined(separator: ", "))
                }
            }
        }
        runtimeEvidence[command.selectionAlgorithm == .legacy ? "version-probe.json" : "capabilities-probe.json"] = try JSONSerialization.data(withJSONObject: [
            "argv": probe.arguments, "stdout": probe.stdout, "stderr": probe.stderr, "exitStatus": probe.exitCode
        ], options: [.prettyPrinted, .sortedKeys])
        if let capabilitiesJSON { runtimeEvidence["capabilities.json"] = capabilitiesJSON }
        try Task.checkCancellation()
        let executionClock = ProvenanceRunClock()
        try persist("03-design-started.json", ["status": "started", "argv": [executable.path] + command.arguments,
            "workingDirectory": command.workingDirectory.path, "startedAt": ISO8601DateFormatter().string(from: executionClock.startedAt)])
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
                     startedAt: executionClock.startedAt, endedAt: executionClock.now, executableSHA256: executableHash,
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
                                              runClock: ProvenanceRunClock, error: Error) throws {
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
            let finishedAt = runClock.now
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
                "startedAt": ISO8601DateFormatter().string(from: runClock.startedAt),
                "endedAt": ISO8601DateFormatter().string(from: finishedAt),
                "wallTimeSeconds": finishedAt.timeIntervalSince(runClock.startedAt),
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
