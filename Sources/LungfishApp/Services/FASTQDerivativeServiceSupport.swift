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
    /// The file the operation read for its source bundle, when the
    /// materializer wrote it for the run (a multi-file bundle's joined copy,
    /// a virtual bundle's materialized reads), so the provenance can record
    /// the step that wrote it (R8, lane 1x). Nil when the source was read
    /// in place.
    let sourceExecutionURL: URL?

    init(
        pathReplacements: [String: String] = [:],
        temporaryPathRoots: [String] = [],
        sourceExecutionURL: URL? = nil
    ) {
        self.pathReplacements = pathReplacements
        self.temporaryPathRoots = temporaryPathRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.sourceExecutionURL = sourceExecutionURL
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
