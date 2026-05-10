import Foundation
import LungfishWorkflow

enum BAMVariantCallingToolID: String, CaseIterable, Sendable {
    case lofreq
    case ivar
    case medaka
    case gatkHaplotypeCaller = "gatk-haplotype-caller"

    var displayName: String {
        switch self {
        case .lofreq:
            return ViralVariantCaller.lofreq.displayName
        case .ivar:
            return ViralVariantCaller.ivar.displayName
        case .medaka:
            return ViralVariantCaller.medaka.displayName
        case .gatkHaplotypeCaller:
            return "GATK HaplotypeCaller"
        }
    }

    var requiredPackID: String {
        switch self {
        case .lofreq, .ivar, .medaka:
            return "variant-calling"
        case .gatkHaplotypeCaller:
            return "gatk-core"
        }
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
        for packID in Set(BAMVariantCallingToolID.allCases.map(\.requiredPackID)) {
            availabilityByPackID[packID] = await resolvedAvailability(forPackID: packID)
        }
        return Self.sidebarItems(availabilityByPackID: availabilityByPackID)
    }

    static func availableSidebarItems() -> [DatasetOperationToolSidebarItem] {
        sidebarItems(availabilityByPackID: [
            "variant-calling": .available,
            "gatk-core": .available,
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
                availability: availabilityByPackID[tool.requiredPackID] ?? .disabled(reason: "No tools available")
            )
        }
    }

    private static func subtitle(for tool: BAMVariantCallingToolID) -> String {
        switch tool {
        case .lofreq:
            return "Sensitive low-frequency calling for viral BAM alignments."
        case .ivar:
            return "Amplicon-oriented calling for primer-trimmed viral BAMs."
        case .medaka:
            return "ONT-focused consensus and variant calling with Medaka."
        case .gatkHaplotypeCaller:
            return "Germline SNP and indel calling with standard VCF genotypes."
        }
    }
}
