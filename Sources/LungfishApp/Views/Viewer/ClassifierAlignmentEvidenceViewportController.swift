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
        case available(reference: ClassifierAlignmentEvidenceValidator.ReferenceStatus)
        case unavailable(String)
    }

    let viewer = ViewerViewController()
    private let validator: ClassifierAlignmentEvidenceValidator
    private var generation = 0
    private var task: Task<Void, Never>?
    private(set) var availability: Availability = .idle

    init(validator: ClassifierAlignmentEvidenceValidator = .init()) {
        self.validator = validator
        super.init()
    }

    var viewController: NSViewController { viewer }

    func display(_ request: ClassifierAlignmentEvidenceRequest) {
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        availability = .loading
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
                availability = .available(reference: validated.reference.status)
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                viewer.viewerView.clearReferenceBundle()
                availability = .unavailable(error.localizedDescription)
            }
        }
    }

    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        viewer.viewerView.clearReferenceBundle()
        availability = .idle
    }
}
