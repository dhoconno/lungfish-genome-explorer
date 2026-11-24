// AffectedResults+PatchBuilds.swift - The patch builds of the Affected Results table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension AffectedResults {
    /// A patch build: stamped on a patch branch of an older release, so its number says nothing of the fixes between that
    /// release and itself. It holds every fix of the release it patches (`base`) and the fixes of the rows it `carries`, by
    /// backlog id, and no other.
    public struct PatchBuild: Equatable, Sendable {
        public let build: Int
        public let base: Int
        public let carries: [String]

        init(build: Int, base: Int, carries: [String]) {
            self.build = build
            self.base = base
            self.carries = carries
        }
    }

    /// Every patch build, each with the rows it carries (BIO-ROUTES-4 item 6, FIX-ROUTES-5). Stable 2026.11.14 is build
    /// 13927 of a patch branch of v2026.11.7 (12972). `git log v2026.11.7..v2026.11.14` holds twelve commits, and one is a
    /// result fix: the port `bbfe6550d` of DEMUX-SHARED-NAME-GZIP, with its red test `83741bccd`. The others are the TOOL
    /// commits of the patch mode and its notes, so no other row's fix is in the patch, and a row of 12972 holds 13927.
    public static let patchBuilds: [PatchBuild] = [
        .init(build: 13927, base: 12972, carries: ["DEMUX-SHARED-NAME-GZIP"]),
    ]

    /// The build a row of `backlogID` reads `build` as: the base of a patch build the row's fix is not in, else `build`.
    static func build(_ build: Int, readFor backlogID: String) -> Int {
        guard let patch = patchBuilds.first(where: { $0.build == build }), !patch.carries.contains(backlogID) else { return build }
        return patch.base
    }
}
