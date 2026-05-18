import Foundation
import LungfishWorkflow

private struct BAMVariantCallingToolGate: Hashable, Sendable {
    let packID: String
    let requirementID: String?
}

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

    fileprivate var requiredToolGates: [BAMVariantCallingToolGate] {
        switch self {
        case .lofreq, .ivar, .medaka, .clair3:
            return [
                BAMVariantCallingToolGate(packID: "variant-calling", requirementID: rawValue),
            ]
        case .bcftools:
            return [
                BAMVariantCallingToolGate(packID: "lungfish-tools", requirementID: "bcftools"),
            ]
        case .gatkHaplotypeCaller:
            return [
                BAMVariantCallingToolGate(packID: "gatk-core", requirementID: "gatk4"),
            ]
        case .gatkWhatsHapPhased:
            return [
                BAMVariantCallingToolGate(packID: "gatk-core", requirementID: "gatk4"),
                BAMVariantCallingToolGate(packID: "phasing", requirementID: "whatshap"),
            ]
        }
    }

    var requiredPackIDs: [String] {
        requiredToolGates.map(\.packID)
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
        var statusByPackID: [String: PluginPackStatus] = [:]
        for packID in Set(BAMVariantCallingToolID.allCases.flatMap(\.requiredPackIDs)) {
            statusByPackID[packID] = await statusProvider.status(forPackID: packID)
        }
        return Self.sidebarItems(statusByPackID: statusByPackID)
    }

    static func availableSidebarItems() -> [DatasetOperationToolSidebarItem] {
        BAMVariantCallingToolID.allCases.map { tool in
            DatasetOperationToolSidebarItem(
                id: tool.rawValue,
                title: tool.displayName,
                subtitle: subtitle(for: tool),
                availability: .available
            )
        }
    }

    private static func disabledReason(forPackID packID: String) -> String {
        guard let pack = PluginPack.builtInPack(id: packID) else {
            return "No tools available"
        }

        return "Requires \(pack.name) Pack"
    }

    private static func disabledReason(for requirement: PackToolRequirement) -> String {
        "Requires \(requirement.displayName)"
    }

    private static func sidebarItems(
        statusByPackID: [String: PluginPackStatus]
    ) -> [DatasetOperationToolSidebarItem] {
        BAMVariantCallingToolID.allCases.map { tool in
            DatasetOperationToolSidebarItem(
                id: tool.rawValue,
                title: tool.displayName,
                subtitle: subtitle(for: tool),
                availability: availability(for: tool, statusByPackID: statusByPackID)
            )
        }
    }

    private static func availability(
        for tool: BAMVariantCallingToolID,
        statusByPackID: [String: PluginPackStatus]
    ) -> DatasetOperationAvailability {
        for gate in tool.requiredToolGates {
            let availability = availability(for: gate, statusByPackID: statusByPackID)
            if availability != DatasetOperationAvailability.available {
                return availability
            }
        }
        return .available
    }

    private static func availability(
        for gate: BAMVariantCallingToolGate,
        statusByPackID: [String: PluginPackStatus]
    ) -> DatasetOperationAvailability {
        guard let status = statusByPackID[gate.packID] else {
            return .disabled(reason: disabledReason(forPackID: gate.packID))
        }

        if let requirementID = gate.requirementID,
           !status.toolStatuses.isEmpty {
            guard let toolStatus = status.toolStatuses.first(where: { $0.requirement.id == requirementID }) else {
                return .disabled(reason: disabledReason(forPackID: gate.packID))
            }
            return toolStatus.isReady
                ? .available
                : .disabled(reason: disabledReason(for: toolStatus.requirement))
        }

        return status.state == .ready
            ? .available
            : .disabled(reason: disabledReason(forPackID: gate.packID))
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
