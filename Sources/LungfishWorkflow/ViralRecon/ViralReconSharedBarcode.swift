// ViralReconSharedBarcode.swift - Two Nanopore inputs of a Viral Recon run that resolve to one barcode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ViralReconSamplesheetBuilder {
    /// Two Nanopore inputs resolve to one barcode folder (`barcodeNN`).
    ///
    /// `stageNanoporeInputs` copies each sample's reads into its barcode folder by file name, so the second
    /// `reads.fastq.gz` replaced the first and one sample's reads were lost (trust session VR-SAME-NAME,
    /// BIO-PROBES-F Q1). "barcode01" and "BC1" are one barcode once normalized, and a typed barcode can meet the
    /// index fallback of an input that has none. The inputs are named by ``describingInputs(_:_:)``.
    public struct SharedBarcodeError: Error, LocalizedError, Sendable, Equatable {
        /// The barcode as the folder takes it, such as `01`.
        public let barcode: String
        public let input: URL
        public let otherInput: URL

        public var errorDescription: String? {
            let (first, second) = ViralReconSamplesheetBuilder.describingInputs(input, otherInput)
            return "The inputs “\(first)” and “\(second)” both use the barcode “\(barcode)”, "
                + "and viralrecon reads each barcode folder as one sample, "
                + "so the reads of one would replace the reads of the other. "
                + "Give one of them its own barcode in its metadata, and run again."
        }
    }
}
