// PluginManagerViewModel+ExperimentalPacks.swift - Pack list reload when experimental features change
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Observation

/// Lives outside the baselined PluginManagerViewModel.swift so that file does
/// not grow (scripts/ratchets/file-size.sh).
extension PluginManagerViewModel {
    /// Reloads the pack list whenever Settings turns experimental features on
    /// or off. The Plugin Manager window outlives a Settings change, so without
    /// this the list stays stale until a tab switch. The task inherits the main
    /// actor, so it needs no `MainActor.assumeIsolated` hop.
    func observeExperimentalFeaturesSetting() {
        experimentalFeaturesObservation?.cancel()
        experimentalFeaturesObservation = Task { [weak self] in
            let settings = Observations { AppSettings.shared.experimentalFeaturesEnabled }
            for await enabled in settings {
                guard let self else { return }
                guard enabled != self.observedExperimentalFeaturesEnabled else { continue }
                self.observedExperimentalFeaturesEnabled = enabled
                self.refreshPackStatuses()
            }
        }
    }
}
