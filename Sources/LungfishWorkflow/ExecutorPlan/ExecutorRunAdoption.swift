// ExecutorRunAdoption.swift - The Mac's adopt of a plan folder a Linux run returned: its reads and refusals (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Which run records the adopt accepts (ARCH ruling Q-C4-6). `release` is the only public value, and the CLI's
/// `--adopt` and the GUI's adopt sheet reach the adopt only through the public entry, which always uses it. The replay
/// value lifts the one refusal of a manifest that `--image-manifest` named, so the parity tests can adopt a Mac replay,
/// and nothing else. It and the entry that takes a policy are `internal`, never `package` or `public`, so only this
/// module and a test that writes `@testable import LungfishWorkflow` reach them.
public struct ExecutorAdoptPolicy: Sendable, Equatable {
    let acceptsArgumentManifestSource: Bool

    /// Refuses a record whose `imageManifest.source` is `argument`.
    public static let release = ExecutorAdoptPolicy(acceptsArgumentManifestSource: false)
    static let macReplayForTests = ExecutorAdoptPolicy(acceptsArgumentManifestSource: true)
}

/// Why the adopt refused a plan folder, naming the file or record field. Every refusal comes before any bundle file
/// exists (C4 design section 2).
public struct ExecutorAdoptRefusal: Error, Equatable, Sendable, LocalizedError {
    public let field: String
    public let reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

/// A returned plan folder whose plan and run record passed every check of the adopt.
struct ExecutorAdoptedRun: Sendable {
    let folder: URL
    let plan: ExecutionPlan
    let record: ExecutorRunRecord
    let payload: ExecutorPayloadRecord
    /// The payload's real path inside the folder, as the resolver checked it.
    let payloadURL: URL
    /// `sample.sampleName` through the one name sanitizer, or the name `--name` gave.
    let sampleName: String
    /// The image `staging.json` names, or nil for a folder that holds none.
    let stagingImage: ExecutorAdoptStagingImage?
}

/// The adopt: it reads a plan folder that `lungfish-executor run --plan` returned and writes the bundle's sidecar and
/// envelope from the plan and the run record with the import's own IO code (Q-C3-1 A, V4a).
public enum ExecutorRunAdoption {
    static let planFileName = "plan.json"
    /// The largest plan the executor reads, so the adopt reads no larger one.
    static let largestPlanBytes = 16 << 20
    static let largestRecordBytes = 256 << 20

    /// Adopts the folder into the project under `ExecutorAdoptPolicy.release` and returns the bundle it published.
    /// The envelope's argv is `cliArguments` of the same values, with `--format json` when `eventsOn` is set.
    public static func adopt(
        resultFolder: URL, projectDirectory: URL, name: String? = nil, force: Bool = false, eventsOn: Bool = false
    ) async throws -> URL {
        try await adopt(
            resultFolder: resultFolder, projectDirectory: projectDirectory, name: name, force: force, eventsOn: eventsOn,
            policy: .release
        )
    }

