// ClassifierAlignmentEvidenceViewportController.swift - App-owned detached evidence provider
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// Bridges classifier leaf requests to the existing App-owned full viewer.
/// No wrapper bundle is created and `clear` only clears in-memory display state.
@MainActor
final class ClassifierAlignmentEvidenceViewportController: NSObject, ClassifierAlignmentViewerProviding {
    private struct InspectorSnapshots {
        let bam: ClassifierAlignmentEvidenceFileSnapshot
        let index: ClassifierAlignmentEvidenceFileSnapshot
        let reference: ClassifierAlignmentEvidenceFileSnapshot?
    }

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
    private var activeRequest: ClassifierAlignmentEvidenceRequest?
    private var observedInspectorSnapshots: InspectorSnapshots?
    /// Detached evidence owns no independent metadata store or chooser.  It
    /// retains the classifier result context so Inspector attachment actions
    /// continue to target the same parent result/list presentation.
    private var sampleMetadataPresentationContext: SampleMetadataPresentationContext?
    private(set) var availability: Availability = .idle
    private(set) var status: ClassifierAlignmentViewerStatus = .idle { didSet { publishStatus() } }
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var inspectorCapabilities: ClassifierAlignmentInspectorCapabilities? {
        didSet { onInspectorCapabilitiesChanged?(inspectorCapabilities) }
    }
    var onInspectorCapabilitiesChanged: (@MainActor (ClassifierAlignmentInspectorCapabilities?) -> Void)?

    var isAvailableForFullViewerActions: Bool {
        if case .available = availability { return true }
        return false
    }

#if DEBUG
    func testSetAvailability(_ availability: Availability) {
        self.availability = availability
    }
#endif

    init(validator: ClassifierAlignmentEvidenceValidator = .init()) {
        self.validator = validator
        super.init()
    }

    var viewController: NSViewController { viewer }
    var visibleStatusText: String { statusLabel.stringValue }

    /// Connects this App-owned viewport to the active Inspector.  The callback
    /// is direct and window-local, avoiding global notification cross-talk.
    func bindInspector(_ inspector: InspectorViewController) {
        viewer.onAlignmentConsensusActionStateChanged = { [weak self, weak inspector] in
            guard let self, let inspector else { return }
            let state = self.consensusScopeState()
            inspector.readStyleSectionViewModel.consensusScope = state.scope
            inspector.readStyleSectionViewModel.consensusExtractionAvailabilityMessage = state.unavailableMessage
        }
        onInspectorCapabilitiesChanged = { [weak self, weak inspector] capabilities in
            guard let inspector else { return }
            guard let capabilities else {
                inspector.readStyleSectionViewModel.clear()
                inspector.viewModel.documentSectionViewModel.visibleAlignmentTrackID = nil
                inspector.viewModel.contentMode = .empty
                inspector.viewModel.selectedTab = .bundle
                return
            }
            inspector.viewModel.contentMode = .metagenomics
            inspector.viewModel.selectedTab = .view
            inspector.updateClassifierAlignmentInspector(
                capabilities: capabilities,
                applySettings: { [weak self] payload in
                    self?.viewer.applyReadDisplaySettings(payload)
                    self?.refreshActionContextFilters()
                },
                consensusScopeState: { [weak self] in self?.consensusScopeState() ?? (.wholeContig, AlignmentScientificActionError.contextUnavailable.localizedDescription) },
                setConsensusScope: { [weak self] in self?.viewer.alignmentConsensusScope = $0 },
                extractConsensus: { [weak self] in self?.requestClassifierConsensusGeneration() }
            )
        }
        if let inspectorCapabilities { onInspectorCapabilitiesChanged?(inspectorCapabilities) }
    }

