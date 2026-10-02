// AlignmentConsensusMode.swift - Consensus caller mode for samtools consensus
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// Consensus caller mode for `samtools consensus`.
public enum AlignmentConsensusMode: String, Sendable, CaseIterable {
    case bayesian
    case simple
}
