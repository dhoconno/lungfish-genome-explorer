import AppKit
import Darwin
import Foundation

struct OperationFailureIssueEnvironment: Equatable, Sendable {
    var appVersion: String
    var operatingSystem: String
    var hardware: String

    static var current: OperationFailureIssueEnvironment {
        OperationFailureIssueEnvironment(
            appVersion: Self.bundleVersionString(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            hardware: Self.hardwareString()
        )
    }

    private static func bundleVersionString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }

    private static func hardwareString() -> String {
        let memory = ByteCountFormatter.string(
            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
            countStyle: .memory
        )
        if let model = sysctlString(named: "hw.model"), !model.isEmpty {
            return "\(model), \(memory) RAM"
        }
        return "Unknown Mac, \(memory) RAM"
    }

    private static func sysctlString(named name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

enum OperationFailureIssueReporter {
    static let repositoryIssuePath = "/dhoconno/lungfish-genome-explorer/issues/new"
    static let issueTitleLimit = 120

    static func newIssueURL(
        for item: OperationCenter.Item,
        failureReport: String,
        environment: OperationFailureIssueEnvironment = .current,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        newIssueURL(
            title: issueTitle(for: item),
            body: issueBody(
                failureReport: failureReport,
                environment: environment,
                homeDirectory: homeDirectory
            )
        )
    }

    static func blankIssueURL() -> URL? {
        newIssueURL(title: nil, body: nil)
    }

    static func issueTitle(for item: OperationCenter.Item) -> String {
        let title = "[Operation failure]: \(item.title.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard title.count > issueTitleLimit else { return title }
        return String(title.prefix(issueTitleLimit - 3)) + "..."
    }

    private static func newIssueURL(title: String?, body: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = repositoryIssuePath

        var queryItems = [
            URLQueryItem(name: "template", value: "rough_report.md"),
            URLQueryItem(name: "labels", value: "triage"),
        ]
        if let title, !title.isEmpty {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
        if let body, !body.isEmpty {
            queryItems.append(URLQueryItem(name: "body", value: body))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func issueBody(
        failureReport: String,
        environment: OperationFailureIssueEnvironment,
        homeDirectory: String
    ) -> String {
        let report = redact(failureReport, homeDirectory: homeDirectory)
        return """
        ## What happened?

        An operation failed in the Operations panel.

        ```text
        \(report)
        ```

        ## What were you trying to do?

        (Describe the workflow or input data you were using.)

        ## What did you expect?

        (Describe the expected result.)

        ## What version and Mac?

        - Lungfish Genome Explorer version: \(environment.appVersion)
        - macOS version: \(environment.operatingSystem)
        - Mac model and memory: \(environment.hardware)

        ## Logs or screenshots

        Review the Operations panel output above before submitting. Remove private paths, PHI, credentials, API keys, and unpublished data.
        """
    }

    private static func redact(_ text: String, homeDirectory: String) -> String {
        let normalizedHome = homeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedHome.isEmpty else { return text }
        let absoluteHome = "/" + normalizedHome
        return text.replacingOccurrences(of: absoluteHome, with: "~")
    }
}

@MainActor
enum GitHubIssueOpener {
    static func open(_ url: URL) {
        let uiTestConfiguration = AppUITestConfiguration.current
        if uiTestConfiguration.isEnabled {
            uiTestConfiguration.appendEvent("githubIssueOpened: \(url.absoluteString)")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
