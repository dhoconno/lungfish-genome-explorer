// ExecutorRunAdoption+SharedChecks.swift - The adopt's checks every returned plan folder takes, whatever its plan makes
// (Phase 5.3 lane EX-ADOPT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// A returned plan folder whose plan and run record passed the checks every run takes, whatever its plan makes (lane
/// EX-ADOPT). The FASTQ adopt and the adopt of a schema 2 run each add their own checks to it.
struct ExecutorAdoptCheckedFolder: Sendable {
    let resolver: PlanResourceResolver
    let plan: ExecutionPlan
    let record: ExecutorRunRecord
    /// The image `staging.json` names, or nil for a folder that holds none.
    let stagingImage: ExecutorAdoptStagingImage?
}

extension ExecutorRunAdoption {
    /// The checks every returned plan folder takes, whatever its plan makes, in the order of the design's section 2: the
    /// folder, the plan and the record read and decoded, the outcome, the plan's digest, the manifest pin, the site facts
    /// and the staging image with its digest fact (lane EX-ADOPT). It writes nothing.
    static func checkShared(
        _ folder: URL, policy: ExecutorAdoptPolicy
    ) throws(ExecutorAdoptRefusal) -> ExecutorAdoptCheckedFolder {
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
        return ExecutorAdoptCheckedFolder(resolver: resolver, plan: plan, record: record, stagingImage: image)
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

    /// BIO 4 and BIO 6: the record holds one succeeded step for each step of the plan, in the plan's order, with the
    /// storage details, the Q20 and Q30 counts and the times that the bundle's records are built from, so the adapter
    /// invents no size, no clumping state, no outcome and no time.
    static func checkSteps(_ record: ExecutorRunRecord, plan: ExecutionPlan) throws(ExecutorAdoptRefusal) {
        for (name, text) in [("startedAt", record.startedAt), ("endedAt", record.endedAt)] where date(text) == nil {
            throw refusal(name, "The run record states a \(name) that is not an ISO 8601 time with milliseconds.")
        }
        for (index, planned) in plan.steps.enumerated() {
            let field = "steps[\(index)]"
            guard index < record.steps.count else {
                throw refusal(field, "The run record holds \(record.steps.count) steps, and the plan's step \(index + 1) is \(planned.id).")
            }
            let step = record.steps[index]
            guard step.id == planned.id, step.kind == planned.kind else {
                throw refusal(
                    field,
                    "The run record's step \(index + 1) is not the plan's step \(index + 1), \(planned.id) of kind \(planned.kind.rawValue)."
                )
            }
            guard step.outcome == .succeeded else {
                throw refusal(
                    field,
                    "The run record states the outcome \(step.outcome.rawValue) for the step \(planned.id), and a succeeded run finishes every step."
                )
            }
            if step.kind == .storage && step.storage == nil {
                throw refusal(field, "The run record states no storage details for the step \(planned.id).")
            }
            if step.kind == .qualityCount && step.qualityCounts == nil {
                throw refusal(field, "The run record states no Q20 and Q30 count for the step \(planned.id).")
            }
            for (name, text) in [("startedAt", step.startedAt), ("endedAt", step.endedAt)] where date(text) == nil {
                throw refusal(field, "The run record states a \(name) for the step \(planned.id) that is not an ISO 8601 time with milliseconds.")
            }
        }
        guard record.steps.count == plan.steps.count else {
            throw refusal(
                "steps[\(plan.steps.count)]", "The run record holds \(record.steps.count) steps, and the plan has \(plan.steps.count)."
            )
        }
    }
}
