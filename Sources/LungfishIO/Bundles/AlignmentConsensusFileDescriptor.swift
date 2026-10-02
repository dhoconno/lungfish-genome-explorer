// AlignmentConsensusFileDescriptor.swift - A checksummed input or staging artifact involved in consensus execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// A checksummed input or staging artifact involved in consensus execution.
public struct AlignmentConsensusFileDescriptor: Sendable, Equatable {
    public let path: String
    public let checksumSHA256: String?
    public let fileSize: UInt64?

    public init(path: String, checksumSHA256: String?, fileSize: UInt64?) {
        self.path = path
        self.checksumSHA256 = checksumSHA256
        self.fileSize = fileSize
    }
}
