// FASTQMetadataStore+PlatformLineage.swift - The platform record a derived FASTQ bundle answers with
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQMetadataStore {

    /// The sidecar that answers for the platform of the reads in `fastqURL`.
    ///
    /// A bundle an operation made (a subsample, a trim, a filter, any derivative) could record no sequencing platform
    /// and no assembly read type, although the bundle it derives from does. Builds up to 12859 wrote every such bundle
    /// that way (row DEMUX-C, BIO ruling S2). This returns the file's own sidecar when it records either field.
    /// Otherwise it returns the sidecar of the nearest bundle in the file's lineage that does, through each derived
    /// manifest's parent and then the root the manifest names, so a derivative already in a project answers as its
    /// source does. A manifest of a bundle that stores its own reads names that bundle as its root, so the parent
    /// chain is what leads out of it. A file outside any bundle has no lineage. When nothing in the lineage records
    /// either field this returns the file's own sidecar, which may be nil.
    public static func platformRecord(for fastqURL: URL) -> PersistedFASTQMetadata? {
        let own = load(for: fastqURL)
        if own?.recordsPlatformOrReadType == true { return own }
        let bundleURL = FASTQBundle.isBundleURL(fastqURL)
            ? fastqURL
            : SequenceInputResolver.enclosingFASTQBundleURL(for: fastqURL)
        return bundleURL.flatMap(lineagePlatformRecord(of:)) ?? own
    }

    /// The record of the nearest bundle `bundleURL` derives from, never its own. A bundle with no derived manifest
    /// derives from nothing and gets none. For each bundle the sidecar of its primary file is read before the sidecar
    /// beside the bundle, the order `FASTQLongReadRule` reads.
    private static func lineagePlatformRecord(of bundleURL: URL) -> PersistedFASTQMetadata? {
        var candidates = FASTQLongReadRule.ancestors(of: bundleURL)
        if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            let named = FASTQBundle.resolveBundle(relativePath: manifest.rootBundleRelativePath, from: bundleURL)
            if FASTQBundle.isBundleURL(named),
               named.path != bundleURL.standardizedFileURL.path,
               !candidates.contains(where: { $0.path == named.path }) {
                candidates.append(named)
            }
        }
        for candidate in candidates {
            let primary = FASTQBundle.resolvePrimaryFASTQURL(for: candidate)
            for record in [primary.flatMap { load(for: $0) }, load(for: candidate)] {
                if let record, record.recordsPlatformOrReadType { return record }
            }
        }
        return nil
    }
}

private extension PersistedFASTQMetadata {
    /// Whether the sidecar names a sequencing platform or an assembly read type.
    var recordsPlatformOrReadType: Bool {
        sequencingPlatform != nil || assemblyReadType != nil
    }
}
