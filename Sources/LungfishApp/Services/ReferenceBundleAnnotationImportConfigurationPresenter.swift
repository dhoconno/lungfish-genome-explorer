// ReferenceBundleAnnotationImportConfigurationPresenter.swift - Shared annotation import identity sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

struct ReferenceBundleAnnotationImportConfiguration: Sendable, Equatable {
    let bundleURL: URL
    let trackID: String?
    let trackName: String?
}

@MainActor
enum ReferenceBundleAnnotationImportConfigurationPresenter {
    private static let missingPresentationWindowResponse: NSApplication.ModalResponse = .alertSecondButtonReturn

    static func choose(
        projectURL: URL,
        preferredBundleURL: URL?,
        sourceURL: URL,
        presentingWindow: NSWindow?
    ) async -> ReferenceBundleAnnotationImportConfiguration? {
        await withCheckedContinuation { continuation in
            present(
                projectURL: projectURL,
                preferredBundleURL: preferredBundleURL,
                sourceURL: sourceURL,
                presentingWindow: presentingWindow
            ) { configuration in
                continuation.resume(returning: configuration)
            }
        }
    }

    static func present(
        projectURL: URL,
        preferredBundleURL: URL?,
        sourceURL: URL,
        presentingWindow: NSWindow?,
        completion: @escaping (ReferenceBundleAnnotationImportConfiguration?) -> Void
    ) {
        let choices: [ReferenceBundleChoice]
        do {
            choices = try ReferenceBundleAnnotationImportService.discoverReferenceBundles(in: projectURL)
        } catch {
            completion(nil)
            return
        }
        guard !choices.isEmpty else {
            completion(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Import Annotation Track"
        alert.informativeText = "Choose the reference bundle and annotation track identity."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let accessory = makeAccessory(
            choices: choices.map { (title: $0.displayPath, url: $0.url) },
            preferredBundleURL: preferredBundleURL,
            sourceURL: sourceURL
        )
        alert.accessoryView = accessory.view
        let popup = accessory.popup
        let trackNameField = accessory.trackNameField
        let trackIDField = accessory.trackIDField

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            complete(
                response: response,
                selectedBundleURL: popup.selectedItem?.representedObject as? URL,
                trackID: trackIDField.stringValue,
                trackName: trackNameField.stringValue,
                completion: completion
            )
        }

        if let presentingWindow = presentationWindow(preferred: presentingWindow) {
            alert.beginSheetModal(for: presentingWindow, completionHandler: finish)
        } else {
            finish(missingPresentationWindowResponse)
        }
    }

    struct Accessory {
        let view: NSView
        let popup: NSPopUpButton
        let trackNameField: NSTextField
        let trackIDField: NSTextField
    }

    /// NSAlert lays out its accessory view from the view's frame, not its
    /// constraints. The stack used to have no frame, so the alert kept its
    /// default size and the three rows drew over the message and past the
    /// alert's right edge.
    static func makeAccessory(
        choices: [(title: String, url: URL)],
        preferredBundleURL: URL?,
        sourceURL: URL
    ) -> Accessory {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
        for choice in choices {
            popup.addItem(withTitle: choice.title)
            popup.lastItem?.representedObject = choice.url
        }
        if let preferredBundleURL,
           let index = choices.firstIndex(where: { $0.url.standardizedFileURL == preferredBundleURL.standardizedFileURL }) {
            popup.selectItem(at: index)
        }

        let trackNameField = NSTextField(
            string: ReferenceBundleAnnotationImportService.defaultTrackName(for: sourceURL)
        )
        trackNameField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        trackNameField.placeholderString = "Track name"

        let trackIDField = NSTextField(
            string: ReferenceBundleAnnotationImportService.defaultTrackID(for: sourceURL)
        )
        trackIDField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        trackIDField.placeholderString = "track_id"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        func fieldRow(label: String, control: NSView) -> NSView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .right
            labelView.widthAnchor.constraint(equalToConstant: 92).isActive = true
            control.widthAnchor.constraint(equalToConstant: 360).isActive = true
            row.addArrangedSubview(labelView)
            row.addArrangedSubview(control)
            return row
        }

        stack.addArrangedSubview(fieldRow(label: "Reference", control: popup))
        stack.addArrangedSubview(fieldRow(label: "Track Name", control: trackNameField))
        stack.addArrangedSubview(fieldRow(label: "Track ID", control: trackIDField))
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return Accessory(view: stack, popup: popup, trackNameField: trackNameField, trackIDField: trackIDField)
    }

    private static func presentationWindow(preferred window: NSWindow?) -> NSWindow? {
        window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    static func complete(
        response: NSApplication.ModalResponse,
        selectedBundleURL: URL?,
        trackID: String,
        trackName: String,
        completion: (ReferenceBundleAnnotationImportConfiguration?) -> Void
    ) {
        completion(makeConfiguration(
            response: response,
            selectedBundleURL: selectedBundleURL,
            trackID: trackID,
            trackName: trackName
        ))
    }

    static func makeConfiguration(
        response: NSApplication.ModalResponse,
        selectedBundleURL: URL?,
        trackID: String,
        trackName: String
    ) -> ReferenceBundleAnnotationImportConfiguration? {
        guard response == .alertFirstButtonReturn,
              let selectedBundleURL else {
            return nil
        }
        let trimmedTrackID = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTrackName = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReferenceBundleAnnotationImportConfiguration(
            bundleURL: selectedBundleURL,
            trackID: trimmedTrackID.isEmpty ? nil : trimmedTrackID,
            trackName: trimmedTrackName.isEmpty ? nil : trimmedTrackName
        )
    }

    static func configurationForTest(
        response: NSApplication.ModalResponse,
        selectedBundleURL: URL?,
        trackID: String,
        trackName: String
    ) -> ReferenceBundleAnnotationImportConfiguration? {
        makeConfiguration(
            response: response,
            selectedBundleURL: selectedBundleURL,
            trackID: trackID,
            trackName: trackName
        )
    }

    static func completeForTest(
        response: NSApplication.ModalResponse,
        selectedBundleURL: URL?,
        trackID: String,
        trackName: String,
        completion: (ReferenceBundleAnnotationImportConfiguration?) -> Void
    ) {
        complete(
            response: response,
            selectedBundleURL: selectedBundleURL,
            trackID: trackID,
            trackName: trackName,
            completion: completion
        )
    }

    static func missingPresentationWindowResponseForTest() -> NSApplication.ModalResponse {
        missingPresentationWindowResponse
    }
}
