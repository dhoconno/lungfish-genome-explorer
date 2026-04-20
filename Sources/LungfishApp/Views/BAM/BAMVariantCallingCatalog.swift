import Foundation
import LungfishWorkflow

struct BAMVariantCallingCatalog: Sendable {
    private let statusProvider: any PluginPackStatusProviding

    init(statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared) {
        self.statusProvider = statusProvider
    }

    func sidebarItems() async -> [DatasetOperationToolSidebarItem] {
        let availability = await resolvedAvailability()
        return Self.sidebarItems(availability: availability)
    }

    static func availableSidebarItems() -> [DatasetOperationToolSidebarItem] {
        sidebarItems(availability: .available)
    }

    private func resolvedAvailability() async -> DatasetOperationAvailability {
        guard let status = await statusProvider.status(forPackID: "variant-calling"),
              status.state == .ready else {
            return .disabled(reason: disabledReason())
        }

        return .available
    }

    private func disabledReason() -> String {
        guard let pack = PluginPack.builtInPack(id: "variant-calling") else {
            return "No tools available"
        }

        return "Requires \(pack.name) Pack"
    }

    private static func sidebarItems(
        availability: DatasetOperationAvailability
    ) -> [DatasetOperationToolSidebarItem] {
        ViralVariantCaller.allCases.map { caller in
            DatasetOperationToolSidebarItem(
                id: caller.rawValue,
                title: caller.displayName,
                subtitle: subtitle(for: caller),
                availability: availability
            )
        }
    }

    private static func subtitle(for caller: ViralVariantCaller) -> String {
        switch caller {
        case .lofreq:
            return "Sensitive low-frequency calling for viral BAM alignments."
        case .ivar:
            return "Amplicon-oriented calling for primer-trimmed viral BAMs."
        case .medaka:
            return "ONT-focused consensus and variant calling with Medaka."
        }
    }
}
