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

struct FASTQDerivativeNativeToolExecution: Sendable {
    let tool: NativeTool
    let toolVersion: String?
    let result: NativeToolResult
    let startedAt: Date
    let completedAt: Date
}

final class FASTQDerivativeNativeProvenanceCollector: @unchecked Sendable {
    let lock = NSLock()
    var executions: [FASTQDerivativeNativeToolExecution] = []

    func append(_ execution: FASTQDerivativeNativeToolExecution) {
        lock.lock()
        executions.append(execution)
        lock.unlock()
    }
}
