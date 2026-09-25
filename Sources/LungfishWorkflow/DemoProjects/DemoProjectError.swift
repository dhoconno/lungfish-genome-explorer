// DemoProjectError.swift - User-facing failures for demo project download and install
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Failures raised while listing, downloading, verifying or installing a demo project.
///
/// Every case carries a message a user can act on; the app shows
/// ``errorDescription`` in an alert and the CLI prints it.
public enum DemoProjectError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case invalidManifest(String)
    case unknownProject(String)
    case archiveNotPublished(title: String)
    case requiresNewerApp(title: String, minimumVersion: String)
    case offline
    case notFound(URL)
    case httpStatus(Int, URL)
    case network(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchive(String)
    case extractionFailed(String)
    case projectFolderMissing(String)
    case alreadyInstalled(URL)
    case projectIsOpen(URL)
    case installFailed(String)
    case cancelled

    public var description: String { errorDescription ?? "Demo project error" }

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let message):
            return message
        case .unknownProject(let id):
            return "There is no demo project called “\(id)”. Run 'lungfish-cli demo list' to see the available projects."
        case .archiveNotPublished(let title):
            return "The “\(title)” demo project has not been published yet, so there is nothing to download. Its manifest entry still has a placeholder checksum. Try again after the next Lungfish Genome Explorer update."
        case .requiresNewerApp(let title, let minimumVersion):
            return "The “\(title)” demo project needs Lungfish Genome Explorer \(minimumVersion) or later. Check for updates, then try again."
        case .offline:
            return "The demo project could not be downloaded because this Mac is not connected to the internet. Check your connection and try again."
        case .notFound(let url):
            return "The demo project archive was not found on the server (HTTP 404). It may have been moved or not yet published. URL: \(url.absoluteString)"
        case .httpStatus(let status, let url):
            return "The server refused the demo project download (HTTP \(status)). URL: \(url.absoluteString)"
        case .network(let message):
            return "The demo project download failed: \(message)"
        case .sizeMismatch(let expected, let actual):
            return "The downloaded archive is \(actual) bytes but the manifest expects \(expected) bytes. The download may be incomplete or the file on the server has changed. Nothing was installed."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded archive failed its SHA-256 check (expected \(expected), got \(actual)). The file may be damaged or has been tampered with. Nothing was installed."
        case .unsafeArchive(let message):
            return "The demo project archive was refused because it is unsafe: \(message). Nothing was installed."
        case .extractionFailed(let message):
            return "The demo project archive could not be unpacked: \(message). Nothing was installed."
        case .projectFolderMissing(let name):
            return "The demo project archive does not contain the expected project folder “\(name)”. Nothing was installed."
        case .alreadyInstalled(let url):
            return "A project already exists at \(url.path). Open it, or replace it with a fresh copy."
        case .projectIsOpen(let url):
            return "The project at \(url.path) is open in a window. Close that window before replacing it with a fresh copy."
        case .installFailed(let message):
            return "The demo project could not be installed: \(message)"
        case .cancelled:
            return "The demo project download was cancelled."
        }
    }
}
