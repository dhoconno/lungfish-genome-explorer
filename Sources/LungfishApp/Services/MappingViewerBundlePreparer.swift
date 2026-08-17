// MappingViewerBundlePreparer.swift - Builds lightweight mapping viewer bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO

enum MappingViewerBundlePreparer {

    static func prepareBaseBundle(
        sourceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let sourceManifest = try BundleManifest.load(from: sourceBundleURL)

        if fileManager.fileExists(atPath: viewerBundleURL.path) {
            try fileManager.removeItem(at: viewerBundleURL)
        }
        try fileManager.createDirectory(
            at: viewerBundleURL,
            withIntermediateDirectories: true
        )

        for itemName in referencedTopLevelItems(in: sourceManifest).sorted() {
            let sourceItem = sourceBundleURL.appendingPathComponent(itemName)
            guard fileManager.fileExists(atPath: sourceItem.path) else { continue }

            let viewerItem = viewerBundleURL.appendingPathComponent(itemName)
            try materializeItem(from: sourceItem, to: viewerItem, fileManager: fileManager)
        }

        let manifest = BundleManifest(
            formatVersion: sourceManifest.formatVersion,
            name: sourceManifest.name,
            identifier: sourceManifest.identifier,
            description: sourceManifest.description,
            originBundlePath: originBundlePath(from: viewerBundleURL, to: sourceBundleURL),
            createdDate: sourceManifest.createdDate,
            modifiedDate: Date(),
            source: sourceManifest.source,
            genome: sourceManifest.genome,
            annotations: sourceManifest.annotations,
            variants: sourceManifest.variants,
            tracks: sourceManifest.tracks,
            alignments: [],
            metadata: sourceManifest.metadata,
            browserSummary: nil
        )
        try manifest.save(to: viewerBundleURL)
    }

    private static func referencedTopLevelItems(in manifest: BundleManifest) -> Set<String> {
        var items = Set<String>()

        if let genome = manifest.genome {
            insertTopLevelItem(from: genome.path, into: &items)
            insertTopLevelItem(from: genome.indexPath, into: &items)
            if let gzipIndexPath = genome.gzipIndexPath {
                insertTopLevelItem(from: gzipIndexPath, into: &items)
            }
        }

        for annotation in manifest.annotations {
            insertTopLevelItem(from: annotation.path, into: &items)
            if let databasePath = annotation.databasePath {
                insertTopLevelItem(from: databasePath, into: &items)
            }
        }

        for variant in manifest.variants {
            insertTopLevelItem(from: variant.path, into: &items)
            insertTopLevelItem(from: variant.indexPath, into: &items)
            if let databasePath = variant.databasePath {
                insertTopLevelItem(from: databasePath, into: &items)
            }
        }

        for track in manifest.tracks {
            insertTopLevelItem(from: track.path, into: &items)
        }

        items.remove(BundleManifest.filename)
        items.remove("alignments")
        return items
    }

    private static func insertTopLevelItem(from path: String, into items: inout Set<String>) {
        guard !path.isEmpty, !path.hasPrefix("/") else { return }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return }
        items.insert(String(first))
    }

    private static func materializeItem(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        try materializeItem(
            from: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            copyfile: { sourcePath, destinationPath, flags in
                let result = Darwin.copyfile(sourcePath, destinationPath, nil, flags)
                return result == 0 ? 0 : errno
            }
        )
    }

    static func materializeItem(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        copyfile: (String, String, copyfile_flags_t) -> Int32
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        // `COPYFILE_CLONE` requests APFS copy-on-write and includes the normal
        // data/metadata copy semantics when cloning is unavailable; recursive
        // copying materializes every file below the manifest's top-level root.
        let cloneFlags = copyfile_flags_t(COPYFILE_RECURSIVE | COPYFILE_CLONE)
        let cloneResult = copyfile(sourceURL.path, destinationURL.path, cloneFlags)
        if cloneResult == 0 {
            return
        }

        guard cloneResult == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: cloneResult) ?? .EIO)
        }

        try fileManager.removeItem(at: destinationURL)

        let fallbackFlags = copyfile_flags_t(
            COPYFILE_RECURSIVE | COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW_SRC
        )
        let fallbackResult = copyfile(sourceURL.path, destinationURL.path, fallbackFlags)
        guard fallbackResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: fallbackResult) ?? .EIO)
        }
    }

    private static func originBundlePath(from viewerBundleURL: URL, to sourceBundleURL: URL) -> String {
        // Finding 2: only emit the `@/` project-relative origin when the VIEWER
        // bundle itself lives inside a `.lungfish` project (so the recorded path
        // is anchored at the viewer's own project root and always resolves when
        // the viewer is reopened). Otherwise fall back to the filesystem-relative
        // (viewer-anchored) form. `FASTQBundle.projectRelativePath` would
        // otherwise fall back to the SOURCE's project root, producing a `@/`
        // path the viewer cannot resolve when it has no project of its own.
        if FASTQBundle.findProjectRoot(from: viewerBundleURL) != nil,
           let projectRelative = FASTQBundle.projectRelativePath(
               for: sourceBundleURL,
               from: viewerBundleURL
           ) {
            return projectRelative
        }
        return filesystemRelativePath(from: viewerBundleURL, to: sourceBundleURL)
    }

    private static func filesystemRelativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents

        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let up = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let down = Array(targetComponents.dropFirst(common))
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
