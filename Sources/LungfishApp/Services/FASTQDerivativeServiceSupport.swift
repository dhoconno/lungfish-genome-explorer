// FASTQDerivativeServiceSupport.swift - Logger, provenance writer, native execution types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

let derivativeLogger = Logger(subsystem: LogSubsystem.app, category: "FASTQDerivativeService")

protocol FASTQDerivativeProvenanceWriting: Sendable {
    @discardableResult
    func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL
}

struct DefaultFASTQDerivativeProvenanceWriter: FASTQDerivativeProvenanceWriting {
    @discardableResult
    func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL {
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
    }
}

struct FASTQDerivativeNativeToolExecution: Sendable {
    let tool: NativeTool
    let toolVersion: String?
    let result: NativeToolResult
    let startedAt: Date
    let completedAt: Date
}

struct FASTQDerivativeNativeReplayContext: Sendable {
    let pathReplacements: [String: String]
    let temporaryPathRoots: [String]

    init(
        pathReplacements: [String: String] = [:],
        temporaryPathRoots: [String] = []
    ) {
        self.pathReplacements = pathReplacements
        self.temporaryPathRoots = temporaryPathRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

final class FASTQDerivativeNativeProvenanceCollector: @unchecked Sendable {
    let lock = NSLock()
    var executions: [FASTQDerivativeNativeToolExecution] = []

    func append(_ execution: FASTQDerivativeNativeToolExecution) {
        lock.lock()
        executions.append(execution)
        lock.unlock()
    }

    func snapshot() -> [FASTQDerivativeNativeToolExecution] {
        lock.lock()
        defer { lock.unlock() }
        return executions
    }
}
