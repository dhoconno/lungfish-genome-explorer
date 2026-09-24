import Foundation

/// Shared anchored barcode assignment for the Fluidigm ONT read layout
/// `CS1 + insert + rc(CS2) + spacer + barcode`.
///
/// GEN-01 (2026-09-23 best-practices audit): both the Swift materializers
/// (`ONTFluidigmAmpliconMaterializer`, `ONTFluidigmSampleMaterializer`) and
/// the embedded Python demux filter used a free `regex.search` /
/// leftmost-two-bit-code scan for the barcode sequence *anywhere* in the
/// read, including inside the MHC amplicon insert. Several MCM DRB alleles
/// contain a Fluidigm barcode as a 10-mer substring, so reads carrying that
/// allele were silently reassigned to whichever sample owned that barcode,
/// even though the read's *real* barcode (at the 3' end, after CS2) may
/// have named a different sample or no sample at all.
///
/// The fix: search for the barcode only in the short window immediately
/// following the anchor (the reverse-complemented CS2 tag), not the whole
/// read. A read is assigned only when exactly one sample's barcode matches
/// inside that window; zero or multiple matches leave the read unassigned
/// with a reason, instead of leftmost-wins.
enum ONTFluidigmAnchoredBarcodeAssigner {
    /// Reason a read could not be assigned to exactly one sample.
    enum UnassignedReason: String, Sendable, Equatable, Error {
        /// Neither CS1 nor rc(CS2) could be located, so there is no anchor
        /// to search a barcode window from.
        case noAnchor = "no_anchor"
        /// The anchor was found but no barcode matched inside the window
        /// that follows it.
        case noBarcodeInWindow = "no_barcode_in_window"
        /// More than one sample's barcode matched inside the window (for
        /// example because two barcodes share a suffix/prefix of the
        /// anchor-adjacent window). The read is ambiguous, not assigned to
        /// whichever barcode was tried first.
        case ambiguousBarcodeInWindow = "ambiguous_barcode_in_window"
    }

    struct Assignment: Sendable, Equatable {
        let sampleID: String
        let barcode: String
        let windowStart: Int
    }

    /// Default trailing spacer between the anchor and the barcode, matching
    /// the shipped Fluidigm layout (`rc(CS2) + NN + barcode`, `NN` typically
    /// 0-2bp). Kept generous (8bp) per GEN-01's recommendation to tolerate
    /// spacer-length variation without reopening the whole read to search.
    static let defaultWindowLength = 8

    /// Attempts anchored assignment against one read, already restored to
    /// the sequencing (forward, CS1-first) orientation by the caller.
    ///
    /// - Parameters:
    ///   - bases: the read sequence, forward-oriented, as ASCII bytes.
    ///   - forwardPrimer: CS1 (searched at the 5' end).
    ///   - reversePrimer: CS2 (searched as its reverse complement, which is
    ///     where it appears in the forward-oriented read).
    ///   - anchorMismatches: mismatches tolerated when locating the anchor.
    ///   - windowLength: bases searched after the anchor for a barcode.
    ///   - barcodes: sample ID -> barcode (forward strand as sequenced).
    /// - Returns: `.success` with the unique matching sample, or `.failure`
    ///   with a reason. Never silently picks a leftmost/first candidate.
    static func assign(
        bases: [UInt8],
        forwardPrimer: [UInt8],
        reversePrimer: [UInt8],
        anchorMismatches: Int = 2,
        windowLength: Int = defaultWindowLength,
        barcodes: [(sampleID: String, barcode: [UInt8])]
    ) -> Result<Assignment, UnassignedReason> {
        let reversePrimerRC = reverseComplementBytes(reversePrimer)

        // Prefer the anchor closest to the barcode: rc(CS2) sits immediately
        // before the spacer+barcode in the shipped layout. Fall back to CS1
        // only if rc(CS2) cannot be located (e.g. a truncated 3' end), by
        // searching the window that starts right after the insert would be
        // expected to end -- but without insert-length knowledge that is not
        // reliable, so CS1-only reads with no locatable CS2 are left
        // unassigned (`.noAnchor`) rather than guessed at.
        guard let cs2End = firstApproximateMatchEnd(
            pattern: reversePrimerRC,
            in: bases,
            startAt: 0,
            maxMismatches: anchorMismatches
        ) else {
            return .failure(.noAnchor)
        }

        let windowStart = cs2End
        let longestBarcode = barcodes.map(\.barcode.count).max() ?? 0
        // The window must be long enough to contain a full barcode that
        // starts anywhere within `windowLength` bases of the anchor.
        let windowEnd = min(bases.count, windowStart + windowLength + longestBarcode)
        guard windowStart < windowEnd else {
            return .failure(.noBarcodeInWindow)
        }
        let window = Array(bases[windowStart..<windowEnd])

        var matches: [Assignment] = []
        for (sampleID, barcode) in barcodes {
            guard !barcode.isEmpty else { continue }
            if let relativeStart = firstExactMatch(pattern: barcode, in: window, startAt: 0),
               relativeStart < windowLength {
                matches.append(
                    Assignment(
                        sampleID: sampleID,
                        barcode: String(decoding: barcode, as: UTF8.self),
                        windowStart: windowStart + relativeStart
                    )
                )
            }
        }

        // De-duplicate by sample (a barcode could theoretically match at more
        // than one offset in the window; that is still one sample match).
        let uniqueSamples = Set(matches.map(\.sampleID))
        switch uniqueSamples.count {
        case 0:
            return .failure(.noBarcodeInWindow)
        case 1:
            return .success(matches[0])
        default:
            return .failure(.ambiguousBarcodeInWindow)
        }
    }

