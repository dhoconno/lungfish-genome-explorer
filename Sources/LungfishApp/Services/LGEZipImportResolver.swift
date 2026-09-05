// LGEZipImportResolver.swift - Resolves ZIP-compressed Lungfish objects before import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

struct LGEZipImportFailure: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case extractionFailed
        case noRecognizedLGEObject
        case multipleRecognizedLGEObjects
    }

    let sourceURL: URL
    let kind: Kind
    let message: String
}

final class LGEZipImportBatch: @unchecked Sendable {
    let sourceURLs: [URL]
    let failures: [LGEZipImportFailure]

    private let cleanupURLs: [URL]
    private let fileManager: FileManager
    private var didCleanup = false

    init(
        sourceURLs: [URL],
        failures: [LGEZipImportFailure],
        cleanupURLs: [URL],
        fileManager: FileManager = .default
    ) {
        self.sourceURLs = sourceURLs
        self.failures = failures
        self.cleanupURLs = cleanupURLs
        self.fileManager = fileManager
    }

    func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        for url in cleanupURLs {
            try? fileManager.removeItem(at: url)
        }
    }

    deinit {
        cleanup()
    }
}

struct LGEZipImportResolver {
    private let fileManager: FileManager
    private let archiveTool: GeneiousArchiveTool

    init(
        fileManager: FileManager = .default,
        archiveTool: GeneiousArchiveTool = GeneiousArchiveTool()
    ) {
        self.fileManager = fileManager
        self.archiveTool = archiveTool
    }

    func resolve(urls: [URL], projectURL: URL?) throws -> LGEZipImportBatch {
        var resolvedURLs: [URL] = []
        var failures: [LGEZipImportFailure] = []
        var cleanupURLs: [URL] = []

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.pathExtension.lowercased() == "zip" else {
                resolvedURLs.append(standardizedURL)
                continue
            }

            let tempRoot = try ProjectTempDirectory.create(prefix: "sidebar-zip-import-", in: projectURL)
            cleanupURLs.append(tempRoot)

            do {
                try archiveTool.extract(archiveURL: standardizedURL, to: tempRoot)
                let candidates = try recognizedLGEObjects(in: tempRoot)
                switch candidates.count {
                case 1:
                    resolvedURLs.append(candidates[0])
                case 0:
                    failures.append(
                        LGEZipImportFailure(
                            sourceURL: standardizedURL,
                            kind: .noRecognizedLGEObject,
                            message: "\(standardizedURL.lastPathComponent) does not contain a recognized Lungfish object."
                        )
                    )
                default:
                    failures.append(
                        LGEZipImportFailure(
                            sourceURL: standardizedURL,
                            kind: .multipleRecognizedLGEObjects,
                            message: "\(standardizedURL.lastPathComponent) contains multiple Lungfish objects; import one archive per object."
                        )
                    )
                }
            } catch {
                failures.append(
                    LGEZipImportFailure(
                        sourceURL: standardizedURL,
                        kind: .extractionFailed,
                        message: error.localizedDescription
                    )
                )
            }
        }

        return LGEZipImportBatch(
            sourceURLs: resolvedURLs,
            failures: failures,
            cleanupURLs: cleanupURLs,
            fileManager: fileManager
        )
    }

    private func recognizedLGEObjects(in rootURL: URL) throws -> [URL] {
        var candidates: [URL] = []
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            guard SidebarProjectScanner.isNativePackage(url) else {
                continue
            }

            candidates.append(url.standardizedFileURL)
            enumerator.skipDescendants()
        }

        return candidates.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

}