    func bindSampleMetadataPresentation(_ context: SampleMetadataPresentationContext?) {
        sampleMetadataPresentationContext = context
    }

#if DEBUG
    var testSampleMetadataPresentationContext: SampleMetadataPresentationContext? {
        sampleMetadataPresentationContext
    }
#endif

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
            self?.viewer.alignmentActionContext = nil
            self?.availability = .unavailable(reason)
            self?.status = .stale(reason)
            self?.publishInspectorCapabilities(reference: .unavailable(reason), readGroups: [])
        }
        // A new request must never leave prior evidence visible while its own
        // validation is pending; this also tears down the old vnode monitors.
        viewer.viewerView.clearReferenceBundle()
        viewer.alignmentActionContext = nil
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        activeRequest = request
        observedInspectorSnapshots = nil
        availability = .loading
        status = .loading
        publishInspectorCapabilities(reference: request.referenceCandidate == nil ? .absent : .unavailable("Reference validation is pending."), readGroups: [])
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
                    viewer.alignmentActionContext = nil
                    let reason = viewer.viewerView.detachedEvidenceStaleReason ?? "Classifier alignment evidence could not be verified."
                    availability = .unavailable(reason)
                    status = .stale(reason)
                    publishInspectorCapabilities(reference: .unavailable(reason), readGroups: [])
                    return
                }
                viewer.alignmentActionContext = try makeActionContext(
                    request: request,
                    validated: validated
                )
                availability = .available(reference: validated.reference.status, reason: validated.reference.reason)
                status = .available(referenceStrength: referenceStrengthText(validated.reference.status), reason: validated.reference.reason)
                observedInspectorSnapshots = .init(
                    bam: validated.bamSnapshot,
                    index: validated.indexSnapshot,
                    reference: validated.referenceSnapshot
                )
                publishInspectorCapabilities(
                    reference: inspectorReferenceValidation(validated.reference),
                    readGroups: validated.readGroups.map { .init(id: $0.id, sample: $0.sample) },
                    snapshots: observedInspectorSnapshots
                )
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                viewer.alignmentActionContext = nil
                viewer.viewerView.clearReferenceBundle()
                if let validationError = error as? ClassifierAlignmentEvidenceValidator.Error,
                   case .snapshotMismatch(let url) = validationError {
                    let reason = "Classifier alignment evidence changed on disk: \(url.lastPathComponent)."
                    availability = .unavailable(reason)
                    status = .stale(reason)
                    publishInspectorCapabilities(reference: .unavailable(reason), readGroups: [])
                } else {
                    availability = .unavailable(error.localizedDescription)
                    status = .unavailable(error.localizedDescription)
                    publishInspectorCapabilities(reference: .unavailable(error.localizedDescription), readGroups: [])
                }
            }
        }
    }

    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        activeRequest = nil
        observedInspectorSnapshots = nil
        viewer.viewerView.clearReferenceBundle()
        viewer.alignmentActionContext = nil
        viewer.viewerView.onDetachedEvidenceStale = nil
        availability = .idle
        status = .idle
        inspectorCapabilities = nil
    }

    private func makeActionContext(
        request: ClassifierAlignmentEvidenceRequest,
        validated: ClassifierAlignmentEvidenceValidator.Result
    ) throws -> AlignmentActionContext {
        guard let settings = viewer.viewerView else {
            throw AlignmentScientificActionError.contextUnavailable
        }
        let isCRAM = request.bamURL.pathExtension.lowercased() == "cram"
        let decodingReferenceURL = isCRAM ? request.referenceCandidate?.fastaURL : nil
        let decodingReferenceSnapshot: AlignmentEvidenceFileSnapshot? = if isCRAM,
                                                                          let referenceURL = decodingReferenceURL,
                                                                          let snapshot = validated.referenceSnapshot {
            .init(url: referenceURL, byteCount: UInt64(snapshot.size), sha256: snapshot.sha256)
        } else {
            nil
        }
        return try AlignmentActionContext(
            identity: .init(
                workflow: request.workflow.rawValue,
                resultID: request.resultIdentity.stableID,
                sampleID: request.sample.canonicalID,
                evidenceID: "\(request.resultIdentity.provenanceID):\(request.contig.name)"
            ),
            alignmentURL: request.bamURL,
            indexURL: request.index.url,
            decodingReferenceURL: decodingReferenceURL,
            contig: validated.contig.name,
            contigLength: validated.contig.length,
            alignmentSnapshot: .init(
                url: request.bamURL,
                byteCount: UInt64(validated.bamSnapshot.size),
                sha256: validated.bamSnapshot.sha256
            ),
            indexSnapshot: .init(
                url: request.index.url,
                byteCount: UInt64(validated.indexSnapshot.size),
                sha256: validated.indexSnapshot.sha256
            ),
            decodingReferenceSnapshot: decodingReferenceSnapshot,
            filters: .init(
                minimumDepth: settings.consensusMinDepthSetting,
                minimumMapQ: max(settings.minMapQSetting, settings.consensusMinMapQSetting),
                minimumBaseQuality: settings.consensusMinBaseQSetting,
                excludedFlags: settings.excludeFlagsSetting,
                readGroups: settings.selectedReadGroupsSetting
            ),
            outputCapability: .userSelectedDestination,
            sourceReads: .bamFallback,
            presentationLabel: "\(request.presentation.sampleLabel) — \(request.presentation.contigLabel)"
        )
    }

    private func refreshActionContextFilters() {
        guard let context = viewer.alignmentActionContext else { return }
        guard let settings = viewer.viewerView else { return }
        let filters = AlignmentConsensusFilters(
            minimumDepth: settings.consensusMinDepthSetting,
            minimumMapQ: max(settings.minMapQSetting, settings.consensusMinMapQSetting),
            minimumBaseQuality: settings.consensusMinBaseQSetting,
            excludedFlags: settings.excludeFlagsSetting,
            readGroups: settings.selectedReadGroupsSetting
        )
        viewer.alignmentActionContext = try? context.replacingFilters(filters)
    }

    private func consensusScopeState() -> (scope: AlignmentConsensusScope, unavailableMessage: String?) {
        let scope = viewer.alignmentConsensusScope
        guard let context = viewer.alignmentActionContext else {
            return (scope, AlignmentScientificActionError.contextUnavailable.localizedDescription)
        }
        do {
            _ = try scope.resolve(in: context, selection: viewer.explicitAlignmentSelection)
            return (scope, nil)
        } catch {
            return (scope, error.localizedDescription)
        }
    }

    private func requestClassifierConsensusGeneration() {
        viewer.presentAlignmentConsensusGeneration()
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

    private func publishInspectorCapabilities(
        reference: ClassifierAlignmentInspectorCapabilities.ReferenceValidation,
        readGroups: [ClassifierAlignmentInspectorCapabilities.ReadGroup],
        snapshots: InspectorSnapshots? = nil
    ) {
        guard let request = activeRequest else { inspectorCapabilities = nil; return }
        let snapshots = snapshots ?? observedInspectorSnapshots
        let referenceSnapshot = if let snapshots {
            snapshots.reference
        } else {
            request.referenceCandidate?.expectedSnapshot
        }
        inspectorCapabilities = .detachedEvidence(
            workflow: request.presentation.workflowLabel, result: request.presentation.resultLabel,
            sample: request.presentation.sampleLabel, contig: request.presentation.contigLabel,
            bamPath: request.bamURL.path, indexPath: request.index.url.path,
            referenceValidation: reference, readGroups: readGroups, status: status,
            referencePath: request.referenceCandidate?.fastaURL.path,
            bamSnapshot: snapshots?.bam ?? request.bamExpectedSnapshot,
            indexSnapshot: snapshots?.index ?? request.index.expectedSnapshot,
            referenceSnapshot: referenceSnapshot,
            provenanceID: request.resultIdentity.provenanceID,
            provenanceSourceURL: request.resultIdentity.finalResultURL
        )
    }
}
