// SamtoolsCancellation.swift - Cancels an in-flight samtools process
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

final class SamtoolsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let onInstall: (@Sendable () -> Void)?
    init(onInstall: (@Sendable () -> Void)? = nil) { self.onInstall = onInstall }
    func install(_ process: Process) { lock.lock(); self.process = process; let cancel = cancelled; lock.unlock(); onInstall?(); if cancel { process.terminate() } }
    func cancel() { lock.lock(); cancelled = true; let process = process; lock.unlock(); process?.terminate() }
}
