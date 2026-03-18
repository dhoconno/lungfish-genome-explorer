// OperationChain.swift - Type-safe operation chain validation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Operation Output Shape

/// Describes what an operation produces.
public struct OperationOutput: Sendable, Equatable {
    /// The data format after the operation.
    public let format: DataFormat
    /// Whether paired-end structure is preserved.
    public let pairing: PairingState

    public enum DataFormat: String, Sendable, Codable {
        case fastq
        case fasta
    }

    public enum PairingState: String, Sendable, Codable {
        /// R1/R2 interleaved in one file.
        case interleaved
        /// Separate R1 and R2 files.
        case splitPaired
        /// Overlapping pairs merged into singles.
        case merged
        /// Unpaired or unknown.
        case single
        /// Multiple read types (merged + unmerged).
        case mixed
    }
}

// MARK: - Operation Input Requirements

/// Describes what an operation requires as input.
public struct OperationInput: Sendable, Equatable {
    /// Accepted data formats.
    public let acceptedFormats: Set<OperationOutput.DataFormat>
    /// Required pairing states. Nil means any pairing is accepted.
    public let requiredPairing: Set<OperationOutput.PairingState>?

    public init(
        acceptedFormats: Set<OperationOutput.DataFormat>,
        requiredPairing: Set<OperationOutput.PairingState>? = nil
    ) {
        self.acceptedFormats = acceptedFormats
        self.requiredPairing = requiredPairing
    }
}

// MARK: - Operation Contract

/// Maps each operation kind to its input requirements and output shape.
///
/// Used by `ProcessingRecipe.validate()` to check that each step's output
/// is compatible with the next step's input, preventing invalid operation
/// orderings at recipe-creation time rather than at execution time.
public enum OperationContract {

    /// Returns the input requirements for an operation kind.
    public static func input(for kind: FASTQDerivativeOperationKind) -> OperationInput {
        switch kind {
        case .pairedEndMerge:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: [.interleaved]
            )
        case .pairedEndRepair:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: [.interleaved, .splitPaired]
            )
        case .qualityTrim, .adapterTrim, .primerRemoval:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .deduplicate, .fixedTrim:
            return OperationInput(
                acceptedFormats: [.fastq, .fasta],
                requiredPairing: nil
            )
        case .contaminantFilter, .errorCorrection:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        case .interleaveReformat:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        case .demultiplex:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        case .orient:
            return OperationInput(
                acceptedFormats: [.fastq, .fasta],
                requiredPairing: nil
            )
        case .sequencePresenceFilter:
            return OperationInput(
                acceptedFormats: [.fastq, .fasta],
                requiredPairing: nil
            )
        case .humanReadScrub:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        }
    }

    /// Returns the output shape for an operation kind given the input pairing.
    public static func output(
        for kind: FASTQDerivativeOperationKind,
        inputPairing: OperationOutput.PairingState
    ) -> OperationOutput {
        switch kind {
        case .pairedEndMerge:
            return OperationOutput(format: .fastq, pairing: .mixed)
        case .pairedEndRepair:
            return OperationOutput(format: .fastq, pairing: .interleaved)
        case .interleaveReformat:
            let newPairing: OperationOutput.PairingState =
                inputPairing == .interleaved ? .splitPaired : .interleaved
            return OperationOutput(format: .fastq, pairing: newPairing)
        case .demultiplex:
            return OperationOutput(format: .fastq, pairing: .single)
        default:
            // Most operations preserve the input pairing and format
            return OperationOutput(format: .fastq, pairing: inputPairing)
        }
    }

    // MARK: - Ordering Validation

    /// Ordering issue severity.
    public enum OrderingSeverity: Sendable {
        /// The ordering is biologically invalid — block execution.
        case error
        /// The ordering is suboptimal but technically valid — warn the user.
        case warning
    }

    /// An ordering issue between two steps.
    public struct OrderingIssue: Sendable {
        public let severity: OrderingSeverity
        public let stepIndex: Int
        public let message: String
    }

    /// Checks for biologically invalid or suboptimal step orderings.
    ///
    /// Rules from bioinformatics expert analysis:
    /// - ERROR: pairedEndMerge before adapterTrim
    /// - WARNING: qualityTrim before primerRemoval
    /// - WARNING: adapterTrim before primerRemoval
    public static func checkOrdering(_ steps: [FASTQDerivativeOperation]) -> [OrderingIssue] {
        var issues: [OrderingIssue] = []

        // Build index of first occurrence of each kind
        var firstIndex: [FASTQDerivativeOperationKind: Int] = [:]
        for (i, step) in steps.enumerated() {
            if firstIndex[step.kind] == nil {
                firstIndex[step.kind] = i
            }
        }

        // ERROR: pairedEndMerge before adapterTrim
        if let mergeIdx = firstIndex[.pairedEndMerge],
           let adapterIdx = firstIndex[.adapterTrim],
           mergeIdx < adapterIdx {
            issues.append(OrderingIssue(
                severity: .error,
                stepIndex: mergeIdx,
                message: "Paired-end merge must come after adapter trimming — residual adapters prevent correct overlap detection."
            ))
        }

        // ERROR: pairedEndMerge before qualityTrim
        if let mergeIdx = firstIndex[.pairedEndMerge],
           let qualIdx = firstIndex[.qualityTrim],
           mergeIdx < qualIdx {
            issues.append(OrderingIssue(
                severity: .error,
                stepIndex: mergeIdx,
                message: "Paired-end merge must come after quality trimming — low-quality tails reduce merge accuracy."
            ))
        }

        // WARNING: qualityTrim before primerRemoval
        if let qualIdx = firstIndex[.qualityTrim],
           let primerIdx = firstIndex[.primerRemoval],
           qualIdx < primerIdx {
            issues.append(OrderingIssue(
                severity: .warning,
                stepIndex: qualIdx,
                message: "Quality trimming before primer removal may partially remove primer bases, leaving unrecognizable fragments."
            ))
        }

        // WARNING: adapterTrim before primerRemoval
        if let adapterIdx = firstIndex[.adapterTrim],
           let primerIdx = firstIndex[.primerRemoval],
           adapterIdx < primerIdx {
            issues.append(OrderingIssue(
                severity: .warning,
                stepIndex: adapterIdx,
                message: "Adapter trimming before primer removal may interfere with primer recognition."
            ))
        }

        return issues
    }
}

