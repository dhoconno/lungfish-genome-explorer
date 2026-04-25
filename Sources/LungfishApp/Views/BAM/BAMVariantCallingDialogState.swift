import Foundation
import Observation
import LungfishIO
import LungfishWorkflow

@MainActor
@Observable
final class BAMVariantCallingDialogState {
    let bundle: ReferenceBundle
    let sidebarItems: [DatasetOperationToolSidebarItem]
    let alignmentTrackOptions: [AlignmentTrackInfo]

    private let eligibleAlignmentTrackIDs: Set<String>

    var selectedAlignmentTrackID: String {
        didSet {
            outputTrackName = suggestedOutputTrackName()
            updatePrimerTrimAutoConfirm()
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
    var advancedOptionsText: String
    private(set) var generatedTrackID: String
    private(set) var pendingRequest: BundleVariantCallingRequest?

    /// Provenance record discovered alongside the selected BAM, when present.
    ///
    /// When non-nil, the iVar primer-trim attestation is treated as
    /// machine-confirmed (auto-checked, disabled in the UI) rather than
    /// requiring the user to attest manually.
    private(set) var autoConfirmedPrimerTrim: BAMPrimerTrimProvenance?

    init(
        bundle: ReferenceBundle,
        preferredAlignmentTrackID: String? = nil,
        sidebarItems: [DatasetOperationToolSidebarItem] = BAMVariantCallingCatalog.availableSidebarItems()
    ) {
        self.bundle = bundle
        self.sidebarItems = sidebarItems
        let eligibleAlignmentTracks = BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle)
        self.alignmentTrackOptions = eligibleAlignmentTracks
        self.eligibleAlignmentTrackIDs = Set(eligibleAlignmentTracks.map(\.id))

        let defaultAlignmentTrackID = BAMVariantCallingEligibility.defaultTrackID(
            in: eligibleAlignmentTracks,
            preferredAlignmentTrackID: preferredAlignmentTrackID
        )
        self.selectedAlignmentTrackID = defaultAlignmentTrackID
        self.selectedCaller = .lofreq
        self.minimumAlleleFrequencyText = "0.05"
        self.minimumDepthText = "10"
        let provenance = Self.readPrimerTrimProvenance(
            for: bundle,
            trackID: defaultAlignmentTrackID
        )
        self.autoConfirmedPrimerTrim = provenance
        self.ivarPrimerTrimConfirmed = provenance != nil
        self.medakaModel = ""
        self.advancedOptionsText = ""
        self.generatedTrackID = Self.makeTrackID()
        self.pendingRequest = nil
        self.outputTrackName = ""
        self.outputTrackName = suggestedOutputTrackName(
            bundle: bundle,
            alignmentTrackID: defaultAlignmentTrackID,
            caller: .lofreq
        )
    }

    /// Reads the JSON provenance sidecar next to the selected track's BAM.
    ///
    /// Returns nil when the bundle has no track at `trackID`, the BAM cannot be
    /// resolved, the sidecar is absent, or the sidecar fails to decode.
    private static func readPrimerTrimProvenance(
        for bundle: ReferenceBundle,
        trackID: String
    ) -> BAMPrimerTrimProvenance? {
        guard let track = bundle.alignmentTrack(id: trackID) else { return nil }
        let bamURL = bundle.url.appendingPathComponent(track.sourcePath)
        // Mirror `BAMPrimerTrimPipeline`, which writes `<bam-sans-ext>.primer-trim-provenance.json`
        // (e.g. `trimmed.primer-trim-provenance.json` next to `trimmed.bam`).
        let sidecarURL = bamURL
            .deletingPathExtension()
            .appendingPathExtension("primer-trim-provenance.json")
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return nil }
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let provenance = try? decoder.decode(BAMPrimerTrimProvenance.self, from: data) else {
            return nil
        }
        guard provenance.operation == "primer-trim" else { return nil }
        return provenance
    }

    /// Re-evaluates the primer-trim sidecar after the selected track changes.
    ///
    /// When a sidecar is discovered, the iVar attestation is auto-confirmed.
    /// When the new track has no sidecar, the user must attest manually, so we
    /// reset `ivarPrimerTrimConfirmed` to `false` to avoid carrying forward a
    /// previous track's attestation.
    private func updatePrimerTrimAutoConfirm() {
        let provenance = Self.readPrimerTrimProvenance(
            for: bundle,
            trackID: selectedAlignmentTrackID
        )
        autoConfirmedPrimerTrim = provenance
        ivarPrimerTrimConfirmed = provenance != nil
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

        guard hasEligibleSelectedAlignmentTrack else {
            return "Select an analysis-ready BAM alignment track."
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

        if let advancedOptionsParseError {
            return advancedOptionsParseError
        }

        switch selectedCaller {
        case .lofreq:
            return "Ready to run LoFreq on \(selectedAlignmentTrack?.name ?? "the selected alignment")."
        case .ivar:
            if let auto = autoConfirmedPrimerTrim {
                return "Ready to run iVar. Primer-trimmed by Lungfish on \(autoConfirmedDateString(auto.timestamp)) using \(auto.primerScheme.bundleName)."
            }
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
        guard hasEligibleSelectedAlignmentTrack else { return false }
        guard !trimmedOutputTrackName.isEmpty else { return false }
        guard trimmedMinimumAlleleFrequency.isEmpty || minimumAlleleFrequency != nil else { return false }
        guard trimmedMinimumDepth.isEmpty || minimumDepth != nil else { return false }
        guard advancedOptionsParseError == nil else { return false }

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
            medakaModel: trimmedMedakaModel.isEmpty ? nil : trimmedMedakaModel,
            advancedArguments: parsedAdvancedOptions
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

    private var hasEligibleSelectedAlignmentTrack: Bool {
        eligibleAlignmentTrackIDs.contains(selectedAlignmentTrackID)
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

    private var parsedAdvancedOptions: [String] {
        (try? AdvancedCommandLineOptions.parse(advancedOptionsText)) ?? []
    }

    private var advancedOptionsParseError: String? {
        do {
            _ = try AdvancedCommandLineOptions.parse(advancedOptionsText)
            return nil
        } catch {
            return error.localizedDescription
        }
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

    /// Renders a primer-trim provenance timestamp for the readiness banner and
    /// the disabled-toggle caption.
    func autoConfirmedDateString(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}
