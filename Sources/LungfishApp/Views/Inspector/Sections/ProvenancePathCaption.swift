// ProvenancePathCaption.swift - A recorded path shown the way the Provenance tab shows it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import LungfishWorkflow
import SwiftUI

/// The caption under a Run Inputs or Output Files row: a project-relative
/// path for a file inside the project, a file name for one outside it, with
/// a note when the file is gone. The recorded absolute path stays in the
/// tooltip and in the accessibility value, so nothing is lost and nothing
/// needs a mouse to reach.
struct ProvenancePathCaption: View {
    let presentation: ProvenancePathPresentation

    init(path: String, projectURL: URL?) {
        presentation = ProvenancePathPresentation.present(path, projectURL: projectURL)
    }

    var body: some View {
        Text(presentation.listLabel)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityValue(presentation.accessibilityValue)
    }
}

extension DocumentSectionViewModel {
    /// The project the inspected bundle lives in, which decides how its
    /// recorded paths are shown.
    var enclosingProjectURL: URL? {
        bundleURL.flatMap { PortablePath.anchors(for: $0).project }
    }
}
