// ClassifierAlignmentEvidenceViewportController.swift - App-owned detached evidence provider
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// Bridges classifier leaf requests to the existing App-owned full viewer.
/// No wrapper bundle is created and `clear` only clears in-memory display state.
@MainActor
final class ClassifierAlignmentEvidenceViewportController: NSObject, ClassifierAlignmentViewerProviding {
    enum Availability: Equatable {
        case idle
        case loading
        case available(reference: ClassifierAlignmentEvidenceValidator.ReferenceStatus, reason: String?)
        case unavailable(String)
    }

    let viewer = ViewerViewController()
    private let statusLabel = NSTextField(labelWithString: "")
    private let validator: ClassifierAlignmentEvidenceValidator
    private var generation = 0
    private var task: Task<Void, Never>?
    private(set) var availability: Availability = .idle
    private(set) var status: ClassifierAlignmentViewerStatus = .idle { didSet { publishStatus() } }
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var inspectorCapabilities: ClassifierAlignmentInspectorCapabilities? {
        didSet { onInspectorCapabilitiesChanged?(inspectorCapabilities) }
    }
    var onInspectorCapabilitiesChanged: (@MainActor (ClassifierAlignmentInspectorCapabilities?) -> Void)?

    init(validator: ClassifierAlignmentEvidenceValidator = .init()) {
        self.validator = validator
        super.init()
    }

    var viewController: NSViewController { viewer }
    var visibleStatusText: String { statusLabel.stringValue }

    private func publishStatus() {
        statusLabel.stringValue = status.message
        statusLabel.isHidden = status == .idle
        onStatusChanged?(status)
    }

    private func installStatusLabel() {
        guard statusLabel.superview == nil else { return }
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.drawsBackground = true
        statusLabel.backgroundColor = .windowBackgroundColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        viewer.view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: viewer.view.leadingAnchor, constant: 8),
            statusLabel.topAnchor.constraint(equalTo: viewer.view.topAnchor, constant: 6),
        ])
        publishStatus()
    }

    func display(_ request: ClassifierAlignmentEvidenceRequest) {
        _ = viewer.view
        installStatusLabel()
        viewer.viewerView.onDetachedEvidenceStale = { [weak self] reason in
            self?.availability = .unavailable(reason)
            self?.status = .stale(reason)
        }
        // A new request must never leave prior evidence visible while its own
        // validation is pending; this also tears down the old vnode monitors.
        viewer.viewerView.clearReferenceBundle()
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        availability = .loading
        status = .loading
        inspectorCapabilities = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let validated = try await validator.validate(request)
                guard !Task.isCancelled, currentGeneration == generation else { return }
                let source = SequenceViewerView.DetachedAlignmentSource(
                    identityURL: request.bamURL,
                    contig: .init(name: validated.contig.name, length: validated.contig.length),
                    provider: validated.provider,
                    referenceSequence: validated.reference.sequence,
                    bamSnapshot: validated.bamSnapshot,
                    indexSnapshot: validated.indexSnapshot,
                    referenceURL: request.referenceCandidate?.fastaURL,
                    referenceSnapshot: validated.referenceSnapshot
                )
                guard viewer.displayDetachedAlignment(source) else {
                    let reason = viewer.viewerView.detachedEvidenceStaleReason ?? "Classifier alignment evidence could not be verified."
                    availability = .unavailable(reason)
                    status = .stale(reason)
                    return
                }
                availability = .available(reference: validated.reference.status, reason: validated.reference.reason)
                status = .available(referenceStrength: referenceStrengthText(validated.reference.status), reason: validated.reference.reason)
                inspectorCapabilities = .detachedEvidence(
                    workflow: request.presentation.workflowLabel,
                    result: request.presentation.resultLabel,
                    sample: request.presentation.sampleLabel,
                    contig: validated.contig.name,
                    bamPath: request.bamURL.path,
                    indexPath: request.index.url.path,
                    referenceValidation: inspectorReferenceValidation(validated.reference),
                    readGroups: validated.readGroups.map { .init(id: $0.id, sample: $0.sample) },
                    status: status
                )
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                viewer.viewerView.clearReferenceBundle()
                availability = .unavailable(error.localizedDescription)
                status = .unavailable(error.localizedDescription)
                inspectorCapabilities = nil
            }
        }
    }

    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        viewer.viewerView.clearReferenceBundle()
        viewer.viewerView.onDetachedEvidenceStale = nil
        availability = .idle
        status = .idle
        inspectorCapabilities = nil
    }

    private func referenceStrengthText(_ status: ClassifierAlignmentEvidenceValidator.ReferenceStatus) -> String {
        switch status {
        case .notProvided: "not provided"
        case .validatedStructural: "structurally validated"
        case .validatedMD5: "BAM M5 validated"
        case .unavailable: "unavailable"
        }
    }

    private func inspectorReferenceValidation(
        _ reference: ClassifierAlignmentEvidenceValidator.Reference
    ) -> ClassifierAlignmentInspectorCapabilities.ReferenceValidation {
        switch reference.status {
        case .notProvided: .absent
        case .validatedStructural: .structural
        case .validatedMD5: .md5
        case .unavailable: .unavailable(reference.reason ?? "The requested FASTA reference is unavailable.")
        }
    }
}
