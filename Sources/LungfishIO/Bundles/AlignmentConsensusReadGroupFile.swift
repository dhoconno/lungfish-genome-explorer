// AlignmentConsensusReadGroupFile.swift - The contents and checksum of the deterministic read-group selection file
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// The contents and checksum of the deterministic read-group selection file.
public struct AlignmentConsensusReadGroupFile: Sendable, Equatable {
    public let path: String
    public let contents: String
    public let checksumSHA256: String

    public init(path: String, contents: String, checksumSHA256: String) {
        self.path = path
        self.contents = contents
        self.checksumSHA256 = checksumSHA256
    }
}
