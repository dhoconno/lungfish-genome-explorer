// BlastContactAddress.swift - The address NCBI gets with each BLAST contact, which no record ever holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastContactAddress")

/// The rule and the words of the address a person may give NCBI for BLAST (O132, UX-BLAST-WORDS Q6).
///
/// Nothing here goes over the network, so a valid address is one of the right form and nobody has checked that it
/// receives mail. A saved address that breaks the rule is never sent, and NCBI then gets LGE's no-reply address.
package enum BlastContactAddress {
    /// What a person's text in the Settings row reads as.
    package enum Reading: Sendable, Equatable {
        case empty
        case valid
        case notValid
    }

    /// The file under `<root>/blast/`, which only ``BlastContactAddressStore`` reads and writes.
    package static let fileName = "contact-email"
    /// The longest address, in characters, once its spaces are trimmed.
    package static let maximumLength = 254
    /// The `--blast-param` names that are refused, since a value given there would land in the record and the replay.
    package static let parametersSettingsOwn: Set<String> = ["EMAIL", "TOOL"]

    private static let shape = #"^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#

    /// The address in `text` with its spaces trimmed, or nil when it is not one address of the right form.
    package static func accepted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumLength, trimmed.range(of: shape, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    /// What `text` reads as in the Settings row.
    package static func reading(of text: String) -> Reading {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return accepted(text) == nil ? .notValid : .valid
    }

    /// `text`, or a short stand-in when it repeats `address` in a spelling a page can use, so that nothing NCBI says can
    /// carry the address into a log, a word or a record.
    package static func scrubbed(_ text: String, address: String?) -> String {
        guard let address, !address.isEmpty else { return text }
        let plain = text.replacingOccurrences(of: "&#64;", with: "@")
            .replacingOccurrences(of: "&#x40;", with: "@", options: .caseInsensitive)
            .replacingOccurrences(of: "&commat;", with: "@")
        let spellings = [text, plain, text.removingPercentEncoding ?? text, plain.removingPercentEncoding ?? plain]
        return spellings.contains { $0.range(of: address, options: .caseInsensitive) != nil }
            ? "NCBI's page repeated the request, so LGE did not keep it." : text
    }

    /// The words of UX-BLAST-WORDS Q6, as written.
    package enum Words {
        package static let section = "NCBI BLAST"
        package static let label = "Contact email (optional):"
        package static let placeholder = "name@example.org"
        package static let caption = "NCBI asks BLAST tools for an address so that it can reach you if your searches cause a problem. "
            + "LGE sends this address only to NCBI, with each BLAST contact. LGE keeps it in this Mac's settings, and never in "
            + "project files, records, logs or replay commands. It is not known to make a search faster."
        package static let commandHelp = "NCBI gets the contact email set in LGE's Settings, or else LGE's shared no-reply address."
        package static let parameterRefusal = "Set the contact email in LGE's Settings, not with --blast-param. "
            + "A value given here would be kept in the record and the replay command."

        /// What the Settings row says under the field for what the person has typed.
        package static func state(_ reading: Reading) -> String {
            switch reading {
            case .empty:
                return "No address set. BLAST works the same, and NCBI gets LGE's shared no-reply address."
            case .valid:
                return "LGE sends this address to NCBI. LGE has not checked that it receives mail."
            case .notValid:
                return "This does not look like one email address, so LGE keeps sending its no-reply address. Use the form name@example.org."
            }
        }

        /// What the Settings row says when the address could not be kept.
        package static func saveFailed(_ reason: String) -> String {
            "LGE could not keep this address: \(reason) Try again, or check that the storage location is available."
        }
    }
}

/// Keeps the address in `<root>/blast/contact-email`, private to this account.
///
/// The Settings row writes it and ``BlastService`` reads it at each contact, so no flag, environment value, form on
/// disk or record ever carries it (ARCH-PLAN item 23). The address moves with the storage root, so a new root reads as
/// no address until a person sets one. A debug stand-in run reads its own state folder and never the root, so a stand-in
/// never sees a real address.
package struct BlastContactAddressStore: Sendable {
    private let fileProvider: @Sendable () async -> URL

    /// A store at `file`, as a test's.
    package init(file: URL) {
        self.fileProvider = { file }
    }

    private init(fileProvider: @escaping @Sendable () async -> URL) {
        self.fileProvider = fileProvider
    }

    /// The store under the active managed storage root, or in a debug stand-in run's own state folder.
    package static func managedStorageDefault(environment: [String: String]) -> BlastContactAddressStore {
        BlastContactAddressStore {
            let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
            return BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
                .appendingPathComponent(BlastContactAddress.fileName, isDirectory: false)
        }
    }

    /// The text as the person left it, empty when there is none. A file that cannot be read counts as none.
    package func savedText() async -> String {
        do {
            return String(decoding: try Data(contentsOf: await fileProvider()), as: UTF8.self)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        } catch {
            logger.warning("Could not read the BLAST contact address, so NCBI gets the no-reply address: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// The address to send now, or nil when none is set or what is saved breaks the rule.
    package func addressInForce() async -> String? {
        BlastContactAddress.accepted(await savedText())
    }

    /// Keeps `text` for every later contact, and spaces alone clear it. Text that breaks the rule is kept as well, so
    /// the row can show it again, and it is never sent.
    package func save(_ text: String) async throws {
        let file = await fileProvider()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            do {
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                // Nothing was set.
            }
            return
        }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DurableReplace.replace(Data(text.utf8), named: file.lastPathComponent, in: folder, beforePublish: { stage in
            guard chmod(stage.path, 0o600) == 0 else {
                // A volume with no owner modes, such as ExFAT, refuses this and the address is kept all the same.
                logger.warning("The BLAST contact address file could not be made private on this volume")
                return
            }
        })
    }
}
