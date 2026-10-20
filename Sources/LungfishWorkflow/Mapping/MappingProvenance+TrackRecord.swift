// MappingProvenance+TrackRecord.swift - The mapping record an adopted track keeps under a name of its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension MappingProvenance {
    /// Whether `name` names a typed mapping record. That is a mapping folder's `mapping-provenance.json`, or the
    /// `<bam stem>.mapping-provenance.json` that `bam adopt-mapping` saves beside each adopted BAM since 2.13
    /// (lane 13.16). A bundle written before 2.13 may hold one shared `alignments/mapped/mapping-provenance.json`
    /// for every track it adopted, which LGE reads and never writes.
    public static func isRecordFilename(_ name: String) -> Bool {
        name == filename || (name.hasSuffix(".\(filename)") && name.count > filename.count + 1)
    }

    /// `<bam stem>.mapping-provenance.json` beside the alignment, the one record of its mapping run that a bundle
    /// keeps for an adopted track. The stem is the one the track's `<bam stem>.adopt-mapping-provenance.json` takes.
    public static func trackRecordURL(forAlignmentAt alignmentURL: URL) -> URL {
        alignmentURL.deletingPathExtension().appendingPathExtension(filename)
    }

    /// Saves the record as the file `url`, its paths stored from the file's folder, through `DurableReplace` as
    /// `save(to:)` saves a folder's `mapping-provenance.json`.
    public func save(toFile url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try persistedData(relativeTo: directory, encoder: encoder)
        try DurableReplace.replace(
            PortablePath.sanitizeJSON(data, forFileAt: url, encoder: encoder),
            named: url.lastPathComponent,
            in: directory
        )
    }

    /// The record the file `url` holds, or nil when there is none or it does not decode as a mapping record.
    public static func load(fromFile url: URL) -> MappingProvenance? {
        decoded(fromFile: url)
    }
}
