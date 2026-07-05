// BundleAttachmentStore.swift — File attachments for classification bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct BundleAttachment: Sendable {
    public let filename: String
    public let fileSize: Int64
    public let dateAdded: Date
    public let url: URL
}

@Observable
public final class BundleAttachmentStore: @unchecked Sendable {
    public static let attachmentsDirectoryName = "attachments"

    public let bundleURL: URL
    public var attachments: [BundleAttachment] = []

    public var attachmentsDirectory: URL {
        bundleURL.appendingPathComponent(Self.attachmentsDirectoryName, isDirectory: true)
    }

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
        reload()
    }

    public func reload() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: attachmentsDirectory.path) else {
            attachments = []
            return
        }
        let urls = (try? fm.contentsOfDirectory(
            at: attachmentsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            BundleAttachmentFilenamePolicy.isUserVisibleAttachmentFilename($0.lastPathComponent)
        } ?? []

        attachments = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            return BundleAttachment(
                filename: url.lastPathComponent,
                fileSize: Int64(values?.fileSize ?? 0),
                dateAdded: values?.creationDate ?? Date(),
                url: url
            )
        }.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    public func attach(fileAt sourceURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let dest = urlForAttachment(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try? fm.removeItem(at: BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: dest))
        try fm.copyItem(at: sourceURL, to: dest)
        reload()
    }

    public func urlForAttachment(_ filename: String) -> URL {
        attachmentsDirectory.appendingPathComponent(filename)
    }

    public func remove(filename: String) throws {
        let fileURL = urlForAttachment(filename)
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        try? FileManager.default.removeItem(
            at: BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: fileURL)
        )
        reload()
    }
}