    /// `signingEnvironment` is where the signing key is read from, the process's own outside a test.
    static func adopt(
        resultFolder: URL, projectDirectory: URL, name: String? = nil, force: Bool = false, eventsOn: Bool = false,
        policy: ExecutorAdoptPolicy, signingEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> URL {
        let run = try check(resultFolder, name: name, policy: policy)
        let argv = [CLICommandIdentity.executableName] + cliArguments(
            resultFolder: resultFolder, projectDirectory: projectDirectory, name: name, force: force, eventsOn: eventsOn
        )
        return try await writeBundle(
            run, projectDirectory: projectDirectory, force: force, argv: argv, signingEnvironment: signingEnvironment
        )
    }

    /// The reads of the design's section 2 in order, the plan, the record, the plan's digest and each payload, with
    /// every refusal. It writes nothing.
    static func check(
        _ folder: URL, name: String? = nil, policy: ExecutorAdoptPolicy
    ) throws(ExecutorAdoptRefusal) -> ExecutorAdoptedRun {
        let resolver: PlanResourceResolver
        do {
            resolver = try PlanResourceResolver(workRoot: folder)
        } catch {
            throw refusal("folder", "The folder \(folder.lastPathComponent) cannot be read. \(error.localizedDescription)")
        }
        let planBytes = try read(planFileName, in: resolver, limit: largestPlanBytes)
        let plan: ExecutionPlan
        do {
            plan = try ExecutionPlan.decode(planBytes)
        } catch let error as PlanDecodeError {
            throw refusal(error.field, "The plan cannot be adopted. \(error.reason)")
        } catch {
            throw refusal(planFileName, "The plan file \(planFileName) cannot be read.")
        }
        let recordBytes = try read(ExecutorRunRecord.fileName, in: resolver, limit: largestRecordBytes)
        let record: ExecutorRunRecord
        do {
            record = try ExecutorRunRecord.decode(recordBytes)
        } catch let error as ExecutorRunRecordDecodeError {
            throw refusal(error.field, "The run record cannot be adopted. \(error.reason)")
        } catch {
            throw refusal(ExecutorRunRecord.fileName, "The run record \(ExecutorRunRecord.fileName) cannot be read.")
        }
        guard record.outcome == .succeeded else {
            let why = record.reason.map { " \($0)" } ?? ""
            throw refusal("outcome", "The run record states the outcome \(record.outcome.rawValue), so the run left nothing to adopt.\(why)")
        }
        let planDigest = PortableDigest.sha256Hex(of: planBytes)
        guard let ran = record.plan, ran.sha256 == planDigest, ran.size == Int64(planBytes.count) else {
            throw refusal("plan", "The run record names a plan with SHA-256 \(record.plan?.sha256 ?? "none"), and this folder's "
                + "\(planFileName) has SHA-256 \(planDigest).")
        }
        try checkManifest(record.imageManifest, pin: plan.imageManifest, policy: policy)
        // C4-02: the executor's own bounds, so a record that breaks one never reaches the bundle.
        if let violation = SiteFactRules.violation(in: record.siteFacts) {
            throw refusal("siteFacts[\(violation.position - 1)]", violation.sentence)
        }
        let image = try stagingImage(in: resolver)
        try checkImageDigestFact(record.siteFacts, image: image)
        let (payload, payloadURL) = try checkPayload(record, resolver: resolver)
        let sampleName = name ?? SampleFolderNaming.sanitizedDirectoryName(for: plan.sample.sampleName)
        return ExecutorAdoptedRun(
            folder: URL(fileURLWithPath: resolver.workRoot, isDirectory: true), plan: plan, record: record,
            payload: payload, payloadURL: payloadURL, sampleName: sampleName, stagingImage: image
        )
    }

    /// The manifest the run read: present, the image's own unless the policy says otherwise, and the plan's pin.
    private static func checkManifest(
        _ manifest: ExecutorImageManifestRecord?, pin: PlanImageManifestPin, policy: ExecutorAdoptPolicy
    ) throws(ExecutorAdoptRefusal) {
        guard let manifest else {
            throw refusal("imageManifest", "The run record names no tool manifest, so the tool versions it states cannot be checked.")
        }
        if manifest.source == .argument && !policy.acceptsArgumentManifestSource {
            throw refusal(
                "imageManifest.source",
                "The run read a tool manifest that --image-manifest named, as a replay on the Mac does, and not the image's own. "
                    + "A replay is never adopted."
            )
        }
        guard manifest.sha256 == pin.sha256, manifest.size == pin.size else {
            throw refusal(
                "imageManifest.sha256",
                "The run read a tool manifest with SHA-256 \(manifest.sha256) and \(manifest.size) bytes, and the plan pins "
                    + "\(pin.sha256) and \(pin.size) bytes."
            )
        }
    }

    /// S-1: the one payload's size and SHA-256 against the record, by the resolver's path and link rules, and its record
    /// count against a pass that read those bytes.
    private static func checkPayload(
        _ record: ExecutorRunRecord, resolver: PlanResourceResolver
    ) throws(ExecutorAdoptRefusal) -> (ExecutorPayloadRecord, URL) {
        guard record.payloads.count == 1, let payload = record.payloads.first else {
            throw refusal("payloads", "The run record states \(record.payloads.count) payloads, and the adopt takes one.")
        }
        let path = payload.relativePath
        let url: URL
        do {
            url = try resolver.verify(PlanEntry(role: .input, relativePath: path, sha256: payload.sha256, size: payload.size))
        } catch let error as PlanResourceRefusal {
            throw refusal("payloads[0]", payloadSentence(error, path: path))
        } catch {
            throw refusal("payloads[0]", "The payload \(path) cannot be read. \(error.localizedDescription)")
        }
        let own = ExecutorFileDigest(relativePath: path, sha256: payload.sha256, size: payload.size)
        guard let count = payload.recordCount, payload.recordCountFile == own else {
            throw refusal("payloads[0].recordCountFile", "The run record states no record count read from the payload \(path) itself.")
        }
        if let index = record.steps.firstIndex(where: { $0.qualityCounts != nil }),
           let counts = record.steps[index].qualityCounts, counts.file != own || counts.recordCount != count {
            throw refusal(
                "steps[\(index)].qualityCounts",
                "The Q20 and Q30 count read \(counts.recordCount) records of \(counts.file.relativePath), and the payload \(path) "
                    + "holds \(count)."
            )
        }
        return (payload, url)
    }

    private static func payloadSentence(_ error: PlanResourceRefusal, path: String) -> String {
        switch error {
        case .digestMismatch(_, let expected, let actual):
            return "The payload \(path) has SHA-256 \(actual), and the run record states \(expected)."
        case .sizeMismatch(_, let expected, let actual):
            return "The payload \(path) holds \(actual) bytes, and the run record states \(expected)."
        case .missing:
            return "The payload \(path) is missing from the folder."
        default:
            return "The payload \(path) cannot be adopted. \(error.reason)"
        }
    }

    /// A regular file at the folder's root, never through a link, at most `limit` bytes.
    static func read(_ name: String, in resolver: PlanResourceResolver, limit: Int) throws(ExecutorAdoptRefusal) -> Data {
        let path = resolver.workRoot + "/" + name
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            throw refusal(name, "The folder holds no \(name).")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw refusal(name, "\(name) is not a regular file.")
        }
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= limit else {
            throw refusal(name, "\(name) is over the limit of \(limit) bytes.")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw refusal(name, "\(name) cannot be read.")
        }
        return data
    }

    static func refusal(_ field: String, _ reason: String) -> ExecutorAdoptRefusal {
        ExecutorAdoptRefusal(field: field, reason: "\(reason) Nothing was imported.")
    }
}
