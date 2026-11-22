// TaxTriageWizardInputSamples.swift - The samples the TaxTriage dialog makes of the inputs it is handed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// One sample the TaxTriage dialog makes of its inputs, before a person edits it.
struct TaxTriageWizardInputSample: Equatable, Sendable {
    var sampleId: String
    var fastq1: URL
    var fastq2: URL?
    /// The role the sample's own FASTQ bundle records, or a test sample.
    var sampleRole: SampleRole = .testSample
    /// The bundle's own sample name, when it differs from `sampleId`.
    var metadataLabel: String?
}

extension TaxTriageWizardSheet {
    /// The samples `populateFromInitialFiles` lists for `urls`, the inputs the dialog is handed.
    nonisolated static func inputSamples(from urls: [URL]) -> [TaxTriageWizardInputSample] {
        let fileGroups: [(url: URL, baseName: String)] = urls.map { url in
            var base = url.deletingPathExtension().lastPathComponent
            if url.pathExtension.lowercased() == "gz" {
                base = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            }
            for suffix in ["_R1", "_R2", "_1", "_2", "_R1_001", "_R2_001"] where base.hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
                break
            }
            return (url, base)
        }
        let grouped = Dictionary(grouping: fileGroups, by: { $0.baseName })
        return grouped.sorted(by: { $0.key < $1.key }).map { baseName, group in
            let urls = group.map(\.url)
            var sample = TaxTriageWizardInputSample(sampleId: baseName, fastq1: urls[0], fastq2: urls.count > 1 ? urls[1] : nil)
            let bundleURL = urls[0].deletingLastPathComponent()
            if bundleURL.pathExtension == "lungfishfastq", let csvMeta = FASTQBundleCSVMetadata.load(from: bundleURL) {
                let meta = FASTQSampleMetadata(from: csvMeta, fallbackName: baseName)
                sample.sampleRole = meta.sampleRole
                sample.metadataLabel = meta.sampleName != baseName ? meta.sampleName : nil
            }
            return sample
        }
    }

    /// The file lines a sample row shows under its Sample ID.
    nonisolated static func sampleFileLines(fastq1: URL?, fastq2: URL?) -> [String] {
        [fastq1?.lastPathComponent ?? "No R1 file"] + (fastq2.map { [$0.lastPathComponent] } ?? [])
    }

    /// The line under a paired row's files.
    nonisolated static func pairedByNamesLine(fastq2: URL?) -> String? {
        nil
    }

    /// The lines under the sample list for bundles named like the two reads of one sample.
    nonisolated static func bundleMateNotices(_ urls: [URL]) -> [String] {
        []
    }
}
