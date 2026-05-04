// IQTreeInferenceOptionsDialog.swift - IQ-TREE operation setup dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

private struct IQTreeInferenceOptionsValidationError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct IQTreeInferenceOptions: Equatable, Sendable {
    var outputName: String
    var model: String
    var sequenceType: String
    var bootstrap: Int?
    var alrt: Int?
    var seed: Int?
    var threads: Int?
    var safeMode: Bool
    var keepIdenticalSequences: Bool
    var extraIQTreeOptions: String

    static func defaults(outputName: String) -> IQTreeInferenceOptions {
        IQTreeInferenceOptions(
            outputName: outputName,
            model: "MFP",
            sequenceType: "Auto",
            bootstrap: nil,
            alrt: nil,
            seed: 1,
            threads: nil,
            safeMode: false,
            keepIdenticalSequences: false,
            extraIQTreeOptions: ""
        )
    }
}

@MainActor
enum IQTreeInferenceOptionsDialog {
    @MainActor
    private final class Controls {
        let outputNameField = NSTextField()
        let modelField = NSTextField(string: "MFP")
        let sequenceTypePopup = NSPopUpButton()
        let bootstrapCheckbox = NSButton(checkboxWithTitle: "Ultrafast Bootstrap", target: nil, action: nil)
        let bootstrapField = NSTextField(string: "1000")
        let alrtCheckbox = NSButton(checkboxWithTitle: "SH-aLRT", target: nil, action: nil)
        let alrtField = NSTextField(string: "1000")
        let seedField = NSTextField(string: "1")
        let threadsField = NSTextField()
        let safeCheckbox = NSButton(checkboxWithTitle: "Safe numerical mode", target: nil, action: nil)
        let keepIdenticalCheckbox = NSButton(checkboxWithTitle: "Keep identical sequences", target: nil, action: nil)
        let advancedDisclosure = NSButton(title: "Advanced Options", target: nil, action: nil)
        let advancedField = NSTextField()
        let advancedHelp = NSTextField(labelWithString: "IQ-TREE Parameters are passed directly after the curated options.")

        init(defaults: IQTreeInferenceOptions) {
            outputNameField.stringValue = defaults.outputName
            outputNameField.setAccessibilityIdentifier("iqtree-options-output-name")
            modelField.stringValue = defaults.model
            modelField.setAccessibilityIdentifier("iqtree-options-model")
            sequenceTypePopup.addItems(withTitles: ["Auto", "DNA", "AA", "CODON", "BIN", "MORPH", "NT2AA"])
            sequenceTypePopup.selectItem(withTitle: defaults.sequenceType)
            sequenceTypePopup.setAccessibilityIdentifier("iqtree-options-sequence-type")
            bootstrapCheckbox.state = defaults.bootstrap == nil ? .off : .on
            bootstrapCheckbox.setAccessibilityIdentifier("iqtree-options-bootstrap-checkbox")
            if let bootstrap = defaults.bootstrap {
                bootstrapField.stringValue = String(bootstrap)
            }
            bootstrapField.setAccessibilityIdentifier("iqtree-options-bootstrap-count")
            alrtCheckbox.state = defaults.alrt == nil ? .off : .on
            alrtCheckbox.setAccessibilityIdentifier("iqtree-options-alrt-checkbox")
            if let alrt = defaults.alrt {
                alrtField.stringValue = String(alrt)
            }
            alrtField.setAccessibilityIdentifier("iqtree-options-alrt-count")
            seedField.stringValue = defaults.seed.map(String.init) ?? ""
            seedField.setAccessibilityIdentifier("iqtree-options-seed")
            threadsField.placeholderString = "Auto"
            if let threads = defaults.threads {
                threadsField.stringValue = String(threads)
            }
            threadsField.setAccessibilityIdentifier("iqtree-options-threads")
            safeCheckbox.state = defaults.safeMode ? .on : .off
            safeCheckbox.setAccessibilityIdentifier("iqtree-options-safe-mode")
            keepIdenticalCheckbox.state = defaults.keepIdenticalSequences ? .on : .off
            keepIdenticalCheckbox.setAccessibilityIdentifier("iqtree-options-keep-identical")
            advancedDisclosure.setButtonType(.pushOnPushOff)
            advancedDisclosure.bezelStyle = .disclosure
            advancedDisclosure.setAccessibilityIdentifier("iqtree-options-advanced-disclosure")
            advancedField.stringValue = defaults.extraIQTreeOptions
            advancedField.placeholderString = "-bnni --pathogen"
            advancedField.setAccessibilityIdentifier("iqtree-options-advanced-parameters")
            advancedField.isHidden = true
            advancedHelp.isHidden = true
        }
    }

