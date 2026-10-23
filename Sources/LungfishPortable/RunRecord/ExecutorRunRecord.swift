// ExecutorRunRecord.swift - The record lungfish-executor writes for one `run --plan`, the one channel to the Mac (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The record of one `lungfish-executor run --plan` run, written last as `run-record.json` at the root of the plan's
/// folder by one rename (ARCH-r3 ruling 2). It is the only channel from the node to the bundle (tally K4.1), so the Mac's
/// adopt decodes it with `decode(_:)` and refuses one this build cannot read.
///
/// It carries no metadata sidecar, CSV or provenance envelope, which the Mac writes at adopt (owner answer O24), and no
/// path outside the work root, so the image manifest is stated by digest, size and source only (SWIFT ruling Q-K4-1).
package struct ExecutorRunRecord: Codable, Sendable, Equatable {
    /// The schema version this build reads and writes.
    package static let currentSchemaVersion = 1
    /// The record's file name at the root of the plan's folder.
    package static let fileName = "run-record.json"

    package var schemaVersion: Int
    package var outcome: ExecutorRunOutcome
    /// The code the executor exits with, `outcome.exitCode`.
    package var exitCode: Int32
    /// Why a run did not succeed, in the words the executor printed.
    package var reason: String?
    /// The plan field or argument a refused run names, such as `imageManifest` or `--site-fact 3`.
    package var refusedField: String?
    /// The step a failed or interrupted run stopped at.
    package var failedStepID: String?
    /// The termination signal that interrupted the run.
    package var signal: Int32?
    package var signalName: String?
    /// The executor's argv after its own path, with the `--plan` value cut to its file name and the `--image-manifest`
    /// value stated as `(not recorded)`, so the record holds no path of the machine (SWIFT rulings N8 and Q-K4-1). The
    /// `--site-fact` pairs are verbatim (tally-r2 3.1).
    package var executorArguments: [String]
    package var executor: ExecutorBinaryIdentity
    /// The plan file the run read, nil when the run was refused before it could read one.
    package var plan: ExecutorFileDigest?
    /// The plan's recipe identity, with each step a switch turned off and that switch (BIO-r3 R8). Nil for a plan with
    /// no recipe and for a run refused before it decoded the plan.
    package var recipe: PlanRecipeIdentity?
    /// The tool manifest the run read, nil when the run was refused before it read one.
    package var imageManifest: ExecutorImageManifestRecord?
    /// What the executor observed of the machine itself. It never reads a scheduler's variable or file.
    package var runtimeIdentity: ExecutorRuntimeIdentity
    /// The `--site-fact KEY=VALUE` arguments in the order given, recorded verbatim and never interpreted.
    package var siteFacts: [PlanKeyValue]
    /// The plan entries the executor checked, each with the digest and size it read.
    package var inputs: [PlanEntry]
    /// The files the run leaves for the Mac to adopt.
    package var payloads: [ExecutorPayloadRecord]
    package var steps: [ExecutorStepRecord]
    /// ISO 8601 times in UTC, from `timestamp(_:)`.
    package var startedAt: String
    package var endedAt: String
    package var wallSeconds: Double

    package init(
        schemaVersion: Int = ExecutorRunRecord.currentSchemaVersion, outcome: ExecutorRunOutcome, reason: String? = nil,
        refusedField: String? = nil, failedStepID: String? = nil, signal: Int32? = nil, signalName: String? = nil,
        executorArguments: [String], executor: ExecutorBinaryIdentity, plan: ExecutorFileDigest?, recipe: PlanRecipeIdentity? = nil,
        imageManifest: ExecutorImageManifestRecord?, runtimeIdentity: ExecutorRuntimeIdentity,
        siteFacts: [PlanKeyValue] = [], inputs: [PlanEntry] = [], payloads: [ExecutorPayloadRecord] = [],
        steps: [ExecutorStepRecord] = [], startedAt: String, endedAt: String, wallSeconds: Double
    ) {
        self.schemaVersion = schemaVersion
        self.outcome = outcome
        self.exitCode = outcome.exitCode
        self.reason = reason
        self.refusedField = refusedField
        self.failedStepID = failedStepID
        self.signal = signal
        self.signalName = signalName
        self.executorArguments = executorArguments
        self.executor = executor
        self.plan = plan
        self.recipe = recipe
        self.imageManifest = imageManifest
        self.runtimeIdentity = runtimeIdentity
        self.siteFacts = siteFacts
        self.inputs = inputs
        self.payloads = payloads
        self.steps = steps
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.wallSeconds = wallSeconds
    }
}

/// The executor binary that ran: the SHA-256 and size of `/proc/self/exe` where it can read them, and the build the
/// plan's `executor` entry pins, which the binary cannot state of itself (ARCH A3).
package struct ExecutorBinaryIdentity: Codable, Sendable, Equatable {
    package var sha256: String?
    package var size: Int64?
    package var buildPin: PlanExecutorBuild?

    package init(sha256: String?, size: Int64?, buildPin: PlanExecutorBuild?) {
        self.sha256 = sha256
        self.size = size
        self.buildPin = buildPin
    }
}

/// Where the executor read its tool manifest (SWIFT ruling Q-K4-1). The C4 adopt refuses a CHTC record with `argument`.
package enum ExecutorImageManifestSource: String, Codable, Sendable, CaseIterable {
    /// The compiled-in `/opt/lungfish/image-manifest.json` of the image.
    case image
    /// The file `--image-manifest` named, as in a Mac replay.
    case argument
}

