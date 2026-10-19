// PluginManagerViewModel+DatabaseHelp.swift — help text of a database row that nothing checked
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishWorkflow

extension PluginManagerViewModel {

    /// The tooltip of a database row's tracking line (UX ruling U-W5).
    ///
    /// An unverified row says that LGE has not checked its files and that an update replaces them with a checked copy.
    /// A catalog row that cannot be updated in place, such as a locally built rRNA index, keeps the first sentence only
    /// (Q-W2), since the second would promise an update that ends in `updateNotSupported`. A checked row has no tooltip.
    static func databaseTrackingHelp(for database: MetagenomicsDatabaseInfo) -> String {
        guard database.isUnverified else { return "" }
        guard case .archive = database.resolvedCatalogEntry?.installationRecipe else {
            return MetagenomicsDatabaseInfo.unverifiedHelpNotChecked
        }
        return "\(MetagenomicsDatabaseInfo.unverifiedHelpNotChecked) \(MetagenomicsDatabaseInfo.unverifiedHelpUpdate)"
    }
}
