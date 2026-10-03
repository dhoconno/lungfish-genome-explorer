// ReferenceBundleAnnotationImportResult.swift - Result of attaching an annotation track to a reference bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

public struct ReferenceBundleAnnotationImportResult: Sendable, Equatable {
    public let bundleURL: URL
    public let track: AnnotationTrackInfo
    public let featureCount: Int

    public init(bundleURL: URL, track: AnnotationTrackInfo, featureCount: Int) {
        self.bundleURL = bundleURL
        self.track = track
        self.featureCount = featureCount
    }
}
