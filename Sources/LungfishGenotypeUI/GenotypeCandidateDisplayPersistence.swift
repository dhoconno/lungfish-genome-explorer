import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum GenotypeCandidateDisplayPersistenceError: Error, LocalizedError, Sendable {
    case staleRevision(latest: GenotypeAnnotationSidecar)

    var errorDescription: String? {
        switch self {
        case .staleRevision:
            return "The genotype annotations changed in another process. The latest bundle settings were restored; review them before saving again."
        }
    }

    var latestSidecar: GenotypeAnnotationSidecar {
        switch self {
        case .staleRevision(let latest): latest
        }
    }
}

/// Performs the locked candidate-display sidecar transaction away from the
/// main actor. Only the resulting immutable sidecar is returned to AppKit.
enum GenotypeCandidateDisplayPersistence {
    static func persist(
        display: ONTMHCCandidateDisplaySettings,
        expectedDisplay: ONTMHCCandidateDisplaySettings,
        bundleURL: URL,
        author: String
    ) async throws -> GenotypeAnnotationSidecar {
        try await Task.detached(priority: .userInitiated) {
            try persistSynchronously(
                display: display,
                expectedDisplay: expectedDisplay,
                bundleURL: bundleURL,
                author: author
            )
        }.value
    }

    private static func persistSynchronously(
        display: ONTMHCCandidateDisplaySettings,
        expectedDisplay: ONTMHCCandidateDisplaySettings,
        bundleURL: URL,
        author: String
    ) throws -> GenotypeAnnotationSidecar {
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let coordinator = GenotypeAnnotationPublicationCoordinator(
            bundleURL: bundleURL,
            annotationFilename: annotationURL.lastPathComponent,
            provenanceFilename: provenanceURL.lastPathComponent,
            faultInjector: nil
        )
        let startedAt = Date()
        let timestamp = ISO8601DateFormatter().string(from: startedAt)
        var published: GenotypeAnnotationSidecar?
        _ = try coordinator.transact { snapshot in
            let latest = try snapshot.annotationData.map(GenotypeAnnotationSidecar.decode)
                ?? GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
            guard latest.settings.mhcCandidateDisplay == expectedDisplay else {
                throw GenotypeCandidateDisplayPersistenceError.staleRevision(latest: latest)
            }
            guard latest.settings.mhcCandidateDisplay != display else {
                published = latest
                return nil
            }
            var next = latest
            try next.promoteToCurrentSchema()
            next.settings.mhcCandidateDisplay = display
            next.append(audit: .init(
                action: "updateMHCCandidateDisplaySettings",
                sample: "bundle",
                locus: nil,
                slot: nil,
                before: summary(latest.settings.mhcCandidateDisplay),
                after: summary(display),
                color: nil,
                reason: "mhc-candidate-display-settings",
                rationale: nil,
                author: author,
                timestamp: timestamp
            ))
            let annotationData = try next.encoded()
            let priorInput = snapshot.annotationData.map {
                descriptor(data: $0, url: annotationURL, role: .input)
            }
            let output = descriptor(data: annotationData, url: annotationURL, role: .output)
            let provenance = makeProvenance(
                sidecar: next,
                display: display,
                bundleURL: bundleURL,
                annotationURL: annotationURL,
                author: author,
                priorInput: priorInput,
                output: output,
                startedAt: startedAt,
                endedAt: Date()
            )
            published = next
            return try GenotypeAnnotationPublicationPayload(
                annotationData: annotationData,
                provenanceData: ProvenanceJSON.encoder.encode(provenance)
            )
        }
        return published ?? GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
    }

    private static func descriptor(
        data: Data,
        url: URL,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            fileSize: UInt64(data.count),
            format: .json,
            role: role
        )
    }

    private static func makeProvenance(
        sidecar: GenotypeAnnotationSidecar,
        display: ONTMHCCandidateDisplaySettings,
        bundleURL: URL,
        annotationURL: URL,
        author: String,
        priorInput: ProvenanceFileDescriptor?,
        output: ProvenanceFileDescriptor,
        startedAt: Date,
        endedAt: Date
    ) -> ProvenanceEnvelope {
        let argv = [
            CLICommandIdentity.executableName,
            "genotype", "apply-annotations",
            "--bundle", bundleURL.path,
            "--patch", annotationURL.path,
        ]
        let inputs = [priorInput].compactMap { $0 }
        let wallTime = max(0, endedAt.timeIntervalSince(startedAt))
        let explicit: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "annotationSidecar": .file(annotationURL),
            "patch": .file(annotationURL),
            "action": .string("updateMHCCandidateDisplaySettings"),
            "showKnown": .boolean(display.showKnown),
            "showSharedCandidates": .boolean(display.showSharedCandidates),
            "showSingletonCandidates": .boolean(display.showSingletonCandidates),
            "candidateTints": .dictionary(Dictionary(uniqueKeysWithValues:
                ONTMHCCandidateTintCategory.allCases.map { category in
                    let color = display.tints[category]
                        ?? ONTMHCCandidateDisplaySettings.defaultTints[category]!
                    return (category.rawValue, tintValue(color))
                }
            )),
        ]
        let step = ProvenanceStep(
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            inputs: inputs,
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: wallTime,
            startedAt: startedAt,
            completedAt: endedAt
        )
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "Genotype annotation sidecar edit",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: .init(name: "Lungfish Genome Explorer", version: WorkflowRun.currentAppVersion, kind: "gui"),
            argv: argv,
            options: .init(
                explicit: explicit,
                defaults: [
                    "format": .string("json"),
                    "sidecarFilename": .string(GenotypeAnnotationSidecar.filename),
                ],
                resolvedDefaults: [
                    "author": .string(author),
                    "auditEntryCount": .integer(sidecar.auditLog.count),
                    "callOverrideCount": .integer(sidecar.callOverrides.count),
                    "matrixStyleCount": .integer(sidecar.matrixStyles.count),
                    "matrixCommentCount": .integer(sidecar.matrixComments.count),
                    "manualHaplotypeAssignmentCount": .integer(sidecar.manualHaplotypeAssignments.count),
                    "smartCohortCount": .integer(sidecar.smartCohorts.count),
                ]
            ),
            runtimeIdentity: .init(user: WorkflowRun.currentUser),
            files: inputs + [output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: wallTime,
            exitStatus: 0
        )
    }

    private static func tintValue(_ color: AnnotationColor) -> ParameterValue {
        .dictionary([
            "red": .number(color.red),
            "green": .number(color.green),
            "blue": .number(color.blue),
            "alpha": .number(color.alpha),
            "hexRGB": .string(color.hexString),
        ])
    }

    private static func summary(_ display: ONTMHCCandidateDisplaySettings) -> String {
        let tints = ONTMHCCandidateTintCategory.allCases.map { category in
            let color = display.tints[category] ?? ONTMHCCandidateDisplaySettings.defaultTints[category]!
            return "\(category.rawValue)={red=\(color.red),green=\(color.green),blue=\(color.blue),alpha=\(color.alpha),hexRGB=\(color.hexString)}"
        }.joined(separator: ",")
        return "showKnown=\(display.showKnown); showSharedCandidates=\(display.showSharedCandidates); showSingletonCandidates=\(display.showSingletonCandidates); \(tints)"
    }
}
