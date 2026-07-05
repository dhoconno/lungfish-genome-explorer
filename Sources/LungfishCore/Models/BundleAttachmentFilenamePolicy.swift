// BundleAttachmentFilenamePolicy.swift - Internal filenames used by attachment directories
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum BundleAttachmentFilenamePolicy {
    public static let provenanceSidecarSuffix = ".lungfish-provenance.json"

    public static func isUserVisibleAttachmentFilename(_ filename: String) -> Bool {
        !filename.hasSuffix(provenanceSidecarSuffix)
    }

    public static func provenanceSidecarURL(forAttachmentURL attachmentURL: URL) -> URL {
        URL(fileURLWithPath: attachmentURL.path + provenanceSidecarSuffix)
    }
}
