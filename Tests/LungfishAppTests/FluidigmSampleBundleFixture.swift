// FluidigmSampleBundleFixture.swift - A bundle the Fluidigm sample materializer writes, for tests of placeholder scores
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
@testable import LungfishWorkflow

/// A `.lungfishfastq` bundle as the Fluidigm sample materializer writes it. Its reads are built from sequence counts,
/// so the Q40 characters they carry were written by the materializer and no instrument measured them
/// (QUALITY-BIO ruling F1 to F4).
enum FluidigmSampleBundleFixture {
    /// Materializes two identical reads of the sample LF2871 and returns its bundle, `LF2871.lungfishfastq` under
    /// `outputDirectory`. `workDirectory` holds the input reads and the barcode table.
    static func materialize(outputDirectory: URL, workDirectory: URL) async throws -> URL {
        let cs1 = "ACACTGACGACATGGTTCTACA"
        let cs2rc = "AGACCAAGTCTCTGCTACCGTA"
        let barcode = "AAAACCCCGG"
        let read = cs1 + "ACGTACGTACGTACGT" + cs2rc + "CC" + barcode
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let input = workDirectory.appendingPathComponent("barcode11.fastq")
        let barcodes = workDirectory.appendingPathComponent("samples.csv")
        let fastq = (1...2).map { "@read-\($0)\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n" }.joined()
        try fastq.write(to: input, atomically: true, encoding: .utf8)
        try "sample,barcode\nLF2871,\(barcode)\n".write(to: barcodes, atomically: true, encoding: .utf8)

        _ = try await ONTFluidigmSampleMaterializer().run(
            ONTFluidigmSampleMaterializationRequest(
                inputURL: input,
                barcodeDefinitionsURL: barcodes,
                outputDirectory: outputDirectory,
                force: true
            )
        )
        return outputDirectory.appendingPathComponent("LF2871.lungfishfastq", isDirectory: true)
    }
}
