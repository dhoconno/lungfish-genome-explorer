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
        viewer.viewerView.cancelDetachedAlignmentFetches()
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        availability = .loading
        status = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let validated = try await validator.validate(request)
                guard !Task.isCancelled, currentGeneration == generation else { return }
                let source = SequenceViewerView.DetachedAlignmentSource(
                    identityURL: request.bamURL,
                    contig: .init(name: validated.contig.name, length: validated.contig.length),
                    provider: validated.provider,
                    referenceSequence: validated.reference.sequence
                )
                viewer.displayDetachedAlignment(source)
                availability = .available(reference: validated.reference.status, reason: validated.reference.reason)
                status = .available(referenceStrength: String(describing: validated.reference.status), reason: validated.reference.reason)
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                viewer.viewerView.clearReferenceBundle()
                availability = .unavailable(error.localizedDescription)
                status = .unavailable(error.localizedDescription)
            }
        }
    }

    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        viewer.viewerView.clearReferenceBundle()
        availability = .idle
        status = .idle
    }
}
