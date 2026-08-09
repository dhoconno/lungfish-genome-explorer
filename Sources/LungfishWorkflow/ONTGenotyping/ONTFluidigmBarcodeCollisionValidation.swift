import Foundation

/// Shared duplicate-barcode-sequence detection for Fluidigm barcode sheets.
///
/// R3-R3H-5 / R3-R3H-6: BarcodeMatcher.findFirst() in both
/// ONTFluidigmAmpliconMaterializer.swift and ONTFluidigmSampleMaterializer.swift
/// resolves a matched k-mer code via `map[code]?.first`, silently picking the
/// first-inserted candidate whenever two barcode entries collide on the same
/// two-bit-packed sequence at the same length (identical barcode strings, or
/// one entry's forward barcode equal to another's reverse-complement).
/// Neither materializer's `loadBarcodeEntries` previously checked for this
/// before building the matcher, so a Fluidigm barcode sheet with two rows
/// sharing an effective barcode would silently and deterministically
/// misattribute every read matching that barcode to whichever sample
/// happened to load first -- no error, no warning, no manifest note.
///
/// This mirrors the existing `duplicateMaterializedSampleName` validation
/// family in ONTPacBioBarcodeDemuxMaterializer.swift, extended to barcode
/// *sequences* (forward and reverse-complement) rather than sample names.
/// Factored into one shared function (rather than duplicated inline in both
/// materializers) so the two near-identical BarcodeEntry/BarcodeMatcher
/// implementations don't drift further on this validation.
enum ONTFluidigmBarcodeCollisionValidation {

    /// One barcode-sheet row's identity, as seen by both materializers'
    /// (private, per-file) `BarcodeEntry` types.
    struct Row {
        let sampleID: String
        let barcode: String
        let reverseComplementBarcode: String

        init(sampleID: String, barcode: String, reverseComplementBarcode: String) {
            self.sampleID = sampleID
            self.barcode = barcode
            self.reverseComplementBarcode = reverseComplementBarcode
        }
    }

    /// Throws `duplicateBarcodeSequence` the first time two rows (by
    /// insertion order) share an effective barcode sequence -- i.e. one
    /// row's forward or reverse-complement barcode string exactly equals
    /// another (different-sample) row's forward or reverse-complement
    /// barcode string. This is the same collision BarcodeMatcher's two-bit
    /// packed code map would silently resolve via `.first`.
    ///
    /// - Parameter onCollision: builds the caller's own error type from the
    ///   two colliding sample IDs and the shared barcode sequence, so this
    ///   shared validator doesn't need to know about
    ///   ONTFluidigmAmpliconMaterializerError vs.
    ///   ONTFluidigmSampleMaterializerError.
    static func validateNoDuplicateBarcodeSequences<E: Error>(
        _ rows: [Row],
        onCollision: (_ firstSampleID: String, _ secondSampleID: String, _ barcode: String) -> E
    ) throws(E) {
        // Maps an effective barcode sequence (forward or reverse-complement)
        // to the first sampleID that claimed it.
        var seenBy: [String: String] = [:]

        for row in rows {
            let effectiveBarcodes = Set([row.barcode, row.reverseComplementBarcode])
            for barcode in effectiveBarcodes where !barcode.isEmpty {
                if let firstSampleID = seenBy[barcode] {
                    guard firstSampleID != row.sampleID else { continue }
                    throw onCollision(firstSampleID, row.sampleID, barcode)
                }
                seenBy[barcode] = row.sampleID
            }
        }
    }
}
