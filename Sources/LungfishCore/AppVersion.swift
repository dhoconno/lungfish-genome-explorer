// AppVersion.swift - Canonical Lungfish release identity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum LungfishAppVersion {
    /// The release version of this process.
    ///
    /// Release packaging stamps `CFBundleShortVersionString` into the app after
    /// it compiles, taking the version from the newest release-notes file, so
    /// cutting a release changes no Swift source and recompiles nothing
    /// (docs/contracts/VERIFICATION-ORDER.md). A bundled `lungfish-cli` reads
    /// the app that contains it. A process without a stamped Lungfish bundle,
    /// such as `swift test` or a bare SwiftPM `lungfish-cli`, reports
    /// `developmentBaseline`.
    public static let short: String = RuntimeAppIdentityResolver.currentVersion() ?? developmentBaseline

    public static let cliToolVersion = "lungfish-cli \(short)"

    /// The version unstamped builds report. Releases never change it. Raise it
    /// only when a test or a bundled resource needs a newer floor, such as a
    /// demo project's `minimumAppVersion`, and change `MARKETING_VERSION` in
    /// Lungfish.xcodeproj and the managed-tools lock `version` with it. That
    /// is a deliberate code change, not a release step, and it changes the
    /// managed-tools manifest hash, so installed apps re-check their tools once.
    public static let developmentBaseline = "2026.10.10"

    /// `YYYY.M.PATCH` without leading zeros, the only shape a release carries.
    public static func isReleaseVersion(_ value: String) -> Bool {
        value.range(of: #"^[1-9][0-9]{3}\.([1-9]|1[0-2])\.[1-9][0-9]*$"#, options: .regularExpression) != nil
    }
}
