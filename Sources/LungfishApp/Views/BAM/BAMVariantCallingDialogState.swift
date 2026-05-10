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

    var selectedToolID: String {
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
    var ivarConsensusAF: Double
    var ivarMergeAFThreshold: Double
    var ivarBadQualityThreshold: Int
    var ivarIgnoreStrandBias: Bool
    var medakaModel: String
    var advancedOptionsText: String
    private(set) var generatedTrackID: String
    private(set) var pendingRequest: BundleVariantCallingRequest?
    private(set) var pendingGATKRequest: GATKPipelineExecutionRequest?
    private(set) var pendingPhasedVariantPlan: PhasedVariantCallingPlan?

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
        self.selectedToolID = BAMVariantCallingToolID.lofreq.rawValue
        self.selectedCaller = .lofreq
        self.minimumAlleleFrequencyText = "0.05"
        self.minimumDepthText = "10"
        let provenance = Self.readPrimerTrimProvenance(
            for: bundle,
            trackID: defaultAlignmentTrackID
        )
        self.autoConfirmedPrimerTrim = provenance
        self.ivarPrimerTrimConfirmed = provenance != nil
        self.ivarConsensusAF = 0.75
        self.ivarMergeAFThreshold = 0.25
        self.ivarBadQualityThreshold = 20
        self.ivarIgnoreStrandBias = true
        self.medakaModel = ""
        self.advancedOptionsText = ""
        self.generatedTrackID = Self.makeTrackID()
        self.pendingRequest = nil
        self.pendingGATKRequest = nil
        self.pendingPhasedVariantPlan = nil
        self.outputTrackName = ""
        self.outputTrackName = suggestedOutputTrackName(
            bundle: bundle,
            alignmentTrackID: defaultAlignmentTrackID,
            toolID: BAMVariantCallingToolID.lofreq.rawValue
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
        return PrimerTrimProvenanceLoader.load(forBAMAt: bamURL)
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
        switch selectedToolAvailability {
        case .available:
            break
        case .comingSoon:
            return "\(selectedToolDisplayName) is coming soon."
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

        if selectedToolID == BAMVariantCallingToolID.gatkHaplotypeCaller.rawValue {
            return "Ready to run GATK HaplotypeCaller on \(selectedAlignmentTrack?.name ?? "the selected alignment")."
        }
        if selectedToolID == BAMVariantCallingToolID.gatkWhatsHapPhased.rawValue {
            return "Ready to build a GATK plus WhatsHap phased command plan for \(selectedAlignmentTrack?.name ?? "the selected alignment")."
        }

        switch selectedCaller {
        case .lofreq:
            return "Ready to run LoFreq on \(selectedAlignmentTrack?.name ?? "the selected alignment")."
        case .bcftools:
            return "Ready to run bcftools mpileup/call on \(selectedAlignmentTrack?.name ?? "the selected alignment")."
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
        case .clair3:
            return trimmedMedakaModel.isEmpty
                ? "Provide the Clair3 model path or ONT model identifier."
                : "Ready to run Clair3 with model \(trimmedMedakaModel)."
        }
    }

    var isRunEnabled: Bool {
        guard selectedToolAvailability == .available else { return false }
        guard !alignmentTrackOptions.isEmpty else { return false }
        guard hasEligibleSelectedAlignmentTrack else { return false }
        guard !trimmedOutputTrackName.isEmpty else { return false }
        guard trimmedMinimumAlleleFrequency.isEmpty || minimumAlleleFrequency != nil else { return false }
        guard trimmedMinimumDepth.isEmpty || minimumDepth != nil else { return false }
        guard advancedOptionsParseError == nil else { return false }

        if selectedToolID == BAMVariantCallingToolID.gatkHaplotypeCaller.rawValue {
            return true
        }
        if selectedToolID == BAMVariantCallingToolID.gatkWhatsHapPhased.rawValue {
            return true
        }

        switch selectedCaller {
        case .lofreq, .bcftools:
            return true
        case .ivar:
            return ivarPrimerTrimConfirmed
        case .medaka:
            return !trimmedMedakaModel.isEmpty
        case .clair3:
            return !trimmedMedakaModel.isEmpty
        }
    }

    func selectCaller(_ caller: ViralVariantCaller) {
        selectedToolID = caller.rawValue
        selectedCaller = caller
    }

    func selectCaller(named rawValue: String) {
        guard let caller = ViralVariantCaller(rawValue: rawValue) else { return }
        selectCaller(caller)
    }

    func selectTool(named rawValue: String) {
        if let caller = ViralVariantCaller(rawValue: rawValue) {
            selectCaller(caller)
            return
        }
        guard BAMVariantCallingToolID(rawValue: rawValue) != nil else { return }
        selectedToolID = rawValue
    }

    func selectAlignmentTrack(id: String) {
        guard alignmentTrackOptions.contains(where: { $0.id == id }) else { return }
        selectedAlignmentTrackID = id
    }

    func prepareForRun() {
        generatedTrackID = Self.makeTrackID()
        if selectedToolID == BAMVariantCallingToolID.gatkHaplotypeCaller.rawValue {
            pendingRequest = nil
            pendingGATKRequest = makeGATKRequest()
            pendingPhasedVariantPlan = nil
        } else if selectedToolID == BAMVariantCallingToolID.gatkWhatsHapPhased.rawValue {
            pendingRequest = nil
            pendingGATKRequest = nil
            pendingPhasedVariantPlan = makePhasedVariantPlan()
        } else {
            pendingGATKRequest = nil
            pendingPhasedVariantPlan = nil
            pendingRequest = makeRequest()
        }
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
            advancedArguments: parsedAdvancedOptions,
            ivarConsensusAF: ivarConsensusAF,
            ivarMergeAFThreshold: ivarMergeAFThreshold,
            ivarBadQualityThreshold: ivarBadQualityThreshold,
            ivarIgnoreStrandBias: ivarIgnoreStrandBias
        )
    }

    private func suggestedOutputTrackName() -> String {
        suggestedOutputTrackName(
            bundle: bundle,
            alignmentTrackID: selectedAlignmentTrackID,
            toolID: selectedToolID
        )
    }

    private func suggestedOutputTrackName(
        bundle: ReferenceBundle,
        alignmentTrackID: String,
        toolID: String
    ) -> String {
        let alignmentName = bundle.alignmentTrack(id: alignmentTrackID)?.name ?? "Alignment"
        let toolName = BAMVariantCallingToolID(rawValue: toolID)?.displayName
            ?? ViralVariantCaller(rawValue: toolID)?.displayName
            ?? "Variants"
        let base = "\(alignmentName) • \(toolName)"
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

    private var selectedToolAvailability: DatasetOperationAvailability {
        sidebarItems.first(where: { $0.id == selectedToolID })?.availability ?? .available
    }

    var selectedToolDisplayName: String {
        BAMVariantCallingToolID(rawValue: selectedToolID)?.displayName
            ?? selectedCaller.displayName
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

    private func makeGATKRequest() -> GATKPipelineExecutionRequest? {
        guard isRunEnabled else { return nil }
        guard let track = selectedAlignmentTrack else { return nil }
        guard let genome = bundle.manifest.genome else { return nil }

        let referenceURL = bundle.url.appendingPathComponent(genome.path)
        let bamURL = bundle.url.appendingPathComponent(track.sourcePath)
        let outputURL = bundle.url
            .appendingPathComponent("variants/gatk", isDirectory: true)
            .appendingPathComponent("\(generatedTrackID).vcf.gz")
        let config = GATKHaplotypeCallerConfiguration(
            referenceFASTAURL: referenceURL,
            inputBAMURL: bamURL,
            outputVCFURL: outputURL,
            emitReferenceConfidence: .none,
            extraArguments: parsedAdvancedOptions
        )
        return .haplotypeCaller(
            configuration: config,
            toolVersion: Self.gatkToolVersion(),
            runtimeIdentity: Self.gatkRuntimeIdentity()
        )
    }

    private func makePhasedVariantPlan() -> PhasedVariantCallingPlan? {
        guard isRunEnabled else { return nil }
        guard let track = selectedAlignmentTrack else { return nil }
        guard let genome = bundle.manifest.genome else { return nil }

        let referenceURL = bundle.url.appendingPathComponent(genome.path)
        let bamURL = bundle.url.appendingPathComponent(track.sourcePath)
        let outputURL = bundle.url
            .appendingPathComponent("variants/phased", isDirectory: true)
            .appendingPathComponent("\(generatedTrackID).phased.vcf.gz")
        return PhasedVariantCallingPlan(
            configuration: PhasedVariantCallingConfiguration(
                referenceFASTAURL: referenceURL,
                inputBAMURL: bamURL,
                outputVCFURL: outputURL,
                outputDirectory: outputURL.deletingLastPathComponent(),
                threads: max(1, ProcessInfo.processInfo.activeProcessorCount),
                extraGATKArguments: parsedAdvancedOptions
            ),
            gatkVersion: Self.gatkToolVersion(),
            whatsHapVersion: Self.whatsHapToolVersion(),
            runtimeIdentity: PhasedVariantRuntimeIdentity(
                gatkCondaEnvironment: Self.gatkRuntimeIdentity().condaEnvironment ?? "",
                whatsHapCondaEnvironment: CondaManager.shared.rootPrefix
                    .appendingPathComponent("envs/phasing", isDirectory: true).path
            )
        )
    }

    private static func gatkToolVersion() -> String {
        PluginPack.builtInPack(id: "gatk-core")?
            .toolRequirements
            .first(where: { $0.environment == "gatk-core" })?
            .version ?? "unknown"
    }

    private static func whatsHapToolVersion() -> String {
        PluginPack.builtInPack(id: "phasing")?
            .toolRequirements
            .first(where: { $0.environment == "phasing" })?
            .version ?? "unknown"
    }

    private static func gatkRuntimeIdentity() -> GATKRuntimeIdentity {
        let environmentURL = CondaManager.shared.rootPrefix
            .appendingPathComponent("envs/gatk-core", isDirectory: true)
        return GATKRuntimeIdentity(condaEnvironment: environmentURL.path)
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
