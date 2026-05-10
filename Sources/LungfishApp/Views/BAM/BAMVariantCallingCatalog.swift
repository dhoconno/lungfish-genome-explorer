import Foundation
import LungfishWorkflow

enum BAMVariantCallingToolID: String, CaseIterable, Sendable {
    case lofreq
    case ivar
    case medaka
    case bcftools
    case clair3
    case gatkHaplotypeCaller = "gatk-haplotype-caller"
    case gatkWhatsHapPhased = "gatk-whatshap-phased"

    var displayName: String {
        switch self {
        case .lofreq:
            return ViralVariantCaller.lofreq.displayName
        case .ivar:
            return ViralVariantCaller.ivar.displayName
        case .medaka:
            return ViralVariantCaller.medaka.displayName
        case .bcftools:
            return ViralVariantCaller.bcftools.displayName
        case .clair3:
            return ViralVariantCaller.clair3.displayName
        case .gatkHaplotypeCaller:
            return "GATK HaplotypeCaller"
        case .gatkWhatsHapPhased:
            return "GATK + WhatsHap Phased"
        }
    }

    var requiredPackID: String {
        switch self {
        case .lofreq, .ivar, .medaka, .clair3:
            return "variant-calling"
        case .bcftools:
            return "lungfish-tools"
        case .gatkHaplotypeCaller:
            return "gatk-core"
        case .gatkWhatsHapPhased:
            return "gatk-core,phasing"
        }
    }

    var requiredPackIDs: [String] {
        requiredPackID.split(separator: ",").map(String.init)
    }

    var viralCaller: ViralVariantCaller? {
        ViralVariantCaller(rawValue: rawValue)
    }
}

struct BAMVariantCallingCatalog: Sendable {
    private let statusProvider: any PluginPackStatusProviding

    init(statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared) {
        self.statusProvider = statusProvider
    }

    func sidebarItems() async -> [DatasetOperationToolSidebarItem] {
        var availabilityByPackID: [String: DatasetOperationAvailability] = [:]
        for packID in Set(BAMVariantCallingToolID.allCases.flatMap(\.requiredPackIDs)) {
            availabilityByPackID[packID] = await resolvedAvailability(forPackID: packID)
        }
        return Self.sidebarItems(availabilityByPackID: availabilityByPackID)
    }

    static func availableSidebarItems() -> [DatasetOperationToolSidebarItem] {
        sidebarItems(availabilityByPackID: [
            "variant-calling": .available,
            "lungfish-tools": .available,
            "gatk-core": .available,
            "phasing": .available,
        ])
    }

    private func resolvedAvailability(forPackID packID: String) async -> DatasetOperationAvailability {
        guard let status = await statusProvider.status(forPackID: packID),
              status.state == .ready else {
            return .disabled(reason: disabledReason(forPackID: packID))
        }

        return .available
    }

    private func disabledReason(forPackID packID: String) -> String {
        guard let pack = PluginPack.builtInPack(id: packID) else {
            return "No tools available"
        }

        return "Requires \(pack.name) Pack"
    }

    private static func sidebarItems(
        availabilityByPackID: [String: DatasetOperationAvailability]
    ) -> [DatasetOperationToolSidebarItem] {
        BAMVariantCallingToolID.allCases.map { tool in
            DatasetOperationToolSidebarItem(
                id: tool.rawValue,
                title: tool.displayName,
                subtitle: subtitle(for: tool),
                availability: availability(for: tool, availabilityByPackID: availabilityByPackID)
            )
        }
    }

    private static func availability(
        for tool: BAMVariantCallingToolID,
        availabilityByPackID: [String: DatasetOperationAvailability]
    ) -> DatasetOperationAvailability {
        for packID in tool.requiredPackIDs {
            let availability = availabilityByPackID[packID] ?? .disabled(reason: "No tools available")
            if availability != .available {
                return availability
            }
        }
        return .available
    }

    private static func subtitle(for tool: BAMVariantCallingToolID) -> String {
        switch tool {
        case .lofreq:
            return "Sensitive low-frequency calling for viral BAM alignments."
        case .ivar:
            return "Amplicon-oriented calling for primer-trimmed viral BAMs."
        case .medaka:
            return "ONT-focused consensus and variant calling with Medaka."
        case .bcftools:
            return "Orthogonal mpileup/call cross-check for BAM alignments."
        case .clair3:
            return "ONT-focused neural-network variant calling with Clair3."
        case .gatkHaplotypeCaller:
            return "Germline SNP and indel calling with standard VCF genotypes."
        case .gatkWhatsHapPhased:
            return "Phase-aware HaplotypeCaller plus WhatsHap command plan."
        }
    }
}
