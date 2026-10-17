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

    /// The build of this process, the `<build>` in `Lungfish <version> (<build>)`.
    ///
    /// It is the `CFBundleVersion` of the Info.plist of the Lungfish app that is
    /// running or that holds this `lungfish-cli`, and `dev` when no Lungfish
    /// plist gives one. Records name it beside ``short``, so a haplotype
    /// definition, a run bundle manifest and a run record all name the same
    /// app. It is read as `WorkflowRun.currentAppVersion` reads its build. Only
    /// a Lungfish Info.plist lends it, so a host's own, such as xctest's in a
    /// test run, never stands for Lungfish's. A test run records `dev`, never
    /// its host's build or `0`.
    public static let build: String = resolveBuild(
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        enclosingAppInfoDictionary: enclosingAppInfoDictionary(executableURL: Bundle.main.executableURL)
    )

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

    // MARK: - The build

    /// What a process without a Lungfish Info.plist records as its build.
    static let developmentBuild = "dev"

    /// ``build`` for explicit Info.plist dictionaries (testable). A dictionary
    /// that is not a Lungfish Info.plist lends no key, and the first Lungfish
    /// one whose `CFBundleVersion` is a text with something in it gives the
    /// build.
    static func resolveBuild(
        infoDictionary: [String: Any],
        enclosingAppInfoDictionary: [String: Any]? = nil
    ) -> String {
        for info in [infoDictionary, enclosingAppInfoDictionary ?? [:]] where isLungfishInfoDictionary(info) {
            if let text = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return developmentBuild
    }

    /// The identity keys of a Lungfish Info.plist. Every plist the repo ships
    /// carries `LungfishReleaseChannel`, and a fork's also carries the other
    /// two. They are the keys `RuntimeAppIdentityResolver` reads to tell
    /// Lungfish's metadata from a host's.
    private static let identityKeys = ["LungfishReleaseChannel", "LungfishRuntimeNamespace", "LungfishIdentitySchemaVersion"]

    /// Whether `info` is a Lungfish Info.plist, the app's or the identity plist
    /// its CLI embeds.
    static func isLungfishInfoDictionary(_ info: [String: Any]) -> Bool {
        identityKeys.contains { info[$0] != nil }
    }

    /// The Info.plist of the `.app` bundle containing `executableURL`
    /// (`<name>.app/Contents/MacOS/<executable>`), or nil when the executable
    /// is not inside an app bundle. Symlinks such as an installed
    /// `/usr/local/bin/lungfish-cli` are resolved first.
    static func enclosingAppInfoDictionary(executableURL: URL?) -> [String: Any]? {
        guard let executable = executableURL?.resolvingSymlinksInPath() else { return nil }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist
    }
}
