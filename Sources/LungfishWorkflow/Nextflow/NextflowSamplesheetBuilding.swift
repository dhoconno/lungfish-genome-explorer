// NextflowSamplesheetBuilding.swift - How a Nextflow workflow's samplesheet is built and written
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A16 (panel N1 and N3). A Nextflow workflow reads its samples from one CSV file that it
// takes as `--input`. A builder turns the samples LGE resolved into the rows of that file and writes it,
// one row per sample keyed by the sample's name. TaxTriage's builder writes the bytes `TaxTriagePipeline`
// writes today, through the same IO writer, so moving the pipeline onto it changes no sheet.

import Foundation
import LungfishIO

/// Builds and writes a Nextflow workflow's samplesheet, one keyed row per sample.
///
/// Each sample gives exactly one row, in the order of the samples, and the row's first field is the
/// sample's name. A workflow names a sample's outputs by that name, so two samples with one name would
/// share one set of outputs, and ``rows(for:)`` refuses them. ``write(_:to:)`` writes the header and the
/// same rows, so the rows a test reads are the rows a run reads.
package protocol NextflowSamplesheetBuilding: Sendable {
    /// One sample as the workflow's sheet describes it.
    associatedtype Sample: Sendable

    /// The rows of the sheet below its header, one per sample in order, each keyed by its first field.
    ///
    /// - Throws: An error when the samples cannot form a sheet, such as two samples with one name.
    func rows(for samples: [Sample]) throws -> [[String]]

    /// Writes the sheet of `samples` to `url`, its header and then the rows of ``rows(for:)``, and
    /// creates the folder that holds it when it does not exist.
    ///
    /// - Throws: An error ``rows(for:)`` throws, before any file is written, or the error of creating
    ///   the folder or writing the file.
    func write(_ samples: [Sample], to url: URL) throws
}

// MARK: - TaxTriage

/// TaxTriage's samplesheet, `sample,fastq_1,fastq_2,platform`, byte-equal to the sheet
/// `TaxTriagePipeline` writes today.
///
/// A row holds the sample's name, the path of its first FASTQ file, the path of its second file or
/// nothing, and its platform, as `TaxTriagePipeline.samplesheetEntries(for:)` builds it. The file goes
/// through `TaxTriageSamplesheet.write(samples:to:)`, the writer the pipeline calls, which quotes a
/// field that holds a comma, a quote or a line break and ends every line with a line feed.
package struct TaxTriageSamplesheetBuilder: NextflowSamplesheetBuilding {
    package typealias Sample = TaxTriageSample

    package init() {}

    package func rows(for samples: [TaxTriageSample]) throws -> [[String]] {
        try entries(for: samples).map { entry in
            [entry.sampleId, entry.fastq1Path, entry.fastq2Path ?? "", entry.platform]
        }
    }

    package func write(_ samples: [TaxTriageSample], to url: URL) throws {
        try TaxTriageSamplesheet.write(samples: entries(for: samples), to: url)
    }

    /// The sheet's entries, with `fastq_2` filled whenever a sample has a second file.
    ///
    /// - Throws: ``TaxTriageConfigError/duplicateSampleIds(_:)`` with the shared names sorted, the error
    ///   `TaxTriageConfig.validate()` throws for the same samples.
    private func entries(for samples: [TaxTriageSample]) throws -> [TaxTriageSampleEntry] {
        let sharedNames = Dictionary(grouping: samples.map(\.sampleId), by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
        guard sharedNames.isEmpty else {
            throw TaxTriageConfigError.duplicateSampleIds(sharedNames.sorted())
        }
        return samples.map { sample in
            TaxTriageSampleEntry(
                sampleId: sample.sampleId,
                fastq1Path: sample.fastq1.path,
                fastq2Path: sample.fastq2?.path,
                platform: sample.platform.rawValue
            )
        }
    }
}