    static func present(
        suggestedOutputName: String,
        window: NSWindow?,
        completion: @escaping (IQTreeInferenceOptions?) -> Void
    ) {
        let defaults = IQTreeInferenceOptions.defaults(outputName: suggestedOutputName)
        let controls = Controls(defaults: defaults)
        let alert = NSAlert()
        alert.messageText = "Build Tree with IQ-TREE"
        alert.informativeText = "Configure common IQ-TREE settings before creating a native .lungfishtree bundle."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = makeAccessoryView(controls: controls)

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            do {
                completion(try options(from: controls))
            } catch {
                presentValidationError(error, window: window)
                completion(nil)
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private static func makeAccessoryView(controls: Controls) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [label("Output Name"), controls.outputNameField],
            [label("Model"), controls.modelField],
            [label("Sequence Type"), controls.sequenceTypePopup],
            [label("Branch Support"), supportControls(controls)],
            [label("Seed"), controls.seedField],
            [label("Threads"), controls.threadsField],
            [NSView(), controls.safeCheckbox],
            [NSView(), controls.keepIdenticalCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        stack.addArrangedSubview(grid)

        controls.advancedDisclosure.target = AdvancedDisclosureTarget.shared
        controls.advancedDisclosure.action = #selector(AdvancedDisclosureTarget.toggle(_:))
        AdvancedDisclosureTarget.shared.register(
            disclosure: controls.advancedDisclosure,
            views: [controls.advancedField, controls.advancedHelp],
            stack: stack
        )
        stack.addArrangedSubview(controls.advancedDisclosure)
        stack.addArrangedSubview(controls.advancedField)
        stack.addArrangedSubview(controls.advancedHelp)
        controls.advancedHelp.textColor = .secondaryLabelColor
        controls.advancedHelp.font = .systemFont(ofSize: 11)

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 430),
            controls.outputNameField.widthAnchor.constraint(equalToConstant: 260),
            controls.modelField.widthAnchor.constraint(equalToConstant: 260),
            controls.seedField.widthAnchor.constraint(equalToConstant: 120),
            controls.threadsField.widthAnchor.constraint(equalToConstant: 120),
            controls.advancedField.widthAnchor.constraint(equalToConstant: 410),
        ])
        return stack
    }

    private static func supportControls(_ controls: Controls) -> NSView {
        let stack = NSStackView(views: [
            controls.bootstrapCheckbox,
            controls.bootstrapField,
            controls.alrtCheckbox,
            controls.alrtField,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        controls.bootstrapField.widthAnchor.constraint(equalToConstant: 58).isActive = true
        controls.alrtField.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return stack
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private static func options(from controls: Controls) throws -> IQTreeInferenceOptions {
        let outputName = controls.outputNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outputName.isEmpty == false else {
            throw IQTreeInferenceOptionsValidationError(message: "Output Name is required.")
        }
        let model = controls.modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty == false else {
            throw IQTreeInferenceOptionsValidationError(message: "Model is required.")
        }
        let bootstrap = try optionalPositiveInteger(
            controls.bootstrapCheckbox.state == .on ? controls.bootstrapField.stringValue : "",
            label: "Ultrafast Bootstrap"
        )
        let alrt = try optionalPositiveInteger(
            controls.alrtCheckbox.state == .on ? controls.alrtField.stringValue : "",
            label: "SH-aLRT"
        )
        let seed = try optionalPositiveInteger(controls.seedField.stringValue, label: "Seed")
        let threads = try optionalPositiveInteger(controls.threadsField.stringValue, label: "Threads")
        let advanced = controls.advancedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try AdvancedCommandLineOptions.parse(advanced)

        return IQTreeInferenceOptions(
            outputName: outputName,
            model: model,
            sequenceType: controls.sequenceTypePopup.titleOfSelectedItem ?? "Auto",
            bootstrap: bootstrap,
            alrt: alrt,
            seed: seed,
            threads: threads,
            safeMode: controls.safeCheckbox.state == .on,
            keepIdenticalSequences: controls.keepIdenticalCheckbox.state == .on,
            extraIQTreeOptions: advanced
        )
    }

    private static func optionalPositiveInteger(_ text: String, label: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let value = Int(trimmed), value > 0 else {
            throw IQTreeInferenceOptionsValidationError(message: "\(label) must be a positive integer.")
        }
        return value
    }

    private static func presentValidationError(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Invalid IQ-TREE Options"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
private final class AdvancedDisclosureTarget: NSObject {
    static let shared = AdvancedDisclosureTarget()

    private struct Registration {
        weak var field: NSTextField?
        weak var help: NSTextField?
        weak var stack: NSStackView?
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]

    func register(disclosure: NSButton, views: [NSView], stack: NSStackView) {
        registrations[ObjectIdentifier(disclosure)] = Registration(
            field: views.first as? NSTextField,
            help: views.dropFirst().first as? NSTextField,
            stack: stack
        )
    }

    @objc func toggle(_ sender: NSButton) {
        let isExpanded = sender.state == .on
        guard let registration = registrations[ObjectIdentifier(sender)] else { return }
        registration.field?.isHidden = !isExpanded
        registration.help?.isHidden = !isExpanded
        registration.stack?.layoutSubtreeIfNeeded()
    }
}
