import Foundation
import Observation
import LungfishIO
import LungfishWorkflow

@MainActor
@Observable
final class BAMVariantCallingDialogState {
    let bundle: ReferenceBundle
    let sidebarItems: [DatasetOperationToolSidebarItem]

    var selectedAlignmentTrackID: String {
        didSet {
            outputTrackName = suggestedOutputTrackName()
        }
    }

    var selectedCaller: ViralVariantCaller {
        didSet {
            outputTrackName = suggestedOutputTrackName()
        }
    }

    var outputTrackName: String
    var minimumAlleleFrequencyText: String
    var minimumDepthText: String
    var ivarPrimerTrimConfirmed: Bool
    var medakaModel: String
    private(set) var generatedTrackID: String
    private(set) var pendingRequest: BundleVariantCallingRequest?

    init(
        bundle: ReferenceBundle,
        preferredAlignmentTrackID: String? = nil,
        sidebarItems: [DatasetOperationToolSidebarItem] = BAMVariantCallingCatalog.availableSidebarItems()
    ) {
        self.bundle = bundle
        self.sidebarItems = sidebarItems

        let defaultAlignmentTrackID = BAMVariantCallingEligibility.defaultTrackID(
            in: bundle,
            preferredAlignmentTrackID: preferredAlignmentTrackID
        )
        self.selectedAlignmentTrackID = defaultAlignmentTrackID
        self.selectedCaller = .lofreq
        self.minimumAlleleFrequencyText = "0.05"
        self.minimumDepthText = "10"
        self.ivarPrimerTrimConfirmed = false
        self.medakaModel = ""
        self.generatedTrackID = Self.makeTrackID()
        self.pendingRequest = nil
        self.outputTrackName = ""
        self.outputTrackName = suggestedOutputTrackName(
            bundle: bundle,
            alignmentTrackID: defaultAlignmentTrackID,
            caller: .lofreq
        )
    }

    var alignmentTrackOptions: [AlignmentTrackInfo] {
        BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle)
    }

    var datasetLabel: String {
        bundle.name
    }

    var selectedAlignmentTrack: AlignmentTrackInfo? {
        bundle.alignmentTrack(id: selectedAlignmentTrackID)
    }

    var readinessText: String {
        switch selectedCallerAvailability {
        case .available:
            break
        case .comingSoon:
            return "\(selectedCaller.displayName) is coming soon."
        case .disabled(let reason):
            return reason
        }

        if alignmentTrackOptions.isEmpty {
            return "This bundle has no analysis-ready BAM alignment tracks to call variants from."
        }

        if trimmedOutputTrackName.isEmpty {
            return "Enter an output track name."
        }

        if minimumAlleleFrequency == nil && !trimmedMinimumAlleleFrequency.isEmpty {
            return "Minimum allele frequency must be a decimal value."
        }

        if minimumDepth == nil && !trimmedMinimumDepth.isEmpty {
            return "Minimum depth must be a whole number."
        }

        switch selectedCaller {
        case .lofreq:
            return "Ready to run LoFreq on \(selectedAlignmentTrack?.name ?? "the selected alignment")."
        case .ivar:
            return ivarPrimerTrimConfirmed
                ? "Ready to run iVar on the primer-trimmed alignment."
                : "Confirm the BAM was primer-trimmed before running iVar."
        case .medaka:
            return trimmedMedakaModel.isEmpty
                ? "Provide the ONT/basecaller model required by Medaka."
                : "Ready to run Medaka with model \(trimmedMedakaModel)."
        }
    }

    var isRunEnabled: Bool {
        guard selectedCallerAvailability == .available else { return false }
        guard !alignmentTrackOptions.isEmpty else { return false }
        guard !trimmedOutputTrackName.isEmpty else { return false }
        guard trimmedMinimumAlleleFrequency.isEmpty || minimumAlleleFrequency != nil else { return false }
        guard trimmedMinimumDepth.isEmpty || minimumDepth != nil else { return false }

        switch selectedCaller {
        case .lofreq:
            return true
        case .ivar:
            return ivarPrimerTrimConfirmed
        case .medaka:
            return !trimmedMedakaModel.isEmpty
        }
    }

    func selectCaller(_ caller: ViralVariantCaller) {
        selectedCaller = caller
    }

    func selectCaller(named rawValue: String) {
        guard let caller = ViralVariantCaller(rawValue: rawValue) else { return }
        selectCaller(caller)
    }

    func selectAlignmentTrack(id: String) {
        guard alignmentTrackOptions.contains(where: { $0.id == id }) else { return }
        selectedAlignmentTrackID = id
    }

    func prepareForRun() {
        generatedTrackID = Self.makeTrackID()
        pendingRequest = makeRequest()
    }

    private func makeRequest() -> BundleVariantCallingRequest? {
        guard isRunEnabled else { return nil }

        return BundleVariantCallingRequest(
            bundleURL: bundle.url,
            alignmentTrackID: selectedAlignmentTrackID,
            caller: selectedCaller,
            outputTrackName: trimmedOutputTrackName,
            minimumAlleleFrequency: minimumAlleleFrequency,
            minimumDepth: minimumDepth,
            ivarPrimerTrimConfirmed: ivarPrimerTrimConfirmed,
            medakaModel: trimmedMedakaModel.isEmpty ? nil : trimmedMedakaModel
        )
    }

    private func suggestedOutputTrackName() -> String {
        suggestedOutputTrackName(
            bundle: bundle,
            alignmentTrackID: selectedAlignmentTrackID,
            caller: selectedCaller
        )
    }

    private func suggestedOutputTrackName(
        bundle: ReferenceBundle,
        alignmentTrackID: String,
        caller: ViralVariantCaller
    ) -> String {
        let alignmentName = bundle.alignmentTrack(id: alignmentTrackID)?.name ?? "Alignment"
        let base = "\(alignmentName) • \(caller.displayName)"
        let existingNames = Set(bundle.manifest.variants.map(\.name))
        guard existingNames.contains(base) else {
            return base
        }

        var suffix = 2
        while existingNames.contains("\(base) (\(suffix))") {
            suffix += 1
        }
        return "\(base) (\(suffix))"
    }

    private var trimmedOutputTrackName: String {
        outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedCallerAvailability: DatasetOperationAvailability {
        sidebarItems.first(where: { $0.id == selectedCaller.rawValue })?.availability ?? .available
    }

    private var trimmedMinimumAlleleFrequency: String {
        minimumAlleleFrequencyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMinimumDepth: String {
        minimumDepthText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMedakaModel: String {
        medakaModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var minimumAlleleFrequency: Double? {
        guard !trimmedMinimumAlleleFrequency.isEmpty else { return nil }
        return Double(trimmedMinimumAlleleFrequency)
    }

    private var minimumDepth: Int? {
        guard !trimmedMinimumDepth.isEmpty else { return nil }
        return Int(trimmedMinimumDepth)
    }

    private static func makeTrackID() -> String {
        "vc-\(UUID().uuidString.lowercased())"
    }
}
