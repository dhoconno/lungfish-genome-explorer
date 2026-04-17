import Foundation
import LungfishWorkflow

struct AboutAcknowledgements {
    struct Entry: Equatable {
        let id: String
        let displayName: String
        let detail: String?
        let secondaryDetail: String?
        let sourceURL: String?
    }

    struct Section: Equatable {
        let title: String
        let entries: [Entry]
    }

    static func currentSections(
        bundledManifest: ToolVersionsManifest? = ToolVersionsManifest.loadFromBundle(),
        requiredPack: PluginPack = .requiredSetupPack,
        activeOptionalPacks: [PluginPack] = PluginPack.activeOptionalPacks
    ) -> [Section] {
        var sections: [Section] = []

        let bundledEntries = bundledManifest?.tools.map { tool in
            Entry(
                id: tool.id,
                displayName: tool.displayName,
                detail: tool.version,
                secondaryDetail: tool.license,
                sourceURL: tool.sourceUrl
            )
        } ?? []
        if !bundledEntries.isEmpty {
            sections.append(Section(title: "Bundled Bootstrap", entries: bundledEntries))
        }

        let requiredEntries = packEntries(for: requiredPack)
        if !requiredEntries.isEmpty {
            sections.append(Section(title: requiredPack.name, entries: requiredEntries))
        }

        for pack in activeOptionalPacks {
            let entries = packEntries(for: pack)
            guard !entries.isEmpty else { continue }
            sections.append(Section(title: pack.name, entries: entries))
        }

        return sections
    }

    private static func packEntries(for pack: PluginPack) -> [Entry] {
        pack.toolRequirements.compactMap { requirement in
            guard requirement.managedDatabaseID == nil else { return nil }
            return Entry(
                id: requirement.id,
                displayName: requirement.displayName,
                detail: packageDetail(for: requirement),
                secondaryDetail: nil,
                sourceURL: nil
            )
        }
    }

    private static func packageDetail(for requirement: PackToolRequirement) -> String? {
        guard !requirement.installPackages.isEmpty else { return nil }
        if requirement.installPackages.count == 1,
           let package = requirement.installPackages.first,
           package == requirement.id
        {
            return nil
        }
        return requirement.installPackages.joined(separator: ", ")
    }
}
