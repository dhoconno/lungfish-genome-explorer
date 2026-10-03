// ReferenceBundleChoice.swift - A reference bundle offered as an annotation import target
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

public struct ReferenceBundleChoice: Sendable, Equatable, Identifiable {
    public let url: URL
    public let displayPath: String

    public var id: String { url.standardizedFileURL.path }
}
