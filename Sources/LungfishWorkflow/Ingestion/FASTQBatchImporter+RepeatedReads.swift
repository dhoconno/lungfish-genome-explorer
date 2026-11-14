// FASTQBatchImporter+RepeatedReads.swift - A project that already holds these read pairs, and the facts the import records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQBatchImporter {

    /// The bundles of the project, other than `bundleURL`, whose sidecar records the same pair count and the same
    /// order-free pair hash as `metadata` (row RS-INSTRUMENT, ruling ADJ-BULK G5). A sidecar counts only while the
    /// stored file still has the size the sidecar bound its count to. Bundles the project hides while it builds them
    /// are skipped, since the walk leaves out hidden folders.
    static func bundlesHoldingTheSameReads(
        as metadata: PersistedFASTQMetadata,
        excluding bundleURL: URL,
        in projectDirectory: URL
    ) -> [URL] {
        guard let recorded = metadata.recordedReadCount, let hash = recorded.pairHash, recorded.pairedR1 > 0,
              let walker = FileManager.default.enumerator(
                  at: projectDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        let suffix = ".lungfish-meta.json"
        let own = bundleURL.standardizedFileURL.path
        var found: [URL] = []
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
            let folder = url.deletingLastPathComponent()
            guard folder.standardizedFileURL.path != own else { continue }
            let reads = folder.appendingPathComponent(String(url.lastPathComponent.dropLast(suffix.count)))
            guard let other = FASTQMetadataStore.load(for: reads),
                  let count = other.recordedReadCount, count.pairHash == hash, count.pairedR1 == recorded.pairedR1,
                  let size = (try? FileManager.default.attributesOfItem(atPath: reads.path)[.size] as? NSNumber)?.int64Value,
                  size == count.storedSizeBytes else { continue }
            found.append(folder)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The warning for a sample whose reads another bundle of the project holds, or nil. It names both bundles. An
    /// import warns and never refuses.
    static func repeatedReadsNotice(
        sample: String,
        bundleURL: URL,
        metadata: PersistedFASTQMetadata,
        projectDirectory: URL
    ) -> String? {
        let others = bundlesHoldingTheSameReads(as: metadata, excluding: bundleURL, in: projectDirectory)
        guard !others.isEmpty, let pairs = metadata.recordedReadCount?.pairedR1 else { return nil }
        let names = others.map(\.lastPathComponent).joined(separator: ", ")
        return "Bundle \(bundleURL.lastPathComponent) holds the same \(pairs) read pairs as bundle \(names), in any order. "
            + "A differential expression analysis that takes both would count one library twice. Both bundles were "
            + "imported, so leave one of them out of any comparison or remove one."
    }

    /// Logs the warning of ``repeatedReadsNotice(sample:bundleURL:metadata:projectDirectory:)`` as a notice of `sample`
    /// when another bundle of the project holds these reads, and logs nothing otherwise. An import never refuses.
    static func warnOfRepeatedReads(
        sample: String,
        bundleURL: URL,
        metadata: PersistedFASTQMetadata,
        projectDirectory: URL,
        log: (@Sendable (ImportLogEvent) -> Void)?
    ) {
        guard let notice = repeatedReadsNotice(
            sample: sample, bundleURL: bundleURL, metadata: metadata, projectDirectory: projectDirectory
        ) else { return }
        log?(.notice(sample: sample, message: notice))
    }

    /// The facts of the stored reads that the import's record carries as resolved parameters (row RS-INSTRUMENT), with
    /// the parameters of an adopted run laid over them, since an adopt states what its job measured. The facts are read
    /// back from the sidecar the import just wrote, so the record and the sidecar cannot differ.
    static func scanFactParameters(of storedFASTQ: URL, adopted: [String: ParameterValue]) -> [String: ParameterValue] {
        guard let metadata = FASTQMetadataStore.load(for: storedFASTQ) else { return adopted }
        var parameters: [String: ParameterValue] = [:]
        if let instrument = metadata.sequencerInstrument {
            parameters["instrumentNameForm"] = .string(instrument.nameForm.rawValue)
            parameters["instrumentIDs"] = .array(instrument.instrumentIDs.map { .string($0) })
            parameters["instrumentRuns"] = .array(instrument.runNumbers.map { .integer($0) })
            parameters["instrumentFlowcells"] = .array(instrument.flowcells.map { .string($0) })
            parameters["instrumentLanes"] = .array(instrument.lanes.map { .integer($0) })
            parameters["instrumentModels"] = .array(instrument.models.map { .string($0) })
            parameters["instrumentModelsInferred"] = .boolean(instrument.modelsAreInferred)
            parameters["instrumentSummary"] = .string(instrument.summary)
        }
        if let recorded = metadata.recordedReadCount, let hash = recorded.pairHash {
            parameters["readPairCount"] = .integer(recorded.pairedR1)
            parameters["readPairHash"] = .string(hash)
        }
        return parameters.merging(adopted) { _, adopted in adopted }
    }
}
