// KrakenResultReadSources+Place.swift - The place inside a project that the read-check words name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension KrakenResultReadSources {

    /// The place the read check's refusal names for `inputs`, the bundles and files a result recorded
    /// (BIO-READ-IDENTITY 4.3): each one's place inside the project that holds it, as `Imports/s.lungfishfastq`, with
    /// a file inside a bundle given as its bundle, or its full path outside a project. Two read "A and B", and more
    /// read "A, B and C".
    public static func place(of inputs: [URL]) -> String {
        let places = inputs.map { input -> String in
            let url = input.standardizedFileURL
            guard let project = ProjectTempDirectory.findProjectRoot(url)?.standardizedFileURL,
                  url.pathComponents.count > project.pathComponents.count else { return url.path }
            var place = Array(url.pathComponents.dropFirst(project.pathComponents.count))
            if let bundle = place.firstIndex(where: { URL(fileURLWithPath: $0).pathExtension == FASTQBundle.directoryExtension }) {
                place = Array(place.prefix(through: bundle))
            }
            return place.joined(separator: "/")
        }
        var unique: [String] = []
        for place in places where !unique.contains(place) { unique.append(place) }
        guard unique.count > 2, let last = unique.last else { return unique.joined(separator: " and ") }
        return unique.dropLast().joined(separator: ", ") + " and " + last
    }
}