// MARK: - ProcessingRecipe Validation

extension ProcessingRecipe {

    /// Validation error describing why a recipe chain is invalid.
    public enum ValidationError: Error, LocalizedError, Sendable, Equatable {
        case incompatibleFormat(stepIndex: Int, expected: Set<OperationOutput.DataFormat>, got: OperationOutput.DataFormat)
        case incompatiblePairing(stepIndex: Int, expected: Set<OperationOutput.PairingState>, got: OperationOutput.PairingState)
        case demultiplexNotTerminal(stepIndex: Int)
        case orderingError(stepIndex: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .incompatibleFormat(let i, let expected, let got):
                let expectedStr = expected.map(\.rawValue).sorted().joined(separator: ", ")
                return "Step \(i + 1) requires \(expectedStr) format but receives \(got.rawValue)."
            case .incompatiblePairing(let i, let expected, let got):
                let expectedStr = expected.map(\.rawValue).sorted().joined(separator: ", ")
                return "Step \(i + 1) requires \(expectedStr) pairing but receives \(got.rawValue)."
            case .demultiplexNotTerminal(let i):
                return "Demultiplex at step \(i + 1) must be the last step in a recipe."
            case .orderingError(let i, let message):
                return "Step \(i + 1): \(message)"
            }
        }
    }

    /// Validation warning for suboptimal but technically valid orderings.
    public struct ValidationWarning: Sendable, Equatable {
        public let stepIndex: Int
        public let message: String
    }

    /// Result of recipe validation.
    public struct ValidationResult: Sendable {
        /// First blocking error, or nil if the recipe is valid.
        public let error: ValidationError?
        /// Non-blocking warnings about suboptimal orderings.
        public let warnings: [ValidationWarning]

        /// Whether the recipe passes validation (no errors).
        public var isValid: Bool { error == nil }
    }

    /// Validates that each step's output is compatible with the next step's input.
    ///
    /// - Parameters:
    ///   - inputFormat: The format of the input data (default: `.fastq`).
    ///   - inputPairing: The pairing state of the input data (default: `.single`).
    /// - Returns: A `ValidationResult` with the first error (if any) and all warnings.
    public func validate(
        inputFormat: OperationOutput.DataFormat = .fastq,
        inputPairing: OperationOutput.PairingState = .single
    ) -> ValidationResult {
        var currentFormat = inputFormat
        var currentPairing = inputPairing

        // Check ordering issues first
        let orderingIssues = OperationContract.checkOrdering(steps)
        var warnings: [ValidationWarning] = []

        for issue in orderingIssues {
            switch issue.severity {
            case .error:
                return ValidationResult(
                    error: .orderingError(stepIndex: issue.stepIndex, message: issue.message),
                    warnings: warnings
                )
            case .warning:
                warnings.append(ValidationWarning(stepIndex: issue.stepIndex, message: issue.message))
            }
        }

        // Check format/pairing compatibility
        for (index, step) in steps.enumerated() {
            let input = OperationContract.input(for: step.kind)

            // Check format compatibility
            if !input.acceptedFormats.contains(currentFormat) {
                return ValidationResult(
                    error: .incompatibleFormat(
                        stepIndex: index,
                        expected: input.acceptedFormats,
                        got: currentFormat
                    ),
                    warnings: warnings
                )
            }

            // Check pairing compatibility
            if let requiredPairing = input.requiredPairing,
               !requiredPairing.contains(currentPairing) {
                return ValidationResult(
                    error: .incompatiblePairing(
                        stepIndex: index,
                        expected: requiredPairing,
                        got: currentPairing
                    ),
                    warnings: warnings
                )
            }

            // Demux must be terminal
            if step.kind == .demultiplex && index < steps.count - 1 {
                return ValidationResult(
                    error: .demultiplexNotTerminal(stepIndex: index),
                    warnings: warnings
                )
            }

            // Compute output for next step
            let output = OperationContract.output(for: step.kind, inputPairing: currentPairing)
            currentFormat = output.format
            currentPairing = output.pairing
        }

        return ValidationResult(error: nil, warnings: warnings)
    }
}