/// The tool manifest the run read, by the SHA-256 and size of its bytes and its source, never its path.
package struct ExecutorImageManifestRecord: Codable, Sendable, Equatable {
    package var sha256: String
    package var size: Int64
    package var source: ExecutorImageManifestSource

    package init(sha256: String, size: Int64, source: ExecutorImageManifestSource) {
        self.sha256 = sha256
        self.size = size
        self.source = source
    }
}

/// How the executor found descendants of a tool that left its group (tally-r2 K3-6, XC-20).
package enum ExecutorOrphanSweep: String, Codable, Sendable, CaseIterable {
    /// The executor is a child subreaper, so a descendant that left the group re-parents to it and is found.
    case subreaper
    /// The subreaper call failed or is absent, so only descendants still under the tool's own tree are found.
    case parentWalkOnly
}

/// A limit the preflight observed, with the file it read. `value` is nil when the executor could not read it, shown as
/// not observed, and a value the executor could not read never refuses a run (SWIFT preflight words).
package struct ExecutorObservedLimit: Codable, Sendable, Equatable {
    /// `memTotalBytes`, `cpusAllowedList` or `cgroupMemoryMaxBytes`.
    package var name: String
    /// The value as read, memory in bytes as a decimal number and the CPU list verbatim.
    package var value: String?
    /// The file and line the value came from, such as `/proc/meminfo MemTotal`.
    package var source: String

    package init(name: String, value: String?, source: String) {
        self.name = name
        self.value = value
        self.source = source
    }
}

/// What the executor observed itself, never a scheduler's attribute (SWIFT preflight words, tally-r2 3.1).
package struct ExecutorRuntimeIdentity: Codable, Sendable, Equatable {
    /// `uname` release and machine.
    package var kernelRelease: String?
    package var machine: String?
    /// The number of PID namespaces on the `NSpid` line of `/proc/self/status`, nil off Linux.
    package var pidNamespaceDepth: Int?
    /// 2 for a unified cgroup line in `/proc/self/cgroup`, 1 for a v1 host, nil when not observed.
    package var cgroupVersion: Int?
    package var observedLimits: [ExecutorObservedLimit]
    package var subreaper: ExecutorStepRecord.Subreaper
    package var orphanSweep: ExecutorOrphanSweep

    package init(
        kernelRelease: String?, machine: String?, pidNamespaceDepth: Int?, cgroupVersion: Int?,
        observedLimits: [ExecutorObservedLimit], subreaper: ExecutorStepRecord.Subreaper, orphanSweep: ExecutorOrphanSweep
    ) {
        self.kernelRelease = kernelRelease
        self.machine = machine
        self.pidNamespaceDepth = pidNamespaceDepth
        self.cgroupVersion = cgroupVersion
        self.observedLimits = observedLimits
        self.subreaper = subreaper
        self.orphanSweep = orphanSweep
    }
}

/// A file the run leaves for the adopt, and the record count of the full pass that read it (tally K4.1).
package struct ExecutorPayloadRecord: Codable, Sendable, Equatable {
    package var relativePath: String
    package var sha256: String
    package var size: Int64
    package var recordCount: Int64?
    /// The file the record-count pass read, which the adopt compares with the payload's own digest.
    package var recordCountFile: ExecutorFileDigest?

    package init(relativePath: String, sha256: String, size: Int64, recordCount: Int64? = nil, recordCountFile: ExecutorFileDigest? = nil) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
        self.recordCount = recordCount
        self.recordCountFile = recordCountFile
    }
}

/// Why a run record cannot be read, naming the field.
package struct ExecutorRunRecordDecodeError: Error, Equatable, CustomStringConvertible {
    package var field: String
    package var reason: String

    package init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    package var description: String { "\(field): \(reason)" }
}

extension ExecutorRunRecord {
    /// Decodes a record and refuses one from a newer schema or whose exit code and outcome disagree.
    package static func decode(_ data: Data) throws -> ExecutorRunRecord {
        let record: ExecutorRunRecord
        do {
            record = try JSONDecoder().decode(ExecutorRunRecord.self, from: data)
        } catch let error as DecodingError {
            throw ExecutorRunRecordDecodeError(field: Self.fieldPath(of: error), reason: "This run record cannot be read.")
        }
        guard (1...currentSchemaVersion).contains(record.schemaVersion) else {
            throw ExecutorRunRecordDecodeError(
                field: "schemaVersion",
                reason: "This run record has schema version \(record.schemaVersion), and this build reads 1 to \(currentSchemaVersion)."
            )
        }
        guard record.exitCode == record.outcome.exitCode else {
            throw ExecutorRunRecordDecodeError(
                field: "exitCode",
                reason: "This run record states exit code \(record.exitCode) for the outcome \(record.outcome.rawValue)."
            )
        }
        return record
    }

    /// The record file's bytes, keys sorted so equal records are equal bytes.
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    /// A time as the record states it, ISO 8601 in UTC with milliseconds.
    package static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fieldPath(of error: DecodingError) -> String {
        let path: [CodingKey]
        switch error {
        case .keyNotFound(let key, let context): path = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
        @unknown default: path = []
        }
        let names = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
        return names.isEmpty ? "record" : names.joined(separator: ".")
    }
}
