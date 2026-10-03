// FASTQBundle+DerivedPayloadRoot.swift - The files of a paired or mixed derived bundle used as a root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBundle {

    /// The payload files of a derived bundle that stores pairs as files of
    /// its own, a deinterleaved bundle (`fullPaired`) or a PE merge or repair
    /// bundle (`fullMixed`), in role order: every R1 file, every R2 file,
    /// every merged file, then every unpaired file, each role in manifest
    /// order. Nil for any other bundle.
    ///
    /// Such a bundle is the root of its virtual children (D1, Phase 1.5 lane
    /// A7). The list names every file the children's reads come from, for
    /// staleness, integrity and provenance records. It is not a read order:
    /// reading R1 then R2 file by file breaks the pairs, so a consumer that
    /// reads the records materializes the bundle instead
    /// (`FASTQCLIMaterializer`). A listed file that does not exist throws
    /// ``FASTQBundlePathError/missingMember(bundle:path:)``.
    public static func derivedPayloadRootSequenceURLs(in bundleURL: URL) throws -> [URL]? {
        guard let manifest = loadDerivedManifest(in: bundleURL) else { return nil }
        let filenames: [String]
        switch manifest.payload {
        case .fullPaired(let r1Filename, let r2Filename):
            filenames = [r1Filename, r2Filename]
        case .fullMixed(let classification):
            let order: [ReadClassification.FileRole] = [.pairedR1, .pairedR2, .merged, .unpaired]
            filenames = order.flatMap { role in
                classification.files.filter { $0.role == role }.map(\.filename)
            }
        case .full, .fullFASTA, .subset, .trim, .demuxedVirtual, .orientMap, .demuxGroup:
            return nil
        }
        return try filenames.map { filename in
            let url = try validatedBundleMemberURL(for: filename, in: bundleURL, field: "payload")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FASTQBundlePathError.missingMember(bundle: bundleURL.lastPathComponent, path: filename)
            }
            return url
        }
    }
}
