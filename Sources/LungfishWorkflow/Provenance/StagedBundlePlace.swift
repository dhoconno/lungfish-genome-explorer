// StagedBundlePlace.swift - The spellings of a staged folder a record may name, and the place that replaces them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The spellings of a staged folder that a provenance record may name, and the folder that replaces them.
///
/// A run builds in a staging folder, publishes by rename and then moves its record's paths to the published place.
/// The record names the staged folder the way the run spelled it, and a tool or a reader may name it by its real path.
/// One folder has several spellings on macOS (`/tmp` and `/private/tmp`, `/var` and `/private/var`, a link). Foundation
/// resolves a path and drops `/private` only while the path exists, and the staged folder is gone when the record
/// moves. So the spellings are taken from the path in every way that works whether or not it exists:
///
/// - the path as given and standardized
/// - the path through its deepest existing ancestor, resolved the way Foundation spells an existing path (`/tmp`)
/// - the real path with `/private` kept (``CanonicalFilePath``)
///
/// Each is replaced, the longest first, so `/private/var/x` goes whole before `/var/x` is looked for. Lane C2-PROVPATH:
/// the envelope relocation, the ONT import's step remap and `fastq ingest` each kept a smaller set and missed a record
/// spelled the other way round. This type is the one place that owns the set.
package struct StagedBundlePlace {
    /// Every spelling of the staged folder, the longest first. Equal lengths keep a fixed order.
    package let spellings: [String]
    /// The folder that takes the staged folder's place, spelled as the caller gave it.
    package let target: String

    package init(staged: URL, final: URL) {
        let candidates: Set<String> = [
            staged.path,
            staged.standardizedFileURL.path,
            CrossProjectItemCopier.resolvedThroughExistingAncestor(staged).path,
            CanonicalFilePath.path(for: staged),
        ]
        spellings = candidates
            .filter { !$0.isEmpty }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        target = final.path
    }

    package func relocating(_ text: String) -> String {
        spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: target) }
    }

    package func relocating(_ values: [String: ParameterValue]) -> [String: ParameterValue] {
        values.mapValues { $0.rewritingPaths(relocating) }
    }

    package func relocating(_ descriptor: ProvenanceFileDescriptor) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: relocating(descriptor.path),
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath.map(relocating),
            sourceProvenancePath: descriptor.sourceProvenancePath.map(relocating))
    }
}
