// QualityScore.swift - Quality score handling for FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

import Foundation

// MARK: - QualityScore

/// A sequence of quality scores from a FASTQ read.
///
/// Quality scores represent the probability that each base call is incorrect.
/// Phred quality Q is related to error probability P by: Q = -10 * log10(P)
///
/// Common quality thresholds:
/// - Q10: 10% error rate (1 in 10 wrong)
/// - Q20: 1% error rate (1 in 100 wrong)
/// - Q30: 0.1% error rate (1 in 1000 wrong)
/// - Q40: 0.01% error rate (1 in 10000 wrong)
///
/// ## Example
/// ```swift
/// let scores = QualityScore(ascii: "IIIIIIIIIII", encoding: .phred33)
/// print(scores.meanQuality)  // 40.0
/// print(scores.qualityAt(0)) // 40
/// ```
public struct QualityScore: Sendable, Equatable, Hashable {

    // MARK: - Storage

    /// Raw quality values (0-93 for Phred+33)
    private let values: [UInt8]

    /// The encoding used for this quality string
    public let encoding: QualityEncoding

    // MARK: - Properties

    /// Number of quality scores
    public var count: Int { values.count }

    /// Whether the quality string is empty
    public var isEmpty: Bool { values.isEmpty }

    /// Arithmetic mean of the Phred values.
    ///
    /// This is a per-record convenience. Dataset-level "mean quality"
    /// (the Mean Q card, `fastq qc-summary`, seqkit's `AvgQual`) uses
    /// ``errorProbabilityMeanQuality`` instead, because Phred values are
    /// logarithmic and averaging them directly overstates quality.
    public var meanQuality: Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, { $0 + Int($1) })) / Double(values.count)
    }

    /// Mean quality defined through error probabilities: every Phred value
    /// becomes its error probability, those are averaged, and the average
    /// is converted back to a Phred value. This is what seqkit reports as
    /// `AvgQual` and what "mean quality" means for a read set.
    public var errorProbabilityMeanQuality: Double {
        Self.errorProbabilityMeanQuality(ofPhredValues: values)
    }

    // MARK: - Error-probability mean

    /// Error probability for each Phred value 0...93, so hot loops avoid `pow`.
    private static let errorProbabilityTable: [Double] = (0...93).map { pow(10.0, -Double($0) / 10.0) }

    /// Error probability for a Phred value (`10^(-Q/10)`), clamped to Q93.
    public static func errorProbability(forPhred q: UInt8) -> Double {
        errorProbabilityTable[Swift.min(Int(q), 93)]
    }

    /// Converts an accumulated error-probability sum back to a Phred mean.
    ///
    /// - Parameters:
    ///   - errorProbabilitySum: Sum of `10^(-Q/10)` over every scored base.
    ///   - baseCount: Number of scored bases the sum covers.
    /// - Returns: `-10 * log10(errorProbabilitySum / baseCount)`, or 0 for no bases.
    public static func phredMean(errorProbabilitySum: Double, baseCount: Int) -> Double {
        guard baseCount > 0, errorProbabilitySum > 0 else { return 0 }
        return -10.0 * log10(errorProbabilitySum / Double(baseCount))
    }

    /// Error-probability mean quality of a sequence of Phred values.
    public static func errorProbabilityMeanQuality<S: Swift.Sequence>(ofPhredValues values: S) -> Double
    where S.Element == UInt8 {
        var sum = 0.0
        var count = 0
        for q in values {
            sum += errorProbability(forPhred: q)
            count += 1
        }
        return phredMean(errorProbabilitySum: sum, baseCount: count)
    }

    /// Error-probability mean quality of an ASCII quality line.
    ///
    /// - Parameters:
    ///   - asciiQuality: The FASTQ quality line.
    ///   - encoding: Encoding of the line (defaults to Phred+33).
    public static func errorProbabilityMeanQuality(
        ofASCII asciiQuality: some StringProtocol,
        encoding: QualityEncoding = .phred33
    ) -> Double {
        let offset = Int(encoding.asciiOffset)
        return errorProbabilityMeanQuality(ofPhredValues: asciiQuality.utf8.lazy.map { byte in
            UInt8(clamping: Swift.max(0, Int(byte) - offset))
        })
    }

    /// Minimum quality value
    public var minQuality: UInt8 {
        values.min() ?? 0
    }

    /// Maximum quality value
    public var maxQuality: UInt8 {
        values.max() ?? 0
    }

    /// Median quality value
    public var medianQuality: Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Double(sorted[mid - 1] + sorted[mid]) / 2.0
        } else {
            return Double(sorted[mid])
        }
    }

    // MARK: - Initialization

    /// Creates a quality score from an ASCII quality string.
    ///
    /// - Parameters:
    ///   - ascii: ASCII-encoded quality string
    ///   - encoding: Quality encoding scheme
    public init(ascii: String, encoding: QualityEncoding = .phred33) {
        self.encoding = encoding
        self.values = ascii.utf8.map { char in
            let value = Int(char) - Int(encoding.asciiOffset)
            return UInt8(Swift.max(0, Swift.min(93, value)))
        }
    }

    /// Creates a quality score from raw quality values.
    ///
    /// - Parameters:
    ///   - values: Array of quality values (0-93)
    ///   - encoding: Quality encoding scheme (for output)
    public init(values: [UInt8], encoding: QualityEncoding = .phred33) {
        self.encoding = encoding
        self.values = values
    }

    /// Creates an empty quality score.
    public init() {
        self.encoding = .phred33
        self.values = []
    }

    // MARK: - Access

    /// Gets the quality value at an index.
    ///
    /// - Parameter index: Zero-based position
    /// - Returns: Quality value (0-93)
    public func qualityAt(_ index: Int) -> UInt8 {
        guard index >= 0 && index < values.count else { return 0 }
        return values[index]
    }

    /// Gets quality values for a range.
    ///
    /// - Parameter range: Range of positions
    /// - Returns: Quality values for the range
    public func qualitiesIn(_ range: Range<Int>) -> [UInt8] {
        let clampedRange = Swift.max(0, range.lowerBound)..<Swift.min(values.count, range.upperBound)
        return Array(values[clampedRange])
    }

    /// Gets the error probability at an index.
    ///
    /// Error probability P = 10^(-Q/10)
    ///
    /// - Parameter index: Zero-based position
    /// - Returns: Error probability (0.0 to 1.0)
    public func errorProbabilityAt(_ index: Int) -> Double {
        let q = Double(qualityAt(index))
        return pow(10.0, -q / 10.0)
    }

    // MARK: - Conversion

    /// Converts to ASCII quality string.
    ///
    /// - Parameter encoding: Target encoding (defaults to original)
    /// - Returns: ASCII quality string
    public func toAscii(encoding: QualityEncoding? = nil) -> String {
        let targetEncoding = encoding ?? self.encoding
        let chars = values.map { value -> Character in
            let ascii = Int(value) + Int(targetEncoding.asciiOffset)
            let clampedAscii = Swift.max(33, Swift.min(126, ascii))
            return Character(UnicodeScalar(clampedAscii)!)
        }
        return String(chars)
    }

    /// Converts to a different encoding.
    ///
    /// - Parameter encoding: Target encoding
    /// - Returns: New QualityScore with the target encoding
    public func convert(to encoding: QualityEncoding) -> QualityScore {
        // Values are stored normalized (0-93), just change the encoding
        QualityScore(values: values, encoding: encoding)
    }

    // MARK: - Statistics

    /// Returns counts of bases at each quality level.
    ///
    /// - Returns: Dictionary mapping quality values to counts
    public func qualityHistogram() -> [UInt8: Int] {
        var histogram: [UInt8: Int] = [:]
        for value in values {
            histogram[value, default: 0] += 1
        }
        return histogram
    }

    /// Returns the percentage of bases meeting a quality threshold.
    ///
    /// - Parameter threshold: Minimum quality value
    /// - Returns: Percentage (0.0 to 100.0)
    public func percentAbove(threshold: UInt8) -> Double {
        guard !values.isEmpty else { return 0 }
        let count = values.filter { $0 >= threshold }.count
        return Double(count) / Double(values.count) * 100.0
    }

    /// Returns Q20 percentage (bases with quality >= 20).
    public var q20Percentage: Double {
        percentAbove(threshold: 20)
    }

    /// Returns Q30 percentage (bases with quality >= 30).
    public var q30Percentage: Double {
        percentAbove(threshold: 30)
    }

    // MARK: - Trimming

    /// Finds the trim position from the 3' end based on quality.
    ///
    /// Uses a sliding window to find where quality drops below threshold.
    ///
    /// - Parameters:
    ///   - threshold: Minimum acceptable quality
    ///   - windowSize: Size of sliding window
    /// - Returns: Trim position (length of trimmed sequence)
    public func trimPosition(threshold: UInt8, windowSize: Int = 5) -> Int {
        guard values.count >= windowSize else {
            return values.filter { $0 >= threshold }.count > 0 ? values.count : 0
        }

        // Find rightmost position where window mean is above threshold
        for i in stride(from: values.count - windowSize, through: 0, by: -1) {
            let windowValues = values[i..<(i + windowSize)]
            let mean = Double(windowValues.reduce(0, { $0 + Int($1) })) / Double(windowSize)
            if mean >= Double(threshold) {
                return i + windowSize
            }
        }

        return 0
    }
}

// MARK: - Collection Conformance

extension QualityScore: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { values.count }

    public subscript(position: Int) -> UInt8 {
        values[position]
    }
}

// MARK: - CustomStringConvertible

extension QualityScore: CustomStringConvertible {
    public var description: String {
        "QualityScore(count: \(count), mean: \(String(format: "%.1f", meanQuality)), Q30: \(String(format: "%.1f", q30Percentage))%)"
    }
}