    // MARK: - Byte-level helpers

    static func firstExactMatch(pattern: [UInt8], in bases: [UInt8], startAt: Int) -> Int? {
        let patternCount = pattern.count
        guard patternCount > 0, bases.count >= patternCount else { return nil }
        var offset = max(0, startAt)
        let lastOffset = bases.count - patternCount
        guard offset <= lastOffset else { return nil }
        let first = pattern[0]
        while offset <= lastOffset {
            if bases[offset] == first {
                var index = 1
                while index < patternCount, bases[offset + index] == pattern[index] {
                    index += 1
                }
                if index == patternCount {
                    return offset
                }
            }
            offset += 1
        }
        return nil
    }

    /// Returns the index immediately after the first approximate match of
    /// `pattern` in `bases`, or nil if none is within `maxMismatches`.
    static func firstApproximateMatchEnd(
        pattern: [UInt8],
        in bases: [UInt8],
        startAt: Int,
        maxMismatches: Int
    ) -> Int? {
        let patternCount = pattern.count
        guard patternCount > 0, bases.count >= patternCount else { return nil }
        var offset = max(0, startAt)
        let lastOffset = bases.count - patternCount
        guard offset <= lastOffset else { return nil }
        while offset <= lastOffset {
            var mismatches = 0
            var index = 0
            while index < patternCount {
                if bases[offset + index] != pattern[index] {
                    mismatches += 1
                    if mismatches > maxMismatches { break }
                }
                index += 1
            }
            if mismatches <= maxMismatches {
                return offset + patternCount
            }
            offset += 1
        }
        return nil
    }

    static func reverseComplementBytes(_ sequence: [UInt8]) -> [UInt8] {
        let table: [UInt8: UInt8] = [
            UInt8(ascii: "A"): UInt8(ascii: "T"), UInt8(ascii: "a"): UInt8(ascii: "T"),
            UInt8(ascii: "C"): UInt8(ascii: "G"), UInt8(ascii: "c"): UInt8(ascii: "G"),
            UInt8(ascii: "G"): UInt8(ascii: "C"), UInt8(ascii: "g"): UInt8(ascii: "C"),
            UInt8(ascii: "T"): UInt8(ascii: "A"), UInt8(ascii: "t"): UInt8(ascii: "A"),
            UInt8(ascii: "N"): UInt8(ascii: "N"), UInt8(ascii: "n"): UInt8(ascii: "N"),
        ]
        return sequence.reversed().map { table[$0] ?? UInt8(ascii: "N") }
    }
}
